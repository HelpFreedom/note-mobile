// Разбор текста заметки на кликабельные элементы: URL и ссылки на заметки [[id]].
// Возвращает спаны для Text.rich. (Распознаватели тапа живут вместе с пузырём;
// для заметок их немного — допустимо.)

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

final _urlRe = RegExp(r'(https?://|www\.)[^\s<>"]+', caseSensitive: false);
final _refRe = RegExp(r'\[\[([0-9a-fA-F]{32})\]\]');

class _Match {
  final int start;
  final int end;
  final String type; // url | ref
  final String value;
  _Match(this.start, this.end, this.type, this.value);
}

List<InlineSpan> buildNoteSpans(
  String text, {
  required TextStyle base,
  required Color linkColor,
  required void Function(String noteId) onRef,
  required void Function(String url) onUrl,
}) {
  final matches = <_Match>[];
  for (final m in _urlRe.allMatches(text)) {
    matches.add(_Match(m.start, m.end, 'url', m.group(0)!));
  }
  for (final m in _refRe.allMatches(text)) {
    matches.add(_Match(m.start, m.end, 'ref', m.group(1)!));
  }
  matches.sort((a, b) => a.start.compareTo(b.start));

  final spans = <InlineSpan>[];
  final linkStyle =
      base.copyWith(color: linkColor, decoration: TextDecoration.underline);
  var last = 0;
  for (final m in matches) {
    if (m.start < last) continue; // пропустить перекрытие
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    }
    if (m.type == 'url') {
      final url = m.value.toLowerCase().startsWith('http') ? m.value : 'http://${m.value}';
      spans.add(TextSpan(
        text: m.value,
        style: linkStyle,
        recognizer: TapGestureRecognizer()..onTap = () => onUrl(url),
      ));
    } else {
      final id = m.value.toLowerCase();
      spans.add(TextSpan(
        text: '↪ #${id.substring(0, 6)}',
        style: base.copyWith(color: linkColor),
        recognizer: TapGestureRecognizer()..onTap = () => onRef(id),
      ));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: base));
  }
  return spans;
}
