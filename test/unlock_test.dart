// Тест контроллера разблокировки (Ф5b) на программном бэкенде.
// Запуск: dart test test/unlock_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:qtnotes_mobile/crypto/hwbackend.dart';
import 'package:qtnotes_mobile/crypto/keyvault.dart' as kv;
import 'package:qtnotes_mobile/crypto/session.dart';
import 'package:qtnotes_mobile/crypto/unlock.dart';

void main() {
  late Directory dir;
  late UnlockController ctl;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('qtnotes-unlock-');
    Session.lock();
    Session.encryptionEnabled = false;
    final sw = SoftwareHardwareKey.generate();
    ctl = UnlockController(File('${dir.path}/keyring.json'), (_) => sw);
  });

  tearDown(() {
    Session.lock();
    Session.encryptionEnabled = false;
    dir.deleteSync(recursive: true);
  });

  test('setup + unlock', () async {
    expect(await ctl.isConfigured(), isFalse);
    final mk = await ctl.setupPin('13579'); // обратный = 97531
    expect(Session.isUnlocked, isTrue);
    expect(Session.masterKey, equals(mk));
    expect(await ctl.isConfigured(), isTrue);

    Session.lock();
    final res = await ctl.tryUnlock('13579');
    expect(res.status, kv.UnlockStatus.ok);
    expect(res.masterKey, equals(mk));
    expect(Session.isUnlocked, isTrue);
  });

  test('lockout после 2 неверных', () async {
    await ctl.setupPin('13579');
    Session.lock();
    final r1 = await ctl.tryUnlock('00000', now: 1000.0);
    expect(r1.status, kv.UnlockStatus.wrong);
    final r2 = await ctl.tryUnlock('00000', now: 1001.0);
    expect(r2.status, kv.UnlockStatus.wrong);
    expect(await ctl.remainingLockout(now: 1001.0), 60);
    final r3 = await ctl.tryUnlock('13579', now: 1030.0);
    expect(r3.status, kv.UnlockStatus.locked);
    final r4 = await ctl.tryUnlock('13579', now: 1062.0);
    expect(r4.status, kv.UnlockStatus.ok);
  });

  test('duress: обратный ПИН вызывает хук и открывает подложку (OK)', () async {
    await ctl.setupPin('13579');
    Session.lock();
    final decoyKey = Uint8List(32)..fillRange(0, 32, 7);
    String? gotPin;
    ctl.onDuress = (pin) async {
      gotPin = pin;
      Session.masterKey = decoyKey;
      return decoyKey;
    };
    final res = await ctl.tryUnlock('97531');
    expect(gotPin, '97531');
    expect(res.status, kv.UnlockStatus.ok);
    expect(res.masterKey, equals(decoyKey));
  });

  test('isConfigured ложно без файла', () async {
    expect(await ctl.isConfigured(), isFalse);
    expect(await ctl.remainingLockout(), 0);
  });
}
