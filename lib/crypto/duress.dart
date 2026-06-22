// Duress-стирание на мобилке (зеркало qtnotes/crypto/duress.py).
//
// Ввод ПИНа задом наперёд необратимо уничтожает реальные данные и создаёт подложку.
// Снаружи — обычная разблокировка (без предупреждений). Последовательность:
// 1) забыть MK + стереть кэш расшифрованных блобов;
// 2) КРИПТО-СТИРАНИЕ: удалить keyring (обёртка MK) + аппаратный ключ (Keystore.deleteKey
//    через инъектированный колбэк) → реальный шифртекст невосстановим;
// 3) удалить owned-данные QtNotes (vault-контент + сопряжение/идентичность);
// 4) подложка: новый ключ под обратный ПИН (без второго уровня duress) + папка «123».
//
// Чистый Dart (стирание аппаратного ключа — колбэк), чтобы тестировать без Keystore.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../storage/models.dart';
import '../storage/vault.dart';
import 'session.dart';
import 'unlock.dart';

// I1 (раунд-3): подложка собирается СЛУЧАЙНО из пулов (зеркало duress.py) — чтобы декой
// разных устройств не был байт-в-байт одинаков. На устройстве создаётся один раз.
const List<String> decoyFolders = ['123', 'Заметки', 'Личное', 'Дела', 'Списки'];
const List<String> decoyPool = [
  'Тест 1',
  'Напомнить пройти последний уровень в Brotato',
  'Досмотреть 2 сезон игры в кальмара',
  'Купить молоко и хлеб',
  'Позвонить маме в выходные',
  'Записаться к стоматологу',
  'Оплатить интернет до 25-го',
  'Забрать посылку с пункта выдачи',
  'Скинуть отчёт коллеге',
  'Полить цветы',
];
const String decoyFolder = '123'; // обратная совместимость имени

// Owned-данные QtNotes в корне vault (мобильный vault app-private — только наши данные).
const List<String> _ownedInVault = [
  'folders',
  'blobs',
  'calendar',
  'shared.json',
  'sync.json',
  'device',
  'peers.json',
  'peer_addrs.json',
  'app_settings.json',
];

Future<void> _rm(FileSystemEntity e) async {
  try {
    if (await e.exists()) await e.delete(recursive: true);
  } catch (_) {}
}

Future<List<FileSystemEntity>> _wipePass(Directory vaultRoot, File keyringFile) async {
  // крипто-стирание прежде всего: ключевой материал (обёртка MK)
  await _rm(keyringFile.parent);
  final targets = <FileSystemEntity>[keyringFile.parent];
  for (final name in _ownedInVault) {
    final dir = Directory('${vaultRoot.path}/$name');
    final file = File('${vaultRoot.path}/$name');
    if (await dir.exists()) {
      await _rm(dir);
      targets.add(dir);
    } else {
      await _rm(file);
      targets.add(file);
    }
  }
  // G3: плейнтекст-бэкап прерванной миграции лежит ВНЕ vaultRoot (в родительском
  // app-private каталоге) и пережил бы стирание. Сметаем и его (это наши же файлы).
  try {
    await for (final e in vaultRoot.parent.list()) {
      if (e.path.split('/').last.startsWith('qtnotes-backup-')) {
        await _rm(e);
        targets.add(e);
      }
    }
  } catch (_) {}
  return targets;
}

Future<void> _wipeOwned(Directory vaultRoot, File keyringFile) async {
  final targets = await _wipePass(vaultRoot, keyringFile);
  // I2 (раунд-3): верификация полноты. Частичное стирание под принуждением недопустимо
  // молча — повторяем и сигналим, если что-то уцелело.
  var survived = <String>[];
  for (final t in targets) {
    if (await t.exists()) survived.add(t.path);
  }
  if (survived.isNotEmpty) {
    await _wipePass(vaultRoot, keyringFile);
    survived = [];
    for (final t in targets) {
      if (await t.exists()) survived.add(t.path);
    }
    if (survived.isNotEmpty) {
      // ignore: avoid_print
      print('[duress] НЕ удалось стереть ${survived.length} путей: $survived');
    }
  }
}

Future<void> _createDecoy(Vault vault) async {
  final rng = Random.secure();
  final folder =
      await vault.createFolder(name: decoyFolders[rng.nextInt(decoyFolders.length)], icon: 'letter');
  final pool = List<String>.from(decoyPool);
  final count = 2 + rng.nextInt(3); // 2..4
  for (var i = 0; i < count; i++) {
    final text = pool.removeAt(rng.nextInt(pool.length));
    await vault.saveNote(
        Note.createText(folderId: folder.id, html: '<p>$text</p>', plaintext: text));
  }
}

class Duress {
  /// Выполнить duress-стирание и создать подложку. Возвращает MK подложки.
  /// eraseHardwareKey — удаление аппаратного ключа (Keystore.deleteKey); null в тестах.
  static Future<Uint8List> execute({
    required String reversePin,
    required Directory vaultRoot,
    required UnlockController controller,
    required Vault vault,
    Future<void> Function()? eraseHardwareKey,
  }) async {
    await vault.wipeBlobCache();
    Session.lock(); // забыть реальный MK

    if (eraseHardwareKey != null) {
      try {
        await eraseHardwareKey();
      } catch (_) {}
    }
    await _wipeOwned(vaultRoot, controller.keyringFile);

    // подложка: обратный ПИН как новый нормальный, без второго уровня duress
    final decoyMk = await controller.setupPin(reversePin, withDuress: false);
    await _createDecoy(vault);
    return decoyMk;
  }
}
