import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/engine.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';
import 'package:qtnotes_mobile/sync/peers.dart';
import 'package:qtnotes_mobile/sync/store.dart';

class Node {
  late final Vault vault;
  late final OpLog oplog;
  late final SyncStore store;
  late final Identity identity;

  Node(Directory root, this.identity) {
    vault = Vault(root);
    oplog = OpLog(File('${root.path}/sync.json'), localId: identity.deviceId);
    store = SyncStore(oplog, ApplyEngine(vault), vault);
  }

  Future<void> saveFolder(Folder f) async {
    await vault.saveFolder(f);
    await oplog.appendLocal('folder.put', f.id, f.toJson());
  }

  Future<void> saveNote(Note n) async {
    await vault.ensureBlobs(n); // синк включён → вложения в blobs (как desktop)
    await vault.saveNote(n);
    await oplog.appendLocal('note.put', n.id, n.toJson());
  }
}

Future<bool> waitUntil(Future<bool> Function() pred, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await pred()) return true;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return await pred();
}

void main() {
  test('два движка сходятся по TLS: начальный синк + blob + push-on-change',
      () async {
    final dirA = await Directory.systemTemp.createTemp('qtn_ea_');
    final dirB = await Directory.systemTemp.createTemp('qtn_eb_');
    final idA = await ensureIdentity(Directory('${dirA.path}/device'), 'A');
    final idB = await ensureIdentity(Directory('${dirB.path}/device'), 'B');
    final a = Node(dirA, idA);
    final b = Node(dirB, idB);

    final peerA = Peer(idA.deviceId, 'A', idA.certPem, 'now');
    final peerB = Peer(idB.deviceId, 'B', idB.certPem, 'now');
    final engA = SyncEngine(idA, a.store, getPeers: () async => [peerB]);
    final engB = SyncEngine(idB, b.store, getPeers: () async => [peerA]);

    // A: папка + заметка-вложение (станет blob)
    final f = Folder.create(name: 'Синк');
    await a.saveFolder(f);
    final n = Note(id: newId(), folderId: f.id, kind: 'file', plaintext: 'file-note');
    final adir = a.vault.attachmentsDir(f.id, n.id);
    await adir.create(recursive: true);
    final data = List<int>.generate(2000, (i) => (i * 13) % 256);
    await File('${adir.path}/x.bin').writeAsBytes(data);
    n.attachments = [
      Attachment(file: 'x.bin', mime: 'application/octet-stream', name: 'x.bin', size: data.length)
    ];
    await a.saveNote(n);
    final sha = n.attachments.first.sha256;
    expect(await a.vault.hasBlob(sha), isTrue);

    await engB.serve(host: '127.0.0.1', port: 0);
    await engA.connect('127.0.0.1', engB.port!, idB.deviceId);

    final ok = await waitUntil(() async =>
        (await b.vault.findNote(n.id)) != null && await b.vault.hasBlob(sha),
        const Duration(seconds: 10));
    expect(ok, isTrue, reason: 'начальный синк (заметка+blob) не сошёлся');
    expect((await b.vault.findNote(n.id))?.plaintext, 'file-note');

    // push-on-change: A добавляет заметку → B получает без переподключения
    final n2 = Note.createText(folderId: f.id, html: '<p>пуш</p>', plaintext: 'пуш');
    await a.saveNote(n2);
    await engA.pushAll();
    final ok2 = await waitUntil(
        () async => (await b.vault.findNote(n2.id)) != null,
        const Duration(seconds: 10));
    expect(ok2, isTrue, reason: 'push-on-change не доставил заметку');

    await engA.stop();
    await engB.stop();
    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });
}
