// Файловое хранилище, идентичное десктопу (qtnotes/storage/vault.py).
//
// Раскладка под корнем vault:
//   folders/<folder-id>/folder.json
//   folders/<folder-id>/notes/<note-id>.json
//   folders/<folder-id>/notes/attachments/<note-id>/<файлы>   (legacy)
//   blobs/<sha256>                                            (content-addressed)
//   calendar/events.json
//
// Vault принимает корневой каталог (на устройстве — каталог документов, в тестах —
// временный), чтобы не зависеть от глобального состояния.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../crypto/blob_crypto.dart';
import '../crypto/crypto_fs.dart' as cfs;
import '../crypto/session.dart';
import 'models.dart';

int _blobTmpSeq = 0; // уникальные tmp-имена для blob-записей (без гонки имён)

/// Простой последовательный замок: цепочка фьючеров. Сериализует read-modify-write
/// агрегатных файлов (events.json/shared.json), которые UI и применение синка могут
/// переписывать одновременно (чередуясь на await) → иначе потеря обновления.
class _AsyncLock {
  Future<void> _tail = Future.value();
  Future<T> synchronized<T>(Future<T> Function() fn) {
    final done = Completer<void>();
    final prev = _tail;
    _tail = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }
}

class Vault {
  final Directory root;
  // G2 (раунд-3): каталог для расшифрованного кэша медиа. В приложении — app-private
  // cache (getApplicationCacheDirectory, гарантированно внутри backup-excluded домена);
  // null → systemTemp (для pure-Dart тестов).
  final Directory? blobCacheRoot;
  Vault(this.root, {this.blobCacheRoot});

  final _AsyncLock _aggLock = _AsyncLock(); // для events.json / shared.json

  Directory get foldersDir => Directory(p.join(root.path, 'folders'));
  Directory get blobsDir => Directory(p.join(root.path, 'blobs'));
  File get _eventsFile => File(p.join(root.path, 'calendar', 'events.json'));

  Directory _folderDir(String id) => Directory(p.join(foldersDir.path, id));
  File _folderJson(String id) => File(p.join(_folderDir(id).path, 'folder.json'));
  Directory _notesDir(String id) => Directory(p.join(_folderDir(id).path, 'notes'));
  File _noteJson(String folderId, String noteId) =>
      File(p.join(_notesDir(folderId).path, '$noteId.json'));

  /// Legacy-папка вложений заметки (создаётся). Новые вложения идут в blobs.
  Directory attachmentsDir(String folderId, String noteId) =>
      Directory(p.join(_notesDir(folderId).path, 'attachments', noteId));

  // --- низкоуровневое ---

  // запись/чтение идут через крипто-слой: при выключенном шифровании — plaintext
  // (как было), при включённом+разблокированном — зашифрованный файл.
  Future<void> _writeJsonAtomic(File f, Object data) => cfs.writeJsonEnc(f, data, root);

  Future<Map<String, dynamic>?> _readJson(File f) async {
    final d = await cfs.readJsonEnc(f, root);
    return d is Map ? d.cast<String, dynamic>() : null;
  }

  // --- папки ---

  Future<List<Folder>> listFolders() async {
    if (!await foldersDir.exists()) return [];
    final out = <Folder>[];
    await for (final e in foldersDir.list()) {
      if (e is Directory) {
        final j = await _readJson(File(p.join(e.path, 'folder.json')));
        if (j != null) out.add(Folder.fromJson(j));
      }
    }
    out.sort((a, b) {
      final c = a.order.compareTo(b.order);
      return c != 0 ? c : a.created.compareTo(b.created);
    });
    return out;
  }

  Future<void> saveFolder(Folder f) => _writeJsonAtomic(_folderJson(f.id), f.toJson());

  Future<Folder> createFolder({
    required String name,
    String caption = '',
    String? color,
    String icon = 'letter',
  }) async {
    final order = (await listFolders()).length;
    final f = Folder.create(name: name, caption: caption, color: color, icon: icon, order: order);
    await saveFolder(f);
    return f;
  }

  Future<void> deleteFolder(String id) async {
    final d = _folderDir(id);
    if (await d.exists()) await d.delete(recursive: true);
    _notesCache.remove(id);
  }

  // --- заметки ---

  // H8: кэш расшифрованных заметок по папкам. Убирает «крипто-шторм»: лента
  // перечитывала и расшифровывала ВСЮ папку на каждый notifyListeners (отправка/синк).
  // Поддерживается когерентно во всех путях записи; очищается при блокировке (плейнтекст
  // не должен жить в памяти после lock). Sync и UI в одном изоляте → кэш общий.
  final Map<String, List<Note>> _notesCache = {};

  void clearNotesCache() => _notesCache.clear();

  void _cacheUpsert(Note n) {
    for (final list in _notesCache.values) {
      list.removeWhere((x) => x.id == n.id); // на случай смены папки
    }
    final list = _notesCache[n.folderId];
    if (list != null) {
      list.add(n);
      list.sort((a, b) => a.created.compareTo(b.created));
    }
  }

  void _cacheRemove(String id) {
    for (final list in _notesCache.values) {
      list.removeWhere((x) => x.id == id);
    }
  }

  Future<List<Note>> listNotes(String folderId) async {
    final cached = _notesCache[folderId];
    if (cached != null) return List.of(cached); // без повторной расшифровки
    final dir = _notesDir(folderId);
    final out = <Note>[];
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          final j = await _readJson(e);
          if (j != null) out.add(Note.fromJson(j));
        }
      }
      out.sort((a, b) => a.created.compareTo(b.created));
    }
    _notesCache[folderId] = out;
    return List.of(out);
  }

  Future<void> saveNote(Note n) async {
    await _writeJsonAtomic(_noteJson(n.folderId, n.id), n.toJson());
    _cacheUpsert(n);
  }

  Future<void> deleteNote(Note n) async {
    final jp = _noteJson(n.folderId, n.id);
    if (await jp.exists()) await jp.delete();
    final adir = attachmentsDir(n.folderId, n.id);
    if (await adir.exists()) await adir.delete(recursive: true);
    _cacheRemove(n.id);
  }

  Future<Note?> findNote(String noteId) async {
    if (!await foldersDir.exists()) return null;
    await for (final e in foldersDir.list()) {
      if (e is Directory) {
        final j = await _readJson(File(p.join(e.path, 'notes', '$noteId.json')));
        if (j != null) return Note.fromJson(j);
      }
    }
    return null;
  }

  Future<void> moveNote(Note n, String target) async {
    if (target == n.folderId) return;
    final oldFolder = n.folderId;
    final oldJson = _noteJson(oldFolder, n.id);
    final oldAtt = attachmentsDir(oldFolder, n.id);
    n.folderId = target;
    await saveNote(n);
    if (await oldAtt.exists()) {
      final newAtt = attachmentsDir(target, n.id);
      await newAtt.create(recursive: true);
      await for (final child in oldAtt.list()) {
        if (child is File) {
          await child.rename(p.join(newAtt.path, p.basename(child.path)));
        }
      }
      await oldAtt.delete(recursive: true);
    }
    if (await oldJson.exists()) await oldJson.delete();
  }

  // --- применение удалённых операций (без логирования; для синка) ---

  Future<void> applyNotePut(Note note) async {
    final existing = await findNote(note.id);
    if (existing != null && existing.folderId != note.folderId) {
      final oldJson = _noteJson(existing.folderId, note.id);
      if (await oldJson.exists()) await oldJson.delete();
      final oldAtt = attachmentsDir(existing.folderId, note.id);
      if (await oldAtt.exists()) await oldAtt.delete(recursive: true);
    }
    await saveNote(note);
  }

  Future<void> applyNoteDel(String noteId) async {
    final existing = await findNote(noteId);
    if (existing != null) {
      final jp = _noteJson(existing.folderId, noteId);
      if (await jp.exists()) await jp.delete();
      final adir = attachmentsDir(existing.folderId, noteId);
      if (await adir.exists()) await adir.delete(recursive: true);
    }
    _cacheRemove(noteId);
  }

  Future<void> applyFolderPut(Folder f) => saveFolder(f);

  Future<void> applyFolderDel(String id) => deleteFolder(id);

  Future<void> applyEventPut(Event ev) => _aggLock.synchronized(() async {
        final events = (await listEvents()).where((e) => e.id != ev.id).toList()..add(ev);
        await _saveEvents(events);
      });

  Future<void> applyEventDel(String id) => _aggLock.synchronized(() async {
        final events = (await listEvents()).where((e) => e.id != id).toList();
        await _saveEvents(events);
      });

  // --- события ---

  Future<List<Event>> listEvents() async {
    try {
      final data = await cfs.readJsonEnc(_eventsFile, root);
      if (data is! List) return [];
      return data.map((e) => Event.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveEvents(List<Event> events) =>
      cfs.writeJsonEnc(_eventsFile, events.map((e) => e.toJson()).toList(), root);

  Future<Event> addEvent(String date, String name, String color) =>
      _aggLock.synchronized(() async {
        final events = await listEvents();
        final ev = Event.create(date: date, name: name, color: color);
        events.add(ev);
        await _saveEvents(events);
        return ev;
      });

  Future<void> deleteEvent(String id) => _aggLock.synchronized(() async {
        await _saveEvents((await listEvents()).where((e) => e.id != id).toList());
      });

  Future<void> updateEvent(String id, {String? name, String? color, String? date}) =>
      _aggLock.synchronized(() async {
        final events = await listEvents();
        for (final ev in events) {
          if (ev.id == id) {
            if (name != null) ev.name = name;
            if (color != null) ev.color = color;
            if (date != null) ev.date = date;
            break;
          }
        }
        await _saveEvents(events);
      });

  // --- blobs (content-addressed вложения) ---

  File blobPath(String sha) => File(p.join(blobsDir.path, sha));

  Future<bool> hasBlob(String sha) => blobPath(sha).exists();

  Future<void> _writeBlobBytes(File f, List<int> data, String relInfo) async {
    final mk = Session.masterKey;
    if (Session.encryptionEnabled && !Session.isUnlocked) {
      throw cfs.VaultLockedException('запись blob при заблокированном хранилище');
    }
    await f.parent.create(recursive: true);
    final List<int> content;
    if (Session.encryptionEnabled && mk != null) {
      // нативный AES (быстро, фоновый поток Android) с pure-Dart фоллбэком
      content = await BlobCrypto.sealFileContent(
          Uint8List.fromList(mk), relInfo, Uint8List.fromList(data));
    } else {
      content = data;
    }
    final tmp = File('${f.path}.${_blobTmpSeq++}.tmp'); // уникальный tmp — без гонки имён
    await tmp.writeAsBytes(content, flush: true); // fsync файла перед rename (durable)
    await tmp.rename(f.path);
  }

  Future<File> writeBlob(String sha, List<int> data) async {
    // data — ПЛЕЙНТЕКСТ; на диск пишется зашифрованным при включённом шифровании
    // (sha — хэш плейнтекста, для дедупа/синка).
    final f = blobPath(sha);
    if (await f.exists()) return f;
    await _writeBlobBytes(f, data, p.relative(f.path, from: root.path));
    return f;
  }

  /// Принять файл-вложение в blob-стор: читает файл, считает sha256, шифрует (нативный
  /// AES) и пишет blob. Возвращает (sha256, размер плейнтекста). Заменяет связку
  /// legacy-копия+ensureBlobs — без тяжёлой крипто-работы на UI-потоке.
  Future<(String, int)> ingestAttachment(String srcPath) async {
    final bytes = await File(srcPath).readAsBytes();
    final sha = sha256.convert(bytes).toString();
    final out = blobPath(sha);
    if (!await out.exists()) {
      await _writeBlobBytes(out, bytes, 'blobs/$sha');
    }
    return (sha, bytes.length);
  }

  Future<List<int>?> readBlob(String sha) async {
    // ПЛЕЙНТЕКСТ (расшифровка при необходимости, нативным AES).
    final f = blobPath(sha);
    if (!await f.exists()) return null;
    final raw = await f.readAsBytes();
    if (!cfs.startsWithMagic(raw)) return raw; // plaintext
    final mk = Session.masterKey;
    if (mk == null) throw cfs.VaultLockedException('blob без ключа');
    return BlobCrypto.openFileContent(
        Uint8List.fromList(mk), p.relative(f.path, from: root.path), raw);
  }

  Future<bool> _verifyBlob(String sha) async {
    try {
      final data = await readBlob(sha);
      return data != null && sha256.convert(data).toString() == sha;
    } catch (_) {
      return false;
    }
  }

  /// Путь к файлу вложения: blob если есть sha256, иначе legacy-папка. Для синка/проверок.
  File attachmentAbsPath(Note note, Attachment att) {
    if (att.sha256.isNotEmpty) return blobPath(att.sha256);
    return File(p.join(attachmentsDir(note.folderId, note.id).path, att.file));
  }

  // --- расшифровка блобов «на доступ» (для UI: Image.file/видео требуют реальный файл) ---

  Directory get _blobCacheDir {
    final h = sha256.convert(utf8.encode(root.path)).toString().substring(0, 16);
    final cacheBase = blobCacheRoot ?? Directory.systemTemp;
    return Directory(p.join(cacheBase.path, 'qtnotes-blobs-$h'));
  }

  /// Путь к вложению, пригодный для ПРЯМОГО чтения UI. При шифровании расшифровывает
  /// blob во временный кэш (app-private) и возвращает его; иначе путь без копий.
  /// Путь к вложению для ПРЯМОГО чтения UI. null — только если blob зашифрован, но
  /// расшифровать не удалось: вызывающий покажет «недоступно», а НЕ шифртекст.
  Future<File?> attachmentAccessPath(Note note, Attachment att) async {
    final path = attachmentAbsPath(note, att);
    if (att.sha256.isNotEmpty && await cfs.isEncryptedFile(path)) {
      return _decryptBlobToCache(att.sha256, path, att);
    }
    return path;
  }

  Future<File?> _decryptBlobToCache(String sha, File enc, Attachment att) async {
    final src = att.name.isNotEmpty ? att.name : att.file;
    final out = File(p.join(_blobCacheDir.path, '$sha${p.extension(src)}'));
    if (await out.exists()) return out;
    final mk = Session.masterKey;
    if (mk == null) return null; // нет ключа — не отдаём шифртекст
    await out.parent.create(recursive: true);
    // расшифровка нативным AES (быстро, фоновый поток) с pure-Dart фоллбэком
    final raw = await enc.readAsBytes();
    final data = await BlobCrypto.openFileContent(
        Uint8List.fromList(mk), p.relative(enc.path, from: root.path), raw);
    if (data == null) return null; // не расшифровали — не отдаём шифртекст
    final tmp = File('${out.path}.${_blobTmpSeq++}.tmp'); // уникальный tmp
    await tmp.writeAsBytes(data, flush: true); // fsync файла перед rename (durable)
    await tmp.rename(out.path);
    return out;
  }

  /// sha256 всех блобов, на которые ссылается заметка или настройка (обои). null —
  /// если разметка НЕПОЛНА (нечитаемая заметка) → GC обязан воздержаться.
  Future<Set<String>?> _referencedBlobShas() async {
    final refs = <String>{};
    if (await foldersDir.exists()) {
      await for (final e in foldersDir.list()) {
        if (e is! Directory) continue;
        final ndir = Directory(p.join(e.path, 'notes'));
        if (!await ndir.exists()) continue;
        await for (final fe in ndir.list()) {
          if (fe is File && fe.path.endsWith('.json')) {
            final j = await _readJson(fe);
            if (j == null) return null; // неполная разметка — не рискуем
            for (final a in (j['attachments'] as List?) ?? const []) {
              final sha = (a as Map)['sha256'];
              if (sha is String && sha.isNotEmpty) refs.add(sha);
            }
          }
        }
      }
    }
    final w = (await listShared())['wallpaper'];
    if (w is String && w.isNotEmpty) refs.add(w);
    return refs;
  }

  /// mark-and-sweep осиротевших блобов. Не запускается при заблокированном шифровании;
  /// воздерживается при неполной разметке; не трогает блобы моложе [minAge] (могли быть
  /// только что докачаны синком к ещё не применённой заметке).
  Future<int> gcBlobs({Duration minAge = const Duration(seconds: 60)}) async {
    if (Session.encryptionEnabled && !Session.isUnlocked) return 0;
    final refs = await _referencedBlobShas();
    if (refs == null) return 0;
    if (!await blobsDir.exists()) return 0;
    final now = DateTime.now();
    var removed = 0;
    await for (final e in blobsDir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.tmp') || refs.contains(name)) continue;
      try {
        final stat = await e.stat();
        if (now.difference(stat.modified) < minAge) continue;
        await e.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  Future<void> wipeBlobCache() async {
    try {
      final d = _blobCacheDir;
      if (await d.exists() && d.path.contains('qtnotes-blobs-')) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// Зашифровать все существующие plaintext-данные на месте (для включения шифрования).
  /// Требует Session: encryptionEnabled + разблокировано. Идемпотентна.
  Future<Map<String, int>> migrateEncrypt() async {
    final stats = {'folders': 0, 'notes': 0, 'blobs': 0, 'events': 0, 'shared': 0};
    for (final f in await listFolders()) {
      await saveFolder(f);
      stats['folders'] = stats['folders']! + 1;
      for (final n in await listNotes(f.id)) {
        await ensureBlobs(n);
        await saveNote(n);
        stats['notes'] = stats['notes']! + 1;
      }
    }
    if (await blobsDir.exists()) {
      await for (final e in blobsDir.list()) {
        if (e is File && !e.path.endsWith('.tmp')) {
          if (await cfs.isEncryptedFile(e)) continue;
          final data = await cfs.readBytesEnc(e, root);
          if (data != null) {
            await cfs.writeBytesEnc(e, data, root);
            stats['blobs'] = stats['blobs']! + 1;
          }
        }
      }
    }
    final ev = await listEvents();
    if (ev.isNotEmpty) {
      await _saveEvents(ev);
      stats['events'] = 1;
    }
    final sh = await listShared();
    if (sh.isNotEmpty) {
      await _writeShared(sh);
      stats['shared'] = 1;
    }
    return stats;
  }

  /// Перевести вложения заметки в blob-стор (идемпотентно). True — если изменилось.
  Future<bool> ensureBlobs(Note note) async {
    var changed = false;
    for (final att in note.attachments) {
      if (att.sha256.isNotEmpty) continue;
      final legacy = File(p.join(attachmentsDir(note.folderId, note.id).path, att.file));
      if (!await legacy.exists()) continue;
      final bytes = await legacy.readAsBytes();
      final sha = sha256.convert(bytes).toString();
      if (!await hasBlob(sha)) await writeBlob(sha, bytes);
      // проверка по содержимому (а не размеру: у зашифрованного blob размер иной)
      if (await hasBlob(sha) && await _verifyBlob(sha)) {
        att.sha256 = sha;
        await legacy.delete();
        changed = true;
      }
    }
    final adir = attachmentsDir(note.folderId, note.id);
    if (await adir.exists() && await adir.list().isEmpty) {
      await adir.delete();
    }
    return changed;
  }

  // --- общие (синхронизируемые) настройки: тема, обои ---

  File get _sharedFile => File(p.join(root.path, 'shared.json'));

  Future<Map<String, dynamic>> listShared() async {
    try {
      final d = await cfs.readJsonEnc(_sharedFile, root);
      return d is Map ? d.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<dynamic> getShared(String key) async => (await listShared())[key];

  Future<void> _writeShared(Map<String, dynamic> d) =>
      cfs.writeJsonEnc(_sharedFile, d, root);

  Future<void> applySettingPut(String key, dynamic value) =>
      _aggLock.synchronized(() async {
        final d = await listShared();
        d[key] = value;
        await _writeShared(d);
      });

  Future<void> applySettingDel(String key) => _aggLock.synchronized(() async {
        final d = await listShared();
        d.remove(key);
        await _writeShared(d);
      });
}
