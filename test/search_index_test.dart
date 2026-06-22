// M4: индекс поиска — нечёткое ранжирование (как desktop), дата, scope, инкремент.
// Запуск: dart test test/search_index_test.dart

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/models.dart';
import 'package:qtnotes_mobile/storage/search_index.dart';

Note _note(String folder, String text, {String? dateTag}) {
  final n = Note.createText(folderId: folder, html: '<p>$text</p>', plaintext: text);
  n.dateTag = dateTag;
  return n;
}

void main() {
  test('подстрока находится с максимальным score', () {
    final idx = SearchIndex();
    idx.upsert(_note('f1', 'купить молоко и хлеб'));
    final hits = idx.search('молоко');
    expect(hits, isNotEmpty);
    expect(hits.first.score, 100);
  });

  test('опечатки толерантны (нечёткое совпадение)', () {
    final idx = SearchIndex();
    idx.upsert(_note('f1', 'позвонить маме'));
    final hits = idx.search('позвонит'); // пропущена буква
    expect(hits, isNotEmpty, reason: 'должно найти с опечаткой/префиксом');
  });

  test('нерелевантный запрос ниже порога — не найден', () {
    final idx = SearchIndex();
    idx.upsert(_note('f1', 'купить молоко'));
    expect(idx.search('zzzzz'), isEmpty);
  });

  test('поиск по дате (DD.MM.YYYY и YYYY-MM-DD)', () {
    final idx = SearchIndex();
    idx.upsert(_note('f1', 'встреча', dateTag: '2026-06-17'));
    idx.upsert(_note('f1', 'другое', dateTag: '2026-06-18'));
    expect(idx.search('17.06.2026').length, 1);
    expect(idx.search('2026-06-17').length, 1);
    expect(idx.search('2026-06-17').first.score, 100);
  });

  test('scope по папке', () {
    final idx = SearchIndex();
    idx.upsert(_note('f1', 'молоко'));
    idx.upsert(_note('f2', 'молоко'));
    expect(idx.search('молоко').length, 2);
    expect(idx.search('молоко', folderId: 'f1').length, 1);
  });

  test('ранжирование: точная подстрока выше нечёткой', () {
    final idx = SearchIndex();
    final exact = _note('f1', 'молоко');
    final fuzzy = _note('f1', 'малоко'); // опечатка
    idx.upsert(exact);
    idx.upsert(fuzzy);
    final hits = idx.search('молоко');
    expect(hits.first.id, exact.id);
    expect(hits.first.score, 100);
  });

  test('инкремент: upsert/remove/removeFolder/clear', () {
    final idx = SearchIndex();
    final n = _note('f1', 'молоко');
    idx.upsert(n);
    expect(idx.search('молоко'), isNotEmpty);
    // обновление содержимого
    n.plaintext = 'кефир';
    idx.upsert(n);
    expect(idx.search('молоко'), isEmpty);
    expect(idx.search('кефир'), isNotEmpty);
    // удаление
    idx.remove(n.id);
    expect(idx.search('кефир'), isEmpty);
    // removeFolder
    idx.upsert(_note('f1', 'яблоко'));
    idx.upsert(_note('f2', 'яблоко'));
    idx.removeFolder('f1');
    expect(idx.search('яблоко').length, 1);
    idx.clear();
    expect(idx.search('яблоко'), isEmpty);
  });
}
