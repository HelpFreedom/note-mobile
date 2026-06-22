// Управление мастер-ключом (зеркало qtnotes/crypto/keyvault.py).
//
// Чистая логика без I/O: настройка ПИНа, разблокировка, различение прямой/обратный
// (duress)/неверный ПИН, нарастающая блокировка. Аппаратная часть инъектируется через
// HardwareKey, что позволяет покрыть логику тестами без Keystore.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/key_derivators/api.dart' show ScryptParameters;
import 'package:pointycastle/key_derivators/scrypt.dart' show Scrypt;

import 'hwbackend.dart';
import 'primitives.dart' as primitives;

const int pinLen = 5;
final Uint8List _infoWrap = Uint8List.fromList(utf8.encode('qtnotes/mk-wrap/v1'));
final Uint8List _infoDuress = Uint8List.fromList(utf8.encode('qtnotes/duress-tag/v1'));

// M1: медленный (memory-hard) KDF поверх аппаратного гейта (как keyvault.py). Защита-в-
// глубину против brute-force 5-значного ПИНа, если гейт быстрый/программный. Параметры
// в keyring → можно поднять без потери совместимости. Keyring — per-device (не
// синхронизируется), поэтому параметры могут отличаться от десктопа. На мобилке scrypt —
// чистый Dart на главном изоляте во время модального ввода ПИНа: N=8192 даёт ощутимую
// стоимость перебора при коротком (доли секунды) залипании UI на разблокировке.
const Map<String, dynamic> defaultKdf = {'algo': 'scrypt', 'n': 8192, 'r': 8, 'p': 1};

Uint8List _stretch(Uint8List material, Uint8List salt, Map<String, dynamic>? kdf) {
  if (kdf == null) return material; // legacy keyring — без растяжения
  if (kdf['algo'] == 'scrypt') {
    final s = Scrypt()
      ..init(ScryptParameters((kdf['n'] as num).toInt(), (kdf['r'] as num).toInt(),
          (kdf['p'] as num).toInt(), 32, salt));
    return s.process(material);
  }
  throw ArgumentError('неизвестный KDF keyring: $kdf');
}

// Нарастающая блокировка после 2-й неверной попытки: 1м, 5м, 30м, 2ч, дальше сутки.
const Map<int, int> _lockoutSchedule = {0: 0, 1: 0, 2: 60, 3: 300, 4: 1800, 5: 7200};
const int _lockoutMax = 24 * 60 * 60;

class PinError implements Exception {
  final String message;
  PinError(this.message);
  @override
  String toString() => message;
}

/// Проверить требования к ПИНу. Бросает PinError. Палиндром запрещён (иначе обратный
/// ПИН совпал бы с прямым и duress был бы неотличим).
void validatePin(String pin) {
  if (pin.length != pinLen) throw PinError('ПИН должен состоять из $pinLen цифр');
  if (!RegExp(r'^\d+$').hasMatch(pin)) throw PinError('ПИН должен содержать только цифры');
  if (pin == pin.split('').reversed.join()) {
    throw PinError('ПИН-палиндром запрещён (обратный совпал бы с прямым)');
  }
}

int lockoutSeconds(int failCount) {
  if (failCount >= 6) return _lockoutMax;
  return _lockoutSchedule[failCount] ?? 0;
}

enum UnlockStatus { ok, duress, wrong, locked }

class UnlockResult {
  final UnlockStatus status;
  final Uint8List? masterKey;
  final int retryAfter;
  final int failCount;
  UnlockResult(this.status, {this.masterKey, this.retryAfter = 0, this.failCount = 0});
}

class KeyringState {
  int version;
  Uint8List saltWrap;
  Uint8List saltDuress;
  Uint8List wrappedMk;
  Uint8List? duressTag; // null у подложки
  int failCount;
  double lastFailTs;
  Map<String, dynamic>? kdf; // M1: параметры медленного KDF; null — legacy

  KeyringState({
    required this.version,
    required this.saltWrap,
    required this.saltDuress,
    required this.wrappedMk,
    required this.duressTag,
    this.failCount = 0,
    this.lastFailTs = 0.0,
    this.kdf,
  });

  KeyringState copyWith({int? failCount, double? lastFailTs}) => KeyringState(
        version: version,
        saltWrap: saltWrap,
        saltDuress: saltDuress,
        wrappedMk: wrappedMk,
        duressTag: duressTag,
        failCount: failCount ?? this.failCount,
        lastFailTs: lastFailTs ?? this.lastFailTs,
        kdf: kdf,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'salt_wrap': base64.encode(saltWrap),
        'salt_duress': base64.encode(saltDuress),
        'wrapped_mk': base64.encode(wrappedMk),
        'duress_tag': duressTag == null ? null : base64.encode(duressTag!),
        'fail_count': failCount,
        'last_fail_ts': lastFailTs,
        'kdf': kdf,
      };

  factory KeyringState.fromJson(Map<String, dynamic> d) => KeyringState(
        version: d['version'] as int,
        saltWrap: base64.decode(d['salt_wrap'] as String),
        saltDuress: base64.decode(d['salt_duress'] as String),
        wrappedMk: base64.decode(d['wrapped_mk'] as String),
        duressTag: d['duress_tag'] == null ? null : base64.decode(d['duress_tag'] as String),
        failCount: (d['fail_count'] ?? 0) as int,
        lastFailTs: ((d['last_fail_ts'] ?? 0) as num).toDouble(),
        kdf: (d['kdf'] as Map?)?.cast<String, dynamic>(),
      );
}

Future<Uint8List> _wrapKey(
        HardwareKey hw, Uint8List salt, String pin, Map<String, dynamic>? kdf) async =>
    primitives.hkdf(_stretch(await hw.mac(salt, pin), salt, kdf), _infoWrap);

Future<Uint8List> _duressTag(
        HardwareKey hw, Uint8List salt, String pin, Map<String, dynamic>? kdf) async =>
    primitives.hkdf(_stretch(await hw.mac(salt, pin), salt, kdf), _infoDuress);

Future<KeyringState> _upgradeKdf(
    KeyringState state, String pin, HardwareKey hw, Uint8List mk) async {
  final kdf = Map<String, dynamic>.from(defaultKdf);
  final sw = primitives.randomBytes(16);
  final sd = primitives.randomBytes(16);
  final wrapped = primitives.seal(await _wrapKey(hw, sw, pin, kdf), mk);
  Uint8List? tag;
  if (state.duressTag != null) {
    tag = await _duressTag(hw, sd, pin.split('').reversed.join(), kdf);
  }
  return KeyringState(
      version: state.version, saltWrap: sw, saltDuress: sd, wrappedMk: wrapped,
      duressTag: tag, kdf: kdf);
}

/// Создать новый key vault под ПИН. Возвращает (состояние, MK).
/// withDuress=false — для подложки (нет обратного ПИНа).
Future<(KeyringState, Uint8List)> setup(String pin, HardwareKey hw,
    {bool withDuress = true, Uint8List? masterKey}) async {
  validatePin(pin);
  final mk = masterKey ?? primitives.randomBytes(32);
  if (mk.length != 32) throw ArgumentError('master_key должен быть 32 байта');
  final saltWrap = primitives.randomBytes(16);
  final saltDuress = primitives.randomBytes(16);
  final kdf = Map<String, dynamic>.from(defaultKdf);
  final wrapped = primitives.seal(await _wrapKey(hw, saltWrap, pin, kdf), mk);
  Uint8List? tag;
  if (withDuress) {
    final rev = pin.split('').reversed.join();
    tag = await _duressTag(hw, saltDuress, rev, kdf);
  }
  final state = KeyringState(
    version: 1,
    saltWrap: saltWrap,
    saltDuress: saltDuress,
    wrappedMk: wrapped,
    duressTag: tag,
    kdf: kdf,
  );
  return (state, mk);
}

int remainingLockout(KeyringState state, double now) {
  final dur = lockoutSeconds(state.failCount);
  if (dur <= 0) return 0;
  final left = (state.lastFailTs + dur - now).floor();
  return left > 0 ? left : 0;
}

/// Попытка разблокировки. Возвращает (новое_состояние, результат). Состояние нужно
/// сохранить. При duress — только распознавание (стирание делает вызывающий).
Future<(KeyringState, UnlockResult)> unlock(
    KeyringState state, String pin, HardwareKey hw, double now) async {
  final left = remainingLockout(state, now);
  if (left > 0) {
    return (state, UnlockResult(UnlockStatus.locked, retryAfter: left, failCount: state.failCount));
  }

  // 1) прямой ПИН?
  Uint8List? mk;
  try {
    mk = primitives.openSealed(
        await _wrapKey(hw, state.saltWrap, pin, state.kdf), state.wrappedMk);
  } catch (_) {
    mk = null;
  }
  if (mk != null) {
    // M1: legacy keyring без медленного KDF → усиливаем при первом успешном входе
    final ns = state.kdf == null
        ? await _upgradeKdf(state, pin, hw, mk)
        : state.copyWith(failCount: 0, lastFailTs: 0.0);
    return (ns, UnlockResult(UnlockStatus.ok, masterKey: mk, failCount: 0));
  }

  // 2) обратный (duress) ПИН?
  if (state.duressTag != null) {
    final cand = await _duressTag(hw, state.saltDuress, pin, state.kdf);
    if (primitives.constEq(cand, state.duressTag!)) {
      return (state, UnlockResult(UnlockStatus.duress, failCount: state.failCount));
    }
  }

  // 3) неверный ПИН → инкремент и (возможно) блокировка
  final ns = state.copyWith(failCount: state.failCount + 1, lastFailTs: now);
  return (ns, UnlockResult(UnlockStatus.wrong,
      failCount: ns.failCount, retryAfter: remainingLockout(ns, now)));
}
