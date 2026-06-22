// Тесты keyvault (Ф5a): setup/unlock, duress, lockout, валидация ПИНа, сериализация.
// Запуск: dart test test/keyvault_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:qtnotes_mobile/crypto/hwbackend.dart';
import 'package:qtnotes_mobile/crypto/keyvault.dart' as kv;
import 'package:qtnotes_mobile/crypto/primitives.dart' as P;

void main() {
  test('валидация ПИНа: 5 цифр, не палиндром', () {
    kv.validatePin('13579');
    for (final bad in ['1234', '123456', '12a45', '12321', '00000']) {
      expect(() => kv.validatePin(bad), throwsA(isA<kv.PinError>()), reason: bad);
    }
  });

  test('setup + unlock прямым ПИНом выдаёт MK, который шифрует', () async {
    final hw = SoftwareHardwareKey.generate();
    final (state, mk) = await kv.setup('13579', hw);
    expect(mk.length, 32);

    final note = Uint8List.fromList(utf8.encode('купить молоко'));
    final blob = P.seal(mk, note);

    final (s2, res) = await kv.unlock(state, '13579', hw, 0);
    expect(res.status, kv.UnlockStatus.ok);
    expect(res.masterKey, equals(mk));
    expect(P.openSealed(res.masterKey!, blob), equals(note));
    expect(s2.failCount, 0);

    // сериализация переживает round-trip
    final restored = kv.KeyringState.fromJson(jsonDecode(jsonEncode(state.toJson())));
    final (_, res2) = await kv.unlock(restored, '13579', hw, 0);
    expect(res2.status, kv.UnlockStatus.ok);
    expect(res2.masterKey, equals(mk));
  });

  test('duress: обратный ПИН распознан, MK не выдан; подложка без duress', () async {
    final hw = SoftwareHardwareKey.generate();
    final (state, mk) = await kv.setup('13579', hw); // обратный = 97531
    final (_, res) = await kv.unlock(state, '97531', hw, 0);
    expect(res.status, kv.UnlockStatus.duress);
    expect(res.masterKey, isNull);

    final (decoy, decoyMk) = await kv.setup('97531', hw, withDuress: false);
    expect(decoyMk, isNot(equals(mk)));
    final (_, r1) = await kv.unlock(decoy, '13579', hw, 0); // исходный → неверный
    expect(r1.status, kv.UnlockStatus.wrong);
    final (_, r2) = await kv.unlock(decoy, '97531', hw, 0); // обратный открывает
    expect(r2.status, kv.UnlockStatus.ok);
  });

  test('нарастающая блокировка', () async {
    expect(kv.lockoutSeconds(1), 0);
    expect(kv.lockoutSeconds(2), 60);
    expect(kv.lockoutSeconds(3), 300);
    expect(kv.lockoutSeconds(6), 86400);

    final hw = SoftwareHardwareKey.generate();
    var (state, mk) = await kv.setup('13579', hw);

    var (s1, r1) = await kv.unlock(state, '00000', hw, 1000.0);
    expect(r1.status, kv.UnlockStatus.wrong);
    expect(kv.remainingLockout(s1, 1000.0), 0);

    var (s2, r2) = await kv.unlock(s1, '00000', hw, 1001.0);
    expect(s2.failCount, 2);
    expect(kv.remainingLockout(s2, 1001.0), 60);

    // во время блокировки даже верный ПИН отклоняется
    var (_, r3) = await kv.unlock(s2, '13579', hw, 1030.0);
    expect(r3.status, kv.UnlockStatus.locked);

    // после окончания — открывает и сбрасывает счётчик
    var (s4, r4) = await kv.unlock(s2, '13579', hw, 1001.0 + 61);
    expect(r4.status, kv.UnlockStatus.ok);
    expect(r4.masterKey, equals(mk));
    expect(s4.failCount, 0);
  });
}
