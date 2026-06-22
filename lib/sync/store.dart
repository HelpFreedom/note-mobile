// Доступ движка синхронизации к хранилищу за тонким интерфейсом (как store.py).
// Объединяет oplog + apply + vault. Методы async (файловый ввод-вывод на Dart).

import 'package:crypto/crypto.dart';

import '../storage/vault.dart';
import 'apply.dart';
import 'oplog.dart';

List<String> blobHashesOfOp(Map<String, dynamic> op) {
  final kind = op['kind'];
  final payload = op['payload'];
  if (payload == null) return [];
  if (kind == 'note.put') {
    final atts = ((payload as Map)['attachments'] ?? []) as List;
    return atts
        .map((a) => (a as Map)['sha256'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (kind == 'setting.put' && payload is Map) {
    final w = payload['wallpaper'];
    if (w is String && w.isNotEmpty) return [w];
  }
  return [];
}

class SyncStore {
  final OpLog oplog;
  final ApplyEngine apply;
  final Vault vault;
  SyncStore(this.oplog, this.apply, this.vault);

  Future<Map<String, int>> versionVector() => oplog.versionVector();

  Future<List<Map<String, dynamic>>> opsSince(Map<String, int> remoteVv) =>
      oplog.opsSince(remoteVv);

  Future<bool> recordAndApply(Map<String, dynamic> op) async {
    // H5: ПРИМЕНЯЕМ до записи. Бросок apply → op НЕ записана (vv не сдвинут) → придёт
    // снова при следующем синке, а не потеряется молча. apply идемпотентен.
    if (await oplog.hasOp(op['op_id'] as String)) return false;
    await apply.applyOp(op);
    await oplog.recordRemote(op);
    return true;
  }

  Future<List<String>> missingBlobHashes(Map<String, dynamic> op) async {
    final out = <String>[];
    for (final h in blobHashesOfOp(op)) {
      if (!await vault.hasBlob(h)) out.add(h);
    }
    return out;
  }

  Future<List<int>?> readBlob(String sha) => vault.readBlob(sha);

  Future<bool> writeBlob(String sha, List<int> data) async {
    if (sha256.convert(data).toString() != sha) return false;
    await vault.writeBlob(sha, data);
    return true;
  }
}
