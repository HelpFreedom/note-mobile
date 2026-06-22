// M4: поисковый индекс в памяти (как desktop index.py + search.py, но без нативного
// sqlite — на масштабе заметочника индекс из id+folder+plaintext занимает единицы МБ).
// Семантика повторяет десктоп: точная дата → 100; иначе нечёткое ранжирование
// max(partial, tokenSet) с порогом 60, сортировка по (score desc, created asc).
//
// Индекс строится один раз за сессию (скан расшифрованных заметок) и поддерживается
// инкрементально при save/delete/move — это убирает «крипто-шторм» на каждый символ.

import 'models.dart';

const int kScoreThreshold = 60;

class SearchEntry {
  final String id;
  final String folderId;
  final String plaintext;
  final String? dateTag;
  final String created;
  SearchEntry(this.id, this.folderId, this.plaintext, this.dateTag, this.created);
}

class SearchHit {
  final String id;
  final String folderId;
  final String plaintext;
  final double score;
  SearchHit(this.id, this.folderId, this.plaintext, this.score);
}

class SearchIndex {
  final Map<String, SearchEntry> _byId = {};

  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;

  void upsert(Note n) {
    _byId[n.id] = SearchEntry(n.id, n.folderId, n.plaintext, n.dateTag, n.created);
  }

  void remove(String id) => _byId.remove(id);
  void removeFolder(String folderId) =>
      _byId.removeWhere((_, e) => e.folderId == folderId);
  void clear() => _byId.clear();

  List<SearchHit> search(String query, {String? folderId, int limit = 80}) {
    final q = query.trim();
    if (q.isEmpty) return [];
    final ql = q.toLowerCase();
    final hits = <SearchHit>[];
    final seen = <String>{};

    // точная дата — высший приоритет
    final dateStr = _tryDate(q);
    if (dateStr != null) {
      for (final e in _byId.values) {
        if (folderId != null && e.folderId != folderId) continue;
        if (e.dateTag == dateStr || e.created.startsWith(dateStr)) {
          hits.add(SearchHit(e.id, e.folderId, e.plaintext, 100));
          seen.add(e.id);
        }
      }
    }

    for (final e in _byId.values) {
      if (seen.contains(e.id)) continue;
      if (folderId != null && e.folderId != folderId) continue;
      final text = e.plaintext;
      if (text.isEmpty) continue;
      final score = _fuzzy(ql, text.toLowerCase());
      if (score >= kScoreThreshold) {
        hits.add(SearchHit(e.id, e.folderId, text, score));
      }
    }

    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  // --- нечёткое ранжирование (приближение rapidfuzz partial/token_set) ---

  double _fuzzy(String q, String text) {
    final p = _partialRatio(q, text);
    if (p >= 100) return 100;
    final t = _tokenSetRatio(q, text);
    return p > t ? p : t;
  }

  /// Лучшее совпадение query как подстроки text (как fuzz.partial_ratio).
  double _partialRatio(String q, String text) {
    if (q.isEmpty || text.isEmpty) return 0;
    if (text.contains(q)) return 100;
    if (q.length >= text.length) return _simRatio(q, text);
    // скользящее окно длины q по text — берём лучшую похожесть
    double best = 0;
    final win = q.length;
    for (var i = 0; i + win <= text.length; i++) {
      final s = _simRatio(q, text.substring(i, i + win));
      if (s > best) best = s;
      if (best >= 100) break;
    }
    return best;
  }

  /// Токенная похожесть: для каждого токена запроса — лучший токен текста, среднее.
  double _tokenSetRatio(String q, String text) {
    final qt = _tokens(q), tt = _tokens(text);
    if (qt.isEmpty || tt.isEmpty) return 0;
    double sum = 0;
    for (final a in qt) {
      double best = 0;
      for (final b in tt) {
        final s = a == b ? 100.0 : _simRatio(a, b);
        if (s > best) best = s;
        if (best >= 100) break;
      }
      sum += best;
    }
    return sum / qt.length;
  }

  List<String> _tokens(String s) =>
      s.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((t) => t.isNotEmpty).toList();

  /// Нормированная похожесть по Левенштейну: 100*(1 - dist/maxLen).
  double _simRatio(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 100;
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return 100;
    final d = _lev(a, b);
    return 100.0 * (1.0 - d / maxLen);
  }

  int _lev(String a, String b) {
    final m = a.length, n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var v = prev[j] + 1;
        if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
        if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
        cur[j] = v;
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }

  // --- разбор даты (как _try_date в search.py: YYYY-MM-DD, DD.MM.YYYY) ---

  String? _tryDate(String q) {
    final s = q.trim();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (iso != null) return s;
    final dmy = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(s);
    if (dmy != null) {
      final d = dmy.group(1)!.padLeft(2, '0');
      final mo = dmy.group(2)!.padLeft(2, '0');
      return '${dmy.group(3)}-$mo-$d';
    }
    return null;
  }
}
