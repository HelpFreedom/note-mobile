// H4 (mobile): tombstones против воскрешения удалённых заметок + LWW-тай-брейк.
// Запуск: dart test test/sync_tombstones_test.dart

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

const tOld = '2020-01-01T00:00:00.000000+00:00';
const tMid = '2023-01-01T00:00:00.000000+00:00';
const tNew = '2026-01-01T00:00:00.000000+00:00';

Map<String, dynamic> _del(String id, String wall, int lam, String dev) => {
      'op_id': '$dev:$lam', 'device_id': dev, 'lamport': lam, 'wall': wall,
      'kind': 'note.del', 'entity_id': id, 'payload': null,
    };

Map<String, dynamic> _put(Map<String, dynamic> nd, String wall, int lam, String dev) => {
      'op_id': '$dev:$lam', 'device_id': dev, 'lamport': lam, 'wall': wall,
      'kind': 'note.put', 'entity_id': nd['id'], 'payload': Map<String, dynamic>.from(nd),
    };

void main() {
  test('tombstone: антивоскрешение + тай-брейк по lamport', () async {
    final dir = await Directory.systemTemp.createTemp('qtn_tomb_');
    final vault = Vault(dir);
    final oplog = OpLog(File('${dir.path}/sync.json'), localId: 'local0');
    final apply = ApplyEngine(vault, oplog);

    final f = Folder.create(name: 'F');
    await vault.saveFolder(f);
    final n = Note.createText(folderId: f.id, html: '<p>v1</p>', plaintext: 'v1');
    n.modified = tMid;
    await vault.saveNote(n);
    final nd = n.toJson();
    expect(await vault.findNote(n.id), isNotNull);

    // удаление новее → заметка удалена, tombstone записан
    final d = _del(n.id, tNew, 100, 'devX');
    expect(await oplog.recordRemote(d), isTrue);
    await apply.applyOp(d);
    expect(await vault.findNote(n.id), isNull);

    // СТАЛЫЙ put (wall старше удаления) → НЕ воскрешает
    final stale = _put(nd, tOld, 50, 'devY');
    await oplog.recordRemote(stale);
    await apply.applyOp(stale);
    expect(await vault.findNote(n.id), isNull,
        reason: 'устаревший put не должен воскрешать удалённую заметку');

    // Вариант A (2026-06-22): удаление побеждает НАВСЕГДА — даже более новый put
    // НЕ воскрешает (раньше воскрешал → расходимость; см. convergence_conformance_test).
    final newer = _put(nd, '2027-01-01T00:00:00.000000+00:00', 200, 'devZ');
    await oplog.recordRemote(newer);
    await apply.applyOp(newer);
    expect(await vault.findNote(n.id), isNull,
        reason: 'после удаления put не должен воскрешать (Вариант A)');

    // тай-брейк по lamport при равном wall
    final n2 = Note.createText(folderId: f.id, html: '<p>x</p>', plaintext: 'x');
    n2.modified = tMid;
    await vault.saveNote(n2);
    final nd2 = n2.toJson();
    final d2 = _del(n2.id, tMid, 10, 'aaa');
    await oplog.recordRemote(d2);
    await apply.applyOp(d2);
    expect(await vault.findNote(n2.id), isNull);

    final pLo = _put(nd2, tMid, 5, 'bbb'); // меньший lamport → удаление новее
    await oplog.recordRemote(pLo);
    await apply.applyOp(pLo);
    expect(await vault.findNote(n2.id), isNull, reason: 'меньший lamport проигрывает удалению');

    final pHi = _put(nd2, tMid, 20, 'ccc'); // Вариант A: даже больший lamport не воскрешает
    await oplog.recordRemote(pHi);
    await apply.applyOp(pHi);
    expect(await vault.findNote(n2.id), isNull,
        reason: 'после удаления put не воскрешает даже с большим lamport (Вариант A)');

    // tombstone переживает перезагрузку оплога (персист в JSON)
    final oplog2 = OpLog(File('${dir.path}/sync.json'), localId: 'local0');
    expect((await oplog2.allOps()).isNotEmpty, isTrue);
    expect(oplog2.tombstoneFor(n.id), isNotNull,
        reason: 'tombstone должен сохраняться и читаться обратно');

    await dir.delete(recursive: true);
  });
}
