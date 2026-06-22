// Тест крипто-слоя хранилища на Dart (Ф5a): шифрование JSON/blobs/events/shared/oplog,
// доступ к вложениям через расшифровку, обратная совместимость, отказ при locked.
// Запуск: dart test test/vault_crypto_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:qtnotes_mobile/crypto/crypto_fs.dart' as cfs;
import 'package:qtnotes_mobile/crypto/primitives.dart' as P;
import 'package:qtnotes_mobile/crypto/session.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

Directory _tmp() => Directory.systemTemp.createTempSync('qtnotes-vault-crypto-');

void _reset() {
  Session.lock();
  Session.encryptionEnabled = false;
}

void main() {
  tearDown(_reset);

  test('plaintext по умолчанию (поведение прежнее)', () async {
    final dir = _tmp();
    final v = Vault(dir);
    final f = await v.createFolder(name: 'Личное');
    final n = Note.createText(folderId: f.id, html: '<p>привет</p>', plaintext: 'привет');
    await v.saveNote(n);

    final fp = File('${dir.path}/folders/${f.id}/folder.json');
    expect(await cfs.isEncryptedFile(fp), isFalse);
    expect((jsonDecode(await fp.readAsString()) as Map)['name'], 'Личное');
    dir.deleteSync(recursive: true);
  });

  test('зашифрованный round-trip: файлы/blobs/events/shared/oplog', () async {
    final dir = _tmp();
    Session.encryptionEnabled = true;
    Session.masterKey = P.randomBytes(32);
    final v = Vault(dir);

    final f = await v.createFolder(name: 'Секреты');
    final n = Note.createText(folderId: f.id, html: '<p>пароль 42</p>', plaintext: 'пароль 42');
    await v.saveNote(n);
    await v.addEvent('2026-06-21', 'День X', '#ff0000');
    await v.applySettingPut('theme', {'accent': '#123456'});

    final fp = File('${dir.path}/folders/${f.id}/folder.json');
    final np = File('${dir.path}/folders/${f.id}/notes/${n.id}.json');
    final ep = File('${dir.path}/calendar/events.json');
    final sp = File('${dir.path}/shared.json');
    for (final p in [fp, np, ep, sp]) {
      expect(await cfs.isEncryptedFile(p), isTrue, reason: p.path);
    }
    // слово «пароль» не должно лежать в открытом виде
    final npBytes = await np.readAsBytes();
    expect(utf8.decode(npBytes, allowMalformed: true).contains('пароль'), isFalse);

    // данные читаются
    expect((await v.findNote(n.id))!.plaintext, 'пароль 42');
    expect((await v.listEvents()).first.name, 'День X');
    expect((await v.getShared('theme'))['accent'], '#123456');

    // blob round-trip
    final data = Uint8List.fromList([1, 2, 3, 200, 201, 202]);
    final sha = await () async {
      await v.writeBlob('deadbeef' * 8, data); // фиктивный sha как имя
      return 'deadbeef' * 8;
    }();
    final bp = v.blobPath(sha);
    expect(await cfs.isEncryptedFile(bp), isTrue);
    expect(await v.readBlob(sha), equals(data));

    // oplog файл зашифрован, но операции читаются
    final ol = OpLog(File('${dir.path}/sync.json'), localId: 'dev1');
    await ol.appendLocal('note.put', n.id, {'plaintext': 'секрет oplog'});
    expect(await cfs.isEncryptedFile(File('${dir.path}/sync.json')), isTrue);
    final ol2 = OpLog(File('${dir.path}/sync.json'), localId: 'dev1');
    final ops = await ol2.allOps();
    expect(ops.first['payload']['plaintext'], 'секрет oplog');

    dir.deleteSync(recursive: true);
  });

  test('вложение: ensureBlobs шифрует, attachmentAccessPath расшифровывает', () async {
    final dir = _tmp();
    Session.encryptionEnabled = true;
    Session.masterKey = P.randomBytes(32);
    final v = Vault(dir);

    final f = await v.createFolder(name: 'Картинки');
    final n = Note.createText(folderId: f.id, html: '<p>фото</p>', plaintext: 'фото');
    final adir = v.attachmentsDir(f.id, n.id);
    await adir.create(recursive: true);
    final payload = Uint8List.fromList(List.generate(300, (i) => i % 256));
    await File('${adir.path}/pic.png').writeAsBytes(payload);
    n.attachments.add(Attachment(file: 'pic.png', mime: 'image/png', name: 'pic.png', size: payload.length));

    await v.ensureBlobs(n);
    final att = n.attachments.first;
    expect(att.sha256.isNotEmpty, isTrue);
    expect(await cfs.isEncryptedFile(v.blobPath(att.sha256)), isTrue);

    final access = await v.attachmentAccessPath(n, att);
    expect(access, isNotNull); // валидный зашифрованный blob → расшифрованный путь
    final accessFile = access!;
    expect(accessFile.path.contains('qtnotes-blobs-'), isTrue);
    expect(await accessFile.readAsBytes(), equals(payload));
    expect(accessFile.path.endsWith('.png'), isTrue);
    await v.wipeBlobCache();
    expect(await accessFile.exists(), isFalse);

    dir.deleteSync(recursive: true);
  });

  test('ingestAttachment: приём вложения в изоляте шифрует blob, sha верный', () async {
    final dir = _tmp();
    Session.encryptionEnabled = true;
    Session.masterKey = P.randomBytes(32);
    final v = Vault(dir);

    final src = File('${dir.path}/source.bin');
    final payload = Uint8List.fromList(List.generate(500, (i) => (i * 7) % 256));
    await src.writeAsBytes(payload);

    final (sha, size) = await v.ingestAttachment(src.path);
    expect(size, payload.length);
    // blob на диске зашифрован, читается обратно как плейнтекст, sha совпадает
    expect(await cfs.isEncryptedFile(v.blobPath(sha)), isTrue);
    expect(await v.readBlob(sha), equals(payload));
    expect(sha.length, 64); // sha256 hex
    dir.deleteSync(recursive: true);
  });

  test('обратная совместимость: plaintext читается при включённом шифровании', () async {
    final dir = _tmp();
    final v = Vault(dir);
    // создаём plaintext (шифрование выкл)
    final f = await v.createFolder(name: 'Старое');
    final n = Note.createText(folderId: f.id, html: '<p>legacy</p>', plaintext: 'legacy');
    await v.saveNote(n);
    // включаем шифрование — старый файл всё ещё читается
    Session.encryptionEnabled = true;
    Session.masterKey = P.randomBytes(32);
    expect((await v.findNote(n.id))!.plaintext, 'legacy');
    dir.deleteSync(recursive: true);
  });

  test('отказ записи при заблокированном хранилище', () async {
    final dir = _tmp();
    Session.encryptionEnabled = true;
    Session.lock(); // ключа нет
    final v = Vault(dir);
    expect(() => v.createFolder(name: 'x'), throwsA(isA<cfs.VaultLockedException>()));
    dir.deleteSync(recursive: true);
  });
}
