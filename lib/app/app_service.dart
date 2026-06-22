// Центральный сервис: инициализация хранилища, жизненный цикл синка, настройки.
// ChangeNotifier — экраны перерисовываются при изменениях (локальных и удалённых).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../crypto/crypto_fs.dart' as cfs;
import '../crypto/duress.dart';
import '../crypto/keystore.dart';
import '../crypto/keyvault.dart' as kv;
import '../crypto/session.dart' as crypto_session;
import '../crypto/unlock.dart';
import '../storage/models.dart';
import '../storage/search_index.dart';
import '../ui/theme.dart' show AppColors;
import '../storage/vault.dart';
import '../sync/apply.dart';
import '../sync/discovery.dart';
import '../sync/engine.dart';
import '../sync/identity.dart';
import '../sync/oplog.dart';
import '../sync/pairing.dart';
import '../sync/peers.dart';
import '../sync/store.dart';
import 'repository.dart';

/// Глобальный экземпляр (инициализируется в main). Экраны обращаются через него.
late AppService appService;

class AppService extends ChangeNotifier {
  final Directory root;
  final Directory? cacheRoot; // G2: app-private cache для расшифрованного кэша медиа
  late final Vault vault;
  late final OpLog oplog;
  late final Repository repo;
  late final PeerStore peers;
  Identity? _identity;
  SyncEngine? _engine;
  Discovery? _discovery;
  bool _syncEnabled = false;
  String syncStatus = 'Синхронизация выключена';
  // известные адреса пиров (из QR) для прямого подключения в обход mDNS
  Map<String, Map<String, dynamic>> _peerAddrs = {};
  Timer? _reconnectTimer;
  // тема, синхронизированная с десктопа (палитра + обои); null = встроенная
  Map<String, Color>? syncedColors;
  File? wallpaper;
  String? _lastThemeKey;

  AppService(this.root, {this.cacheRoot});

  bool get syncEnabled => _syncEnabled;
  Identity get identity => _identity!;

  // --- локальное шифрование ---
  UnlockController? _unlock;
  bool _locked = false;
  bool get isLocked => _locked;
  UnlockController get unlockController => _unlock!;
  // keyring — вне vault (per-device, не синхронизируется)
  Directory get _keyringDir => Directory('${root.parent.path}/qtnotes_keyring');

  File get _settingsFile => File('${root.path}/app_settings.json');
  File get _peerAddrsFile => File('${root.path}/peer_addrs.json');
  Directory get _deviceDir => Directory('${root.path}/device');
  File get _deviceKeyFile => File('${_deviceDir.path}/device_key.pem');

  /// Если приватный ключ синка лежит плейнтекстом, а шифрование включено и
  /// разблокировано — перешифровать его at-rest под MK. Идемпотентно.
  Future<void> _ensureDeviceKeyEncrypted() async {
    if (!crypto_session.Session.encryptionEnabled ||
        !crypto_session.Session.isUnlocked) {
      return;
    }
    if (!await _deviceKeyFile.exists()) return;
    final raw = await _deviceKeyFile.readAsBytes();
    if (cfs.startsWithMagic(raw)) return; // уже зашифрован
    await cfs.writeBytesEnc(_deviceKeyFile, raw, root); // плейнтекст → шифртекст
  }

  /// Догрузить приватный ключ в личность после разблокировки (при старте-locked он был
  /// недоступен: device_id берётся из cert, ключ — позже).
  Future<void> _refreshIdentityKey() async {
    if (_identity != null && _identity!.keyAvailable) return;
    _identity = await ensureIdentity(_deviceDir, _deviceName());
  }

  Future<void> init() async {
    vault = Vault(root, blobCacheRoot: cacheRoot);
    peers = PeerStore(File('${root.path}/peers.json'));
    _identity = await ensureIdentity(_deviceDir, _deviceName());
    oplog = OpLog(File('${root.path}/sync.json'), localId: _identity!.deviceId);
    repo = Repository(vault, oplog);
    await _loadSettings();
    await _loadPeerAddrs();

    // шифрование: если ПИН настроен — блокируем до ввода ПИНа (данные шифрованы).
    // Бэкенд выбирается по флагу biometric: при включённой биометрии — ключ с
    // аппаратной аутентификацией устройства (setUserAuthenticationRequired).
    _unlock = UnlockController(
        File('${_keyringDir.path}/keyring.json'),
        (bio) => KeystoreHardwareKey(
            alias: bio ? keystoreAliasAuth : keystoreAliasPlain, requireAuth: bio));
    _unlock!.onDuress = _runDuress; // обратный ПИН → стирание + подложка
    _unlock!.integrityMac = Keystore.keyringMac; // H9: MAC keyring под non-auth Keystore
    // D2: маркер «MAC включался» = существование Keystore-алиаса. Делает проверку
    // целостности fail-closed (срезание поля mac/удаление ключа → блокировка).
    _unlock!.macEverEnabled = () => Keystore.hasKey(keystoreAliasKeyringMac);
    crypto_session.Session.encryptionEnabled = await _unlock!.isConfigured();
    _locked = crypto_session.Session.encryptionEnabled;
    if (!_locked) {
      await _afterUnlockLoad();
    } else {
      // Заблокированы при старте → стереть расшифрованный кэш медиа прошлой сессии:
      // в заблокированном состоянии плейнтекста на диске быть не должно.
      await vault.wipeBlobCache();
    }
    unawaited(_cleanupStaleMigrationBackups()); // G3: подмести бэкапы прерванной миграции
  }

  /// Заблокировать приложение: забыть MK и стереть расшифрованный кэш медиа (плейнтекст
  /// не должен оставаться на диске после блокировки).
  Future<void> lock() async {
    // ВАЖНО: остановить движок синка ПЕРЕД забвением MK. Иначе сессия остаётся живой,
    // а входящие op'ы пишутся в зашифрованный oplog при отсутствии MK → VaultLocked →
    // op молча теряется (напр. удаление с десктопа не доходит). После разблокировки
    // движок поднимается заново и доберёт пропущенное чистым ре-синком (have-обмен).
    await _stopEngine();
    crypto_session.Session.lock();
    await vault.wipeBlobCache();
    vault.clearNotesCache(); // плейнтекст заметок не должен жить в памяти после блокировки
    _searchIndex = null; // плейнтекст-индекс не должен жить в памяти после блокировки
    _indexBuilding = null;
    _locked = true;
    notifyListeners();
  }

  // G1-fix (раунд-3): подавление авто-lock на время СИСТЕМНОГО пикера/диалога. Открытие
  // file/image-picker уводит приложение в paused — без этого флага оно бы залочилось и
  // возврат из пикера падал бы («запись blob при заблокированном хранилище»).
  // СЧЁТЧИК (не bool): вложенные/перекрывающиеся внешние активности (пикер + шаринг)
  // корректны — подавление держится до ПОСЛЕДНЕГО end. Утёкший begin без end (например,
  // если внешний вызов бросил без finally) самовосстанавливается на resume (onResumed),
  // иначе авто-lock отключился бы на всю сессию → плейнтекст при каждом сворачивании.
  int _externalDepth = 0;
  void beginExternalActivity() => _externalDepth++;
  void endExternalActivity() {
    if (_externalDepth > 0) _externalDepth--;
  }

  /// Возврат приложения на передний план: внешняя активность завершена → сброс счётчика
  /// (страховка от утёкшего begin). Вызывается из didChangeAppLifecycleState(resumed).
  void onResumed() => _externalDepth = 0;

  /// G1 (раунд-3): заблокировать при сворачивании приложения. Только если шифрование
  /// настроено (иначе ПИНа нет и гейт повесил бы приложение) и это НЕ системный пикер.
  Future<void> lockForBackground() async {
    if (!crypto_session.Session.encryptionEnabled || _locked) return;
    if (_externalDepth > 0) return; // системный пикер/диалог/шаринг — вернёмся в то же состояние
    await lock();
  }

  /// G3: удалить устаревшие плейнтекст-бэкапы миграции (от прерванной миграции). Безопасно
  /// только когда шифрование уже включено (иначе бэкап — единственная валидная копия).
  Future<void> _cleanupStaleMigrationBackups() async {
    if (!crypto_session.Session.encryptionEnabled) return;
    try {
      await for (final e in root.parent.list()) {
        if (e is Directory && e.path.split('/').last.startsWith('qtnotes-backup-')) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Загрузка данных, требующих расшифровки (тема, движок) — после разблокировки
  /// или сразу при старте, если шифрование не настроено.
  Future<void> _afterUnlockLoad() async {
    // приватный ключ синка хранится зашифрованным под MK: дошифровать (если лежал
    // плейнтекстом) и догрузить в личность (при старте-locked он был недоступен).
    await _ensureDeviceKeyEncrypted();
    await _refreshIdentityKey();
    await _reloadTheme();
    unawaited(_ensureSearchIndex()); // прогреть поисковый индекс в фоне
    // Движок поднимаем в фоне (не блокируем запуск): сеть может быть недоступна.
    if (_syncEnabled) unawaited(_startEngine());
    // Отложенная сборка мусора блобов: подобрать вложения удалённых заметок (в т.ч.
    // удалённых синком). С задержкой — не мешаем старту и даём синку докачать в полёте.
    Future.delayed(const Duration(seconds: 3), () => vault.gcBlobs());
  }

  Future<kv.UnlockResult> tryUnlock(String pin) async {
    // в биометр-режиме ВСЕГДА явно спрашиваем аутентификацию устройства (консистентно):
    // успех обновляет окно валидности ключа → проверка ПИНа проходит молча, без второго
    // запроса. Отмена биометрии → не пускаем (повтор).
    if (await _unlock!.biometricEnabled()) {
      final ok = await Keystore.authenticateDevice();
      if (!ok) return kv.UnlockResult(kv.UnlockStatus.wrong);
    }
    final res = await _unlock!.tryUnlock(pin);
    if (res.status == kv.UnlockStatus.ok) {
      _locked = false;
      await _afterUnlockLoad();
      notifyListeners();
    }
    return res;
  }

  Future<int> unlockRemaining() => _unlock!.remainingLockout();

  /// Duress-обработчик (вызывается контроллером при обратном ПИНе): стереть реальные
  /// данные, создать подложку, выключить синхронизацию. Возвращает MK подложки.
  Future<Uint8List> _runDuress(String reversePin) async {
    final mk = await Duress.execute(
      reversePin: reversePin,
      vaultRoot: root,
      controller: _unlock!,
      vault: vault,
      // крипто-стирание: удалить ОБА возможных ключа (обычный и auth-привязанный)
      eraseHardwareKey: () async {
        await Keystore.deleteKey(keystoreAliasPlain);
        await Keystore.deleteKey(keystoreAliasAuth);
        await Keystore.deleteKey(keystoreAliasKeyringMac); // H9 integrity-ключ тоже
      },
    );
    _syncEnabled = false;
    repo.syncEnabled = false;
    await _saveSettings(); // app_settings.json пересоздаётся с sync=off
    return mk;
  }

  bool get encryptionConfigured =>
      _unlock != null && crypto_session.Session.encryptionEnabled;

  // --- биометрия устройства (опциональный аппаратный гейт ключа) ---

  Future<bool> biometricEnabled() async =>
      _unlock != null && await _unlock!.biometricEnabled();

  Future<bool> canDeviceAuth() => Keystore.canDeviceAuth();

  /// Включить/выключить разблокировку с биометрией/кодом устройства. Требует ввод ПИНа
  /// (проверка + перевыпуск ключа). True — успех.
  Future<bool> setBiometric(bool enabled, String pin) =>
      _unlock!.setBiometric(enabled, pin);

  /// Включить шифрование: задать ПИН (Keystore) → в ФОНОВОМ изоляте бэкап + шифрование
  /// существующих данных (AES в чистом Dart медленный — на UI-потоке вешает app).
  Future<Map<String, int>> enableEncryption(String pin) async {
    final mk = await _unlock!.setupPin(pin); // Keystore на главном изоляте + Session
    final rootPath = root.path;
    final result = await Isolate.run(() => _migrateInIsolate(rootPath, mk));
    // приватный ключ синка был плейнтекстом до включения шифрования → перешифровать
    await _ensureDeviceKeyEncrypted();
    notifyListeners();
    return result;
  }

  Color? _parseHex(dynamic v) {
    if (v is! String || !v.startsWith('#') || v.length != 7) return null;
    final n = int.tryParse('FF${v.substring(1)}', radix: 16);
    return n == null ? null : Color(n);
  }

  /// Подхватить тему/обои из общих настроек (приходят с десктопа по синку).
  Future<void> _reloadTheme() async {
    final theme = await vault.getShared('theme');
    final wsha = (theme is Map) ? theme['wallpaper'] : null;
    final wpPresent =
        wsha is String && wsha.isNotEmpty && await vault.hasBlob(wsha);
    final key = jsonEncode({'t': theme, 'wp': wpPresent});
    if (key == _lastThemeKey) return; // ничего не изменилось
    _lastThemeKey = key;

    Map<String, Color>? colors;
    File? wp;
    if (theme is Map && theme['palette'] is Map) {
      colors = {};
      (theme['palette'] as Map).forEach((k, v) {
        final c = _parseHex(v);
        if (c != null) colors![k as String] = c;
      });
      if (colors.isEmpty) colors = null;
    }
    if (wpPresent) wp = vault.blobPath(wsha);
    syncedColors = colors;
    wallpaper = wp;
    AppColors.applyPalette(colors); // перекрасить весь интерфейс
    notifyListeners();
  }

  Future<void> _loadPeerAddrs() async {
    try {
      if (await _peerAddrsFile.exists()) {
        final d = (jsonDecode(await _peerAddrsFile.readAsString()) as Map);
        _peerAddrs = d.map((k, v) =>
            MapEntry(k as String, (v as Map).cast<String, dynamic>()));
      }
    } catch (_) {}
  }

  Future<void> _savePeerAddr(String deviceId, String host, int port) async {
    _peerAddrs[deviceId] = {'host': host, 'port': port};
    await _peerAddrsFile.writeAsString(jsonEncode(_peerAddrs));
  }

  String _deviceName() => 'Телефон';

  // --- настройки ---

  Future<void> _loadSettings() async {
    try {
      if (await _settingsFile.exists()) {
        final d = (jsonDecode(await _settingsFile.readAsString()) as Map);
        _syncEnabled = (d['sync_enabled'] ?? false) as bool;
      }
    } catch (_) {}
    repo.syncEnabled = _syncEnabled;
  }

  Future<void> _saveSettings() async {
    await _settingsFile.writeAsString(jsonEncode({'sync_enabled': _syncEnabled}));
  }

  // --- данные (делегируем в repo + уведомляем UI) ---

  // --- поиск (M4): индекс в памяти, строится один раз, поддерживается инкрементально ---
  SearchIndex? _searchIndex;
  Future<SearchIndex>? _indexBuilding;

  Future<SearchIndex> _ensureSearchIndex() {
    if (_searchIndex != null) return Future.value(_searchIndex!);
    return _indexBuilding ??= _buildSearchIndex();
  }

  Future<SearchIndex> _buildSearchIndex() async {
    final idx = SearchIndex();
    for (final f in await vault.listFolders()) {
      for (final n in await vault.listNotes(f.id)) {
        idx.upsert(n);
      }
    }
    _searchIndex = idx;
    _indexBuilding = null;
    return idx;
  }

  /// Поиск по заметкам (нечёткий, семантика как на десктопе). folderId=null — везде.
  Future<List<SearchHit>> search(String query, {String? folderId}) async {
    final idx = await _ensureSearchIndex();
    return idx.search(query, folderId: folderId);
  }

  Future<List<Folder>> folders() => repo.folders();
  Future<List<Note>> notes(String folderId) => repo.notes(folderId);
  Future<List<Event>> events() => repo.events();
  Future<Note?> findNote(String id) => repo.findNote(id);

  Future<Folder> createFolder(String name,
      {String icon = 'letter', String? color}) async {
    final f = await repo.createFolder(name, icon: icon, color: color);
    notifyListeners();
    return f;
  }

  Future<void> deleteFolder(String id) async {
    await repo.deleteFolder(id);
    _searchIndex?.removeFolder(id);
    notifyListeners();
    unawaited(vault.gcBlobs()); // папка унесла заметки → подобрать осиротевшие блобы
  }

  Future<void> saveNote(Note n) async {
    await repo.saveNote(n);
    _searchIndex?.upsert(n);
    notifyListeners();
  }

  Future<void> deleteNote(Note n) async {
    await repo.deleteNote(n);
    _searchIndex?.remove(n.id);
    notifyListeners();
  }

  Future<void> moveNote(Note n, String target) async {
    await repo.moveNote(n, target);
    // заметка сменила папку → переиндексировать с новым folderId
    _searchIndex?.upsert(Note(
        id: n.id, folderId: target, kind: n.kind, html: n.html,
        plaintext: n.plaintext, captionHtml: n.captionHtml,
        attachments: n.attachments, dateTag: n.dateTag,
        created: n.created, modified: n.modified));
    notifyListeners();
  }

  Future<Event> addEvent(String date, String name, String color) async {
    final e = await repo.addEvent(date, name, color);
    notifyListeners();
    return e;
  }

  Future<void> updateEvent(String id, {String? name, String? color, String? date}) async {
    await repo.updateEvent(id, name: name, color: color, date: date);
    notifyListeners();
  }

  Future<void> deleteEvent(String id) async {
    await repo.deleteEvent(id);
    notifyListeners();
  }

  // --- синхронизация ---

  Future<void> setSyncEnabled(bool on) async {
    _syncEnabled = on;
    repo.syncEnabled = on;
    await _saveSettings();
    if (on) {
      await _startEngine();
    } else {
      await _stopEngine();
    }
    notifyListeners();
  }

  List<String> onlinePeers() => _engine?.sessions.keys.toList() ?? [];

  Future<void> _startEngine() async {
    if (_engine != null) return;
    await _seedIfNeeded();
    await oplog.compact(); // B1: подрезать историю до старта синка с пирами
    final store = SyncStore(oplog, ApplyEngine(vault, oplog), vault);
    _engine = SyncEngine(identity, store,
        getPeers: () => peers.list(), onChanged: _onRemoteChanged);
    oplog.changeListener = () {
      _engine?.pushAll();
    };
    await _engine!.serve();
    debugPrint('SYNC start: port=${_engine!.port} '
        'peerAddrs=${_peerAddrs.length} peers=${(await peers.list()).length}');
    _discovery = Discovery(identity, _engine!.port!,
        onFound: (p) => _onPeerFound(p), onLost: (id) => _onPeerLost(id));
    try {
      await _discovery!.start();
    } catch (e) {
      debugPrint('SYNC mDNS start failed: $e');
      _discovery = null;
    }
    _updateStatus();
    // прямое подключение к известным пирам (из QR) + периодическое переподключение
    await _connectKnownPeers();
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _connectKnownPeers());
  }

  Future<void> _connectKnownPeers() async {
    final eng = _engine;
    if (eng == null) return;
    for (final entry in _peerAddrs.entries) {
      final id = entry.key;
      if (eng.sessions.containsKey(id)) continue; // уже на связи
      if (!await peers.isTrusted(id)) continue;
      final host = entry.value['host'] as String?;
      final port = (entry.value['port'] as num?)?.toInt();
      if (host == null || port == null || port <= 0) continue;
      try {
        await eng.connect(host, port, id);
        debugPrint('SYNC connect OK -> $host:$port');
        _updateStatus();
      } catch (e) {
        debugPrint('SYNC connect FAIL -> $host:$port : $e');
      }
    }
  }

  Future<void> _stopEngine() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    oplog.changeListener = null;
    await _discovery?.stop();
    _discovery = null;
    await _engine?.stop();
    _engine = null;
    _updateStatus();
  }

  Future<void> _seedIfNeeded() async {
    if (await oplog.getMeta('seeded') == '1') return;
    for (final f in await vault.listFolders()) {
      await oplog.appendLocal('folder.put', f.id, f.toJson());
      for (final n in await vault.listNotes(f.id)) {
        if (await vault.ensureBlobs(n)) await vault.applyNotePut(n);
        await oplog.appendLocal('note.put', n.id, n.toJson());
      }
    }
    for (final e in await vault.listEvents()) {
      await oplog.appendLocal('event.put', e.id, e.toJson());
    }
    await oplog.setMeta('seeded', '1');
  }

  Future<void> _onPeerFound(FoundPeer p) async {
    debugPrint('SYNC mDNS found ${p.deviceId} @ ${p.host}:${p.port} '
        'trusted=${await peers.isTrusted(p.deviceId)}');
    if (!await peers.isTrusted(p.deviceId)) return;
    if (_engine!.sessions.containsKey(p.deviceId)) return;
    // одно соединение на пару: инициирует устройство с меньшим device_id
    if (identity.deviceId.compareTo(p.deviceId) < 0) {
      try {
        await _engine!.connect(p.host, p.port, p.deviceId);
        debugPrint('SYNC mDNS connect OK -> ${p.host}:${p.port}');
        _updateStatus();
      } catch (e) {
        debugPrint('SYNC mDNS connect FAIL: $e');
      }
    }
  }

  void _onPeerLost(String deviceId) {
    _engine?.sessions[deviceId]?.close();
    _updateStatus();
  }

  void _onRemoteChanged() {
    _updateStatus(); // обновит статус «онлайн» + уведомит UI
    _reloadTheme(); // тема/обои могли прийти или догрузиться
    // синк применяет заметки мимо AppService.saveNote → инвалидируем индекс (ленивая
    // пересборка при следующем поиске)
    _searchIndex = null;
    _indexBuilding = null;
  }

  void _updateStatus() {
    if (!_syncEnabled) {
      syncStatus = 'Синхронизация выключена';
    } else {
      final n = onlinePeers().length;
      syncStatus = 'Синхронизация включена · онлайн: $n';
    }
    notifyListeners();
  }

  // --- сопряжение (сканируем QR десктопа) ---

  Future<void> pairFromQr(String qrText) async {
    final payload = parsePairingPayload(qrText);
    final peer = await pairWith(payload, identity);
    await peers.add(peer.deviceId, peer.name, peer.certPem);
    // запомнить адрес десктопа из QR — для прямого подключения в обход mDNS
    final host = payload['host'] as String?;
    final syncPort = (payload['sync_port'] as num?)?.toInt() ?? 0;
    if (host != null && syncPort > 0) {
      await _savePeerAddr(peer.deviceId, host, syncPort);
    }
    // сервер доверяет cert пиров на момент bind — перезапускаем движок,
    // затем _startEngine сам подключится к известным адресам (включая этот)
    if (_syncEnabled) {
      await _stopEngine();
      await _startEngine();
    }
    notifyListeners();
  }

  Future<List<Peer>> pairedDevices() => peers.list();

  Future<void> removePeer(String deviceId) async {
    await peers.remove(deviceId);
    if (_syncEnabled) {
      await _stopEngine();
      await _startEngine();
    }
    notifyListeners();
  }
}

// --- работа в фоновом изоляте (Session здесь свой, ставим из переданного MK) ---

Future<Map<String, int>> _migrateInIsolate(String rootPath, Uint8List mk) async {
  crypto_session.Session.masterKey = mk;
  crypto_session.Session.encryptionEnabled = true;
  final root = Directory(rootPath);
  final vault = Vault(root);
  final backup = await _backupVaultData(root); // плейнтекст-копия на случай сбоя миграции
  final stats = await vault.migrateEncrypt();
  await OpLog(File('$rootPath/sync.json')).resave();
  // успех → удалить плейнтекст-бэкап (он не должен пережить включение шифрования и
  // duress-стирание). При сбое выше — исключение пробрасывается, копия остаётся для отката.
  try {
    if (await backup.exists()) await backup.delete(recursive: true);
  } catch (_) {}
  return stats;
}

/// Бэкап данных vault БЕЗ блобов (они перешифровываются атомарно — копия не нужна,
/// а копировать крупные видео долго). Для отката JSON-данных.
Future<Directory> _backupVaultData(Directory root) async {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final dest = Directory('${root.parent.path}/qtnotes-backup-$ts');
  await dest.create(recursive: true);
  await for (final e in root.list(recursive: true)) {
    final rel = e.path.substring(root.path.length + 1);
    if (rel.startsWith('blobs')) continue;
    if (e is File) {
      final f = File('${dest.path}/$rel');
      await f.parent.create(recursive: true);
      await e.copy(f.path);
    }
  }
  return dest;
}
