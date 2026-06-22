import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/peers.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('qtn_id_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('identity: стабильный device_id, выводится из cert', () async {
    final dir = Directory('${tmp.path}/device');
    final id1 = await ensureIdentity(dir, 'Телефон');
    expect(id1.deviceId.length, 16);
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id1.deviceId), isTrue);
    expect(id1.fingerprint.startsWith(id1.deviceId), isTrue);
    expect(id1.certPem.contains('CERTIFICATE'), isTrue);
    expect(id1.keyPem.isNotEmpty, isTrue);

    // повторный вызов — та же личность (ключ не перегенерён)
    final id2 = await ensureIdentity(dir, 'Телефон');
    expect(id2.deviceId, id1.deviceId);
    expect(id2.certPem, id1.certPem);

    // device_id выводится из cert тем же алгоритмом, что у пира
    expect(deviceIdFromCertPem(id1.certPem), id1.deviceId);
  });

  test('peers: trust-store add/get/update/remove', () async {
    final store = PeerStore(File('${tmp.path}/peers.json'));
    expect(await store.list(), isEmpty);
    await store.add('aabbccddeeff0011', 'Десктоп', '-----CERT-----');
    expect(await store.isTrusted('aabbccddeeff0011'), isTrue);
    final p = await store.get('aabbccddeeff0011');
    expect(p!.name, 'Десктоп');
    expect(p.pairedAt.isNotEmpty, isTrue);
    await store.add('aabbccddeeff0011', 'Мой ПК', '-----CERT2-----');
    expect((await store.list()).length, 1);
    expect((await store.get('aabbccddeeff0011'))!.name, 'Мой ПК');
    await store.remove('aabbccddeeff0011');
    expect(await store.isTrusted('aabbccddeeff0011'), isFalse);
  });
}
