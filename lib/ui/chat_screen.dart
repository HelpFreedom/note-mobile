import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_service.dart';
import '../storage/models.dart';
import 'theme.dart';
import 'widgets/confirm.dart';
import 'widgets/message_bubble.dart';

String _escapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
String _toHtml(String text) => '<p>${_escapeHtml(text).replaceAll('\n', '<br>')}</p>';

class _Pending {
  final String path;
  final String name;
  final String mime;
  _Pending(this.path, this.name, this.mime);
  bool get isImage => mime.startsWith('image/');
}

class ChatScreen extends StatefulWidget {
  final Folder folder;
  const ChatScreen({super.key, required this.folder});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  List<Note> _notes = [];
  final List<_Pending> _pending = [];
  final Set<String> _selected = {};
  Note? _editing;
  bool _sending = false; // идёт отправка вложений (показываем индикатор)

  @override
  void initState() {
    super.initState();
    appService.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    appService.removeListener(_reload);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final notes = await appService.notes(widget.folder.id);
    if (!mounted) return;
    // новейшие первыми (индекс 0): лента reverse:true рисует индекс 0 снизу. Так
    // прокрутка вверх (к старым) идёт «вперёд» по индексам → плавно, без рывков
    // от пересчёта высот (которые были при не-реверснутой ленте, закреплённой снизу).
    setState(() => _notes = notes.reversed.toList());
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // при reverse:true «низ» (новейшая заметка) — это offset 0
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
  }

  Future<void> _pickFiles() async {
    // G1-fix: системный пикер уводит приложение в paused — подавляем авто-lock, иначе
    // вернувшись получим «запись blob при заблокированном хранилище».
    appService.beginExternalActivity();
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(allowMultiple: true);
    } finally {
      appService.endExternalActivity();
    }
    if (result == null) return;
    final picked = result;
    setState(() {
      for (final f in picked.files) {
        if (f.path == null) continue;
        _pending.add(_Pending(
            f.path!, f.name, lookupMimeType(f.name) ?? 'application/octet-stream'));
      }
    });
  }

  // M3: видимая обратная связь по ошибкам (раньше сбои сохранения молчали)
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (_editing != null) {
      if (text.isEmpty) return;
      final n = _editing!;
      n.plaintext = text;
      if (n.kind == 'text') {
        n.html = _toHtml(text);
      } else {
        n.captionHtml = _toHtml(text);
      }
      n.touch();
      try {
        await appService.saveNote(n);
      } catch (e) {
        _snack('Не удалось сохранить изменения: $e');
        return;
      }
      setState(() => _editing = null);
      _input.clear();
      return;
    }
    if (_pending.isNotEmpty) {
      await _sendPending(text);
      return;
    }
    if (text.isEmpty) return;
    final n = Note.createText(
        folderId: widget.folder.id, html: _toHtml(text), plaintext: text);
    try {
      await appService.saveNote(n);
    } catch (e) {
      _snack('Не удалось сохранить заметку: $e');
      return;
    }
    _input.clear();
  }

  Future<void> _sendPending(String caption) async {
    // сразу показываем, что отправка началась: чистим лоток/поле и включаем индикатор
    final pending = List<_Pending>.from(_pending);
    setState(() {
      _sending = true;
      _pending.clear();
    });
    _input.clear();
    try {
      final folderId = widget.folder.id;
      final note = Note(id: newId(), folderId: folderId);
      var images = 0, videos = 0, files = 0;
      for (final p in pending) {
        final src = File(p.path);
        if (!await src.exists()) continue;
        // приём вложения целиком (чтение+sha256+нативное шифрование+запись)
        final (sha, size) = await appService.vault.ingestAttachment(p.path);
        // размеры картинки сохраняем в метаданные → лента резервирует точную высоту
        // ДО загрузки → нет рывков прокрутки (декод один раз, не на пути прокрутки).
        var w = 0, h = 0;
        if (p.mime.startsWith('image/')) {
          try {
            final codec = await ui.instantiateImageCodec(await src.readAsBytes());
            final frame = await codec.getNextFrame();
            w = frame.image.width;
            h = frame.image.height;
            frame.image.dispose();
            codec.dispose();
          } catch (_) {}
        }
        note.attachments.add(Attachment(
            file: p.name, mime: p.mime, name: p.name, size: size, sha256: sha, w: w, h: h));
        if (p.mime.startsWith('image/')) {
          images++;
        } else if (p.mime.startsWith('video/')) {
          videos++;
        } else {
          files++;
        }
      }
      if (note.attachments.isEmpty) return;
      final total = images + videos + files;
      note.kind = total > 1
          ? 'album'
          : (images == 1 ? 'image' : (videos == 1 ? 'video' : 'file'));
      if (caption.isNotEmpty) {
        note.captionHtml = _toHtml(caption);
        note.plaintext = caption;
      } else {
        note.plaintext = note.attachments.map((a) => a.name).join(', ');
      }
      await appService.saveNote(note);
    } catch (e) {
      _snack('Не удалось отправить вложение: $e'); // M3
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startEdit(Note n) {
    setState(() => _editing = n);
    _input.text = n.plaintext;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Future<void> _openRef(String id) async {
    final note = await appService.findNote(id);
    if (!mounted) return;
    if (note == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Заметка не найдена — возможно, удалена')));
      return;
    }
    if (note.folderId == widget.folder.id) return; // уже в этой папке
    final folders = await appService.folders();
    if (!mounted) return;
    Folder? folder;
    for (final f in folders) {
      if (f.id == note.folderId) {
        folder = f;
        break;
      }
    }
    if (folder != null) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => ChatScreen(folder: folder!)));
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // открытие ссылки уводит приложение в фон — подавить авто-lock, иначе вернёмся на
    // PIN-экран после каждой ссылки (и lock() стёр бы кэш медиа посреди операции).
    appService.beginExternalActivity();
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } finally {
      appService.endExternalActivity();
    }
  }

  bool get _dirty =>
      _input.text.trim().isNotEmpty || _pending.isNotEmpty || _editing != null;

  @override
  Widget build(BuildContext context) {
    final wp = appService.wallpaper;
    // M2: защита от потери несохранённого ввода при уходе с экрана
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (!_dirty) {
          navigator.pop();
          return;
        }
        final discard = await confirmDelete(context,
            title: 'Несохранённый ввод',
            message: 'Сбросить набранный текст и вложения?',
            confirmLabel: 'Сбросить');
        if (discard && mounted) navigator.pop();
      },
      child: _buildScaffold(wp),
    );
  }

  Widget _buildScaffold(File? wp) {
    return Scaffold(
      appBar: _selected.isEmpty ? _normalAppBar() : _selectionAppBar(),
      body: Stack(
        children: [
          if (wp != null)
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: Image.file(wp, fit: BoxFit.cover),
              ),
            ),
          if (wp != null)
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.42)),
            ),
          Column(
          children: [
            Expanded(
            child: _notes.isEmpty
                ? Center(
                    child: Text('Здесь пока нет заметок.\nНапишите первую ниже.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary)))
                : ListView.builder(
                    controller: _scroll,
                    reverse: true, // чат-лента: индекс 0 снизу, растёт вверх
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _notes.length,
                    itemBuilder: (ctx, i) {
                      final n = _notes[i];
                      return MessageBubble(
                        note: n,
                        selected: _selected.contains(n.id),
                        selectionMode: _selected.isNotEmpty,
                        onSelectToggle: () => _toggleSelect(n.id),
                        onDelete: () => _confirmDeleteNote(n),
                        onEdit: () => _startEdit(n),
                        onRef: _openRef,
                        onUrl: _openUrl,
                      );
                    },
                  ),
          ),
            if (_selected.isEmpty) _inputBar(),
          ],
          ),
        ],
      ),
    );
  }

  AppBar _normalAppBar() => AppBar(title: Text(widget.folder.name));

  AppBar _selectionAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear),
        ),
        title: Text('Выбрано: ${_selected.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Переместить',
            onPressed: _moveSelected,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Удалить',
            onPressed: _deleteSelected,
          ),
        ],
      );

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _confirmDeleteNote(Note n) async {
    final ok = await confirmDelete(
      context,
      title: 'Удалить заметку',
      message: 'Удалить эту заметку? Это необратимо.',
    );
    if (ok) await appService.deleteNote(n);
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.appBar,
        title: const Text('Удалить заметки'),
        content: Text('Удалить выбранные (${ids.length})? Это необратимо.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final n in List<Note>.from(_notes)) {
      if (ids.contains(n.id)) await appService.deleteNote(n);
    }
    setState(_selected.clear);
  }

  Future<void> _moveSelected() async {
    final folders = (await appService.folders())
        .where((f) => f.id != widget.folder.id)
        .toList();
    if (!mounted) return;
    if (folders.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Нет других папок')));
      return;
    }
    final targetId = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.appBar,
        title: const Text('Переместить в…'),
        children: folders
            .map((f) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, f.id),
                  child: Text(f.name, style: TextStyle(color: AppColors.text)),
                ))
            .toList(),
      ),
    );
    if (targetId == null) return;
    final ids = _selected.toList();
    for (final n in List<Note>.from(_notes)) {
      if (ids.contains(n.id)) await appService.moveNote(n, targetId);
    }
    setState(_selected.clear);
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        color: AppColors.field,
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_editing != null)
              Row(
                children: [
                  const SizedBox(width: 8),
                  Icon(Icons.edit, size: 16, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text('Редактирование заметки',
                          style: TextStyle(color: AppColors.textSecondary))),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      setState(() => _editing = null);
                      _input.clear();
                    },
                  ),
                ],
              ),
            if (_pending.isNotEmpty) _pendingTray(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: Icon(Icons.attach_file, color: AppColors.textSecondary),
                  onPressed: (_editing == null && !_sending) ? _pickFiles : null,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 6,
                    style: TextStyle(color: AppColors.text),
                    decoration: InputDecoration(
                      hintText: 'Напишите заметку…',
                      hintStyle: TextStyle(color: AppColors.textSecondary),
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                  ),
                ),
                _sending
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: Icon(Icons.send, color: AppColors.accent),
                        onPressed: _send,
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingTray() {
    return SizedBox(
      height: 64,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _pending.length,
        itemBuilder: (ctx, i) {
          final p = _pending[i];
          return Padding(
            padding: const EdgeInsets.all(4),
            child: Stack(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: p.isImage
                      ? Image.file(File(p.path), fit: BoxFit.cover)
                      : Center(
                          child: Text(
                              p.mime.startsWith('video/') ? '🎬' : '📄',
                              style: const TextStyle(fontSize: 22))),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: () => setState(() => _pending.removeAt(i)),
                    child: const CircleAvatar(
                      radius: 9,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.close, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
