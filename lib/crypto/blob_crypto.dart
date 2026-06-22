// Шифрование/расшифровка СОДЕРЖИМОГО blob-файлов. Нативный AES (быстро) ставится
// приложением через хуки nativeEncrypt/nativeDecrypt; в чистых dart-тестах хуки null →
// pure-Dart фоллбэк. Так vault.dart НЕ тащит flutter/services (тесты компилируются).
//
// Формат идентичен crypto_fs: magic || nonce(12) || ct+tag. HKDF/AAD берём из crypto_fs
// (fileSubkey/fileAad) — чтобы native и pure-Dart были совместимы и читали старые данные.

import 'dart:isolate';
import 'dart:typed_data';

import 'crypto_fs.dart' as cfs;
import 'primitives.dart' as primitives;

typedef AesFn = Future<Uint8List?> Function(
    Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data);

class BlobCrypto {
  /// Нативные реализации AES-GCM (ставит приложение в main). В тестах — null.
  static AesFn? nativeEncrypt;
  static AesFn? nativeDecrypt;

  /// Содержимое зашифрованного blob-файла (magic||nonce||ct+tag) для plaintext `data`.
  static Future<Uint8List> sealFileContent(
      Uint8List mk, String relInfo, Uint8List data) async {
    final key = cfs.fileSubkey(mk, relInfo);
    final aad = cfs.fileAad(relInfo);
    final nonce = primitives.randomBytes(12);
    final fn = nativeEncrypt;
    if (fn != null) {
      final ct = await fn(key, nonce, aad, data);
      if (ct != null) return Uint8List.fromList([...cfs.magic, ...nonce, ...ct]);
    }
    // фоллбэк pure-Dart (в изоляте, чтобы не блокировать там, где нет нативного AES)
    return Isolate.run(() => cfs.encryptRawWith(data, mk, relInfo));
  }

  /// Plaintext из содержимого blob-файла. Для файла без magic — те же байты.
  static Future<Uint8List?> openFileContent(
      Uint8List mk, String relInfo, Uint8List fileBytes) async {
    if (!cfs.startsWithMagic(fileBytes)) return fileBytes;
    final key = cfs.fileSubkey(mk, relInfo);
    final aad = cfs.fileAad(relInfo);
    final body = fileBytes.sublist(cfs.magic.length);
    final nonce = Uint8List.fromList(body.sublist(0, 12));
    final ctTag = Uint8List.fromList(body.sublist(12));
    final fn = nativeDecrypt;
    if (fn != null) {
      final pt = await fn(key, nonce, aad, ctTag);
      if (pt != null) return pt;
    }
    return Isolate.run(() => cfs.decryptRawWith(fileBytes, mk, relInfo));
  }
}
