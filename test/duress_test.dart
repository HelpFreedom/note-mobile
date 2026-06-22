// Тест duress-стирания (Ф5d) на программном бэкенде.
// Запуск: dart test test/duress_test.dart

import 'dart:io';

import 'package:test/test.dart';

import 'package:qtnotes_mobile/crypto/duress.dart';
import 'package:qtnotes_mobile/crypto/hwbackend.dart';
import 'package:qtnotes_mobile/crypto/keyvault.dart' as kv;
import 'package:qtnotes_mobile/crypto/session.dart';
import 'package:qtnotes_mobile/crypto/unlock.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/vault.dart';

void main() {
  test('duress: стирание owned + подложка, чужой файл цел, только обратный ПИН', () async {
    final tmp = Directory.systemTemp.createTempSync('qtnotes-duress-');
    final root = Directory('${tmp.path}/QtNotes')..createSync(recursive: true);
    Session.lock();
    Session.encryptionEnabled = false;
    try {
      final sw = SoftwareHardwareKey.generate();
      final ctl = UnlockController(
          File('${tmp.path}/qtnotes_keyring/keyring.json'), (_) => sw);
      final vault = Vault(root);

      // включаем шифрование + реальные данные
      final realMk = await ctl.setupPin('13579'); // обратный = 97531
      final f = await vault.createFolder(name: 'Реальная');
      final n = Note.createText(
          folderId: f.id, html: '<p>секрет 4242</p>', plaintext: 'секрет 4242');
      await vault.saveNote(n);

      // файл в корне vault НЕ из owned-списка — должен уцелеть (allowlist, не rm -rf)
      final untouchable = File('${root.path}/untouchable.dat')
        ..writeAsBytesSync([1, 2, 3, 4, 5]);

      // G3: утёкший плейнтекст-бэкап миграции рядом с vaultRoot — должен быть стёрт.
      final leak = Directory('${tmp.path}/qtnotes-backup-999')..createSync();
      File('${leak.path}/plain.json').writeAsStringSync('секрет 4242');
      // посторонний каталог в том же родителе (НЕ наш префикс) — трогать нельзя.
      final sibling = Directory('${tmp.path}/unrelated')..createSync();
      File('${sibling.path}/keep.txt').writeAsStringSync('keep');

      expect(await ctl.isConfigured(), isTrue);

      // duress-хук (как в AppService, без Keystore)
      ctl.onDuress = (pin) => Duress.execute(
            reversePin: pin,
            vaultRoot: root,
            controller: ctl,
            vault: vault,
          );

      // --- ввод обратного ПИНа ---
      Session.lock();
      final res = await ctl.tryUnlock('97531');
      expect(res.status, kv.UnlockStatus.ok, reason: 'duress открывается как обычная разблокировка');
      expect(res.masterKey, isNotNull);
      expect(res.masterKey, isNot(equals(realMk)));
      expect(Session.isUnlocked, isTrue);

      // реальные данные стёрты
      expect(await Directory('${root.path}/folders/${f.id}').exists(), isFalse);
      // чужой файл цел
      expect(await untouchable.exists(), isTrue);
      expect(await untouchable.readAsBytes(), equals([1, 2, 3, 4, 5]));
      // G3: утёкший бэкап стёрт, посторонний каталог цел
      expect(await leak.exists(), isFalse, reason: 'G3: бэкап прерванной миграции стёрт');
      expect(await sibling.exists(), isTrue, reason: 'посторонний каталог не трогаем');

      // подложка (I1: случайная из пулов)
      final folders = await vault.listFolders();
      expect(folders.length, 1);
      expect(decoyFolders, contains(folders.first.name));
      final notes = await vault.listNotes(folders.first.id);
      final texts = notes.map((x) => x.plaintext).toList();
      expect(texts.length, inInclusiveRange(2, 4));
      expect(texts.every(decoyPool.contains), isTrue);
      expect(texts.toSet().length, texts.length); // без повторов

      // только обратный ПИН открывает подложку; исходный — неверный
      Session.lock();
      expect((await ctl.tryUnlock('97531')).status, kv.UnlockStatus.ok);
      Session.lock();
      expect((await ctl.tryUnlock('13579')).status, kv.UnlockStatus.wrong);
    } finally {
      Session.lock();
      Session.encryptionEnabled = false;
      tmp.deleteSync(recursive: true);
    }
  });
}
