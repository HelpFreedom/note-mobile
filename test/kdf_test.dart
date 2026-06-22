// M1 (mobile): медленный KDF (scrypt) поверх гейта + апгрейд legacy keyring при входе.
// Запуск: dart test test/kdf_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/crypto/hwbackend.dart';
import 'package:qtnotes_mobile/crypto/keyvault.dart' as kv;
import 'package:qtnotes_mobile/crypto/primitives.dart' as p;

void main() {
  test('scrypt KDF: setup/unlock/wrong/duress + сериализация', () async {
    final hw = SoftwareHardwareKey.generate();

    final tSetup = Stopwatch()..start();
    final (state, mk) = await kv.setup('13579', hw);
    tSetup.stop();
    expect(state.kdf?['algo'], 'scrypt');

    final tUnlock = Stopwatch()..start();
    final (_, res) = await kv.unlock(state, '13579', hw, 0);
    tUnlock.stop();
    expect(res.status, kv.UnlockStatus.ok);
    expect(res.masterKey, equals(mk));
    // ignore: avoid_print
    print('scrypt(host): setup ${tSetup.elapsedMilliseconds}ms unlock ${tUnlock.elapsedMilliseconds}ms');

    expect((await kv.unlock(state, '00000', hw, 0)).$2.status, kv.UnlockStatus.wrong);
    expect((await kv.unlock(state, '97531', hw, 0)).$2.status, kv.UnlockStatus.duress);

    // сериализация сохраняет kdf
    final restored = kv.KeyringState.fromJson(jsonDecode(jsonEncode(state.toJson())));
    expect(restored.kdf?['algo'], 'scrypt');
    expect((await kv.unlock(restored, '13579', hw, 0)).$2.masterKey, equals(mk));
  });

  test('legacy keyring (kdf=null) разворачивается и апгрейдится на scrypt', () async {
    final hw = SoftwareHardwareKey.generate();
    // собираем legacy публичными примитивами (как было до M1: без растяжения)
    final saltW = p.randomBytes(16), saltD = p.randomBytes(16);
    final mk2 = p.randomBytes(32);
    final infoWrap = Uint8List.fromList(utf8.encode('qtnotes/mk-wrap/v1'));
    final infoDuress = Uint8List.fromList(utf8.encode('qtnotes/duress-tag/v1'));
    final wrapped = p.seal(p.hkdf(await hw.mac(saltW, '24680'), infoWrap), mk2);
    final dtag = p.hkdf(await hw.mac(saltD, '08642'), infoDuress); // обратный к 24680
    final legacy = kv.KeyringState(
        version: 1, saltWrap: saltW, saltDuress: saltD, wrappedMk: wrapped,
        duressTag: dtag, kdf: null);
    expect(legacy.kdf, isNull);

    final (ns2, r2) = await kv.unlock(legacy, '24680', hw, 0);
    expect(r2.status, kv.UnlockStatus.ok);
    expect(r2.masterKey, equals(mk2));
    expect(ns2.kdf?['algo'], 'scrypt', reason: 'legacy должен апгрейдиться при входе');

    // после апгрейда тот же ПИН по-прежнему разворачивает (уже через scrypt)
    expect((await kv.unlock(ns2, '24680', hw, 0)).$2.masterKey, equals(mk2));
    // duress сохранён, неверный — wrong
    expect((await kv.unlock(ns2, '08642', hw, 0)).$2.status, kv.UnlockStatus.duress);
    expect((await kv.unlock(ns2, '11111', hw, 0)).$2.status, kv.UnlockStatus.wrong);
  });
}
