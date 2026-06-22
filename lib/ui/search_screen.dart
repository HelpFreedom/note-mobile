import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_service.dart';
import '../storage/models.dart';
import 'chat_screen.dart';
import 'theme.dart';

class _Hit {
  final String plaintext;
  final Folder folder;
  _Hit(this.plaintext, this.folder);
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<_Hit> _results = [];
  bool _searched = false;
  Timer? _debounce; // отложить поиск до паузы в наборе
  int _seq = 0; // токен запроса: ответ устаревшего запроса не перезатрёт свежий

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    final mySeq = ++_seq; // помечаем этот запрос самым свежим
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searched = false;
      });
      return;
    }
    // M4: поиск по индексу в памяти (нечёткий, без расшифровки всех заметок на символ)
    final foldersById = {for (final f in await appService.folders()) f.id: f};
    final hits = <_Hit>[];
    for (final hit in await appService.search(query)) {
      final folder = foldersById[hit.folderId];
      if (folder == null) continue; // папка удалена — пропускаем
      hits.add(_Hit(hit.plaintext, folder));
    }
    if (!mounted || mySeq != _seq) return; // не перезатираем результат свежего запроса
    setState(() {
      _results = hits;
      _searched = true;
    });
  }

  String _snippet(String text) {
    final t = text.replaceAll('\n', ' ').trim();
    return t.length <= 120 ? t : '${t.substring(0, 120)}…';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: TextStyle(color: AppColors.text),
          decoration: InputDecoration(
            hintText: 'Поиск по заметкам…',
            hintStyle: TextStyle(color: AppColors.textSecondary),
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(_searched ? 'Ничего не найдено' : 'Введите запрос',
                  style: TextStyle(color: AppColors.textSecondary)))
          : ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (ctx, i) {
                final h = _results[i];
                return ListTile(
                  title: Text(h.folder.name,
                      style: TextStyle(
                          color: AppColors.accent, fontSize: 13)),
                  subtitle: Text(_snippet(h.plaintext)),
                  onTap: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ChatScreen(folder: h.folder))),
                );
              },
            ),
    );
  }
}
