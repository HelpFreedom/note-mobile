// H6 (mobile): раздельные лимиты кадров (CONTROL << BLOB), применяются до аллокации тела.
// Запуск: dart test test/wire_caps_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/sync/wire.dart';

Uint8List _hdr(int length, int type) {
  final b = BytesBuilder();
  b.add((ByteData(4)..setUint32(0, length, Endian.big)).buffer.asUint8List());
  b.add([type]);
  return b.takeBytes();
}

void main() {
  test('лимиты кадров: CONTROL << BLOB, проверка размера до тела', () async {
    // 1) round-trip нормального control-кадра
    final body = utf8.encode('{"type":"hello"}');
    final frame = BytesBuilder()
      ..add(_hdr(body.length + 1, kControl))
      ..add(body);
    final r = ByteReader(Stream.fromIterable([frame.takeBytes()]));
    final f = await readFrame(r);
    expect(f.isControl, isTrue);
    expect(f.control!['type'], 'hello');

    // 2) CONTROL сверх лимита → ProtocolException про лимит (только заголовок, тело не нужно)
    final r2 = ByteReader(Stream.fromIterable([_hdr(kMaxControlFrame + 1, kControl)]));
    try {
      await readFrame(r2);
      fail('ожидали отказ по размеру CONTROL');
    } on ProtocolException catch (e) {
      expect(e.message, contains('превышает лимит'));
    }

    // 3) BLOB той же длины — в пределах blob-лимита: НЕ отвергается по размеру (падает на EOF)
    final r3 = ByteReader(Stream.fromIterable([_hdr(kMaxControlFrame + 1, kBlob)]));
    try {
      await readFrame(r3);
      fail('должно бросить (нет тела)');
    } on ProtocolException catch (e) {
      expect(e.message, isNot(contains('превышает лимит')),
          reason: 'BLOB в пределах лимита не отвергается по размеру');
    }

    // 4) BLOB сверх blob-лимита → ProtocolException про лимит
    final r4 = ByteReader(Stream.fromIterable([_hdr(kMaxBlobFrame + 1, kBlob)]));
    try {
      await readFrame(r4);
      fail('ожидали отказ по размеру BLOB');
    } on ProtocolException catch (e) {
      expect(e.message, contains('превышает лимит'));
    }
  });
}
