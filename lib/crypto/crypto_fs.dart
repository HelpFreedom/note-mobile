// Прозрачный крипто-слой файлов (зеркало qtnotes/storage/crypto_fs.py).
//
// Шифрование выкл → plaintext (как было). Вкл+разблокировано → файл с magic-заголовком
// QTNC1\n и AES-GCM (субключ HKDF(MK,"file/"+relPath), aad=relPath). Файл без magic
// читается как plaintext (обратная совместимость). relPath — путь относительно root.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'blob_crypto.dart';
import 'primitives.dart' as primitives;
import 'session.dart';

final List<int> magic = utf8.encode('QTNC1\n'); // 6 байт
final Uint8List _infoPrefix = Uint8List.fromList(utf8.encode('file/'));

class VaultLockedException implements Exception {
  final String message;
  VaultLockedException(this.message);
  @override
  String toString() => message;
}

bool _encrypting() => Session.encryptionEnabled && Session.isUnlocked;

// Монотонный счётчик для УНИКАЛЬНЫХ tmp-имён: при одновременной записи одного файла
// (UI-правка и применение входящего синка в одном изоляте, чередуясь на await) общий
// `<path>.tmp` портил бы друг друга / ловил ошибку rename. Инкремент без await — атомарен.
int _tmpSeq = 0;

String _relInfoStr(File f, Directory root) {
  try {
    return p.relative(f.path, from: root.path);
  } catch (_) {
    return p.basename(f.path);
  }
}

Uint8List _subkey(List<int> mk, Uint8List info) =>
    primitives.hkdf(Uint8List.fromList(mk),
        Uint8List.fromList([..._infoPrefix, ...info]));

bool _startsWith(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// Начинается ли содержимое с magic-заголовка (т.е. зашифровано нашим слоем).
bool startsWithMagic(List<int> data) => _startsWith(data, magic);

/// Субключ файла = HKDF(MK, "file/"+relInfo). Публично — чтобы native-путь (Kotlin AES)
/// и pure-Dart использовали ОДИН вывод ключа (совместимость формата).
Uint8List fileSubkey(Uint8List mk, String relInfo) =>
    _subkey(mk, Uint8List.fromList(utf8.encode(relInfo)));

/// AAD файла = relInfo (как в seal/openSealed).
Uint8List fileAad(String relInfo) => Uint8List.fromList(utf8.encode(relInfo));

Future<void> writeBytesEnc(File f, List<int> data, Directory root) async {
  if (Session.encryptionEnabled && !Session.isUnlocked) {
    throw VaultLockedException('запись при заблокированном хранилище');
  }
  await f.parent.create(recursive: true);
  List<int> out;
  if (_encrypting()) {
    // C1: шифруем через BlobCrypto → на устройстве быстрый native AES, иначе pure-Dart
    // в Isolate.run. Раньше GCM шёл синхронно на UI-изоляте (фриз при большом oplog/
    // пересборке индекса). Формат идентичен (magic||nonce||ct+tag).
    out = await BlobCrypto.sealFileContent(Uint8List.fromList(Session.masterKey!),
        _relInfoStr(f, root), Uint8List.fromList(data));
  } else {
    out = data;
  }
  final tmp = File('${f.path}.${_tmpSeq++}.tmp'); // уникальный tmp — без гонки имён
  // flush:true → содержимое сброшено на диск (fsync файла) ДО rename, иначе при потере
  // питания файл окажется пустым/битым. fsync каталога в Dart недоступен (ОС упорядочит
  // rename после данных в ext4 ordered-mode).
  await tmp.writeAsBytes(out, flush: true);
  await tmp.rename(f.path);
}

Future<Uint8List?> readBytesEnc(File f, Directory root) async {
  Uint8List raw;
  try {
    if (!await f.exists()) return null;
    raw = await f.readAsBytes();
  } catch (_) {
    return null;
  }
  if (_startsWith(raw, magic)) {
    final mk = Session.masterKey;
    if (mk == null) {
      throw VaultLockedException('зашифрованный файл без ключа: ${p.basename(f.path)}');
    }
    // C1: расшифровка через BlobCrypto (native/Isolate) — не блокируем UI-изолят.
    return BlobCrypto.openFileContent(
        Uint8List.fromList(mk), _relInfoStr(f, root), raw);
  }
  return raw;
}

Future<void> writeJsonEnc(File f, Object data, Directory root) => writeBytesEnc(
    f, utf8.encode(const JsonEncoder.withIndent('  ').convert(data)), root);

Future<dynamic> readJsonEnc(File f, Directory root) async {
  final raw = await readBytesEnc(f, root);
  if (raw == null) return null;
  try {
    return jsonDecode(utf8.decode(raw));
  } catch (_) {
    return null;
  }
}

Future<bool> isEncryptedFile(File f) async {
  try {
    final raf = await f.open();
    final head = await raf.read(magic.length);
    await raf.close();
    return _startsWith(head, magic);
  } catch (_) {
    return false;
  }
}

/// Расшифровать сырые байты файла ЯВНЫМ ключом (без Session) — для фонового изолята,
/// где глобальный Session недоступен. relInfo = путь относительно root (как в _relInfo).
/// Возвращает plaintext; для файла без magic — те же байты.
Uint8List? decryptRawWith(Uint8List raw, Uint8List mk, String relInfo) {
  if (!_startsWith(raw, magic)) return raw;
  final info = Uint8List.fromList(utf8.encode(relInfo));
  return primitives.openSealed(
      _subkey(mk, info), Uint8List.fromList(raw.sublist(magic.length)), aad: info);
}

/// Зашифровать байты ЯВНЫМ ключом (без Session), вернуть содержимое файла
/// (magic || sealed). Парная к decryptRawWith — для фонового изолята.
Uint8List encryptRawWith(Uint8List data, Uint8List mk, String relInfo) {
  final info = Uint8List.fromList(utf8.encode(relInfo));
  final sealed = primitives.seal(_subkey(mk, info), data, aad: info);
  return Uint8List.fromList([...magic, ...sealed]);
}
