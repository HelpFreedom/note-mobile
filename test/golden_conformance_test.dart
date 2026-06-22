// M5: golden-vector конформанс Python↔Dart. Проверяет, что вывод субключа, формат
// crypto_fs (в обе стороны) и сериализация моделей БАЙТ-В-БАЙТ совместимы между
// реализациями. Драйвится из tests/test_golden_vectors.py (через GOLDEN_DIR); при
// отсутствии vectors.json — пропускается (чтобы обычный `dart test` не падал).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/crypto/crypto_fs.dart' as cfs;
import 'package:qtnotes_mobile/storage/models.dart';

String _canon(Map<String, dynamic> m) {
  final keys = m.keys.toList()..sort();
  return jsonEncode({for (final k in keys) k: m[k]});
}

void main() {
  test('golden: крипто-формат и сериализация совпадают с Python', () async {
    final goldenDir = Platform.environment['GOLDEN_DIR'];
    final vf = goldenDir == null ? null : File('$goldenDir/vectors.json');
    if (vf == null || !await vf.exists()) {
      markTestSkipped('запускать через tests/test_golden_vectors.py');
      return;
    }
    final v = (jsonDecode(await vf.readAsString()) as Map).cast<String, dynamic>();
    final mk = Uint8List.fromList(base64.decode(v['mk_b64'] as String));
    final relpath = v['relpath'] as String;
    final plaintext = Uint8List.fromList(base64.decode(v['plaintext_b64'] as String));

    // 1) субключ HKDF(mk,"file/"+relpath) совпадает
    final dartSubkey = cfs.fileSubkey(mk, relpath);
    expect(base64.encode(dartSubkey), v['py_subkey_b64'],
        reason: 'вывод субключа разошёлся Python↔Dart');

    // 2) Python→Dart: Dart расшифровывает Python-шифртекст
    final pySealed = Uint8List.fromList(base64.decode(v['py_sealed_b64'] as String));
    final dec = cfs.decryptRawWith(pySealed, mk, relpath);
    expect(dec, equals(plaintext), reason: 'Dart не расшифровал Python-шифртекст');

    // 3) сериализация модели совпадает (те же входы, что в Python)
    final note = Note(
      id: 'n1', folderId: 'f1', kind: 'text', html: '<p>Привет 🎉</p>',
      plaintext: 'Привет 🎉', captionHtml: '', dateTag: null,
      created: '2026-01-01T00:00:00.000000+00:00',
      modified: '2026-01-02T03:04:05.000000+00:00',
    );
    expect(_canon(note.toJson()),
        _canon((v['note_json'] as Map).cast<String, dynamic>()),
        reason: 'JSON заметки разошёлся');

    // 4) Dart→Python: шифруем для проверки расшифровки на стороне Python
    final dartSealed = cfs.encryptRawWith(plaintext, mk, relpath);

    // H1: сериализация всех синкаемых моделей (те же литералы, что в Python)
    final folder = Folder(
      id: 'f1', name: 'Папка 🎉', caption: 'подпись', color: '#ff0000',
      icon: 'star', order: 3, created: '2026-01-01T00:00:00.000000+00:00',
    );
    final att = Attachment(
      file: 'x.bin', mime: 'application/octet-stream', name: 'икс.bin',
      size: 1234, w: 640, h: 480, sha256: 'abcdef00',
    );
    final event = Event(id: 'e1', date: '2026-03-15', name: 'Событие 🎂', color: '#00ff00');
    final noteAtt = Note(
      id: 'n2', folderId: 'f1', kind: 'image', html: '<p>подпись</p>',
      plaintext: 'подпись', captionHtml: '<p>подпись</p>', attachments: [att],
      dateTag: '2026-03-15', created: '2026-01-01T00:00:00.000000+00:00',
      modified: '2026-01-02T03:04:05.000000+00:00',
    );

    await File('$goldenDir/dart_out.json').writeAsString(jsonEncode({
      'dart_subkey_b64': base64.encode(dartSubkey),
      'dart_sealed_b64': base64.encode(dartSealed),
      'note_json': note.toJson(),
      'folder_json': folder.toJson(),
      'attachment_json': att.toJson(),
      'event_json': event.toJson(),
      'note_att_json': noteAtt.toJson(),
    }));
  });
}
