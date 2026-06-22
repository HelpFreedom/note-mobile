// B1 (mobile): компакция журнала. По сущности остаётся op-победитель; vv (_clock) и
// tombstones сохранны → сходимость не ломается. Зеркало tests/test_compaction.py.
// Запуск: dart test test/sync_compaction_test.dart

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

Map<String, dynamic> _put(String eid, String modified, String dev, int lam) => {
      'op_id': '$dev:$lam', 'device_id': dev, 'lamport': lam, 'wall': modified,
      'kind': 'note.put', 'entity_id': eid,
      'payload': {'id': eid, 'modified': modified, 'plaintext': modified},
    };

Map<String, dynamic> _del(String eid, String wall, String dev, int lam) => {
      'op_id': '$dev:$lam', 'device_id': dev, 'lamport': lam, 'wall': wall,
      'kind': 'note.del', 'entity_id': eid, 'payload': null,
    };

void main() {
  test('компакция: победитель на сущность, vv сохранён', () async {
    final dir = await Directory.systemTemp.createTemp('qtn_compact_');
    final oplog = OpLog(File('${dir.path}/sync.json'), localId: 'local0');

    final T = [for (var i = 1; i <= 5; i++) '2026-01-01T00:00:0$i.000000+00:00'];

    // повторные правки X + одна правка Y
    for (var i = 0; i < T.length; i++) {
      expect(await oplog.recordRemote(_put('X', T[i], 'devA', 100 + i)), isTrue);
    }
    expect(await oplog.recordRemote(_put('Y', T[0], 'devB', 50)), isTrue);

    expect((await oplog.allOps()).length, 6);
    final vvBefore = await oplog.versionVector();

    expect(await oplog.compact(), 4, reason: 'удалить 4 устаревших put X');
    final ops = await oplog.allOps();
    expect(ops.length, 2);
    final winners = {for (final o in ops) o['entity_id'] as String: o};
    expect(winners['X']!['payload']['modified'], T.last, reason: 'победитель X — свежайший');
    expect(winners['Y']!['payload']['modified'], T[0]);
    expect(await oplog.versionVector(), vvBefore, reason: 'vv не меняется');
    final fresh = await oplog.opsSince({});
    expect({for (final o in fresh) o['entity_id']}, {'X', 'Y'});
    expect(await oplog.compact(), 0, reason: 'идемпотентно');

    // удаление поглощает старые put
    for (var i = 0; i < 3; i++) {
      expect(await oplog.recordRemote(_put('Z', T[i], 'devA', 200 + i)), isTrue);
    }
    expect(await oplog.recordRemote(_del('Z', T[4], 'devA', 210)), isTrue);
    expect(await oplog.compact(), 3);
    final z = (await oplog.allOps()).where((o) => o['entity_id'] == 'Z').toList();
    expect(z.length, 1);
    expect(z.first['kind'], 'note.del');

    // воскрешение (put новее del) — не компактим
    expect(await oplog.recordRemote(_del('W', T[1], 'devA', 300)), isTrue);
    expect(await oplog.recordRemote(_put('W', T[3], 'devB', 305)), isTrue);
    await oplog.compact();
    final w = (await oplog.allOps()).where((o) => o['entity_id'] == 'W').toList();
    expect(w.length, 2, reason: 'воскрешающую смесь не компактим');

    await dir.delete(recursive: true);
  });
}
