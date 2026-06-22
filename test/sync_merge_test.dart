import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

class Device {
  late final Vault vault;
  late final OpLog oplog;
  late final ApplyEngine apply;

  Device(Directory root, String id) {
    vault = Vault(root);
    oplog = OpLog(File('${root.path}/sync.json'), localId: id);
    apply = ApplyEngine(vault);
  }

  Future<void> saveFolder(Folder f) async {
    await vault.saveFolder(f);
    await oplog.appendLocal('folder.put', f.id, f.toJson());
  }

  Future<void> saveNote(Note n) async {
    await vault.saveNote(n);
    await oplog.appendLocal('note.put', n.id, n.toJson());
  }

  Future<void> deleteNote(Note n) async {
    await vault.deleteNote(n);
    await oplog.appendLocal('note.del', n.id, null);
  }
}

Future<void> syncOneWay(Device src, Device dst) async {
  final dstVv = await dst.oplog.versionVector();
  final ops = await src.oplog.opsSince(dstVv);
  for (final op in ops) {
    if (await dst.oplog.recordRemote(op)) await dst.apply.applyOp(op);
  }
}

void main() {
  late Directory dirA, dirB;
  late Device a, b;

  setUp(() async {
    dirA = await Directory.systemTemp.createTemp('qtn_a_');
    dirB = await Directory.systemTemp.createTemp('qtn_b_');
    a = Device(dirA, 'a' * 16);
    b = Device(dirB, 'b' * 16);
  });
  tearDown(() async {
    if (await dirA.exists()) await dirA.delete(recursive: true);
    if (await dirB.exists()) await dirB.delete(recursive: true);
  });

  test('два устройства сходятся: перенос, правка, LWW-конфликт, удаление', () async {
    final f = Folder.create(name: 'Общая');
    await a.saveFolder(f);
    final n = Note.createText(folderId: f.id, html: '<p>v1</p>', plaintext: 'v1');
    await a.saveNote(n);
    expect(await b.vault.findNote(n.id), isNull);

    // A → B
    await syncOneWay(a, b);
    expect((await b.vault.findNote(n.id))?.plaintext, 'v1');
    expect((await b.vault.listFolders()).any((x) => x.id == f.id), isTrue);

    // правка на B → A подтягивает
    final nb = (await b.vault.findNote(n.id))!;
    nb.plaintext = 'v2-from-B';
    nb.html = '<p>v2-from-B</p>';
    nb.touch();
    await b.saveNote(nb);
    await syncOneWay(b, a);
    expect((await a.vault.findNote(n.id))?.plaintext, 'v2-from-B');

    // конфликт: побеждает более свежая по modified (B)
    final na = (await a.vault.findNote(n.id))!;
    na.plaintext = 'A-edit';
    na.modified = '2029-01-01T00:00:00.000000+00:00';
    await a.saveNote(na);
    final nb2 = (await b.vault.findNote(n.id))!;
    nb2.plaintext = 'B-edit';
    nb2.modified = '2030-01-01T00:00:00.000000+00:00';
    await b.saveNote(nb2);
    await syncOneWay(a, b);
    await syncOneWay(b, a);
    expect((await a.vault.findNote(n.id))?.plaintext, 'B-edit');
    expect((await b.vault.findNote(n.id))?.plaintext, 'B-edit');

    // удаление на A распространяется на B
    await a.deleteNote((await a.vault.findNote(n.id))!);
    await syncOneWay(a, b);
    expect(await b.vault.findNote(n.id), isNull);
  });

  test('version vector и ops_since', () async {
    final f = Folder.create(name: 'X');
    await a.saveFolder(f);
    final n = Note.createText(folderId: f.id, html: 'x', plaintext: 'x');
    await a.saveNote(n);
    final vv = await a.oplog.versionVector();
    expect(vv['a' * 16], greaterThanOrEqualTo(2));
    expect((await a.oplog.opsSince({})).length, (await a.oplog.allOps()).length);
    expect(await a.oplog.opsSince(vv), isEmpty);
  });
}
