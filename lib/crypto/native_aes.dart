// Нативный AES-256-GCM через Android (аппаратный AES-NI) по MethodChannel.
// В сотни раз быстрее pure-Dart pointycastle. Вычисление на фоновом потоке Android.
//
// Если канал недоступен (чистые dart-тесты / другой изолят) — возвращает null,
// вызывающий падает на pure-Dart фоллбэк.

import 'package:flutter/services.dart';

class NativeAes {
  static const MethodChannel _ch = MethodChannel('qtnotes/keystore');
  static bool _unavailable = false;

  static Future<Uint8List?> _call(
      String method, Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data) async {
    if (_unavailable) return null;
    try {
      return await _ch.invokeMethod<Uint8List>(
          method, {'key': key, 'nonce': nonce, 'aad': aad, 'data': data});
    } on MissingPluginException {
      _unavailable = true; // нет плагина (чистый dart-тест) — навсегда на pure-Dart
      return null;
    } catch (_) {
      // канал недоступен (фоновый изолят без binding) или сбой — фоллбэк pure-Dart
      // (реальная ошибка расшифровки всплывёт уже в pure-Dart). Native не отключаем.
      return null;
    }
  }

  /// Зашифровать → ciphertext||tag(16). Null, если канал недоступен.
  static Future<Uint8List?> encrypt(
          Uint8List key, Uint8List nonce, Uint8List aad, Uint8List plaintext) =>
      _call('aesGcmEncrypt', key, nonce, aad, plaintext);

  /// Расшифровать ciphertext||tag → plaintext. Null, если канал недоступен.
  static Future<Uint8List?> decrypt(
          Uint8List key, Uint8List nonce, Uint8List aad, Uint8List ciphertextTag) =>
      _call('aesGcmDecrypt', key, nonce, aad, ciphertextTag);
}
