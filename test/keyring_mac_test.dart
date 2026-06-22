// H9: integrity-MAC keyring — подделка счётчика перебора (root) детектируется и приводит
// к недеструктивной блокировке. integrityMac инъектируется (в приложении — Keystore).
// Запуск: dart test test/keyring_mac_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/crypto/hwbackend.dart';
import 'package:qtnotes_mobile/crypto/keyvault.dart' as kv;
import 'package:qtnotes_mobile/crypto/primitives.dart' as p;
import 'package:qtnotes_mobile/crypto/session.dart';
import 'package:qtnotes_mobile/crypto/unlock.dart';

void main() {
  late Directory dir;
  setUp(() async {
    Session.masterKey = null;
    Session.encryptionEnabled = false;
    dir = await Directory.systemTemp.createTemp('qtn_h9_');
  });
  tearDown(() async {
    Session.masterKey = null;
    Session.encryptionEnabled = false;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  // программный MAC-«Keystore»: детерминированный HMAC под фиксированным ключом
  final macKey = Uint8List.fromList(List.generate(32, (i) => (i + 1) & 0xFF));
  Future<Uint8List> swMac(Uint8List data) async => p.hmacSha256(macKey, data);

  test('подделка fail_count → блокировка 24ч (с integrityMac)', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/keyring.json');
    final ctrl = UnlockController(file, (_) => sw)
      ..onDuress = ((_) async => Uint8List(32))
      ..integrityMac = swMac;

    await ctrl.setupPin('13579');
    expect((await ctrl.tryUnlock('13579')).status, kv.UnlockStatus.ok);

    // неверная попытка → fail_count=1, mac пересчитан под него
    await ctrl.tryUnlock('00000');
    var raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((raw['keyring'] as Map)['fail_count'], 1);

    // root подделывает счётчик в 0 (сброс бюджета перебора), НЕ пересчитав mac
    (raw['keyring'] as Map)['fail_count'] = 0;
    (raw['keyring'] as Map)['last_fail_ts'] = 0;
    await file.writeAsString(jsonEncode(raw));

    final res = await ctrl.tryUnlock('13579'); // даже верный ПИН — блокировка из-за подделки
    expect(res.status, kv.UnlockStatus.locked, reason: 'подделка keyring должна детектироваться');
    expect(res.retryAfter, greaterThan(60000), reason: '~24ч');
  });

  test('без integrityMac (legacy) подделка НЕ ломает вход', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/legacy.json');
    final ctrl = UnlockController(file, (_) => sw)..onDuress = ((_) async => Uint8List(32));
    // integrityMac НЕ задан

    await ctrl.setupPin('13579');
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(raw.containsKey('mac'), isFalse, reason: 'без integrityMac mac не пишется');
    (raw['keyring'] as Map)['fail_count'] = 0;
    await file.writeAsString(jsonEncode(raw));
    expect((await ctrl.tryUnlock('13579')).status, kv.UnlockStatus.ok);
  });

  test('D2: срезание поля mac при выставленном маркере → блокировка (fail-closed)', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/strip.json');
    final ctrl = UnlockController(file, (_) => sw)
      ..onDuress = ((_) async => Uint8List(32))
      ..integrityMac = swMac
      ..macEverEnabled = (() async => true); // MAC включался (алиас существует)

    await ctrl.setupPin('13579');
    expect((await ctrl.tryUnlock('13579')).status, kv.UnlockStatus.ok);

    // root полностью УБИРАЕТ поле mac (раньше это обходило защиту — _integrityOk=true)
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw.remove('mac');
    (raw['keyring'] as Map)['fail_count'] = 0;
    await file.writeAsString(jsonEncode(raw));

    final res = await ctrl.tryUnlock('13579');
    expect(res.status, kv.UnlockStatus.locked,
        reason: 'срезанный mac при включённом MAC — это снятие защиты → блокировка');
  });

  test('D2: mac есть, но Keystore-ключ удалён (маркер=false) → блокировка', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/delkey.json');
    final ctrl = UnlockController(file, (_) => sw)
      ..onDuress = ((_) async => Uint8List(32))
      ..integrityMac = swMac
      ..macEverEnabled = (() async => true);
    await ctrl.setupPin('13579'); // mac записан

    // теперь имитируем «ключ удалён»: маркер возвращает false, хотя mac в файле есть
    ctrl.macEverEnabled = () async => false;
    final res = await ctrl.tryUnlock('13579');
    expect(res.status, kv.UnlockStatus.locked,
        reason: 'mac заявлен, но ключа нет — подделка → блокировка');
  });

  test('D2: настоящий legacy (mac не включался, маркер=false) — НЕ блокируем', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/genuine_legacy.json');
    // легаси: integrityMac отсутствует при setup → mac не пишется
    final ctrl = UnlockController(file, (_) => sw)..onDuress = ((_) async => Uint8List(32));
    await ctrl.setupPin('13579');
    // позже сборка получила MAC-движок, но на этом устройстве он НИКОГДА не включался
    ctrl
      ..integrityMac = swMac
      ..macEverEnabled = (() async => false);
    expect((await ctrl.tryUnlock('13579')).status, kv.UnlockStatus.ok,
        reason: 'настоящий legacy без mac и без маркера не должен блокироваться');
  });

  test('честная запись пересчитывает mac — вход проходит', () async {
    final sw = SoftwareHardwareKey.generate();
    final file = File('${dir.path}/ok.json');
    final ctrl = UnlockController(file, (_) => sw)
      ..onDuress = ((_) async => Uint8List(32))
      ..integrityMac = swMac;
    await ctrl.setupPin('24680');
    // несколько честных циклов wrong→ok, mac всегда консистентен
    await ctrl.tryUnlock('11111');
    expect((await ctrl.tryUnlock('24680')).status, kv.UnlockStatus.ok);
    expect((await ctrl.tryUnlock('24680')).status, kv.UnlockStatus.ok);
  });
}
