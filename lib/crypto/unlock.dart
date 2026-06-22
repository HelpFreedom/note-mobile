// Контроллер разблокировки на Dart (зеркало qtnotes/crypto/unlock.py, упрощённый —
// без NV-счётчика: на Android аппаратного монотонного счётчика нет, lockout-счётчик
// хранится в app-private keyring-файле).
//
// Бэкенд выбирается фабрикой по флагу biometric из keyring — чтобы контроллер оставался
// чистым Dart (без импорта flutter/services) и тестировался без Android/Keystore.
// Состояние: <keyring>/keyring.json = {"keyring": <KeyringState>, "biometric": bool}.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'hwbackend.dart';
import 'keyvault.dart' as kv;
import 'primitives.dart' as primitives;
import 'session.dart';

double _nowSec() => DateTime.now().millisecondsSinceEpoch / 1000.0;

/// Возвращает аппаратный бэкенд для режима (biometric=true → ключ с аппаратной
/// аутентификацией устройства). В тестах — всегда программный.
typedef BackendFactory = HardwareKey Function(bool biometric);

// H9: подделка keyring.json на rooted-устройстве (сброс fail_count/last_fail_ts) обходила
// бы лимит перебора ПИНа. integrity-MAC под неизвлекаемым non-auth Keystore-ключом ловит
// это: при несовпадении MAC — недеструктивная блокировка 24ч, бюджет перебора не сбросить.
const int _tamperLockoutSeconds = 24 * 60 * 60;

class UnlockController {
  final File keyringFile;
  final BackendFactory backendFactory;
  UnlockController(this.keyringFile, this.backendFactory);

  /// H9: функция integrity-MAC (инъекция, чтобы контроллер оставался чистым Dart). В
  /// приложении — Keystore.keyringMac (non-auth ключ); в тестах — программный HMAC; null
  /// — MAC отключён (legacy/без поддержки). Сбой/отсутствие → деградация без блокировки.
  Future<Uint8List> Function(Uint8List data)? integrityMac;

  /// D2 (раунд-3): маркер «MAC когда-либо включался на этом устройстве» (в приложении —
  /// существование Keystore-алиаса keyring-MAC; в тестах — стаб). Делает проверку
  /// fail-CLOSED: если MAC включался, но в файле его срезали (поле mac отсутствует) или
  /// Keystore-ключ удалён — это снятие защиты от перебора → блокировка, а не «легаси».
  /// Без маркера (null) поведение прежнее (легаси-совместимое).
  Future<bool> Function()? macEverEnabled;

  Future<bool> isConfigured() => keyringFile.exists();

  Future<Map<String, dynamic>?> _readRaw() async {
    if (!await keyringFile.exists()) return null;
    try {
      return (jsonDecode(await keyringFile.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<kv.KeyringState?> _read() async {
    final d = await _readRaw();
    if (d == null) return null;
    try {
      return kv.KeyringState.fromJson((d['keyring'] as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<bool> biometricEnabled() async {
    final d = await _readRaw();
    return d != null && d['biometric'] == true;
  }

  Future<void> _write(kv.KeyringState state, bool biometric) async {
    await keyringFile.parent.create(recursive: true);
    final map = <String, dynamic>{'keyring': state.toJson(), 'biometric': biometric};
    final fn = integrityMac;
    if (fn != null) {
      try {
        map['mac'] = base64.encode(await fn(_canonicalBytes(map)));
      } catch (_) {/* сбой MAC-движка → пишем без mac (деградация до legacy) */}
    }
    final tmp = File('${keyringFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(map));
    await tmp.rename(keyringFile.path);
  }

  /// Канонические байты для MAC: JSON map БЕЗ поля 'mac' (порядок ключей сохраняется
  /// при записи и при чтении-разборе, поэтому байты совпадают).
  Uint8List _canonicalBytes(Map<String, dynamic> map) {
    final m = Map<String, dynamic>.from(map)..remove('mac');
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  Future<bool> _integrityOk(Map<String, dynamic> raw) async {
    final fn = integrityMac;
    final stored = raw['mac'];
    if (fn == null) return true; // MAC-движка нет вовсе (легаси-сборка) → не блокируем
    // D2: проверяем маркер ДО вызова fn — иначе fn (Keystore.keyringMac) ПЕРЕСОЗДАСТ
    // удалённый алиас как побочный эффект и подделка осталась бы незамеченной.
    final marker = macEverEnabled;
    final macWasEnabled = marker != null ? await marker() : false;
    if (stored == null) {
      // mac в файле отсутствует. Если MAC когда-либо включался — это срезание защиты
      // (root удалил поле mac) → блокируем. Иначе настоящий легаси-файл → пропускаем.
      return !macWasEnabled;
    }
    if (marker != null && !macWasEnabled) {
      // в файле есть заявленный mac, но Keystore-ключа нет (удалён) → подделка.
      return false;
    }
    try {
      final mac = await fn(_canonicalBytes(raw));
      return primitives.constEq(base64.decode(stored as String), mac);
    } catch (_) {
      return true; // сбой MAC-движка → деградация (вход не страдает)
    }
  }

  /// Первичная настройка ПИНа. biometric=true — ключ привязан к аппаратной
  /// аутентификации устройства (при использовании всплывёт биометрия).
  Future<Uint8List> setupPin(String pin,
      {bool withDuress = true, bool biometric = false}) async {
    kv.validatePin(pin);
    final (state, mk) =
        await kv.setup(pin, backendFactory(biometric), withDuress: withDuress);
    await _write(state, biometric);
    Session.masterKey = mk;
    Session.encryptionEnabled = true;
    return mk;
  }

  /// Включить/выключить биометрию: проверить ПИН, затем перевыпустить обёртку MK под
  /// новый бэкенд (тот же ПИН и MK). True — успех; false — неверный ПИН / отмена.
  Future<bool> setBiometric(bool enabled, String pin) async {
    final cur = await _read();
    if (cur == null) return false;
    final curBio = await biometricEnabled();
    // проверить ПИН текущим бэкендом (для биометрии тут всплывёт подтверждение)
    final (_, res) = await kv.unlock(cur, pin, backendFactory(curBio), _nowSec());
    if (res.status != kv.UnlockStatus.ok || res.masterKey == null) return false;
    // перевыпустить под новый бэкенд тем же MK (при enabled всплывёт биометрия)
    final (state, _) = await kv.setup(pin, backendFactory(enabled),
        withDuress: true, masterKey: res.masterKey);
    await _write(state, enabled);
    Session.masterKey = res.masterKey;
    return true;
  }

  Future<int> remainingLockout({double? now}) async {
    final state = await _read();
    if (state == null) return 0;
    return kv.remainingLockout(state, now ?? _nowSec());
  }

  /// Попытка разблокировки. На OK кладёт MK в сессию. На DURESS — стирание + подложка.
  Future<kv.UnlockResult> tryUnlock(String pin, {double? now}) async {
    final d = await _readRaw();
    if (d == null) throw StateError('ПИН не настроен');
    // H9: подделка keyring (сброс счётчика перебора) → недеструктивная блокировка 24ч
    if (!await _integrityOk(d)) {
      return kv.UnlockResult(kv.UnlockStatus.locked, retryAfter: _tamperLockoutSeconds);
    }
    final state = kv.KeyringState.fromJson((d['keyring'] as Map).cast<String, dynamic>());
    final biometric = d['biometric'] == true;
    final backend = backendFactory(biometric);
    final t = now ?? _nowSec();
    final (newState, res) = await kv.unlock(state, pin, backend, t);

    if (res.status == kv.UnlockStatus.duress) {
      final decoyMk = await _onDuress(pin);
      return kv.UnlockResult(kv.UnlockStatus.ok, masterKey: decoyMk);
    }

    await _write(newState, biometric);
    if (res.status == kv.UnlockStatus.ok) {
      Session.masterKey = res.masterKey;
    }
    return res;
  }

  /// Хук duress-стирания. Ставится из приложения. Возвращает MK подложки.
  Future<Uint8List> Function(String reversePin)? onDuress;

  Future<Uint8List> _onDuress(String pin) async {
    final h = onDuress;
    if (h == null) throw StateError('duress-обработчик не задан');
    return h(pin);
  }

  void lock() => Session.lock();
}
