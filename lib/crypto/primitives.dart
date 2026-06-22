// Криптопримитивы (зеркало qtnotes/crypto/primitives.py).
//
// AES-256-GCM (AEAD), HKDF-SHA256, HMAC-SHA256, сравнение в постоянное время.
// Реализация на pointycastle (+ crypto для HMAC) — без новых зависимостей.

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';

const int keyLen = 32; // 256 бит
const int nonceLen = 12; // стандартный nonce для GCM
const int _macBits = 128; // тег GCM 16 байт

final Random _rng = Random.secure();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// Зашифровать AES-256-GCM. Результат: nonce(12) || ciphertext+tag.
/// aad аутентифицируется, но не шифруется (контекст: путь файла и т.п.).
Uint8List seal(Uint8List key, Uint8List plaintext, {Uint8List? aad}) {
  if (key.length != keyLen) throw ArgumentError('ключ должен быть 32 байта');
  final nonce = randomBytes(nonceLen);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), _macBits, nonce, aad ?? Uint8List(0)));
  final ct = cipher.process(plaintext);
  final out = Uint8List(nonceLen + ct.length);
  out.setRange(0, nonceLen, nonce);
  out.setRange(nonceLen, out.length, ct);
  return out;
}

/// Расшифровать то, что произвёл seal(). Бросает InvalidCipherTextException при
/// неверном ключе/подмене (включая несовпадение aad).
Uint8List openSealed(Uint8List key, Uint8List blob, {Uint8List? aad}) {
  if (key.length != keyLen) throw ArgumentError('ключ должен быть 32 байта');
  if (blob.length < nonceLen) throw ArgumentError('слишком короткий blob');
  final nonce = blob.sublist(0, nonceLen);
  final ct = blob.sublist(nonceLen);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), _macBits, nonce, aad ?? Uint8List(0)));
  return cipher.process(ct);
}

/// Вывести субключ по HKDF-SHA256.
Uint8List hkdf(Uint8List keyMaterial, Uint8List info, {int length = keyLen, Uint8List? salt}) {
  final d = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(keyMaterial, length, salt, info));
  return d.process(Uint8List(0));
}

/// HMAC-SHA256.
Uint8List hmacSha256(Uint8List key, Uint8List message) {
  return Uint8List.fromList(c.Hmac(c.sha256, key).convert(message).bytes);
}

/// Сравнение в постоянное время.
bool constEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}
