// Кросс-языковая проверка синка: Dart-сторона (мобильный движок).
// Генерирует личность, ждёт данные Python-сервера, подключается по TLS и
// проверяет, что заметка десктопа дошла, а своя — ушла. Координация через файлы
// в /tmp/interop. См. tools/interop_server.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/engine.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';
import 'package:qtnotes_mobile/sync/peers.dart';
import 'package:qtnotes_mobile/sync/store.dart';

const base = '/tmp/interop';

Future<void> main() async {
  final myDir = Directory('$base/dart');
  if (await myDir.exists()) await myDir.delete(recursive: true);
  await myDir.create(recursive: true);

  final id = await ensureIdentity(Directory('${myDir.path}/device'), 'DartPhone');
  await File('$base/dart_cert.pem').writeAsString(id.certPem);

  // ждём данные Python-сервера
  final readyFile = File('$base/py_ready.json');
  for (var i = 0; i < 120 && !await readyFile.exists(); i++) {
    await Future.delayed(const Duration(milliseconds: 500));
  }
  final py = (jsonDecode(await readyFile.readAsString()) as Map).cast<String, dynamic>();

  final vaultDir = Directory('${myDir.path}/vault');
  await vaultDir.create(recursive: true);
  final vault = Vault(vaultDir);
  final oplog = OpLog(File('${myDir.path}/sync.json'), localId: id.deviceId);
  final store = SyncStore(oplog, ApplyEngine(vault), vault);

  final pyPeer = Peer(py['device_id'] as String, 'Desktop', py['cert'] as String, 'now');
  final engine = SyncEngine(id, store, getPeers: () async => [pyPeer]);

  // своя заметка
  final f = Folder.create(name: 'FromPhone');
  await vault.saveFolder(f);
  await oplog.appendLocal('folder.put', f.id, f.toJson());
  final n = Note.createText(
      folderId: f.id, html: '<p>привет с телефона</p>', plaintext: 'привет с телефона');
  await vault.saveNote(n);
  await oplog.appendLocal('note.put', n.id, n.toJson());

  try {
    await engine.connect('127.0.0.1', (py['port'] as num).toInt(), py['device_id'] as String);
    stdout.writeln('DART: connect ok, sessions=${engine.sessions.keys.toList()}');
  } catch (e) {
    stdout.writeln('DART: connect error: $e');
  }
  // начальный синк идёт через have-обмен; запись сериализуется write-lock'ом

  // ждём заметку десктопа
  var gotPy = false;
  for (var i = 0; i < 60; i++) {
    await Future.delayed(const Duration(milliseconds: 250));
    for (final fl in await vault.listFolders()) {
      for (final note in await vault.listNotes(fl.id)) {
        if (note.plaintext == 'привет с десктопа') gotPy = true;
      }
    }
    if (gotPy) break;
  }
  await Future.delayed(const Duration(seconds: 1));

  // проверка синка темы: пришли ли общие настройки + обои (blob)
  final theme = await vault.getShared('theme');
  final gotTheme = theme is Map && theme['palette'] is Map;
  final wsha = (theme is Map) ? theme['wallpaper'] as String? : null;
  final gotWallpaper = wsha != null && wsha.isNotEmpty && await vault.hasBlob(wsha);

  await File('$base/dart_result.json').writeAsString(
      jsonEncode({'gotPy': gotPy, 'gotTheme': gotTheme, 'gotWallpaper': gotWallpaper}));
  stdout.writeln('DART: note=$gotPy theme=$gotTheme wallpaper=$gotWallpaper');
  await engine.stop();
  exit(0);
}
