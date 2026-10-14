/// Sekcja 1 i 3 przewodnika: serializacja JSON.
///
/// Warianty od najwolniejszego do najszybszego:
///  1. `jsonEncode(map)` + `utf8.encode(...)`: Map -> String (UTF-16) -> bajty.
///     Dwie pełne kopie i tysiące obiektów pośrednich.
///  2. `JsonUtf8Encoder().convert(map)`: fuzja "serializuj + koduj UTF-8" prosto
///     do bufora bajtów; omija obiekt String.
///  3. `JsonUtf8Encoder` na obiekcie z `toJson()` (nadal Map pośrednia).
///  4. Ręczny writer bajtowy do reużywalnego `Uint8List` (wzorzec z
///     `dart-rawsocket-C-Hatton` i zwycięskiego Rusta): zero alokacji w hot
///     path, pola zapisywane bezpośrednio z surowych bajtów.
///
/// Dekodowanie: `jsonDecode(utf8.decode(bytes))` vs
/// `utf8.decoder.fuse(json.decoder).convert(bytes)` (jeden przebieg, bez
/// pośredniego Stringa UTF-16 dla całego dokumentu).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../harness.dart';

class Post {
  final int id;
  final String body;
  final String createdAt;
  final String author;
  final int likeCount;
  Post(this.id, this.body, this.createdAt, this.author, this.likeCount);

  Map<String, Object?> toJson() => {
        'id': id,
        'body': body,
        'created_at': createdAt,
        'author': author,
        'like_count': likeCount,
      };
}

final List<Post> _posts = List.generate(
  20,
  (i) => Post(
    500_000 - i,
    'user$i says hi at 2026-10-14T10:00:00.000Z (VU $i, iter 3) "quoted"',
    '2026-10-14T10:00:0$i.123Z',
    'user_${1000 + i}',
    i * 7,
  ),
);

// Te same dane jako surowe bajty UTF-8, tak jak przychodzą z SQLite
// (`CAST(col AS BLOB)`) albo z sieci.
final List<Uint8List> _bodyBytes =
    _posts.map((p) => Uint8List.fromList(utf8.encode(p.body))).toList();
final List<Uint8List> _createdBytes =
    _posts.map((p) => Uint8List.fromList(utf8.encode(p.createdAt))).toList();
final List<Uint8List> _authorBytes =
    _posts.map((p) => Uint8List.fromList(utf8.encode(p.author))).toList();

Map<String, Object?> _feedMap() => {
      'posts': [for (final p in _posts) p.toJson()],
    };

Uint8List _encodeNaive() {
  final s = jsonEncode(_feedMap());
  return Uint8List.fromList(utf8.encode(s));
}

final _utf8Encoder = JsonUtf8Encoder();

Uint8List _encodeJsonUtf8Encoder() {
  return _utf8Encoder.convert(_feedMap()) as Uint8List;
}

/// Reużywalny bufor wyjściowy + ręczne pisanie bajtów (zero alokacji
/// poza wynikową kopią o dokładnym rozmiarze).
class ByteWriter {
  Uint8List _buf = Uint8List(1 << 16);
  int _len = 0;

  int get length => _len;
  void reset() => _len = 0;

  void _grow(int extra) {
    if (_len + extra <= _buf.length) return;
    final nb = Uint8List((_len + extra) * 2);
    nb.setRange(0, _len, _buf);
    _buf = nb;
  }

  void ascii(String s) {
    _grow(s.length);
    final b = _buf;
    var n = _len;
    for (var i = 0; i < s.length; i++) {
      b[n++] = s.codeUnitAt(i);
    }
    _len = n;
  }

  void byte(int c) {
    _grow(1);
    _buf[_len++] = c;
  }

  void integer(int v) {
    if (v == 0) {
      byte(0x30);
      return;
    }
    if (v < 0) {
      byte(0x2d);
      v = -v;
    }
    // Zapis cyfr od końca do małego bufora na stosie, potem kopiujemy.
    var tmp = 0;
    var digits = 0;
    while (v > 0) {
      tmp = tmp * 10 + (v % 10);
      v ~/= 10;
      digits++;
    }
    _grow(digits);
    for (var i = 0; i < digits; i++) {
      _buf[_len++] = 0x30 + tmp % 10;
      tmp ~/= 10;
    }
  }

  /// JSON string z surowych bajtów UTF-8: escapujemy tylko `"`, `\` i < 0x20.
  void jsonString(Uint8List s) {
    _grow(s.length * 6 + 2);
    final b = _buf;
    var n = _len;
    b[n++] = 0x22;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c >= 0x20 && c != 0x22 && c != 0x5c) {
        b[n++] = c;
      } else if (c == 0x22 || c == 0x5c) {
        b[n++] = 0x5c;
        b[n++] = c;
      } else {
        const hex = '0123456789abcdef';
        b[n++] = 0x5c;
        b[n++] = 0x75;
        b[n++] = 0x30;
        b[n++] = 0x30;
        b[n++] = hex.codeUnitAt(c >> 4);
        b[n++] = hex.codeUnitAt(c & 15);
      }
    }
    b[n++] = 0x22;
    _len = n;
  }

  /// Widok (bez kopii) na zapisane bajty. Ważny tylko do następnego reset().
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);

  Uint8List copy() => Uint8List.fromList(view());
}

final _writer = ByteWriter();

Uint8List _encodeHandRolled() {
  final w = _writer..reset();
  w.ascii('{"posts":[');
  for (var i = 0; i < _posts.length; i++) {
    if (i != 0) w.byte(0x2c);
    final p = _posts[i];
    w.ascii('{"id":');
    w.integer(p.id);
    w.ascii(',"body":');
    w.jsonString(_bodyBytes[i]);
    w.ascii(',"created_at":');
    w.jsonString(_createdBytes[i]);
    w.ascii(',"author":');
    w.jsonString(_authorBytes[i]);
    w.ascii(',"like_count":');
    w.integer(p.likeCount);
    w.byte(0x7d);
  }
  w.ascii(']}');
  // W serwerze wysłalibyśmy w.view() prosto do socketu. Tu kopiujemy, żeby
  // porównanie z innymi wariantami (które zwracają świeży bufor) było uczciwe.
  return w.copy();
}

final Uint8List _encoded = _encodeNaive();
final _fusedDecoder = utf8.decoder.fuse(json.decoder);

Object? _decodeNaive() => jsonDecode(utf8.decode(_encoded));
Object? _decodeFused() => _fusedDecoder.convert(_encoded);

List<Suite> suites() {
  // Sanity check: wszystkie encodery dają identyczne bajty.
  final a = _encodeNaive(),
      b = _encodeJsonUtf8Encoder(),
      c = _encodeHandRolled();
  if (a.length != b.length || a.length != c.length) {
    throw StateError(
        'JSON encoders differ: ${a.length} ${b.length} ${c.length}');
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i] || a[i] != c[i]) {
      throw StateError('JSON encoders differ at byte $i');
    }
  }

  final enc = Suite('json/encode feed (20 postów, ~2.6 KB)')
    ..add('jsonEncode(map) + utf8.encode', () => blackHole(_encodeNaive()))
    ..add('JsonUtf8Encoder().convert(map)',
        () => blackHole(_encodeJsonUtf8Encoder()))
    ..add('ByteWriter: bajty prosto do Uint8List (zero-alloc)',
        () => blackHole(_encodeHandRolled()));

  final dec = Suite('json/decode feed (~2.6 KB)')
    ..add('jsonDecode(utf8.decode(bytes))', () => blackHole(_decodeNaive()))
    ..add('utf8.decoder.fuse(json.decoder).convert(bytes)',
        () => blackHole(_decodeFused()));

  return [enc, dec];
}
