// Кадрирование и (де)сериализация сообщений протокола (docs/sync-protocol.md).
// Кадр: uint32 длина (big-endian) + uint8 тип (1=CONTROL JSON, 2=BLOB) + тело.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

const int kControl = 1;
const int kBlob = 2;
// H6: раздельные потолки. CONTROL (hello/have/ops/want_blobs JSON) много меньше BLOB
// (вложения/видео). Тип читается ДО тела → лимит применяется до аллокации.
const int kMaxControlFrame = 64 * 1024 * 1024;
const int kMaxBlobFrame = 256 * 1024 * 1024;
const int kMaxFrame = kMaxBlobFrame; // абсолютный потолок (для записи)
const int _hashHex = 64;

class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

/// Результат чтения кадра: либо CONTROL (JSON), либо BLOB (sha256 + байты).
class Frame {
  final Map<String, dynamic>? control;
  final String? blobSha;
  final Uint8List? blobData;
  Frame.control(this.control)
      : blobSha = null,
        blobData = null;
  Frame.blob(this.blobSha, this.blobData) : control = null;
  bool get isControl => control != null;
}

/// Буферизованное чтение точного числа байт из потока сокета.
class ByteReader {
  late final StreamSubscription _sub;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _len = 0;
  final List<Completer<void>> _waiters = [];
  bool _done = false;
  Object? _error;

  ByteReader(Stream<List<int>> stream) {
    _sub = stream.listen((data) {
      _buf.add(data);
      _len += data.length;
      _wake();
    }, onError: (Object e) {
      _error = e;
      _done = true;
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    });
  }

  void _wake() {
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> readExactly(int n) async {
    while (_len < n) {
      if (_done) throw _error ?? ProtocolException('поток закрыт');
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    final all = _buf.takeBytes(); // забирает и очищает буфер
    _len = 0;
    final out = Uint8List.sublistView(all, 0, n);
    if (all.length > n) {
      _buf.add(Uint8List.sublistView(all, n));
      _len = all.length - n;
    }
    return Uint8List.fromList(out);
  }

  Future<void> cancel() => _sub.cancel();
}

void _writeFrame(Sink<List<int>> sink, int type, List<int> body) {
  final total = body.length + 1;
  if (total > kMaxFrame) throw ProtocolException('кадр больше лимита: $total');
  final head = ByteData(4)..setUint32(0, total, Endian.big);
  sink.add(head.buffer.asUint8List());
  sink.add([type]);
  sink.add(body);
}

void writeMessage(Sink<List<int>> sink, Map<String, dynamic> obj) {
  _writeFrame(sink, kControl, utf8.encode(jsonEncode(obj)));
}

void writeBlob(Sink<List<int>> sink, String sha256Hex, List<int> data) {
  if (sha256Hex.length != _hashHex) {
    throw ProtocolException('sha256 должен быть 64 hex-символа');
  }
  final body = BytesBuilder(copy: false)
    ..add(ascii.encode(sha256Hex))
    ..add(data);
  _writeFrame(sink, kBlob, body.takeBytes());
}

Future<Frame> readFrame(ByteReader r) async {
  // длина + тип (5 байт): тип нужен, чтобы применить лимит ДО аллокации тела
  final head = await r.readExactly(5);
  final len = ByteData.sublistView(head, 0, 4).getUint32(0, Endian.big);
  final type = head[4];
  if (len < 1) throw ProtocolException('некорректная длина кадра: $len');
  final cap = type == kControl ? kMaxControlFrame : kMaxBlobFrame;
  if (len > cap) {
    throw ProtocolException('кадр типа $type превышает лимит: $len > $cap');
  }
  final payload = await r.readExactly(len - 1); // тело без байта типа
  if (type == kControl) {
    final obj = jsonDecode(utf8.decode(payload));
    return Frame.control((obj as Map).cast<String, dynamic>());
  }
  if (type == kBlob) {
    if (payload.length < _hashHex) throw ProtocolException('BLOB короче заголовка');
    final sha = ascii.decode(Uint8List.sublistView(payload, 0, _hashHex));
    final data = Uint8List.sublistView(payload, _hashHex);
    return Frame.blob(sha, Uint8List.fromList(data));
  }
  throw ProtocolException('неизвестный тип кадра: $type');
}
