// S1: приватный ключ синка (device_key.pem) шифруется at-rest под MK; cert остаётся
// плейнтекстом (нужен для device_id); ключ догружается после разблокировки.
//
// Запуск: dart test test/sync_identity_enc_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/crypto/crypto_fs.dart' as cfs;
import 'package:qtnotes_mobile/crypto/session.dart';
import 'package:qtnotes_mobile/sync/identity.dart';

void _lockPlain() {
  Session.masterKey = null;
  Session.encryptionEnabled = false;
}

void _unlock(Uint8List mk) {
  Session.masterKey = mk;
  Session.encryptionEnabled = true;
}

void main() {
  late Directory tmp;
  setUp(() async {
    _lockPlain();
    tmp = await Directory.systemTemp.createTemp('qtn_iden_');
  });
  tearDown(() async {
    _lockPlain();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List mk() => Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));

  test('шифрование ВЫКЛ: ключ на диске плейнтекстом, keyPem непустой', () async {
    final dev = Directory('${tmp.path}/device');
    final id = await ensureIdentity(dev, 'Телефон');
    expect(id.keyAvailable, isTrue);
    final raw = await File('${dev.path}/device_key.pem').readAsBytes();
    expect(cfs.startsWithMagic(raw), isFalse, reason: 'без шифрования — без magic');
    // device_id стабилен при перезагрузке
    final id2 = await ensureIdentity(dev, 'Телефон');
    expect(id2.deviceId, id.deviceId);
    expect(id2.keyPem, id.keyPem);
  });

  test('шифрование ВКЛ: ключ на диске — шифртекст (magic), расшифровывается', () async {
    _unlock(mk());
    final dev = Directory('${tmp.path}/device');
    final id = await ensureIdentity(dev, 'Телефон');
    expect(id.keyAvailable, isTrue);
    final raw = await File('${dev.path}/device_key.pem').readAsBytes();
    expect(cfs.startsWithMagic(raw), isTrue, reason: 'ключ должен быть зашифрован');
    // перезагрузка под тем же MK — ключ читается корректно
    final id2 = await ensureIdentity(dev, 'Телефон');
    expect(id2.deviceId, id.deviceId);
    expect(id2.keyPem, id.keyPem);
  });

  test('locked: device_id из cert доступен, keyPem пуст; разблокировка догружает ключ',
      () async {
    final key = mk();
    _unlock(key);
    final dev = Directory('${tmp.path}/device');
    final created = await ensureIdentity(dev, 'Телефон'); // создан зашифрованным
    final expectedKey = created.keyPem;
    final expectedId = created.deviceId;

    // имитируем старт в заблокированном состоянии: MK нет, но шифрование настроено
    Session.masterKey = null;
    Session.encryptionEnabled = true;
    final locked = await ensureIdentity(dev, 'Телефон');
    expect(locked.deviceId, expectedId, reason: 'device_id из cert — без ключа');
    expect(locked.keyAvailable, isFalse, reason: 'ключ недоступен под locked');
    expect(() => locked.keyPemOrThrow, throwsStateError);

    // разблокировка → ключ догружается
    _unlock(key);
    final unlocked = await ensureIdentity(dev, 'Телефон');
    expect(unlocked.keyAvailable, isTrue);
    expect(unlocked.keyPem, expectedKey);
  });

  test('cert на диске ВСЕГДА плейнтекст (нужен для device_id до разблокировки)', () async {
    _unlock(mk());
    final dev = Directory('${tmp.path}/device');
    await ensureIdentity(dev, 'Телефон');
    final certRaw = await File('${dev.path}/device_cert.pem').readAsBytes();
    expect(cfs.startsWithMagic(certRaw), isFalse);
    expect(String.fromCharCodes(certRaw), contains('BEGIN CERTIFICATE'));
  });
}
