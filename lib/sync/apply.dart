// Применение удалённых операций к хранилищу с разрешением конфликтов (LWW).
// Идентично qtnotes/sync/apply.py:
//   * note.put применяется, только если входящая версия не старше по modified
//     (сравнение строк в UTC-формате — потому формат nowIso обязан совпадать с Python);
//   * note.del — безусловно (сознательный выбор пользователя 2026-06-22: удаление
//     всегда побеждает, даже более позднюю по времени правку); folder/event — по порядку.

import '../storage/models.dart';
import '../storage/vault.dart';
import 'oplog.dart';

class ApplyEngine {
  final Vault vault;
  final OpLog? oplog; // для проверки tombstone'ов (антивоскрешение, H4)
  ApplyEngine(this.vault, [this.oplog]);

  String _wall(String? s) => s ?? '';

  /// True, если для сущности есть ЛЮБОЙ tombstone → put не применяем.
  /// Вариант A (выбор пользователя 2026-06-22): удаление побеждает НАВСЕГДА — любое
  /// удаление подавляет все put для сущности, независимо от времени/lamport. Раньше
  /// put новее tombstone'а «воскрешал» заметку, но note.del применяется безусловно →
  /// при доставке put→del выходило absent, при del→put — present (расходимость
  /// навсегда: vv равны, переобмена нет). Безусловное подавление = независимость от
  /// порядка. id — UUID, повторного создания того же id не бывает. Идентично apply.py.
  bool _suppressedByTombstone(Map<String, dynamic> op) {
    return oplog?.tombstoneFor(op['entity_id'] as String? ?? '') != null;
  }

  Future<void> applyOp(Map<String, dynamic> op) async {
    final kind = op['kind'] as String?;
    final payload = op['payload'];
    final entityId = op['entity_id'] as String?;

    if (kind == 'note.put' && payload != null) {
      await _applyNotePut(op, (payload as Map).cast<String, dynamic>());
    } else if (kind == 'note.del' && entityId != null) {
      await vault.applyNoteDel(entityId);
    } else if (kind == 'folder.put' && payload != null) {
      if (_suppressedByTombstone(op)) return;
      await vault.applyFolderPut(Folder.fromJson((payload as Map).cast<String, dynamic>()));
    } else if (kind == 'folder.del' && entityId != null) {
      await vault.applyFolderDel(entityId);
    } else if (kind == 'event.put' && payload != null) {
      if (_suppressedByTombstone(op)) return;
      await vault.applyEventPut(Event.fromJson((payload as Map).cast<String, dynamic>()));
    } else if (kind == 'event.del' && entityId != null) {
      await vault.applyEventDel(entityId);
    } else if (kind == 'setting.put' && payload != null && entityId != null) {
      await vault.applySettingPut(entityId, payload);
    } else if (kind == 'setting.del' && entityId != null) {
      await vault.applySettingDel(entityId);
    } else {
      // Неизвестный kind (или put без payload) — НЕ молчим. Бросок не даёт
      // recordAndApply записать op (vv не двигается) → op переиграется после апгрейда
      // схемы, а не потеряется молча. Форвард-совместимость (как apply.py).
      throw StateError('неизвестный/неполный kind операции: $kind');
    }
  }

  Future<void> _applyNotePut(Map<String, dynamic> op, Map<String, dynamic> payload) async {
    if (_suppressedByTombstone(op)) return; // есть удаление → не воскрешаем (Вариант A)
    final incoming = Note.fromJson(payload);
    final existing = await vault.findNote(incoming.id);
    if (existing != null && _wall(existing.modified).compareTo(_wall(incoming.modified)) > 0) {
      return; // локальная версия новее — сохраняем её (LWW по времени)
    }
    await vault.applyNotePut(incoming);
  }
}
