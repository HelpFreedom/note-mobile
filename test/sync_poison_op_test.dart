// H5 (mobile): битая op изолируется — не рвёт сессию, соседние применяются, vv не сдвинут.
// Запуск: dart test test/sync_poison_op_test.dart

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';
import 'package:qtnotes_mobile/sync/store.dart';

const t = '2026-01-01T00:00:00.000000+00:00';

Map<String, dynamic> _op(String kind, String eid, Object? payload, String dev, int lam) => {
      'op_id': '$dev:$lam', 'device_id': dev, 'lamport': lam, 'wall': t,
      'kind': kind, 'entity_id': eid, 'payload': payload,
    };

void main() {
  test('битая op изолируется, соседние применяются, vv не сдвинут', () async {
    final dir = await Directory.systemTemp.createTemp('qtn_poison_');
    final vault = Vault(dir);
    final oplog = OpLog(File('${dir.path}/sync.json'), localId: 'local0');
    final store = SyncStore(oplog, ApplyEngine(vault, oplog), vault);

    final f = Folder.create(name: 'F');
    await vault.saveFolder(f);
    final n1 = Note.createText(folderId: f.id, html: '<p>a</p>', plaintext: 'a');
    final n2 = Note.createText(folderId: f.id, html: '<p>b</p>', plaintext: 'b');

    final good1 = _op('note.put', n1.id, n1.toJson(), 'devA', 100);
    final poison = _op('note.put', 'poison', <String, dynamic>{}, 'devB', 101); // fromJson → throw
    final good2 = _op('note.put', n2.id, n2.toJson(), 'devC', 102);

    final raised = <String>[];
    for (final o in [good1, poison, good2]) {
      try {
        await store.recordAndApply(o);
      } catch (_) {
        raised.add(o['op_id'] as String);
      }
    }

    expect(raised, contains('devB:101'), reason: 'битая op должна бросить');
    expect(await vault.findNote(n1.id), isNotNull, reason: 'good1 применился');
    expect(await vault.findNote(n2.id), isNotNull, reason: 'good2 применился после битой');
    expect(await oplog.hasOp('devB:101'), isFalse, reason: 'битая op не записана');
    expect(await oplog.hasOp('devA:100'), isTrue);
    expect(await oplog.hasOp('devC:102'), isTrue);
    final vv = await oplog.versionVector();
    expect(vv.containsKey('devB'), isFalse, reason: 'vv не содержит устройство битой op');
    expect(vv['devA'], 100);
    expect(vv['devC'], 102);

    // идемпотентность: повторная запись уже виденной op — no-op
    expect(await store.recordAndApply(good1), isFalse);

    await dir.delete(recursive: true);
  });
}
