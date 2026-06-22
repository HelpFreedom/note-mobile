// «Логирующее» хранилище: каждое изменение пишет op в журнал (если синк включён),
// как vault._log на десктопе. Централизует доступ экранов к данным.

import '../storage/models.dart';
import '../storage/vault.dart';
import '../sync/oplog.dart';

class Repository {
  final Vault vault;
  final OpLog oplog;
  bool syncEnabled = false;

  Repository(this.vault, this.oplog);

  Future<void> _log(String kind, String id, Map<String, dynamic>? payload) async {
    if (!syncEnabled) return;
    await oplog.appendLocal(kind, id, payload);
  }

  // --- папки ---
  Future<List<Folder>> folders() => vault.listFolders();

  Future<Folder> createFolder(String name, {String icon = 'letter', String? color}) async {
    final f = await vault.createFolder(name: name, icon: icon, color: color);
    await _log('folder.put', f.id, f.toJson());
    return f;
  }

  Future<void> updateFolder(Folder f) async {
    await vault.saveFolder(f);
    await _log('folder.put', f.id, f.toJson());
  }

  Future<void> deleteFolder(String id) async {
    await vault.deleteFolder(id);
    await _log('folder.del', id, null);
  }

  // --- заметки ---
  Future<List<Note>> notes(String folderId) => vault.listNotes(folderId);
  Future<Note?> findNote(String id) => vault.findNote(id);

  Future<void> saveNote(Note n) async {
    if (syncEnabled) await vault.ensureBlobs(n);
    await vault.saveNote(n);
    await _log('note.put', n.id, n.toJson());
  }

  Future<void> deleteNote(Note n) async {
    await vault.deleteNote(n);
    await _log('note.del', n.id, null);
  }

  Future<void> moveNote(Note n, String targetFolderId) async {
    await vault.moveNote(n, targetFolderId);
    await _log('note.put', n.id, n.toJson());
  }

  // --- события ---
  Future<List<Event>> events() => vault.listEvents();

  Future<Event> addEvent(String date, String name, String color) async {
    final e = await vault.addEvent(date, name, color);
    await _log('event.put', e.id, e.toJson());
    return e;
  }

  Future<void> updateEvent(String id, {String? name, String? color, String? date}) async {
    await vault.updateEvent(id, name: name, color: color, date: date);
    final events = await vault.listEvents();
    final ev = events.where((e) => e.id == id).firstOrNull;
    if (ev != null) await _log('event.put', ev.id, ev.toJson());
  }

  Future<void> deleteEvent(String id) async {
    await vault.deleteEvent(id);
    await _log('event.del', id, null);
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
