import 'package:flutter/material.dart';

// Те же 15 идентификаторов иконок, что на десктопе (qtnotes/ui/folder_icons.py).
const folderIconIds = [
  'letter', 'dot', 'ring', 'square', 'triangle', 'diamond', 'star', 'heart',
  'hexagon', 'pentagon', 'plus', 'cross', 'check', 'bolt', 'moon',
];

/// IconData для id папки. null для 'letter' — тогда показываем первую букву имени.
IconData? folderIconData(String id) {
  switch (id) {
    case 'dot':
      return Icons.circle;
    case 'ring':
      return Icons.radio_button_unchecked;
    case 'square':
      return Icons.square;
    case 'triangle':
      return Icons.change_history;
    case 'diamond':
      return Icons.diamond;
    case 'star':
      return Icons.star;
    case 'heart':
      return Icons.favorite;
    case 'hexagon':
      return Icons.hexagon;
    case 'pentagon':
      return Icons.pentagon;
    case 'plus':
      return Icons.add;
    case 'cross':
      return Icons.close;
    case 'check':
      return Icons.check;
    case 'bolt':
      return Icons.bolt;
    case 'moon':
      return Icons.dark_mode;
    default:
      return null; // 'letter'
  }
}
