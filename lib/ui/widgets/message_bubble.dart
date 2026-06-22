import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_service.dart';
import '../../crypto/keystore.dart';
import '../../storage/models.dart';
import '../linkify.dart';
import '../theme.dart';
import 'video_view.dart';

String formatTime(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  } catch (_) {
    return '';
  }
}

/// Пузырь заметки (все заметки «наши»). Длинное нажатие — меню действий.
class MessageBubble extends StatelessWidget {
  final Note note;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final void Function(String noteId) onRef;
  final void Function(String url) onUrl;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onSelectToggle;

  const MessageBubble({
    super.key,
    required this.note,
    required this.onDelete,
    required this.onEdit,
    required this.onRef,
    required this.onUrl,
    required this.selected,
    required this.selectionMode,
    required this.onSelectToggle,
  });

  String get _body => note.kind == 'text' ? note.plaintext : note.plaintext;

  @override
  Widget build(BuildContext context) {
    final accent = appService.syncedColors?['accent'] ?? AppColors.accent;
    final bubble = appService.syncedColors?['bubble'] ?? AppColors.bubble;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: GestureDetector(
        onTap: selectionMode ? onSelectToggle : null,
        onLongPress: selectionMode ? onSelectToggle : () => _menu(context),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.45)
                : bubble.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
            border: selected ? Border.all(color: accent, width: 2) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._media(),
              if (_body.isNotEmpty)
                Text.rich(TextSpan(
                  children: buildNoteSpans(
                    _body,
                    base: TextStyle(color: AppColors.text, fontSize: 16),
                    linkColor: AppColors.link,
                    onRef: onRef,
                    onUrl: onUrl,
                  ),
                )),
              const SizedBox(height: 3),
              Text(
                formatTime(note.modified.isNotEmpty ? note.modified : note.created),
                style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Каждое вложение — отдельный StatefulWidget, который разрешает путь ОДИН раз
  // (а не новый Future на каждый build) — иначе при прокрутке повторный файловый I/O
  // и мигание дают дёрганую прокрутку. Ключ по sha → переразрешение при смене вложения.
  List<Widget> _media() => note.attachments
      .map((att) => _AttachmentView(
            key: ValueKey(
                '${note.id}/${att.sha256.isNotEmpty ? att.sha256 : att.file}'),
            note: note,
            att: att,
            selectionMode: selectionMode,
          ))
      .toList();

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.appBar,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.check_circle_outline, color: AppColors.text),
              title: const Text('Выделить'),
              onTap: () {
                Navigator.pop(ctx);
                onSelectToggle();
              },
            ),
            if (note.kind == 'text')
              ListTile(
                leading: Icon(Icons.edit, color: AppColors.text),
                title: const Text('Изменить'),
                onTap: () {
                  Navigator.pop(ctx);
                  onEdit();
                },
              ),
            ListTile(
              leading: Icon(Icons.copy, color: AppColors.text),
              title: const Text('Копировать текст'),
              onTap: () async {
                Navigator.pop(ctx);
                // D4: плейнтекст заметки — чувствительный; native пометит буфер sensitive.
                try {
                  await Keystore.copySensitive(note.plaintext);
                } catch (_) {
                  await Clipboard.setData(ClipboardData(text: note.plaintext));
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.link, color: AppColors.text),
              title: const Text('Копировать ID-ссылку'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: '[[${note.id}]]'));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.danger),
              title: const Text('Удалить', style: TextStyle(color: AppColors.danger)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Один элемент вложения. Разрешает путь (расшифровку blob) ОДИН раз и кэширует —
/// без файлового I/O и нового Future на каждый build (иначе прокрутка дёргается).
class _AttachmentView extends StatefulWidget {
  final Note note;
  final Attachment att;
  final bool selectionMode;
  const _AttachmentView({
    super.key,
    required this.note,
    required this.att,
    required this.selectionMode,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  File? _file; // расшифрованный/доступный файл; null — нет/ещё не разрешён
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final f = await appService.vault.attachmentAccessPath(widget.note, widget.att);
      final ok = f != null && await f.exists();
      if (!mounted) return;
      setState(() {
        _file = ok ? f : null;
        _resolved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _resolved = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final att = widget.att;
    final mime = att.mime;
    final file = _file;
    final exists = file != null;
    Widget media;
    if (mime.startsWith('image/')) {
      media = Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          // КЛЮЧ ПЛАВНОЙ ПРОКРУТКИ: резервируем СТАБИЛЬНУЮ высоту из метаданных w/h
          // ДО загрузки картинки. Иначе пузырь меняет высоту при появлении картинки →
          // лента пересчитывает позицию → рывки (в сторону подгрузки). С фикс-высотой
          // размер не меняется → прокрутка гладкая в обе стороны.
          // cacheWidth: декод под ширину пузыря (а не полное разрешение фото).
          child: LayoutBuilder(builder: (ctx, c) {
            final w = c.maxWidth;
            final hasDim = att.w > 0 && att.h > 0;
            final reserved =
                hasDim ? (w * att.h / att.w).clamp(80.0, 320.0).toDouble() : 220.0;
            final dpr = MediaQuery.of(ctx).devicePixelRatio;
            return SizedBox(
              width: w,
              height: reserved,
              child: exists
                  ? Image.file(file,
                      fit: BoxFit.cover, width: w, height: reserved,
                      cacheWidth: (w * dpr).round(), gaplessPlayback: true)
                  : _missingChip(att.name.isNotEmpty ? att.name : 'изображение'),
            );
          }),
        ),
      );
    } else if (mime.startsWith('video/')) {
      media = Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: exists ? VideoView(file) : _fileChip('🎬 ${att.name}', false),
      );
    } else {
      media = _fileChip('📄 ${att.name}', exists);
    }
    if (exists && !widget.selectionMode) {
      return GestureDetector(onLongPress: () => _menu(context, file), child: media);
    }
    return media;
  }

  Widget _fileChip(String label, bool exists) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(exists ? label : '$label · файл отсутствует',
              style: TextStyle(color: exists ? AppColors.text : AppColors.textSecondary)),
        ),
      );

  Widget _missingChip(String name) => Container(
        height: 60,
        alignment: Alignment.center,
        color: Colors.black26,
        child: Text(_resolved ? '$name · файл отсутствует' : '$name · загружается…',
            style: TextStyle(color: AppColors.textSecondary)),
      );

  void _menu(BuildContext context, File file) {
    final att = widget.att;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.appBar,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.ios_share, color: AppColors.text),
              title: const Text('Поделиться / Сохранить'),
              subtitle: Text(att.name.isNotEmpty ? att.name : att.file,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textSecondary)),
              onTap: () {
                Navigator.pop(ctx);
                _share(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(File file) async {
    final att = widget.att;
    // Share-sheet уводит приложение в фон. Без подавления авто-lock сработал бы и
    // lock()→wipeBlobCache() удалил бы расшифрованный файл из-под получающего
    // приложения (ушла бы пустышка/обрезок). Счётчик сбросится на resume в любом случае.
    appService.beginExternalActivity();
    try {
      await Share.shareXFiles([
        XFile(file.path,
            mimeType: att.mime.isNotEmpty ? att.mime : null,
            name: att.name.isNotEmpty ? att.name : att.file),
      ]);
    } catch (_) {
    } finally {
      appService.endExternalActivity();
    }
  }
}
