// Проверка криптопримитивов (Ф5a): AES-GCM round-trip, аутентификация, HKDF, HMAC.
// Запуск: dart test test/crypto_primitives_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show InvalidCipherTextException;
import 'package:test/test.dart';

import 'package:qtnotes_mobile/crypto/primitives.dart' as P;

void main() {
  test('AES-GCM round-trip', () {
    final key = P.randomBytes(32);
    final msg = Uint8List.fromList(utf8.encode('секретная заметка 🔒'));
    final blob = P.seal(key, msg);
    expect(P.openSealed(key, blob), equals(msg));
  });

  test('неверный ключ ломает расшифровку', () {
    final key = P.randomBytes(32);
    final blob = P.seal(key, Uint8List.fromList([1, 2, 3]));
    expect(() => P.openSealed(P.randomBytes(32), blob),
        throwsA(isA<InvalidCipherTextException>()));
  });

  test('AAD аутентифицируется', () {
    final key = P.randomBytes(32);
    final msg = Uint8List.fromList(utf8.encode('x'));
    final aad1 = Uint8List.fromList(utf8.encode('folder/1/note.json'));
    final aad2 = Uint8List.fromList(utf8.encode('folder/9/note.json'));
    final blob = P.seal(key, msg, aad: aad1);
    expect(P.openSealed(key, blob, aad: aad1), equals(msg));
    expect(() => P.openSealed(key, blob, aad: aad2),
        throwsA(isA<InvalidCipherTextException>()));
  });

  test('случайный nonce — разные шифртексты', () {
    final key = P.randomBytes(32);
    final msg = Uint8List.fromList([9, 9, 9]);
    expect(P.seal(key, msg), isNot(equals(P.seal(key, msg))));
  });

  test('HKDF детерминирован и зависит от info', () {
    final km = P.randomBytes(32);
    expect(P.hkdf(km, Uint8List.fromList([1])),
        equals(P.hkdf(km, Uint8List.fromList([1]))));
    expect(P.hkdf(km, Uint8List.fromList([1])),
        isNot(equals(P.hkdf(km, Uint8List.fromList([2])))));
    expect(P.hkdf(km, Uint8List.fromList([1])).length, 32);
  });

  test('HMAC детерминирован, зависит от ключа/сообщения, 32 байта', () {
    final k = P.randomBytes(32);
    final m = Uint8List.fromList(utf8.encode('msg'));
    expect(P.hmacSha256(k, m), equals(P.hmacSha256(k, m)));
    expect(P.hmacSha256(k, m).length, 32);
    expect(P.hmacSha256(k, m), isNot(equals(P.hmacSha256(P.randomBytes(32), m))));
  });

  test('constEq', () {
    expect(P.constEq([1, 2, 3], [1, 2, 3]), isTrue);
    expect(P.constEq([1, 2, 3], [1, 2, 4]), isFalse);
    expect(P.constEq([1, 2], [1, 2, 3]), isFalse);
  });
}
