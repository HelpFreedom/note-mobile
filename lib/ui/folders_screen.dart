import 'package:flutter/material.dart';

import '../app/app_service.dart';
import '../storage/models.dart';
import 'calendar_screen.dart';
import 'chat_screen.dart';
import 'folder_icons.dart';
import 'search_screen.dart';
import 'sync_screen.dart';
import 'theme.dart';
import 'widgets/confirm.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  List<Folder> _folders = [];

  @override
  void initState() {
    super.initState();
    appService.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    appService.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final folders = await appService.folders();
    if (mounted) setState(() => _folders = folders);
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    var iconId = 'letter';
    var colorIndex = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.appBar,
          title: const Text('Новая папка'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Название'),
                ),
                const SizedBox(height: 14),
                Text('Иконка', style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: folderIconIds.map((id) {
                    final selected = id == iconId;
                    final icon = folderIconData(id);
                    return GestureDetector(
                      onTap: () => setLocal(() => iconId = id),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.eventColors[colorIndex],
                          shape: BoxShape.circle,
                          border: selected
                              ? Border.all(color: Colors.white, width: 2)
                              : null,
                        ),
                        child: icon != null
                            ? Icon(icon, color: Colors.white, size: 19)
                            : const Center(
                                child: Text('А',
                                    style: TextStyle(
                                        color: Colors.white, fontWeight: FontWeight.bold))),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                Text('Цвет', style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: List.generate(AppColors.eventColors.length, (i) {
                    return GestureDetector(
                      onTap: () => setLocal(() => colorIndex = i),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: AppColors.eventColors[i],
                          shape: BoxShape.circle,
                          border: i == colorIndex
                              ? Border.all(color: Colors.white, width: 2)
                              : null,
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      final hex =
          '#${AppColors.eventColors[colorIndex].toARGB32().toRadixString(16).substring(2)}';
      await appService.createFolder(controller.text.trim(), icon: iconId, color: hex);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QtNotes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Поиск',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SearchScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Календарь',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const CalendarScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Синхронизация',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SyncScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addFolder,
        child: const Icon(Icons.create_new_folder),
      ),
      body: _folders.isEmpty
          ? Center(
              child: Text('Нет папок. Создайте первую кнопкой ниже.',
                  style: TextStyle(color: AppColors.textSecondary)))
          : ListView.separated(
              itemCount: _folders.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (ctx, i) {
                final f = _folders[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _avatarColor(f),
                    child: _avatarChild(f),
                  ),
                  title: Text(f.name),
                  subtitle: f.caption.isNotEmpty
                      ? Text(f.caption,
                          maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => ChatScreen(folder: f))),
                  onLongPress: () => _folderMenu(f),
                );
              },
            ),
    );
  }

  Color _avatarColor(Folder f) {
    if (f.color != null && f.color!.startsWith('#') && f.color!.length == 7) {
      return Color(int.parse('FF${f.color!.substring(1)}', radix: 16));
    }
    return AppColors.accent;
  }

  Widget _avatarChild(Folder f) {
    final icon = folderIconData(f.icon);
    if (icon != null) return Icon(icon, color: Colors.white, size: 20);
    return Text(
      f.name.isNotEmpty ? f.name.characters.first.toUpperCase() : '?',
      style: const TextStyle(color: Colors.white),
    );
  }

  void _folderMenu(Folder f) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.appBar,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.danger),
              title: const Text('Удалить папку',
                  style: TextStyle(color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await confirmDelete(
                  context,
                  title: 'Удалить папку',
                  message: 'Удалить папку «${f.name}» со всеми заметками? '
                      'Это необратимо.',
                );
                if (ok) await appService.deleteFolder(f.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}
