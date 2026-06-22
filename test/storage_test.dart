import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';

void main() {
  late Directory tmp;
  late Vault vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qtnotes_test_');
    vault = Vault(tmp);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('nowIso совпадает с форматом Python isoformat(microseconds)+00:00', () {
    final s = nowIso();
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00$').hasMatch(s),
        isTrue, reason: s);
  });

  test('newId — 32 hex-символа', () {
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(newId()), isTrue);
  });

  test('папки/заметки: CRUD, порядок, roundtrip сериализации', () async {
    final f1 = await vault.createFolder(name: 'Работа', caption: 'раб', color: '#5288c1');
    final f2 = await vault.createFolder(name: 'Личное');
    final folders = await vault.listFolders();
    expect(folders.length, 2);
    expect(folders.map((f) => f.order).toList(), [0, 1]);
    expect(folders[0].name, 'Работа');
    expect(folders[0].caption, 'раб');

    final n1 = Note.createText(folderId: f1.id, html: '<p>привет</p>', plaintext: 'привет');
    await vault.saveNote(n1);
    final loaded = (await vault.listNotes(f1.id)).first;
    expect(loaded.plaintext, 'привет');
    expect(loaded.folderId, f1.id);
    expect(await vault.listNotes(f2.id), isEmpty);

    await vault.deleteNote(n1);
    expect(await vault.listNotes(f1.id), isEmpty);
  });

  test('перенос заметки между папками и поиск по id', () async {
    final f1 = await vault.createFolder(name: 'A');
    final f2 = await vault.createFolder(name: 'B');
    final n = Note.createText(folderId: f1.id, html: 'x', plaintext: 'x');
    await vault.saveNote(n);
    await vault.moveNote(n, f2.id);
    expect(n.folderId, f2.id);
    expect((await vault.listNotes(f2.id)).any((x) => x.id == n.id), isTrue);
    expect((await vault.listNotes(f1.id)).any((x) => x.id == n.id), isFalse);
    final found = await vault.findNote(n.id);
    expect(found?.folderId, f2.id);
    expect(await vault.findNote('0' * 32), isNull);
  });

  test('события: CRUD', () async {
    final ev = await vault.addEvent('2026-06-17', 'Встреча', '#5288c1');
    await vault.addEvent('2026-06-17', 'Второе', '#67b35e');
    final events = await vault.listEvents();
    expect(events.length, 2);
    expect(events[0].name, 'Встреча');
    await vault.deleteEvent(ev.id);
    expect((await vault.listEvents()).length, 1);
  });

  test('blobs: миграция legacy → blob, дедуп, attachmentAbsPath', () async {
    final f = await vault.createFolder(name: 'Медиа');
    final data = List<int>.generate(500, (i) => i % 256);

    Future<Note> mk(String fname) async {
      final n = Note(id: newId(), folderId: f.id, kind: 'file', plaintext: fname);
      final adir = vault.attachmentsDir(f.id, n.id);
      await adir.create(recursive: true);
      await File('${adir.path}/$fname').writeAsBytes(data);
      n.attachments = [
        Attachment(file: fname, mime: 'application/octet-stream', name: fname, size: data.length)
      ];
      await vault.saveNote(n);
      return n;
    }

    final n1 = await mk('a.bin');
    final n2 = await mk('b.bin'); // тот же контент, другое имя

    expect(await vault.ensureBlobs(n1), isTrue);
    final sha = n1.attachments.first.sha256;
    expect(sha.isNotEmpty, isTrue);
    expect(await vault.hasBlob(sha), isTrue);
    expect(await File('${vault.attachmentsDir(f.id, n1.id).path}/a.bin').exists(), isFalse);

    expect(await vault.ensureBlobs(n2), isTrue);
    expect(n2.attachments.first.sha256, sha); // дедуп

    final blobs = await vault.blobsDir.list().where((e) => e is File).toList();
    expect(blobs.length, 1);
    expect(vault.attachmentAbsPath(n1, n1.attachments.first).path,
        vault.blobPath(sha).path);
  });
}
