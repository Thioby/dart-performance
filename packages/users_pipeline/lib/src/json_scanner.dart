/// Byte-level JSON parser specialized for the users array:
/// reads `[ {...}, {...} ]` straight into [UserTable], without building a
/// `Map`/`List`/`String` tree. Unknown fields are skipped (validated syntactically),
/// so adding a field to the API breaks nothing.
///
/// This is the counterpart of `BodySeed` from the winning Rust entry and `_parseHead` from
/// the Dart submission: one pass, offsets instead of Strings.
library;

import 'dart:typed_data';

import 'columnar.dart';
import 'generator.dart' show countries;

class JsonFormatError extends FormatException {
  JsonFormatError(String message, int offset) : super(message, null, offset);
}

/// Parses JSON bytes into a columnar table.
UserTable parseUsersColumnar(Uint8List b) {
  final p = _Scanner(b);
  final t = UserTable(b, capacity: 1024);
  p.ws();
  p.expect(0x5b); // [
  p.ws();
  if (p.peek() == 0x5d) {
    p.pos++;
    return t;
  }
  while (true) {
    if (t.length == t.capacity) t.grow();
    p.parseUser(t, t.length);
    t.length++;
    p.ws();
    final c = p.next();
    if (c == 0x2c) {
      p.ws();
      continue;
    }
    if (c == 0x5d) break;
    throw JsonFormatError('expected , or ]', p.pos - 1);
  }
  return t;
}

// Key codes recognized by length and first byte (like HTTP headers).
const _kUnknown = 0;
const _kId = 1, _kUsername = 2, _kEmail = 3, _kFirst = 4, _kLast = 5;
const _kAge = 6, _kCountry = 7, _kCity = 8, _kActive = 9, _kPremium = 10;
const _kScore = 11, _kBalance = 12, _kCreated = 13, _kTags = 14, _kAddress = 15;

// Lookup table: country by its 2 ASCII letters -> index in `countries` (or -1).
final Int8List _countryLookup = () {
  final l = Int8List(26 * 26)..fillRange(0, 26 * 26, -1);
  for (var i = 0; i < countries.length; i++) {
    final c = countries[i];
    l[(c.codeUnitAt(0) - 65) * 26 + (c.codeUnitAt(1) - 65)] = i;
  }
  return l;
}();

class _Scanner {
  final Uint8List b;
  int pos = 0;
  _Scanner(this.b);

  int peek() => pos < b.length ? b[pos] : -1;
  int next() {
    if (pos >= b.length) throw JsonFormatError('unexpected end', pos);
    return b[pos++];
  }

  void expect(int c) {
    if (next() != c) {
      throw JsonFormatError('expected ${String.fromCharCode(c)}', pos - 1);
    }
  }

  void ws() {
    while (pos < b.length) {
      final c = b[pos];
      if (c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09) {
        pos++;
      } else {
        break;
      }
    }
  }

  /// Skips the body of a string (after the opening "). Returns the end offset
  /// (position of the closing "), with pos set past it.
  int skipStringBody() {
    while (true) {
      final c = next();
      if (c == 0x22) return pos - 1;
      if (c == 0x5c) {
        // escape: skip the next byte (\uXXXX has 4 hex digits, but skipping
        // \ and u is enough, hex never contains ")
        pos++;
      }
    }
  }

  /// Recognizes a key without creating a String.
  int keyCode(int start, int end) {
    final len = end - start;
    final f = b[start];
    switch (len) {
      case 2:
        return f == 0x69 && b[start + 1] == 0x64 ? _kId : _kUnknown; // id
      case 3:
        return f == 0x61 && _eq(start, 'age') ? _kAge : _kUnknown;
      case 4:
        if (f == 0x63 && _eq(start, 'city')) return _kCity;
        if (f == 0x74 && _eq(start, 'tags')) return _kTags;
        return _kUnknown;
      case 5:
        if (f == 0x65 && _eq(start, 'email')) return _kEmail;
        if (f == 0x73 && _eq(start, 'score')) return _kScore;
        return _kUnknown;
      case 7:
        if (f == 0x63 && _eq(start, 'country')) return _kCountry;
        if (f == 0x70 && _eq(start, 'premium')) return _kPremium;
        if (f == 0x62 && _eq(start, 'balance')) return _kBalance;
        if (f == 0x61 && _eq(start, 'address')) return _kAddress;
        return _kUnknown;
      case 8:
        if (f == 0x75 && _eq(start, 'username')) return _kUsername;
        if (f == 0x6c && _eq(start, 'lastName')) return _kLast;
        if (f == 0x69 && _eq(start, 'isActive')) return _kActive;
        return _kUnknown;
      case 9:
        if (f == 0x66 && _eq(start, 'firstName')) return _kFirst;
        if (f == 0x63 && _eq(start, 'createdAt')) return _kCreated;
        return _kUnknown;
      default:
        return _kUnknown;
    }
  }

  bool _eq(int start, String s) {
    for (var i = 0; i < s.length; i++) {
      if (b[start + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  void parseUser(UserTable t, int row) {
    expect(0x7b); // {
    ws();
    t.flags[row] = 0;
    t.tagCount[row] = 0;
    if (peek() == 0x7d) {
      pos++;
      return;
    }
    while (true) {
      expect(0x22);
      final ks = pos;
      final ke = skipStringBody();
      ws();
      expect(0x3a); // :
      ws();
      switch (keyCode(ks, ke)) {
        case _kId:
          t.id[row] = parseInt();
        case _kAge:
          t.age[row] = parseInt();
        case _kScore:
          t.score[row] = parseDouble();
        case _kBalance:
          t.balance[row] = parseDouble();
        case _kActive:
          if (parseBool()) t.flags[row] |= flagActive;
        case _kPremium:
          if (parseBool()) t.flags[row] |= flagPremium;
        case _kUsername:
          expect(0x22);
          t.usernameOff[row] = pos;
          t.usernameLen[row] = skipStringBody() - t.usernameOff[row];
        case _kEmail:
          expect(0x22);
          t.emailOff[row] = pos;
          t.emailLen[row] = skipStringBody() - t.emailOff[row];
        case _kFirst:
          expect(0x22);
          t.firstOff[row] = pos;
          t.firstLen[row] = skipStringBody() - t.firstOff[row];
        case _kLast:
          expect(0x22);
          t.lastOff[row] = pos;
          t.lastLen[row] = skipStringBody() - t.lastOff[row];
        case _kCity:
          expect(0x22);
          t.cityOff[row] = pos;
          t.cityLen[row] = skipStringBody() - t.cityOff[row];
        case _kCountry:
          expect(0x22);
          final s = pos;
          final e = skipStringBody();
          var idx = -1;
          if (e - s == 2) {
            final a = b[s] - 65, c = b[s + 1] - 65;
            if (a >= 0 && a < 26 && c >= 0 && c < 26) {
              idx = _countryLookup[a * 26 + c];
            }
          }
          if (idx < 0) throw JsonFormatError('unknown country', s);
          t.countryId[row] = idx;
        case _kCreated:
          expect(0x22);
          t.createdAtMs[row] = parseIsoDateMs();
          expect(0x22);
        case _kTags:
          t.tagCount[row] = skipArrayCount();
        default:
          skipValue();
      }
      ws();
      final c = next();
      if (c == 0x2c) {
        ws();
        continue;
      }
      if (c == 0x7d) return;
      throw JsonFormatError('expected , or }', pos - 1);
    }
  }

  int parseInt() {
    var neg = false;
    if (peek() == 0x2d) {
      neg = true;
      pos++;
    }
    var v = 0;
    var digits = 0;
    while (pos < b.length) {
      final d = b[pos] - 48;
      if (d < 0 || d > 9) break;
      v = v * 10 + d;
      pos++;
      digits++;
    }
    if (digits == 0) throw JsonFormatError('expected digit', pos);
    return neg ? -v : v;
  }

  static const _pow10 = [
    1.0,
    10.0,
    100.0,
    1e3,
    1e4,
    1e5,
    1e6,
    1e7,
    1e8,
    1e9,
    1e10,
    1e11,
    1e12,
    1e13,
    1e14,
    1e15
  ];

  double parseDouble() {
    final start = pos;
    var neg = false;
    if (peek() == 0x2d) {
      neg = true;
      pos++;
    }
    var mant = 0;
    var digits = 0;
    while (pos < b.length) {
      final d = b[pos] - 48;
      if (d < 0 || d > 9) break;
      mant = mant * 10 + d;
      pos++;
      digits++;
    }
    var frac = 0;
    if (peek() == 0x2e) {
      pos++;
      while (pos < b.length) {
        final d = b[pos] - 48;
        if (d < 0 || d > 9) break;
        mant = mant * 10 + d;
        pos++;
        frac++;
        digits++;
      }
    }
    if (digits == 0) throw JsonFormatError('expected number', pos);
    final c = peek();
    if (c == 0x65 || c == 0x45 || digits > 15) {
      // Exponent or too many digits for an exact int64*10^k: hand off to double.parse.
      while (pos < b.length) {
        final x = b[pos];
        if ((x >= 48 && x <= 57) ||
            x == 0x65 ||
            x == 0x45 ||
            x == 0x2b ||
            x == 0x2d ||
            x == 0x2e) {
          pos++;
        } else {
          break;
        }
      }
      return double.parse(String.fromCharCodes(b, start, pos));
    }
    final v = mant / _pow10[frac];
    return neg ? -v : v;
  }

  bool parseBool() {
    final c = next();
    if (c == 0x74) {
      // true
      if (_eq(pos, 'rue')) {
        pos += 3;
        return true;
      }
    } else if (c == 0x66) {
      if (_eq(pos, 'alse')) {
        pos += 4;
        return false;
      }
    }
    throw JsonFormatError('expected bool', pos - 1);
  }

  /// "2024-03-01T10:20:30.123Z" -> epoch ms. Only the ISO format with 'Z'
  /// (as written by `toIso8601String()` for UTC); other formats -> fallback.
  int parseIsoDateMs() {
    final start = pos;
    int d(int n) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        final x = b[pos++] - 48;
        if (x < 0 || x > 9) throw JsonFormatError('bad date', pos - 1);
        v = v * 10 + x;
      }
      return v;
    }

    final y = d(4);
    expect(0x2d);
    final m = d(2);
    expect(0x2d);
    final day = d(2);
    expect(0x54); // T
    final hh = d(2);
    expect(0x3a);
    final mm = d(2);
    expect(0x3a);
    final ss = d(2);
    var ms = 0;
    if (peek() == 0x2e) {
      pos++;
      ms = d(3);
      // microseconds (optional) — skip
      while (pos < b.length && b[pos] >= 48 && b[pos] <= 57) {
        pos++;
      }
    }
    if (peek() != 0x5a) {
      // not UTC 'Z' -> slow path
      final e = skipStringBody();
      pos = e; // rewind to the closing quote (the caller will do expect)
      return DateTime.parse(String.fromCharCodes(b, start, e))
          .millisecondsSinceEpoch;
    }
    pos++; // Z
    return _daysFromCivil(y, m, day) * 86400000 +
        hh * 3600000 +
        mm * 60000 +
        ss * 1000 +
        ms;
  }

  // Howard Hinnant, days_from_civil — without allocating a DateTime.
  static int _daysFromCivil(int y, int m, int d) {
    y -= m <= 2 ? 1 : 0;
    final era = (y >= 0 ? y : y - 399) ~/ 400;
    final yoe = y - era * 400;
    final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
    final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
    return era * 146097 + doe - 719468;
  }

  /// Skips an array, returns the element count (for tags).
  int skipArrayCount() {
    expect(0x5b);
    ws();
    if (peek() == 0x5d) {
      pos++;
      return 0;
    }
    var n = 0;
    while (true) {
      skipValue();
      n++;
      ws();
      final c = next();
      if (c == 0x2c) {
        ws();
        continue;
      }
      if (c == 0x5d) return n;
      throw JsonFormatError('expected , or ]', pos - 1);
    }
  }

  /// Skips any JSON value (validating bracket nesting).
  void skipValue() {
    final c = peek();
    switch (c) {
      case 0x22:
        pos++;
        skipStringBody();
      case 0x7b:
        pos++;
        ws();
        if (peek() == 0x7d) {
          pos++;
          return;
        }
        while (true) {
          expect(0x22);
          skipStringBody();
          ws();
          expect(0x3a);
          ws();
          skipValue();
          ws();
          final d = next();
          if (d == 0x2c) {
            ws();
            continue;
          }
          if (d == 0x7d) return;
          throw JsonFormatError('expected , or }', pos - 1);
        }
      case 0x5b:
        skipArrayCount();
      case 0x74:
      case 0x66:
        parseBool();
      case 0x6e:
        if (_eq(pos, 'null')) {
          pos += 4;
        } else {
          throw JsonFormatError('expected null', pos);
        }
      default:
        parseDouble();
    }
  }
}
