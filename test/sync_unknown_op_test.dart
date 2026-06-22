// A2 (раунд-3, mobile): op неизвестного kind НЕ записывается (vv не двигается) →
// переиграется после апгрейда схемы. Форвард-совместимость (как apply.py/test_unknown_op.py).
// Запуск: dart test test/sync_unknown_op_test.dart

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
  test('op неизвестного kind бросает и не записывается (vv не сдвинут)', () async {
    final dir = await Directory.systemTemp.createTemp('qtn_unknownop_');
    final vault = Vault(dir);
    final oplog = OpLog(File('${dir.path}/sync.json'), localId: 'local0');
    final store = SyncStore(oplog, ApplyEngine(vault, oplog), vault);

    final f = Folder.create(name: 'F');
    await vault.saveFolder(f);
    final n1 = Note.createText(folderId: f.id, html: '<p>a</p>', plaintext: 'a');

    final good = _op('note.put', n1.id, n1.toJson(), 'devA', 10);
    // op новой версии: kind, которого этот клиент ещё не знает
    final future = _op('note.archive', n1.id, {'archived': true}, 'devB', 11);

    expect(await store.recordAndApply(good), isTrue);

    var raised = false;
    try {
      await store.recordAndApply(future);
    } catch (_) {
      raised = true;
    }
    expect(raised, isTrue, reason: 'неизвестный kind должен бросать, а не игнорироваться');

    // КЛЮЧЕВОЕ: op неизвестного kind НЕ записана → vv не двигается → переиграется
    expect(await oplog.hasOp('devB:11'), isFalse, reason: 'op неизвестного kind не записана');
    final vv = await oplog.versionVector();
    expect(vv.containsKey('devB'), isFalse, reason: 'vv не покрывает устройство непонятой op');

    // put без payload — тоже неполная → бросок
    var raised2 = false;
    try {
      await ApplyEngine(vault, oplog).applyOp(_op('note.put', 'x', null, 'devC', 12));
    } catch (_) {
      raised2 = true;
    }
    expect(raised2, isTrue, reason: 'put без payload должен бросать');

    await dir.delete(recursive: true);
  });
}
