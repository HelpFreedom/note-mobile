import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/transport.dart';
import 'package:qtnotes_mobile/sync/wire.dart';

void main() {
  test('взаимный TLS (pinning): обмен CONTROL+BLOB, сверка device_id', () async {
    final dirA = await Directory.systemTemp.createTemp('qtn_ta_');
    final dirB = await Directory.systemTemp.createTemp('qtn_tb_');
    final idA = await ensureIdentity(Directory('${dirA.path}/d'), 'A');
    final idB = await ensureIdentity(Directory('${dirB.path}/d'), 'B');
    final blob = Uint8List.fromList(List<int>.generate(200, (i) => (i * 7) % 256));
    final blobSha = sha256.convert(blob).toString();

    final server = await startServer(idB, [idA.certPem], host: '127.0.0.1', port: 0);
    final seen = <String, dynamic>{};
    server.listen((socket) async {
      seen['server_sees'] = peerDeviceId(socket);
      final r = ByteReader(socket);
      final f = await readFrame(r);
      seen['got'] = f.control;
      writeMessage(socket, {'type': 'hello', 'device_id': idB.deviceId});
      writeBlob(socket, blobSha, blob);
      await socket.flush();
    });

    final client = await connect('127.0.0.1', server.port, idA, idB.fingerprint);
    final clientSees = peerDeviceId(client);
    writeMessage(client, {'type': 'hello', 'device_id': idA.deviceId});
    await client.flush();
    final r = ByteReader(client);
    final f1 = await readFrame(r); // hello
    final f2 = await readFrame(r); // blob
    await client.close();
    await server.close();

    expect(seen['server_sees'], idA.deviceId);
    expect(clientSees, idB.deviceId);
    expect((seen['got'] as Map)['device_id'], idA.deviceId);
    expect(f1.control!['device_id'], idB.deviceId);
    expect(f2.isControl, isFalse);
    expect(f2.blobSha, blobSha);
    expect(f2.blobData, equals(blob));

    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });

  test('сервер закрывает соединение для недоверенного клиента', () async {
    final dirA = await Directory.systemTemp.createTemp('qtn_a_');
    final dirB = await Directory.systemTemp.createTemp('qtn_b_');
    final dirC = await Directory.systemTemp.createTemp('qtn_c_');
    final idA = await ensureIdentity(Directory('${dirA.path}/d'), 'A'); // доверенный
    final idB = await ensureIdentity(Directory('${dirB.path}/d'), 'B'); // сервер
    final idC = await ensureIdentity(Directory('${dirC.path}/d'), 'C'); // чужой

    // сервер доверяет только A; C не в списке → рукопожатие отвергнется
    final server = await startServer(idB, [idA.certPem], host: '127.0.0.1', port: 0);
    server.listen((socket) {}, onError: (Object _) {}); // отказ рукопожатия — не ошибка теста

    var failed = false;
    try {
      final c = await connect('127.0.0.1', server.port, idC, idB.fingerprint);
      final r = ByteReader(c);
      writeMessage(c, {'type': 'hello'});
      await c.flush();
      await readFrame(r); // сервер уже уничтожил сокет → исключение
    } catch (_) {
      failed = true;
    }
    await server.close();
    expect(failed, isTrue, reason: 'недоверенный клиент НЕ был отвергнут');

    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
    await dirC.delete(recursive: true);
  });
}
