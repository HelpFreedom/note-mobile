// H8: кэш расшифрованных заметок — listNotes не перечитывает диск повторно; запись/
// удаление/перемещение когерентно обновляют кэш; clearNotesCache сбрасывает.
// Запуск: dart test test/notes_cache_test.dart

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';

void main() {
  late Directory dir;
  late Vault vault;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qtn_cache_');
    vault = Vault(dir);
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Note n(String folder, String text) =>
      Note.createText(folderId: folder, html: '<p>$text</p>', plaintext: text);

  test('listNotes отдаёт из кэша без повторного чтения диска', () async {
    final a = n('f1', 'a');
    await vault.saveNote(a);
    expect((await vault.listNotes('f1')).length, 1); // строит кэш

    // удаляем файл с диска НАПРЯМУЮ (минуя vault) — кэш не знает
    await Directory('${dir.path}/folders/f1/notes').delete(recursive: true);
    expect((await vault.listNotes('f1')).length, 1,
        reason: 'должно вернуться из кэша, не с диска');

    // сброс кэша → читает с диска (там пусто)
    vault.clearNotesCache();
    expect((await vault.listNotes('f1')).length, 0);
  });

  test('saveNote инкрементально обновляет кэш (без re-decrypt)', () async {
    await vault.saveNote(n('f1', 'a'));
    await vault.listNotes('f1'); // кэш построен
    final b = n('f1', 'b');
    await vault.saveNote(b);
    final notes = await vault.listNotes('f1');
    expect(notes.map((x) => x.plaintext), containsAll(['a', 'b']));
  });

  test('deleteNote убирает из кэша', () async {
    final a = n('f1', 'a');
    await vault.saveNote(a);
    await vault.listNotes('f1');
    await vault.deleteNote(a);
    expect(await vault.listNotes('f1'), isEmpty);
  });

  test('moveNote переносит между кэшами папок', () async {
    final a = n('f1', 'a');
    await vault.saveNote(a);
    await vault.listNotes('f1');
    await vault.listNotes('f2');
    await vault.moveNote(a, 'f2');
    expect(await vault.listNotes('f1'), isEmpty);
    expect((await vault.listNotes('f2')).single.plaintext, 'a');
  });

  test('applyNoteDel и deleteFolder чистят кэш', () async {
    final a = n('f1', 'a');
    await vault.saveNote(a);
    await vault.listNotes('f1');
    await vault.applyNoteDel(a.id);
    expect(await vault.listNotes('f1'), isEmpty);

    await vault.saveNote(n('f3', 'c'));
    await vault.listNotes('f3');
    await vault.deleteFolder('f3');
    expect(await vault.listNotes('f3'), isEmpty);
  });
}
