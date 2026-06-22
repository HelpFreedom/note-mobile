// Регрессия (мобилка): recordRemote/appendLocal обязаны коммитить состояние в память
// ТОЛЬКО после успешной записи на диск. Иначе упавший _save (VaultLocked при блокировке
// телефона, диск полон) оставляет _clock/_ops/_tombstones продвинутыми, но не на диске →
// versionVector() обещает op, которого нет; процесс убит → расхождение с диском.
// Связано с G1-классом: lock() забывает MK, а живой движок ещё пишет входящую op.
//
// Запуск: dart test test/oplog_durable_commit_test.dart

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

const _wall = '2026-01-01T00:00:00.000000+00:00';

// OpLog, у которого _save гарантированно бросит: родитель файла журнала — обычный файл,
// поэтому любая запись '<file>/sync.json' падает FileSystemException.
OpLog _failingOplog(Directory tmp) {
  final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
  return OpLog(File('${blocker.path}/sync.json'), localId: 'local0');
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('qtn_durable_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('recordRemote: упавший _save не оставляет частичное состояние в памяти', () async {
    final log = _failingOplog(tmp);
    final op = {
      'op_id': 'devA:5', 'device_id': 'devA', 'lamport': 5, 'wall': _wall,
      'kind': 'note.del', 'entity_id': 'X', 'payload': null,
    };
    await expectLater(log.recordRemote(op), throwsA(isA<Object>()));

    expect((await log.versionVector())['devA'] ?? 0, 0,
        reason: 'vv не должен продвинуться, пока op не записан на диск');
    expect(await log.allOps(), isEmpty,
        reason: 'op не должен осесть в памяти при упавшем _save');
    expect(log.tombstoneFor('X'), isNull,
        reason: 'tombstone не должен записаться при упавшем _save');
  });

  test('appendLocal: упавший _save не оставляет частичное состояние в памяти', () async {
    final log = _failingOplog(tmp);
    await expectLater(
        log.appendLocal('note.del', 'Y', null), throwsA(isA<Object>()));

    expect((await log.versionVector())['local0'] ?? 0, 0,
        reason: 'локальные часы не должны продвинуться при упавшем _save');
    expect(await log.allOps(), isEmpty,
        reason: 'локальная op не должна осесть в памяти при упавшем _save');
    expect(log.tombstoneFor('Y'), isNull,
        reason: 'tombstone не должен записаться при упавшем _save');
  });
}
