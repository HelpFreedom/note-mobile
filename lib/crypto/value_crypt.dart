// Шифрование строковых значений (зеркало qtnotes/crypto/valuecrypt.py).
// Для oplog payload: ENC1: || base64(seal). Значение без префикса — plaintext.

import 'dart:convert';
import 'dart:typed_data';

import 'crypto_fs.dart' show VaultLockedException;
import 'primitives.dart' as primitives;
import 'session.dart';

const String encPrefix = 'ENC1:';

bool _encrypting() => Session.encryptionEnabled && Session.isUnlocked;

String sealStr(String plaintext, {required Uint8List info, Uint8List? aad}) {
  if (Session.encryptionEnabled && !Session.isUnlocked) {
    throw VaultLockedException('запись значения при заблокированном хранилище');
  }
  if (_encrypting()) {
    final key = primitives.hkdf(Uint8List.fromList(Session.masterKey!), info);
    final ct = primitives.seal(
        key, Uint8List.fromList(utf8.encode(plaintext)), aad: aad ?? Uint8List(0));
    return encPrefix + base64.encode(ct);
  }
  return plaintext;
}

String openStr(String stored, {required Uint8List info, Uint8List? aad}) {
  if (stored.startsWith(encPrefix)) {
    final mk = Session.masterKey;
    if (mk == null) throw VaultLockedException('зашифрованное значение без ключа');
    final key = primitives.hkdf(Uint8List.fromList(mk), info);
    final pt = primitives.openSealed(
        key, base64.decode(stored.substring(encPrefix.length)), aad: aad ?? Uint8List(0));
    return utf8.decode(pt);
  }
  return stored;
}
