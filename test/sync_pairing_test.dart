import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/pairing.dart';
import 'package:qtnotes_mobile/sync/peers.dart';
import 'package:qtnotes_mobile/sync/wire.dart';

void main() {
  test('сопряжение: обмен доверием, отказ при подмене fingerprint/токене', () async {
    final dirD = await Directory.systemTemp.createTemp('qtn_pd_');
    final dirP = await Directory.systemTemp.createTemp('qtn_pp_');
    final idDesktop = await ensureIdentity(Directory('${dirD.path}/device'), 'Десктоп');
    final idPhone = await ensureIdentity(Directory('${dirP.path}/device'), 'Телефон');
    const token = 'secret-token-123';

    // stub pairing-сервера десктопа: TLS без запроса клиентского cert (CERT_NONE)
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(idDesktop.certPem))
      ..usePrivateKeyBytes(utf8.encode(idDesktop.keyPem));
    final server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
    Peer? gotPhone;
    server.listen((socket) async {
      try {
        final r = ByteReader(socket);
        final f = await readFrame(r);
        final msg = f.control!;
        if (msg['type'] == 'pair_hello' && msg['token'] == token) {
          gotPhone = Peer(deviceIdFromCertPem(msg['cert_pem'] as String),
              msg['name'] as String, msg['cert_pem'] as String, 'now');
          writeMessage(socket,
              {'type': 'pair_ok', 'device_id': idDesktop.deviceId, 'name': idDesktop.name});
        } else {
          writeMessage(socket, {'type': 'pair_err', 'reason': 'token'});
        }
        await socket.flush();
      } catch (_) {}
    }, onError: (Object _) {});

    Map<String, dynamic> payload({String? fp, String? tok}) => {
          'v': 1,
          'did': idDesktop.deviceId,
          'fp': fp ?? idDesktop.fingerprint,
          'name': idDesktop.name,
          'host': '127.0.0.1',
          'port': server.port,
          'token': tok ?? token,
        };

    // успех
    final peer = await pairWith(payload(), idPhone);
    expect(peer.deviceId, idDesktop.deviceId);
    expect(fingerprintFromCertPem(peer.certPem), idDesktop.fingerprint);
    expect(gotPhone, isNotNull);
    expect(gotPhone!.deviceId, idPhone.deviceId);

    // подмена fingerprint → рукопожатие/сопряжение падает
    await expectLater(pairWith(payload(fp: '0' * 64), idPhone), throwsA(anything));

    // неверный token → pair_err → исключение
    await expectLater(
        pairWith(payload(tok: 'wrong'), idPhone), throwsA(isA<PairingException>()));

    await server.close();
    await dirD.delete(recursive: true);
    await dirP.delete(recursive: true);
  });

  test('parsePairingPayload требует ключевые поля', () {
    final ok = parsePairingPayload(jsonEncode(
        {'v': 1, 'did': 'x', 'fp': 'y', 'host': 'h', 'port': 1, 'token': 't'}));
    expect(ok['did'], 'x');
    expect(() => parsePairingPayload(jsonEncode({'did': 'x'})), throwsA(anything));
  });
}
