// Keystone сетки, Dart-сторона. Читает tests/golden/convergence_vectors.json (через
// CONV_DIR), применяет каждый сценарий ВО ВСЕХ порядках доставки к свежему хранилищу,
// и пишет per-порядок результаты в conv_out.json. Python-драйвер
// (tests/test_convergence_conformance.py) сверяет: (а) независимость от порядка внутри
// Dart, (б) Python == Dart по каждому порядку. Без CONV_DIR — тест пропускается, чтобы
// обычный `dart test` не падал.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';

List<List<int>> _perms(List<int> xs) {
  if (xs.length <= 1) return [xs];
  final out = <List<int>>[];
  for (var i = 0; i < xs.length; i++) {
    final rest = [...xs]..removeAt(i);
    for (final p in _perms(rest)) {
      out.add([xs[i], ...p]);
    }
  }
  return out;
}

Future<Map<String, dynamic>> _applySequence(List ops) async {
  final dir = await Directory.systemTemp.createTemp('qtn_conv_');
  try {
    final vault = Vault(dir);
    final oplog = OpLog(File('${dir.path}/sync.json'), localId: 'local0');
    final apply = ApplyEngine(vault, oplog);
    await vault.saveFolder(Folder(
        id: 'F', name: 'F', caption: '', color: null, icon: 'letter', order: 0,
        created: '2026-01-01T00:00:00.000000+00:00'));
    final ids = <String>{};
    for (final op in ops) {
      final m = (op as Map).cast<String, dynamic>();
      ids.add(m['entity_id'] as String);
      if (await oplog.recordRemote(m)) await apply.applyOp(m);
    }
    final state = <String, dynamic>{};
    for (final id in ids) {
      final n = await vault.findNote(id);
      state[id] = n == null
          ? {'present': false}
          : {'present': true, 'plaintext': n.plaintext};
    }
    return state;
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  test('convergence conformance (Dart-сторона)', () async {
    final dirEnv = Platform.environment['CONV_DIR'];
    final vf = dirEnv == null ? null : File('$dirEnv/convergence_vectors.json');
    if (vf == null || !await vf.exists()) {
      markTestSkipped('запускать через tests/test_convergence_conformance.py');
      return;
    }
    final v = (jsonDecode(await vf.readAsString()) as Map).cast<String, dynamic>();
    final scenarios = (v['scenarios'] as List).cast<Map>();

    final out = <String, dynamic>{};
    for (final sc in scenarios) {
      final name = sc['name'] as String;
      final ops = sc['ops'] as List;
      final idx = [for (var i = 0; i < ops.length; i++) i];
      final perResult = <String, dynamic>{};
      for (final perm in _perms(idx)) {
        final seq = [for (final i in perm) ops[i]];
        perResult[perm.join(',')] = await _applySequence(seq);
      }
      out[name] = perResult;
    }
    await File('$dirEnv/conv_out.json').writeAsString(jsonEncode(out));
  });
}
