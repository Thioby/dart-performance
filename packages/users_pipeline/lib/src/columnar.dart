/// Columnar representation of 10k users: instead of 100 000 objects —
/// a dozen or so typed lists. Strings are not decoded: we keep offsets into
/// the original JSON buffer and lazily decode only those the UI
/// actually needs (e.g. 100 last names out of 10 000).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'generator.dart' show countries;

/// Bit fields in [UserTable.flags].
const int flagActive = 1;
const int flagPremium = 2;

class UserTable {
  /// Original JSON bytes — the source for lazy string decoding.
  final Uint8List raw;

  int length = 0;
  Int32List id;
  Uint8List age;
  Uint8List countryId; // index into [countries]
  Uint8List flags; // flagActive | flagPremium
  Float64List score;
  Float64List balance;
  Int64List createdAtMs; // epoch ms (UTC)
  Uint8List tagCount;

  // Strings as (offset, length) into [raw]; the values are in JSON form
  // (with escapes), so they can be copied 1:1 into the output JSON.
  Int32List usernameOff, usernameLen;
  Int32List emailOff, emailLen;
  Int32List firstOff, firstLen;
  Int32List lastOff, lastLen;
  Int32List cityOff, cityLen;

  UserTable(this.raw, {int capacity = 1024})
      : id = Int32List(capacity),
        age = Uint8List(capacity),
        countryId = Uint8List(capacity),
        flags = Uint8List(capacity),
        score = Float64List(capacity),
        balance = Float64List(capacity),
        createdAtMs = Int64List(capacity),
        tagCount = Uint8List(capacity),
        usernameOff = Int32List(capacity),
        usernameLen = Int32List(capacity),
        emailOff = Int32List(capacity),
        emailLen = Int32List(capacity),
        firstOff = Int32List(capacity),
        firstLen = Int32List(capacity),
        lastOff = Int32List(capacity),
        lastLen = Int32List(capacity),
        cityOff = Int32List(capacity),
        cityLen = Int32List(capacity);

  int get capacity => id.length;

  /// New table sharing the columns with [this], but with a different [raw] buffer
  /// (used when the strings were rewritten into their own buffer).
  UserTable withRaw(Uint8List newRaw) {
    final n = UserTable(newRaw, capacity: 1)..length = length;
    n.id = id;
    n.age = age;
    n.countryId = countryId;
    n.flags = flags;
    n.score = score;
    n.balance = balance;
    n.createdAtMs = createdAtMs;
    n.tagCount = tagCount;
    n.usernameOff = usernameOff;
    n.usernameLen = usernameLen;
    n.emailOff = emailOff;
    n.emailLen = emailLen;
    n.firstOff = firstOff;
    n.firstLen = firstLen;
    n.lastOff = lastOff;
    n.lastLen = lastLen;
    n.cityOff = cityOff;
    n.cityLen = cityLen;
    return n;
  }

  /// Doubles the capacity of all columns (amortized O(1) per row).
  void grow() {
    final n = capacity * 2;
    Int32List g32(Int32List l) => Int32List(n)..setRange(0, l.length, l);
    Uint8List g8(Uint8List l) => Uint8List(n)..setRange(0, l.length, l);
    id = g32(id);
    age = g8(age);
    countryId = g8(countryId);
    flags = g8(flags);
    score = Float64List(n)..setRange(0, score.length, score);
    balance = Float64List(n)..setRange(0, balance.length, balance);
    createdAtMs = Int64List(n)..setRange(0, createdAtMs.length, createdAtMs);
    tagCount = g8(tagCount);
    usernameOff = g32(usernameOff);
    usernameLen = g32(usernameLen);
    emailOff = g32(emailOff);
    emailLen = g32(emailLen);
    firstOff = g32(firstOff);
    firstLen = g32(firstLen);
    lastOff = g32(lastOff);
    lastLen = g32(lastLen);
    cityOff = g32(cityOff);
    cityLen = g32(cityLen);
  }

  /// Decodes a string from raw JSON bytes (without quotes, with escapes).
  String _str(int off, int len) => decodeJsonString(raw, off, off + len);

  String username(int i) => _str(usernameOff[i], usernameLen[i]);
  String email(int i) => _str(emailOff[i], emailLen[i]);
  String firstName(int i) => _str(firstOff[i], firstLen[i]);
  String lastName(int i) => _str(lastOff[i], lastLen[i]);
  String city(int i) => _str(cityOff[i], cityLen[i]);
  String country(int i) => countries[countryId[i]];
  String fullName(int i) => '${firstName(i)} ${lastName(i)}';
  bool isActive(int i) => flags[i] & flagActive != 0;
  bool isPremium(int i) => flags[i] & flagPremium != 0;

  /// Packs the table into a list of buffers (for `TransferableTypedData.fromList`).
  /// The order is fixed; [unpack] restores it.
  List<Uint8List> pack() {
    final header = Int32List.fromList([length, raw.length]);
    Uint8List v(TypedData t) =>
        Uint8List.view(t.buffer, t.offsetInBytes, t.lengthInBytes);
    final n = length;
    return [
      v(header),
      raw,
      v(Int32List.sublistView(id, 0, n)),
      Uint8List.sublistView(age, 0, n),
      Uint8List.sublistView(countryId, 0, n),
      Uint8List.sublistView(flags, 0, n),
      v(Float64List.sublistView(score, 0, n)),
      v(Float64List.sublistView(balance, 0, n)),
      v(Int64List.sublistView(createdAtMs, 0, n)),
      Uint8List.sublistView(tagCount, 0, n),
      for (final l in [
        usernameOff,
        usernameLen,
        emailOff,
        emailLen,
        firstOff,
        firstLen,
        lastOff,
        lastLen,
        cityOff,
        cityLen,
      ])
        v(Int32List.sublistView(l, 0, n)),
    ];
  }

  /// Restores the table from a buffer materialized on the other side of the port.
  /// All columns are VIEWS over a single buffer — zero copying.
  static UserTable unpack(ByteBuffer buf) {
    var off = 0;
    int align(int a) => off = (off + a - 1) & ~(a - 1);
    final header = Int32List.view(buf, 0, 2);
    final n = header[0], rawLen = header[1];
    off = 8;
    final raw = Uint8List.view(buf, off, rawLen);
    off += rawLen;
    final t = UserTable(raw, capacity: n == 0 ? 1 : n)..length = n;
    Int32List i32() {
      align(4);
      final l = Int32List.view(buf, off, n);
      off += n * 4;
      return l;
    }

    Uint8List u8() {
      final l = Uint8List.view(buf, off, n);
      off += n;
      return l;
    }

    Float64List f64() {
      align(8);
      final l = Float64List.view(buf, off, n);
      off += n * 8;
      return l;
    }

    Int64List i64() {
      align(8);
      final l = Int64List.view(buf, off, n);
      off += n * 8;
      return l;
    }

    t.id = i32();
    t.age = u8();
    t.countryId = u8();
    t.flags = u8();
    t.score = f64();
    t.balance = f64();
    t.createdAtMs = i64();
    t.tagCount = u8();
    t.usernameOff = i32();
    t.usernameLen = i32();
    t.emailOff = i32();
    t.emailLen = i32();
    t.firstOff = i32();
    t.firstLen = i32();
    t.lastOff = i32();
    t.lastLen = i32();
    t.cityOff = i32();
    t.cityLen = i32();
    return t;
  }

  /// Joins [pack] into one contiguous buffer with alignment (for TransferableTypedData
  /// and for writing to disk).
  Uint8List packContiguous() {
    final parts = pack();
    // Alignments match the order in unpack(): raw then i32 (4), u8,
    // f64 (8), i64 (8), u8, 10 × i32 (4).
    const aligns = [1, 1, 4, 1, 1, 1, 8, 8, 8, 1, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4];
    var total = 0;
    for (var i = 0; i < parts.length; i++) {
      total = (total + aligns[i] - 1) & ~(aligns[i] - 1);
      total += parts[i].length;
    }
    final out = Uint8List(total);
    var off = 0;
    for (var i = 0; i < parts.length; i++) {
      off = (off + aligns[i] - 1) & ~(aligns[i] - 1);
      out.setRange(off, off + parts[i].length, parts[i]);
      off += parts[i].length;
    }
    return out;
  }
}

/// Decodes the content of a JSON string (between the quotes) from UTF-8 bytes.
/// Fast path: no `\` and no bytes >= 0x80 → `String.fromCharCodes`.
String decodeJsonString(Uint8List b, int start, int end) {
  var plainAscii = true;
  for (var i = start; i < end; i++) {
    final c = b[i];
    if (c == 0x5c || c >= 0x80) {
      plainAscii = false;
      break;
    }
  }
  if (plainAscii) return String.fromCharCodes(b, start, end);
  // General path: use the JSON decoder on a slice wrapped in quotes.
  final slice = Uint8List(end - start + 2);
  slice[0] = 0x22;
  slice.setRange(1, slice.length - 1, b, start);
  slice[slice.length - 1] = 0x22;
  return json.decode(utf8.decode(slice)) as String;
}
