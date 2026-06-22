// Личность устройства: ключ + самоподписанный cert + стабильный device_id.
//
// device_id = первые 16 hex от sha256(DER сертификата) — ТОТ ЖЕ алгоритм, что на
// десктопе (qtnotes/sync/identity.py). Сам cert тут RSA (а не EC), но это неважно:
// каждое устройство выводит id из СВОЕГО cert, а при сверке считает sha256 от cert
// пира — алгоритм одинаков на обеих платформах, значит id совпадают.

import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

import '../crypto/crypto_fs.dart' as cfs;

class Identity {
  final String deviceId;
  final String fingerprint;
  final String name;
  final String certPem;

  /// Приватный ключ синка в PEM. ПУСТАЯ строка означает «недоступен» — ключ зашифрован
  /// at-rest под MK и хранилище ещё заблокировано (device_id берётся из cert, поэтому
  /// личность валидна и без ключа). Ключ догружается после разблокировки.
  final String keyPem;
  Identity(this.deviceId, this.fingerprint, this.name, this.certPem, this.keyPem);

  bool get keyAvailable => keyPem.isNotEmpty;

  /// Приватный ключ для TLS-стека; бросает, если недоступен (хранилище заблокировано).
  String get keyPemOrThrow {
    if (keyPem.isEmpty) {
      throw StateError('приватный ключ синка недоступен (хранилище заблокировано)');
    }
    return keyPem;
  }
}

/// Прочитать приватный ключ через прозрачный крипто-слой. Если файл зашифрован, а
/// хранилище заблокировано — вернуть '' (ключ догрузится после разблокировки).
Future<String> _readKeyPem(File keyFile, Directory root) async {
  try {
    final raw = await cfs.readBytesEnc(keyFile, root);
    return raw == null ? '' : utf8.decode(raw);
  } on cfs.VaultLockedException {
    return '';
  }
}

/// Записать приватный ключ через крипто-слой (шифруется, если разблокировано+вкл).
Future<void> _writeKeyPem(File keyFile, String keyPem, Directory root) async {
  try {
    await cfs.writeBytesEnc(keyFile, utf8.encode(keyPem), root);
  } on cfs.VaultLockedException {
    // Редко: шифрование включено, но мы заблокированы (свежая личность подложки после
    // duress до первой разблокировки). Пишем плейнтекст — он будет дошифрован при
    // следующей разблокировке (AppService._ensureDeviceKeyEncrypted).
    await keyFile.writeAsString(keyPem);
  }
}

List<int> _derFromPem(String pem) {
  final cleaned = pem
      .replaceAll(RegExp(r'-----BEGIN[^-]*-----'), '')
      .replaceAll(RegExp(r'-----END[^-]*-----'), '')
      .replaceAll(RegExp(r'\s'), ''); // убрать переводы строк/\r/пробелы
  return base64.decode(cleaned);
}

String fingerprintFromCertPem(String certPem) =>
    sha256.convert(_derFromPem(certPem)).toString();

String deviceIdFromCertPem(String certPem) =>
    fingerprintFromCertPem(certPem).substring(0, 16);

/// sha256(DER) от уже разобранного X509 (для cert пира из TLS — у него есть .der).
String fingerprintFromDer(List<int> der) => sha256.convert(der).toString();

Future<Identity> ensureIdentity(Directory deviceDir, String name) async {
  await deviceDir.create(recursive: true);
  final root = deviceDir.parent; // device/ лежит прямо под root → relPath = device/...
  final certFile = File(p.join(deviceDir.path, 'device_cert.pem'));
  final keyFile = File(p.join(deviceDir.path, 'device_key.pem'));

  String certPem;
  String keyPem;
  if (await certFile.exists() && await keyFile.exists()) {
    certPem = await certFile.readAsString(); // cert публичный → плейнтекст (нужен для id)
    keyPem = await _readKeyPem(keyFile, root); // приватный ключ → шифр at-rest под MK
  } else {
    final pair = CryptoUtils.generateRSAKeyPair();
    final priv = pair.privateKey as pc.RSAPrivateKey;
    final pub = pair.publicKey as pc.RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': name}, priv, pub);
    // cert — самоподписанный CA: BoringSSL (Dart TLS) принимает доверенный cert как
    // якорь только если он CA. Так десктоп и телефон валидируют cert друг друга.
    // (только basicConstraints CA:TRUE — keyUsage/extKeyUsage в basic_utils ломают
    // ASN.1, BoringSSL не парсит такой cert.)
    // Срок < 2050: basic_utils кодирует время как UTCTime, который не поддерживает
    // годы ≥ 2050 (иначе cert выглядит «просроченным»). 2020..~2044 — безопасно.
    certPem = X509Utils.generateSelfSignedCertificate(
      priv, csr, 9000, // ~24.6 года
      cA: true,
      notBefore: DateTime.utc(2020, 1, 1),
    );
    keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(priv);
    await certFile.writeAsString(certPem);
    await _writeKeyPem(keyFile, keyPem, root);
  }

  final fp = fingerprintFromCertPem(certPem);
  return Identity(fp.substring(0, 16), fp, name, certPem, keyPem);
}
