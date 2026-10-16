/// 🚀 variants in three stages:
///  1. [decodeFused] + [queryObjects]: the same `User` objects, but bytes
///     instead of a String, fused decoder, loops instead of chains, JsonUtf8Encoder.
///     "One afternoon" changes.
///  2. [tableFromTree]: JSON tree -> columnar table; shows how much the
///     `User` objects themselves cost vs the Map/List tree.
///  3. [parseUsersColumnar] (json_scanner.dart) + [queryColumnar]: a single
///     pass over the bytes, zero tree, strings decoded only for the top-N.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'columnar.dart';
import 'generator.dart' show countries;
import 'json_scanner.dart';
import 'model.dart';

final _fused = utf8.decoder.fuse(json.decoder);
final _utf8Json = JsonUtf8Encoder();

// ---------------------------------------------------------------- stage 1

/// bodyBytes -> fused utf8+json -> `List<User>` (without the intermediate 2 MB String).
List<User> decodeFused(Uint8List bytes) {
  final list = _fused.convert(bytes) as List<dynamic>;
  final out = List<User>.filled(list.length, _placeholder, growable: false);
  for (var i = 0; i < list.length; i++) {
    out[i] = User.fromJson(list[i] as Map<String, dynamic>);
  }
  return out;
}

final _placeholder = User(
  id: 0,
  username: '',
  email: '',
  firstName: '',
  lastName: '',
  age: 0,
  country: '',
  city: '',
  isActive: false,
  premium: false,
  score: 0,
  balance: 0,
  createdAt: DateTime.utc(1970),
  tags: const [],
  address: const Address(street: '', zip: ''),
);

/// Loops instead of where/map; epoch ms comparison instead of DateTime.isAfter;
/// JsonUtf8Encoder instead of jsonEncode+utf8.encode.
PipelineResult queryObjects(List<User> users, UserQuery q) {
  final afterMs = q.createdAfter.millisecondsSinceEpoch;
  final matching = <User>[];
  final perCountry = Int32List(countries.length);
  for (var i = 0; i < users.length; i++) {
    final u = users[i];
    if (u.isActive) perCountry[countries.indexOf(u.country)]++;
    if (u.country == q.country &&
        u.isActive &&
        u.premium &&
        u.age >= q.minAge &&
        u.age <= q.maxAge &&
        u.score >= q.minScore &&
        u.createdAt.millisecondsSinceEpoch > afterMs) {
      matching.add(u);
    }
  }
  matching.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  final n = matching.length < q.top ? matching.length : q.top;
  final names =
      List<String>.generate(n, (i) => matching[i].fullName, growable: false);
  final encoded =
      _utf8Json.convert([for (var i = 0; i < n; i++) matching[i].toJson()]);
  return PipelineResult(names, _countsToMap(perCountry), encoded);
}

// ---------------------------------------------------------------- stage 2

/// JSON tree -> columnar table (without User objects). String offsets are
/// not available (the tree already decoded them), so the strings would live as a
/// `List<String>` in a helper structure — here we write them back into a buffer
/// so the table API is identical. This is the "intermediate" variant for cost comparison.
UserTable tableFromTree(Uint8List bytes) {
  final list = _fused.convert(bytes) as List<dynamic>;
  // Build our own string buffer (UTF-8, JSON-escaped) that the offsets point into.
  final sb = BytesBuilder(copy: false);
  var off = 0;
  final t = UserTable(Uint8List(0), capacity: list.isEmpty ? 1 : list.length);
  int put(String s) {
    final enc = _utf8Json.convert(s) as Uint8List; // with quotes
    sb.add(Uint8List.sublistView(enc, 1, enc.length - 1));
    final start = off;
    off += enc.length - 2;
    return start;
  }

  for (var i = 0; i < list.length; i++) {
    final m = list[i] as Map<String, dynamic>;
    t.id[i] = m['id'] as int;
    t.age[i] = m['age'] as int;
    t.countryId[i] = countries.indexOf(m['country'] as String);
    t.flags[i] = ((m['isActive'] as bool) ? flagActive : 0) |
        ((m['premium'] as bool) ? flagPremium : 0);
    t.score[i] = (m['score'] as num).toDouble();
    t.balance[i] = (m['balance'] as num).toDouble();
    t.createdAtMs[i] =
        DateTime.parse(m['createdAt'] as String).millisecondsSinceEpoch;
    t.tagCount[i] = (m['tags'] as List).length;
    t.usernameOff[i] = put(m['username'] as String);
    t.usernameLen[i] = off - t.usernameOff[i];
    t.emailOff[i] = put(m['email'] as String);
    t.emailLen[i] = off - t.emailOff[i];
    t.firstOff[i] = put(m['firstName'] as String);
    t.firstLen[i] = off - t.firstOff[i];
    t.lastOff[i] = put(m['lastName'] as String);
    t.lastLen[i] = off - t.lastOff[i];
    t.cityOff[i] = put(m['city'] as String);
    t.cityLen[i] = off - t.cityOff[i];
  }
  t.length = list.length;
  return t.withRaw(sb.takeBytes());
}

// ---------------------------------------------------------------- stage 3

/// Bytes -> columnar table in a single pass (json_scanner.dart).
UserTable decodeColumnar(Uint8List bytes) => parseUsersColumnar(bytes);

/// Filter over typed lists, top-N via a min-heap (no sorting of 10k),
/// group-by via Int32List, encode by copying raw JSON bytes.
PipelineResult queryColumnar(UserTable t, UserQuery q) {
  final country = countries.indexOf(q.country);
  final afterMs = q.createdAfter.millisecondsSinceEpoch;
  final flagsNeeded = flagActive | flagPremium;
  final perCountry = Int32List(countries.length);

  // Min-heap of size top: holds row indices; the worst one is on top.
  final heap = Int32List(q.top);
  var heapSize = 0;
  final score = t.score, id = t.id;
  bool worse(int a, int b) {
    // a is "worse" than b (lower score; on a tie, higher id)
    final sa = score[a], sb = score[b];
    return sa != sb ? sa < sb : id[a] > id[b];
  }

  void siftDown(int i) {
    while (true) {
      final l = 2 * i + 1, r = l + 1;
      var m = i;
      if (l < heapSize && worse(heap[l], heap[m])) m = l;
      if (r < heapSize && worse(heap[r], heap[m])) m = r;
      if (m == i) return;
      final tmp = heap[i];
      heap[i] = heap[m];
      heap[m] = tmp;
      i = m;
    }
  }

  void siftUp(int i) {
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (!worse(heap[i], heap[p])) return;
      final tmp = heap[i];
      heap[i] = heap[p];
      heap[p] = tmp;
      i = p;
    }
  }

  final n = t.length;
  final flags = t.flags,
      countryId = t.countryId,
      age = t.age,
      created = t.createdAtMs;
  for (var i = 0; i < n; i++) {
    final f = flags[i];
    if (f & flagActive != 0) perCountry[countryId[i]]++;
    if (countryId[i] != country || f & flagsNeeded != flagsNeeded) continue;
    final a = age[i];
    if (a < q.minAge ||
        a > q.maxAge ||
        score[i] < q.minScore ||
        created[i] <= afterMs) {
      continue;
    }
    if (heapSize < q.top) {
      heap[heapSize++] = i;
      siftUp(heapSize - 1);
    } else if (worse(heap[0], i)) {
      heap[0] = i;
      siftDown(0);
    }
  }
  // Pull from the heap starting with the worst -> reverse.
  final order = Int32List(heapSize);
  for (var k = heapSize - 1; k >= 0; k--) {
    order[k] = heap[0];
    heap[0] = heap[--heapSize];
    siftDown(0);
  }

  final names = List<String>.generate(order.length, (k) => t.fullName(order[k]),
      growable: false);
  final encoded = _encodeRows(t, order);
  return PipelineResult(names, _countsToMap(perCountry), encoded);
}

/// Serialization of the top-N: numeric fields formatted by hand, strings copied
/// as raw JSON bytes (they are already correctly escaped in the source).
Uint8List _encodeRows(UserTable t, Int32List rows) {
  final w = _ByteWriter(64 * 1024);
  w.byte(0x5b);
  for (var k = 0; k < rows.length; k++) {
    if (k != 0) w.byte(0x2c);
    final i = rows[k];
    w.ascii('{"id":');
    w.integer(t.id[i]);
    w.ascii(',"username":');
    w.rawString(t.raw, t.usernameOff[i], t.usernameLen[i]);
    w.ascii(',"email":');
    w.rawString(t.raw, t.emailOff[i], t.emailLen[i]);
    w.ascii(',"firstName":');
    w.rawString(t.raw, t.firstOff[i], t.firstLen[i]);
    w.ascii(',"lastName":');
    w.rawString(t.raw, t.lastOff[i], t.lastLen[i]);
    w.ascii(',"age":');
    w.integer(t.age[i]);
    w.ascii(',"country":"');
    w.ascii(countries[t.countryId[i]]);
    w.byte(0x22);
    w.ascii(',"city":');
    w.rawString(t.raw, t.cityOff[i], t.cityLen[i]);
    w.ascii(',"isActive":');
    w.ascii(t.isActive(i) ? 'true' : 'false');
    w.ascii(',"premium":');
    w.ascii(t.isPremium(i) ? 'true' : 'false');
    w.ascii(',"score":');
    w.ascii(_fmtDouble(t.score[i]));
    w.ascii(',"balance":');
    w.ascii(_fmtDouble(t.balance[i]));
    w.ascii(',"createdAt":"');
    w.isoDate(t.createdAtMs[i]);
    w.byte(0x22);
    w.ascii(',"tagCount":');
    w.integer(t.tagCount[i]);
    w.byte(0x7d);
  }
  w.byte(0x5d);
  return w.take();
}

/// A double's `toString()` gives the same representation as jsonEncode (shortest round-trip),
/// just without intermediate objects; for integral values Dart gives "87.0".
String _fmtDouble(double v) => v.toString();

Map<String, int> _countsToMap(Int32List counts) {
  final m = <String, int>{};
  final keys = List<String>.of(countries)..sort();
  for (final k in keys) {
    final c = counts[countries.indexOf(k)];
    if (c != 0) m[k] = c;
  }
  return m;
}

class _ByteWriter {
  Uint8List _b;
  int _n = 0;
  _ByteWriter(int cap) : _b = Uint8List(cap);
  void _grow(int extra) {
    if (_n + extra <= _b.length) return;
    _b = Uint8List((_n + extra) * 2)..setRange(0, _n, _b);
  }

  void byte(int c) {
    _grow(1);
    _b[_n++] = c;
  }

  void ascii(String s) {
    _grow(s.length);
    for (var i = 0; i < s.length; i++) {
      _b[_n++] = s.codeUnitAt(i);
    }
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
    var digits = 0;
    var t = v;
    while (t > 0) {
      t ~/= 10;
      digits++;
    }
    _grow(digits);
    var p = _n + digits - 1;
    while (v > 0) {
      _b[p--] = 0x30 + v % 10;
      v ~/= 10;
    }
    _n += digits;
  }

  void rawString(Uint8List src, int off, int len) {
    _grow(len + 2);
    _b[_n++] = 0x22;
    _b.setRange(_n, _n + len, src, off);
    _n += len;
    _b[_n++] = 0x22;
  }

  void _pad(int v, int w) {
    _grow(w);
    for (var i = w - 1; i >= 0; i--) {
      _b[_n + i] = 0x30 + v % 10;
      v ~/= 10;
    }
    _n += w;
  }

  /// epoch ms -> "YYYY-MM-DDTHH:MM:SS.mmmZ" without DateTime.
  void isoDate(int ms) {
    var days = ms ~/ 86400000;
    var rem = ms - days * 86400000;
    if (rem < 0) {
      rem += 86400000;
      days--;
    }
    // civil_from_days (H. Hinnant)
    final z = days + 719468;
    final era = (z >= 0 ? z : z - 146096) ~/ 146097;
    final doe = z - era * 146097;
    final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
    var y = yoe + era * 400;
    final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
    final mp = (5 * doy + 2) ~/ 153;
    final d = doy - (153 * mp + 2) ~/ 5 + 1;
    final m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    _pad(y, 4);
    byte(0x2d);
    _pad(m, 2);
    byte(0x2d);
    _pad(d, 2);
    byte(0x54);
    _pad(rem ~/ 3600000, 2);
    byte(0x3a);
    _pad(rem % 3600000 ~/ 60000, 2);
    byte(0x3a);
    _pad(rem % 60000 ~/ 1000, 2);
    byte(0x2e);
    _pad(rem % 1000, 3);
    byte(0x5a);
  }

  Uint8List take() => Uint8List.sublistView(_b, 0, _n);
}
