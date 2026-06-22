// Журнал операций (op-log), идентичный по СМЫСЛУ десктопу (qtnotes/sync/oplog.py).
//
// Бэкенд хранения здесь — JSON-файл (а не SQLite), это локальная деталь устройства.
// Формат самих операций на проводе совпадает с протоколом:
//   {op_id:"<device>:<lamport>", device_id, lamport, wall, kind, entity_id, payload}
// Версионный вектор vv = {device_id: max_lamport}. Часы Лампорта: новый lamport =
// max(всех известных)+1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/crypto_fs.dart' as cfs;
import '../storage/models.dart' show nowIso;

class OpLog {
  final File file;
  String localId; // device_id этого устройства (ставит движок)
  void Function()? changeListener;

  final List<Map<String, dynamic>> _ops = [];
  final Set<String> _opIds = {};
  final Map<String, int> _clock = {};
  final Map<String, String> _meta = {};
  // H4: tombstones — «часы удаления» на сущность {entity_id: {wall, lamport, device_id}}.
  // Весь файл оплога шифруется крипто-слоем, поэтому entity_id храним как есть.
  final Map<String, Map<String, dynamic>> _tombstones = {};
  bool _loaded = false;
  int _appendsSinceCompact = 0;
  static const int _kCompactEvery = 200;

  // Сериализующий лок (аналог `with _lock` в oplog.py): мутаторы не должны
  // переплетаться на await-точках в одном изоляте (recordRemote из движка + appendLocal
  // из UI). Без него откат частичного состояния был бы небезопасен.
  Future<void> _mx = Future<void>.value();
  Future<T> _withLock<T>(Future<T> Function() body) {
    final prev = _mx;
    final gate = Completer<void>();
    _mx = gate.future;
    return prev.then((_) => body()).whenComplete(gate.complete);
  }

  OpLog(this.file, {this.localId = ''});

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      // файл оплога шифруется целиком крипто-слоем (содержит текст заметок в payload)
      final raw = await cfs.readBytesEnc(file, file.parent);
      if (raw != null) {
        final data = (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>();
        for (final o in (data['ops'] ?? []) as List) {
          final op = (o as Map).cast<String, dynamic>();
          _ops.add(op);
          _opIds.add(op['op_id'] as String);
        }
        ((data['clock'] ?? {}) as Map).forEach((k, v) => _clock[k as String] = v as int);
        ((data['meta'] ?? {}) as Map).forEach((k, v) => _meta[k as String] = v as String);
        ((data['tombstones'] ?? {}) as Map).forEach((k, v) =>
            _tombstones[k as String] = (v as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // повреждённый журнал — начинаем с пустого (он перестраиваемый кэш)
    }
  }

  Future<void> _save() => _saveState(_ops, _clock, _meta, _tombstones);

  // Записать ЯВНО переданное состояние (диск раньше памяти): мутаторы сначала пишут
  // прожективное состояние сюда, и лишь при успехе коммитят его в живые структуры.
  Future<void> _saveState(List<Map<String, dynamic>> ops, Map<String, int> clock,
      Map<String, String> meta, Map<String, Map<String, dynamic>> tombstones) async {
    await cfs.writeBytesEnc(
        file,
        utf8.encode(jsonEncode(
            {'ops': ops, 'clock': clock, 'meta': meta, 'tombstones': tombstones})),
        file.parent);
  }

  // Копия tombstones, дополненная удалением из op (если это .del и оно новее). Чистая
  // функция: не трогает живой _tombstones, чтобы можно было сперва записать на диск.
  Map<String, Map<String, dynamic>> _tombsWith(Map<String, dynamic> op) {
    final copy = {
      for (final e in _tombstones.entries) e.key: Map<String, dynamic>.from(e.value)
    };
    if ((op['kind'] as String).endsWith('.del')) {
      final eid = op['entity_id'] as String;
      final wall = op['wall'] as String;
      final lam = (op['lamport'] as num).toInt();
      final dev = op['device_id'] as String;
      final ex = copy[eid];
      if (ex == null ||
          _cmpClock(wall, lam, dev, ex['wall'] as String,
                  (ex['lamport'] as num).toInt(), ex['device_id'] as String) >
              0) {
        copy[eid] = {'wall': wall, 'lamport': lam, 'device_id': dev};
      }
    }
    return copy;
  }

  /// (wall, lamport, device_id) сравнение: >0 если первый «новее».
  int _cmpClock(String w1, int l1, String d1, String w2, int l2, String d2) {
    var c = w1.compareTo(w2);
    if (c != 0) return c;
    c = l1.compareTo(l2);
    if (c != 0) return c;
    return d1.compareTo(d2);
  }

  /// Часы удаления сущности {wall, lamport, device_id} или null.
  Map<String, dynamic>? tombstoneFor(String entityId) => _tombstones[entityId];

  int _nextLamport() {
    var base = 0;
    for (final v in _clock.values) {
      if (v > base) base = v;
    }
    return base + 1;
  }

  Future<String> appendLocal(String kind, String entityId, Map<String, dynamic>? payload) async {
    await _ensureLoaded();
    if (localId.isEmpty) throw StateError('OpLog.localId не задан');
    final opId = await _withLock<String>(() async {
      final lam = _nextLamport();
      final id = '$localId:$lam';
      final op = {
        'op_id': id, 'device_id': localId, 'lamport': lam, 'wall': nowIso(),
        'kind': kind, 'entity_id': entityId, 'payload': payload,
      };
      // прожективное состояние → диск → и только при успехе коммит в память
      final newOps = [..._ops, op];
      final newClock = Map<String, int>.from(_clock);
      if (lam > (newClock[localId] ?? 0)) newClock[localId] = lam;
      final newTombs = _tombsWith(op);
      await _saveState(newOps, newClock, _meta, newTombs);
      _ops.add(op);
      _opIds.add(id);
      _clock
        ..clear()
        ..addAll(newClock);
      _tombstones
        ..clear()
        ..addAll(newTombs);
      _appendsSinceCompact++;
      return id;
    });
    await maybeCompact(); // B1: амортизированная подрезка истории (сама под локом)
    changeListener?.call();
    return opId;
  }

  /// Есть ли уже такая операция (дедуп до применения, H5).
  Future<bool> hasOp(String opId) async {
    await _ensureLoaded();
    return _opIds.contains(opId);
  }

  Future<bool> recordRemote(Map<String, dynamic> op) async {
    await _ensureLoaded();
    return _withLock<bool>(() async {
      final opId = op['op_id'] as String;
      if (_opIds.contains(opId)) return false;
      // прожективное состояние → диск → и только при успехе коммит в память
      final newOps = [..._ops, op];
      final newClock = Map<String, int>.from(_clock);
      final dev = op['device_id'] as String;
      final lam = (op['lamport'] as num).toInt();
      if (lam > (newClock[dev] ?? 0)) newClock[dev] = lam;
      final newTombs = _tombsWith(op);
      await _saveState(newOps, newClock, _meta, newTombs);
      _ops.add(op);
      _opIds.add(opId);
      _clock
        ..clear()
        ..addAll(newClock);
      _tombstones
        ..clear()
        ..addAll(newTombs);
      return true;
    });
  }

  Future<Map<String, int>> versionVector() async {
    await _ensureLoaded();
    return Map<String, int>.from(_clock);
  }

  Future<List<Map<String, dynamic>>> opsSince(Map<String, int> remoteVv) async {
    await _ensureLoaded();
    final out = _ops.where((op) {
      final d = op['device_id'] as String;
      final th = remoteVv[d] ?? 0;
      return (op['lamport'] as num).toInt() > th;
    }).toList();
    out.sort((a, b) {
      final c = (a['lamport'] as num).compareTo(b['lamport'] as num);
      return c != 0 ? c : (a['device_id'] as String).compareTo(b['device_id'] as String);
    });
    return out;
  }

  Future<List<Map<String, dynamic>>> allOps() async {
    await _ensureLoaded();
    return List<Map<String, dynamic>>.from(_ops);
  }

  // --- компакция (B1, раунд-3) -------------------------------------------------
  // Журнал хранит полный снимок сущности на каждый put → растёт без границ, и на
  // мобилке _save переписывает весь файл на каждую правку. Компакция оставляет по
  // сущности только op-победителя (LWW по modified для заметок, (lamport,device) для
  // папок/событий, tombstone для удалений) — как apply.dart/oplog.py. _clock (vv) и
  // _tombstones НЕ трогаются → сходимость сохранна; свежий пир получает по сущности
  // ровно победителя. Воскрешение (put новее удаления) консервативно не компактим.

  String? _modOf(Map<String, dynamic> op) {
    final p = op['payload'];
    if (p is Map && p['modified'] is String) return p['modified'] as String;
    return null;
  }

  Map<String, dynamic> _bestPut(List<Map<String, dynamic>> puts) {
    puts.sort((a, b) {
      var c = (_modOf(a) ?? '').compareTo(_modOf(b) ?? '');
      if (c != 0) return c;
      c = (a['lamport'] as num).compareTo(b['lamport'] as num);
      if (c != 0) return c;
      return (a['device_id'] as String).compareTo(b['device_id'] as String);
    });
    return puts.last; // максимум
  }

  Map<String, dynamic>? _winnerOrNone(List<Map<String, dynamic>> ops) {
    final dels = ops.where((o) => (o['kind'] as String).endsWith('.del')).toList();
    final puts = ops.where((o) => !(o['kind'] as String).endsWith('.del')).toList();
    if (dels.isNotEmpty) {
      var strongest = dels.first;
      for (final d in dels.skip(1)) {
        if (_cmpClock(d['wall'] as String, (d['lamport'] as num).toInt(),
                d['device_id'] as String, strongest['wall'] as String,
                (strongest['lamport'] as num).toInt(), strongest['device_id'] as String) >
            0) {
          strongest = d;
        }
      }
      final tw = strongest['wall'] as String,
          tl = (strongest['lamport'] as num).toInt(),
          td = strongest['device_id'] as String;
      final survivors = puts.where((o) =>
          _cmpClock(o['wall'] as String, (o['lamport'] as num).toInt(),
              o['device_id'] as String, tw, tl, td) >
          0);
      if (survivors.isNotEmpty) return null; // воскрешение — не компактим
      return strongest;
    }
    return puts.isNotEmpty ? _bestPut(puts) : null;
  }

  /// Схлопнуть журнал до победителя на сущность. Возвращает число удалённых ops.
  Future<int> compact() async {
    await _ensureLoaded();
    return _withLock<int>(() async {
      final byEntity = <String, List<Map<String, dynamic>>>{};
      for (final op in _ops) {
        (byEntity[op['entity_id'] as String] ??= []).add(op);
      }
      final remove = <String>{};
      byEntity.forEach((_, group) {
        if (group.length < 2) return;
        final w = _winnerOrNone(group);
        if (w == null) return;
        for (final op in group) {
          if (op['op_id'] != w['op_id']) remove.add(op['op_id'] as String);
        }
      });
      if (remove.isEmpty) return 0;
      // диск раньше памяти: пишем подрезанный список, и лишь при успехе коммитим
      final newOps = _ops.where((op) => !remove.contains(op['op_id'])).toList();
      await _saveState(newOps, _clock, _meta, _tombstones);
      _ops
        ..clear()
        ..addAll(newOps);
      _opIds.removeAll(remove);
      return remove.length;
    });
  }

  Future<int> maybeCompact() async {
    if (_appendsSinceCompact < _kCompactEvery) return 0;
    _appendsSinceCompact = 0;
    return compact();
  }

  Future<String?> getMeta(String key) async {
    await _ensureLoaded();
    return _meta[key];
  }

  Future<void> setMeta(String key, String value) async {
    await _ensureLoaded();
    await _withLock<void>(() async {
      final newMeta = Map<String, String>.from(_meta)..[key] = value;
      await _saveState(_ops, _clock, newMeta, _tombstones);
      _meta
        ..clear()
        ..addAll(newMeta);
    });
  }

  /// Перечитать и перезаписать журнал (для миграции: при включённом шифровании
  /// _save пишет зашифрованно).
  Future<void> resave() async {
    await _ensureLoaded();
    await _save();
  }
}
