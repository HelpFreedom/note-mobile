// Оркестратор синхронизации на Dart (по docs/sync-protocol.md, как engine.py).
//
// Сессия: обе стороны шлют hello+have, на have отвечают порцией ops, на ops —
// докачкой недостающих blobs. Соединение держится для push-on-change. На пир — одно
// соединение (инициирует устройство с меньшим device_id). Доступ к данным — через
// SyncStore; доверенные устройства — через getPeers.

import 'dart:async';
import 'dart:io';

import 'identity.dart';
import 'peers.dart';
import 'store.dart';
import 'transport.dart' as tp;
import 'wire.dart';

const int _kMaxWantBlobs = 4096; // H6: потолок числа блобов на один запрос want_blobs
const int kProtoVersion = 1; // версия протокола синка (hello.proto)

class Session {
  final SyncEngine engine;
  final SecureSocket socket;
  final String peerId;
  final ByteReader reader;
  Map<String, int> peerVv = {};
  bool _closed = false;
  // Завершается, когда цикл чтения вышел (in-flight recordAndApply/writeBlob дошли до
  // конца). stop() дожидается этого, чтобы lock() забыл MK уже после «успокоения» движка.
  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;
  // сериализация записи: start() и push() могут писать в один сокет одновременно —
  // без этого кадры перемешаются и соединение порвётся (в Dart нет Lock — цепочка).
  Future<void> _writeChain = Future.value();

  Session(this.engine, this.socket, this.peerId) : reader = ByteReader(socket);

  Future<void> _locked(Future<void> Function() action) {
    final next = _writeChain.then((_) => action());
    _writeChain = next.catchError((_) {}); // цепочка не должна рваться на ошибке
    return next;
  }

  Future<void> _send(Map<String, dynamic> obj) => _locked(() async {
        writeMessage(socket, obj);
        await socket.flush();
      });

  Future<void> start() async {
    try {
      await _send({
        'type': 'hello',
        'device_id': engine.identity.deviceId,
        'name': engine.identity.name,
        'proto': 1,
      });
      await _send({'type': 'have', 'vv': await engine.store.versionVector()});
      while (!_closed) {
        final f = await readFrame(reader);
        if (!f.isControl) {
          if (await engine.store.writeBlob(f.blobSha!, f.blobData!)) {
            engine.notifyChanged();
          }
        } else {
          await _dispatch(f.control!);
        }
      }
    } catch (_) {
      // обрыв/ошибка протокола — закрываем сессию
    } finally {
      close();
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> _dispatch(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'hello':
        if (msg['device_id'] != null && msg['device_id'] != peerId) {
          close();
          return;
        }
        if (msg['proto'] != kProtoVersion) {
          // A2: версии протокола различаются. НЕ закрываем — throw на неизвестный kind
          // (apply.dart) гарантирует, что непонятая op переиграется после апгрейда, а не
          // потеряется. Знакомые ops синкаются как обычно.
          // ignore: avoid_print
          print('[sync] пир $peerId на proto=${msg['proto']}, у нас $kProtoVersion'
              ' — частичная совместимость (незнакомые ops отложатся до апгрейда)');
        }
        break;
      case 'have':
        peerVv = (msg['vv'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toInt()));
        final ops = await engine.store.opsSince(peerVv);
        if (ops.isNotEmpty) await _send({'type': 'ops', 'ops': ops});
        peerVv = await engine.store.versionVector();
        break;
      case 'ops':
        var changed = false;
        final missing = <String>[];
        for (final raw in (msg['ops'] as List)) {
          final op = (raw as Map).cast<String, dynamic>();
          // H5: одна битая op не должна рвать сессию и ронять остальные ops.
          try {
            if (await engine.store.recordAndApply(op)) changed = true;
            missing.addAll(await engine.store.missingBlobHashes(op));
          } catch (e) {
            // op не записана (vv не сдвинут) → повтор при следующем синке
            // ignore: avoid_print
            print('[sync] пропуск битой op ${op['op_id']}: $e');
          }
        }
        if (missing.isNotEmpty) {
          await _send({'type': 'want_blobs', 'hashes': missing.toSet().toList()});
        }
        if (changed) {
          engine.notifyChanged();
          // A1: подтвердить отправителю реально применённое (наш свежий vv). Пропущенные
          // ops (apply бросил — пир залочился и т.п.) наш vv не покрывает → отправитель
          // пере-предложит. При changed=false (всё пропущено/дубликаты) have НЕ шлём →
          // нет бесконечного цикла на «ядовитой» op.
          await _send({'type': 'have', 'vv': await engine.store.versionVector()});
        }
        break;
      case 'want_blobs':
        // H6: потолок числа блобов на запрос (защита от усилителя); лишнее до-запросится
        final reqHashes = (msg['hashes'] as List);
        final hashes = reqHashes.length > _kMaxWantBlobs
            ? reqHashes.sublist(0, _kMaxWantBlobs)
            : reqHashes;
        for (final h in hashes) {
          final data = await engine.store.readBlob(h as String);
          if (data != null) {
            await _locked(() async {
              writeBlob(socket, h, data);
              await socket.flush();
            });
          }
        }
        break;
      case 'bye':
        close();
        break;
    }
  }

  Future<void> push() async {
    final ops = await engine.store.opsSince(peerVv);
    if (ops.isEmpty) return;
    try {
      await _send({'type': 'ops', 'ops': ops});
      peerVv = await engine.store.versionVector();
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      socket.destroy();
    } catch (_) {}
    engine._removeSession(this);
  }
}

class SyncEngine {
  final Identity identity;
  final SyncStore store;
  final Future<List<Peer>> Function() getPeers;
  final void Function()? onChanged;
  final Map<String, Session> sessions = {};
  SecureServerSocket? _server;
  // E2 (паритет с десктопом): слоты «сейчас дозваниваемся» — резервируются СИНХРОННо в
  // connect() до await, чтобы всплеск mDNS не плодил параллельные соединения к пиру
  // (которые рвут друг друга в _runSession). Кулдаун гасит тугой цикл повторов при сбое.
  final Set<String> _connecting = {};
  final Map<String, int> _lastAttemptMs = {};
  static const int _reconnectCooldownMs = 3000;

  SyncEngine(this.identity, this.store, {required this.getPeers, this.onChanged});

  int? get port => _server?.port;

  void notifyChanged() => onChanged?.call();

  void _removeSession(Session s) {
    if (sessions[s.peerId] == s) {
      sessions.remove(s.peerId);
      notifyChanged(); // обновить статус «онлайн» в UI
    }
  }

  Future<List<String>> _trustedPems() async =>
      (await getPeers()).map((p) => p.certPem).where((c) => c.isNotEmpty).toList();

  Future<String?> _peerCert(String deviceId) async {
    for (final p in await getPeers()) {
      if (p.deviceId == deviceId) return p.certPem;
    }
    return null;
  }

  Future<void> serve({String host = '0.0.0.0', int port = 0}) async {
    _server = await tp.startServer(identity, await _trustedPems(), host: host, port: port);
    _server!.listen(_onIncoming, onError: (Object _) {});
  }

  Future<void> _onIncoming(SecureSocket socket) async {
    final pid = tp.peerDeviceId(socket);
    if (pid == null || await _peerCert(pid) == null) {
      socket.destroy();
      return;
    }
    _runSession(socket, pid);
  }

  Future<void> connect(String host, int port, String peerId) async {
    // E2: не открывать второе соединение к пиру и гасить шторм параллельных connect от
    // всплесков mDNS — слот резервируется СИНХРОННо (до первого await).
    if (sessions.containsKey(peerId) || _connecting.contains(peerId)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_lastAttemptMs[peerId] ?? 0) < _reconnectCooldownMs) return;
    _lastAttemptMs[peerId] = now;
    _connecting.add(peerId);
    try {
      final cert = await _peerCert(peerId);
      if (cert == null) throw StateError('пир не в списке доверенных');
      final socket = await tp.connect(host, port, identity, fingerprintFromCertPem(cert));
      _runSession(socket, peerId);
    } finally {
      _connecting.remove(peerId); // слот свободен (сессия зарегистрирована или не открылась)
    }
  }

  void _runSession(SecureSocket socket, String peerId) {
    sessions[peerId]?.close();
    final s = Session(this, socket, peerId);
    sessions[peerId] = s;
    notifyChanged(); // обновить статус «онлайн» в UI
    s.start(); // фоново; читает до закрытия
  }

  Future<void> pushAll() async {
    for (final s in sessions.values.toList()) {
      await s.push();
    }
  }

  Future<void> stop() async {
    final live = sessions.values.toList();
    for (final s in live) {
      s.close();
    }
    // Дождаться завершения циклов чтения: in-flight recordAndApply/applyOp/writeBlob
    // дойдут до конца ДО возврата stop(). Тогда AppService.lock() забывает MK уже после
    // «успокоения» движка — входящая op не пишется в заблокированное хранилище.
    // Таймаут — страховка от зависшего await, чтобы блокировка не подвисла.
    await Future.wait(live.map(
        (s) => s.done.timeout(const Duration(seconds: 3), onTimeout: () {})));
    await _server?.close();
    _server = null;
  }
}
