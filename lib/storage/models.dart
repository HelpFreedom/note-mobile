// Модели данных, идентичные десктопу (qtnotes/storage/models.py).
//
// JSON-ключи и формат должны совпадать с Python, иначе синхронизация и LWW
// сломаются. Особенно ВАЖЕН формat метки времени: "YYYY-MM-DDTHH:MM:SS.ffffff+00:00"
// (как datetime.isoformat(timespec='microseconds') в UTC) — сравнение строк modified
// в LWW обязано быть согласованным между Python и Dart.

import 'dart:math';

String _pad(int n, int width) => n.toString().padLeft(width, '0');

/// Метка времени в формате Python isoformat(microseconds) с суффиксом +00:00.
String nowIso() {
  final d = DateTime.now().toUtc();
  final micros = d.millisecond * 1000 + d.microsecond; // 0..999999
  return '${_pad(d.year, 4)}-${_pad(d.month, 2)}-${_pad(d.day, 2)}'
      'T${_pad(d.hour, 2)}:${_pad(d.minute, 2)}:${_pad(d.second, 2)}'
      '.${_pad(micros, 6)}+00:00';
}

final _rng = Random.secure();

/// 32 hex-символа, как uuid4().hex в Python (значимы только как идентификатор).
String newId() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

// --- Папка ---

class Folder {
  String id;
  String name;
  String caption;
  String? color;
  String icon;
  int order;
  String created;

  Folder({
    required this.id,
    required this.name,
    this.caption = '',
    this.color,
    this.icon = 'letter',
    this.order = 0,
    String? created,
  }) : created = created ?? nowIso();

  factory Folder.create({
    required String name,
    String caption = '',
    String? color,
    String icon = 'letter',
    int order = 0,
  }) =>
      Folder(
        id: newId(),
        name: name.trim(),
        caption: caption.trim(),
        color: color,
        icon: icon.isEmpty ? 'letter' : icon,
        order: order,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'caption': caption,
        'color': color,
        'icon': icon,
        'order': order,
        'created': created,
      };

  factory Folder.fromJson(Map<String, dynamic> d) => Folder(
        id: d['id'] as String,
        name: (d['name'] ?? '') as String,
        caption: (d['caption'] ?? '') as String,
        color: d['color'] as String?,
        icon: (d['icon'] ?? 'letter') as String,
        order: (d['order'] ?? 0) as int,
        created: (d['created'] ?? nowIso()) as String,
      );
}

// --- Вложение ---

class Attachment {
  String file; // имя файла (для отображения/расширения)
  String mime;
  String name;
  int size;
  int w;
  int h;
  String sha256; // если задан — файл в blobs/<sha256>

  Attachment({
    required this.file,
    this.mime = '',
    this.name = '',
    this.size = 0,
    this.w = 0,
    this.h = 0,
    this.sha256 = '',
  });

  Map<String, dynamic> toJson() => {
        'file': file,
        'mime': mime,
        'name': name,
        'size': size,
        'w': w,
        'h': h,
        'sha256': sha256,
      };

  factory Attachment.fromJson(Map<String, dynamic> d) => Attachment(
        file: d['file'] as String,
        mime: (d['mime'] ?? '') as String,
        name: (d['name'] ?? '') as String,
        size: (d['size'] ?? 0) as int,
        w: (d['w'] ?? 0) as int,
        h: (d['h'] ?? 0) as int,
        sha256: (d['sha256'] ?? '') as String,
      );
}

// --- Заметка ---

class Note {
  String id;
  String folderId;
  String kind; // text | image | file | album | video
  String html;
  String plaintext;
  String captionHtml;
  List<Attachment> attachments;
  String? dateTag; // YYYY-MM-DD
  String created;
  String modified;

  Note({
    required this.id,
    required this.folderId,
    this.kind = 'text',
    this.html = '',
    this.plaintext = '',
    this.captionHtml = '',
    List<Attachment>? attachments,
    this.dateTag,
    String? created,
    String? modified,
  })  : attachments = attachments ?? [],
        created = created ?? nowIso(),
        modified = modified ?? nowIso();

  factory Note.createText({
    required String folderId,
    required String html,
    required String plaintext,
  }) =>
      Note(id: newId(), folderId: folderId, kind: 'text', html: html, plaintext: plaintext);

  void touch() => modified = nowIso();

  Map<String, dynamic> toJson() => {
        'id': id,
        'folder_id': folderId,
        'kind': kind,
        'html': html,
        'plaintext': plaintext,
        'caption_html': captionHtml,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'date_tag': dateTag,
        'created': created,
        'modified': modified,
      };

  factory Note.fromJson(Map<String, dynamic> d) => Note(
        id: d['id'] as String,
        folderId: (d['folder_id'] ?? '') as String,
        kind: (d['kind'] ?? 'text') as String,
        html: (d['html'] ?? '') as String,
        plaintext: (d['plaintext'] ?? '') as String,
        captionHtml: (d['caption_html'] ?? '') as String,
        attachments: ((d['attachments'] ?? []) as List)
            .map((a) => Attachment.fromJson((a as Map).cast<String, dynamic>()))
            .toList(),
        dateTag: d['date_tag'] as String?,
        created: (d['created'] ?? nowIso()) as String,
        modified: (d['modified'] ?? nowIso()) as String,
      );
}

// --- Событие календаря ---

class Event {
  String id;
  String date; // YYYY-MM-DD
  String name;
  String color;

  Event({required this.id, required this.date, required this.name, required this.color});

  factory Event.create({required String date, required String name, required String color}) =>
      Event(id: newId(), date: date, name: name.trim(), color: color);

  Map<String, dynamic> toJson() => {'id': id, 'date': date, 'name': name, 'color': color};

  factory Event.fromJson(Map<String, dynamic> d) => Event(
        id: d['id'] as String,
        date: d['date'] as String,
        name: (d['name'] ?? '') as String,
        color: (d['color'] ?? '') as String,
      );
}
