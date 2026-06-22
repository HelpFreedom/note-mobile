import 'package:flutter/material.dart';

import '../theme.dart';

/// Единый диалог подтверждения необратимого удаления. Консистентен с батч-удалением
/// заметок (chat_screen). Возвращает true, если пользователь подтвердил.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Удалить',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.appBar,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel,
                style: const TextStyle(color: AppColors.danger))),
      ],
    ),
  );
  return ok == true;
}
