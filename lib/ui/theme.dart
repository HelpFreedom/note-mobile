// Тёмная тема в стиле Telegram. Цвета РАНТАЙМ-обновляемые: при синхронизации с
// десктопа применяется его палитра (AppColors.applyPalette), и весь интерфейс
// перекрашивается. Дефолты — встроенная тёмная тема.

import 'package:flutter/material.dart';

class AppColors {
  // дефолты встроенной темы
  static const _dBackground = Color(0xFF0E1621);
  static const _dAppBar = Color(0xFF17212B);
  static const _dBubble = Color(0xFF2B5278);
  static const _dBubbleAlt = Color(0xFF182533);
  static const _dAccent = Color(0xFF5288C1);
  static const _dField = Color(0xFF17212B);
  static const _dFieldBorder = Color(0xFF242F3D);
  static const _dText = Color(0xFFE9EDF0);
  static const _dTextSecondary = Color(0xFF7D8E9C);

  // текущие значения (переопределяются синхронизированной палитрой)
  static Color background = _dBackground;
  static Color appBar = _dAppBar;
  static Color bubble = _dBubble;
  static Color bubbleAlt = _dBubbleAlt;
  static Color accent = _dAccent;
  static Color field = _dField;
  static Color fieldBorder = _dFieldBorder;
  static Color text = _dText;
  static Color textSecondary = _dTextSecondary;
  static Color link = _dAccent; // десктоп шлёт отдельный цвет ссылок

  // неизменяемые
  static const danger = Color(0xFFE0524F);
  static const divider = Color(0xFF101921);

  // 10 цветов событий календаря (как на десктопе)
  static const eventColors = <Color>[
    Color(0xFF5288C1),
    Color(0xFF67B35E),
    Color(0xFFE0524F),
    Color(0xFFE8A33D),
    Color(0xFF9B59B6),
    Color(0xFF16A6A6),
    Color(0xFFE066A8),
    Color(0xFF8E7CC3),
    Color(0xFF5FA8D3),
    Color(0xFFC0894B),
  ];

  /// Применить синхронизированную палитру (или вернуть встроенные дефолты при null).
  static void applyPalette(Map<String, Color>? p) {
    background = p?['background'] ?? _dBackground;
    appBar = p?['appBar'] ?? _dAppBar;
    bubble = p?['bubble'] ?? _dBubble;
    bubbleAlt = p?['bubbleAlt'] ?? _dBubbleAlt;
    accent = p?['accent'] ?? _dAccent;
    field = p?['field'] ?? _dField;
    fieldBorder = p?['fieldBorder'] ?? _dFieldBorder;
    text = p?['text'] ?? _dText;
    textSecondary = p?['textSecondary'] ?? _dTextSecondary;
    link = p?['link'] ?? p?['accent'] ?? _dAccent;
  }
}

/// Тема Material из текущих AppColors (применять applyPalette ДО построения).
ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.appBar,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.appBar,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    dividerColor: AppColors.divider,
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    iconTheme: IconThemeData(color: AppColors.textSecondary),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: Colors.white,
    ),
    listTileTheme: ListTileThemeData(textColor: AppColors.text),
  );
}
