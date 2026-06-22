// TLS-транспорт со взаимной аутентификацией по pinned-сертификатам.
//
// Доверие не через CA: клиент пинит cert сервера по fingerprint (onBadCertificate),
// сервер запрашивает клиентский cert и проверяет его device_id по trust-store вручную
// (Dart не валидирует самоподписанный клиентский cert цепочкой). device_id выводится
// из cert так же, как на десктопе.

import 'dart:convert';
import 'dart:io';

import 'identity.dart';

SecurityContext baseContext(String certPem, String keyPem) {
  final ctx = SecurityContext(withTrustedRoots: false);
  ctx.useCertificateChainBytes(utf8.encode(certPem));
  ctx.usePrivateKeyBytes(utf8.encode(keyPem));
  return ctx;
}

/// device_id пира из его cert (после рукопожатия).
String? peerDeviceId(SecureSocket socket) {
  final cert = socket.peerCertificate;
  if (cert == null) return null;
  return fingerprintFromDer(cert.der).substring(0, 16);
}

/// Запустить TLS-сервер. Доверенные cert пиров добавляются как корневые, поэтому
/// самоподписанный cert доверенного устройства проходит проверку, а чужой —
/// отвергается на рукопожатии (как CERT_REQUIRED + load_verify_locations на десктопе).
Future<SecureServerSocket> startServer(Identity identity, List<String> trustedPems,
    {String host = '0.0.0.0', int port = 0}) {
  final ctx = baseContext(identity.certPem, identity.keyPemOrThrow);
  final hasTrust = trustedPems.where((p) => p.isNotEmpty).isNotEmpty;
  if (hasTrust) {
    ctx.setTrustedCertificatesBytes(utf8.encode(trustedPems.join('\n')));
  }
  return SecureServerSocket.bind(host, port, ctx,
      requireClientCertificate: hasTrust);
}

/// Подключиться к серверу, закрепив его cert по fingerprint (pinning).
///
/// Таймаут обязателен: если пир недоступен (например, телефон в мобильной сети, а
/// не в общем Wi-Fi), TCP-connect без таймаута висит минутами и блокирует вызывающий
/// код. Здесь обрываем попытку быстро — пир просто считается офлайн.
Future<SecureSocket> connect(
    String host, int port, Identity identity, String expectedServerFingerprint,
    {Duration timeout = const Duration(seconds: 6)}) {
  final ctx = baseContext(identity.certPem, identity.keyPemOrThrow);
  return SecureSocket.connect(
    host,
    port,
    context: ctx,
    onBadCertificate: (cert) =>
        fingerprintFromDer(cert.der) == expectedServerFingerprint,
  ).timeout(timeout);
}
