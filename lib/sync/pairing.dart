// Клиент сопряжения (телефон сканирует QR десктопа). Зеркалит клиентскую часть
// qtnotes/sync/pairing.py. Телефон не доверяет cert десктопа заранее — пинит его по
// fingerprint из QR (TOFU), затем сохраняет в trust-store. Свой cert телефон передаёт
// явно в pair_hello (сервер десктопа не запрашивает клиентский cert на уровне TLS).

import 'dart:convert';
import 'dart:io';

import '../storage/models.dart' show nowIso;
import 'identity.dart';
import 'peers.dart';
import 'wire.dart';

class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => 'PairingException: $message';
}

Map<String, dynamic> parsePairingPayload(String text) {
  final d = (jsonDecode(text) as Map).cast<String, dynamic>();
  for (final key in ['did', 'fp', 'host', 'port', 'token']) {
    if (!d.containsKey(key)) throw PairingException('в QR нет поля $key');
  }
  return d;
}

/// Подключиться к десктопу из QR, сверить fingerprint, обменяться доверием.
/// Возвращает Peer десктопа (для занесения в trust-store).
Future<Peer> pairWith(Map<String, dynamic> payload, Identity identity) async {
  final ctx = SecurityContext(withTrustedRoots: false);
  ctx.useCertificateChainBytes(utf8.encode(identity.certPem));
  ctx.usePrivateKeyBytes(utf8.encode(identity.keyPemOrThrow));

  // I6 (раунд-3): таймаут на коннект — иначе при недостижимом/устаревшем QR UI висит
  // до OS-таймаута TCP (минуты) без обратной связи.
  final socket = await SecureSocket.connect(
    payload['host'] as String,
    (payload['port'] as num).toInt(),
    context: ctx,
    // цепочку не валидируем — сверяем fingerprint cert сервера с тем, что в QR
    onBadCertificate: (cert) => fingerprintFromDer(cert.der) == payload['fp'],
  ).timeout(const Duration(seconds: 8));
  try {
    final serverCert = socket.peerCertificate;
    if (serverCert == null) throw PairingException('сервер не предъявил cert');
    final serverPem = serverCert.pem;

    final reader = ByteReader(socket);
    writeMessage(socket, {
      'type': 'pair_hello',
      'token': payload['token'],
      'device_id': identity.deviceId,
      'name': identity.name,
      'cert_pem': identity.certPem,
    });
    await socket.flush();

    final f = await readFrame(reader);
    if (!f.isControl || f.control!['type'] != 'pair_ok') {
      throw PairingException('сопряжение отклонено: ${f.control}');
    }
    return Peer(payload['did'] as String, (f.control!['name'] ?? '') as String,
        serverPem, nowIso());
  } finally {
    socket.destroy();
  }
}
