// Боевой аппаратный бэкенд: Android Keystore через MethodChannel (зеркало TpmHardwareKey).
//
// HMAC считается на неизвлекаемом ключе в Keystore (StrongBox/TEE). Импортирует
// flutter/services, поэтому используется только в приложении, НЕ в чистых dart-тестах
// (там — SoftwareHardwareKey).

import 'dart:convert';

import 'package:flutter/services.dart';

import 'hwbackend.dart';

class Keystore {
  static const MethodChannel _ch = MethodChannel('qtnotes/keystore');

  static Future<void> ensureHmacKey(String alias, {bool requireAuth = false}) =>
      _ch.invokeMethod('ensureHmacKey', {'alias': alias, 'requireAuth': requireAuth});

  static Future<bool> hasKey(String alias) async =>
      (await _ch.invokeMethod<bool>('hasKey', {'alias': alias})) ?? false;

  static Future<Uint8List> hmac(String alias, Uint8List data) async {
    final r = await _ch.invokeMethod<Uint8List>('hmac', {'alias': alias, 'data': data});
    if (r == null) throw StateError('Keystore.hmac вернул null');
    return r;
  }

  static Future<void> deleteKey(String alias) =>
      _ch.invokeMethod('deleteKey', {'alias': alias});

  /// D4: скопировать текст в буфер, помечая чувствительным (Android 13+ скрывает превью
  /// и не тащит в облачную историю буфера). При сбое канала — вызывающий падает на
  /// обычный Clipboard.setData.
  static Future<void> copySensitive(String text) =>
      _ch.invokeMethod('copySensitive', {'text': text});

  /// H9: integrity-MAC keyring под ВЫДЕЛЕННЫМ non-auth Keystore-ключом. Non-auth —
  /// чтобы MAC можно было считать молча на каждой записи (без биометрии), в отличие от
  /// PIN-ключа, который может требовать аутентификацию. Ключ неизвлекаемый (TEE/StrongBox)
  /// → подделать MAC на rooted-устройстве нельзя, и сброс счётчика перебора детектируется.
  static Future<Uint8List> keyringMac(Uint8List data) async {
    await ensureHmacKey(keystoreAliasKeyringMac, requireAuth: false);
    return hmac(keystoreAliasKeyringMac, data);
  }

  /// Поддерживает ли устройство аппаратную аутентификацию (биометрия/код блокировки).
  static Future<bool> canDeviceAuth() async {
    try {
      return (await _ch.invokeMethod<bool>('canDeviceAuth')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Явно запросить аутентификацию устройства (биометрия/код). True — успех.
  /// Обновляет окно валидности auth-привязанных ключей.
  static Future<bool> authenticateDevice() async {
    try {
      return (await _ch.invokeMethod<bool>('authenticateDevice')) ?? false;
    } catch (_) {
      return false;
    }
  }
}

// Боевые алиасы: обычный (без auth) и привязанный к аутентификации устройства.
const String keystoreAliasPlain = 'qtnotes_pin_hmac';
const String keystoreAliasAuth = 'qtnotes_pin_hmac_auth';
const String keystoreAliasKeyringMac = 'qtnotes_keyring_mac'; // H9: integrity-MAC keyring

class KeystoreHardwareKey implements HardwareKey {
  final String alias;
  final bool requireAuth; // привязка ключа к аппаратной аутентификации устройства
  const KeystoreHardwareKey({this.alias = keystoreAliasPlain, this.requireAuth = false});

  @override
  Future<Uint8List> mac(Uint8List salt, String pin) async {
    await Keystore.ensureHmacKey(alias, requireAuth: requireAuth);
    final data = Uint8List.fromList([...salt, ...utf8.encode(pin)]);
    return Keystore.hmac(alias, data); // при requireAuth здесь всплывёт биометрия
  }
}
