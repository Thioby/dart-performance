/// Guide section 2: Group Commit / batching in SQLite via
/// `package:sqlite3` (FFI). Shows why 10,000 separate auto-commits take
/// seconds (every COMMIT = a WAL fsync at synchronous=FULL, and at NORMAL
/// still a full pager/lock cycle), while a single transaction with a
/// prepared statement takes milliseconds.
///
/// Variants:
///  1. `db.execute('INSERT ... VALUES (?, ?)', [a, b])` per record, autocommit:
///     SQL compilation + bind + COMMIT for every row.
///  2. Prepared statement, autocommit: no compilation, still a COMMIT per row.
///  3. Prepared statement in one transaction (BEGIN ... COMMIT): group commit.
///  4. Like 3, but in batches of 500 (a latency/throughput trade-off — this is
///     how the server works: it collects the requests from one event-loop
///     iteration and commits once).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../harness.dart';

const _rows = 10_000;
late Database _db;
late PreparedStatement _insert;
late String _path;

void setupSqlite() {
  _path = '${Directory.systemTemp.path}/dart_perf_bench_$pid.db';
  _db = sqlite3.open(_path, mutex: false);
  _db.execute('PRAGMA journal_mode = WAL');
  _db.execute('PRAGMA synchronous = NORMAL');
  _db.execute('PRAGMA temp_store = MEMORY');
  _db.execute('CREATE TABLE IF NOT EXISTS t ('
      'id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, body TEXT NOT NULL, '
      'created_at TEXT NOT NULL DEFAULT (strftime(\'%Y-%m-%dT%H:%M:%fZ\',\'now\')))');
  _insert = _db.prepare('INSERT INTO t (user_id, body) VALUES (?, ?)',
      persistent: true);
}

void teardownSqlite() {
  _insert.close();
  _selectAll.close();
  _selectBlob.close();
  _db.close();
  for (final suffix in ['', '-wal', '-shm']) {
    final f = File('$_path$suffix');
    if (f.existsSync()) f.deleteSync();
  }
}

void _reset() => _db.execute('DELETE FROM t');

void _execPerRowAutocommit() {
  _reset();
  for (var i = 0; i < _rows; i++) {
    _db.execute('INSERT INTO t (user_id, body) VALUES (?, ?)', [i, 'post $i']);
  }
}

void _preparedAutocommit() {
  _reset();
  for (var i = 0; i < _rows; i++) {
    _insert.execute([i, 'post $i']);
  }
}

void _preparedOneTransaction() {
  _reset();
  _db.execute('BEGIN');
  for (var i = 0; i < _rows; i++) {
    _insert.execute([i, 'post $i']);
  }
  _db.execute('COMMIT');
}

void _preparedBatches(int batch) {
  _reset();
  var i = 0;
  while (i < _rows) {
    _db.execute('BEGIN');
    final end = (i + batch).clamp(0, _rows);
    for (; i < end; i++) {
      _insert.execute([i, 'post $i']);
    }
    _db.execute('COMMIT');
  }
}

/// Reading: `select()` builds a `ResultSet` (a list of `List<Object?>` + a
/// `Row` created on every access), `selectCursor()` reads row by row (still a
/// `Row` + a list per row), and `stmt.raw` (`RawPreparedStatement`, sqlite3
/// >= 3.5) is direct `sqlite3_step`/`sqlite3_column_int64` with no object on
/// the Dart heap at all. `columnBlobInto` (>= 3.7) reads the BLOB into a
/// reused buffer instead of allocating a `Uint8List` per value.
late PreparedStatement _selectAll;
late PreparedStatement _selectBlob;
final Uint8List _blobScratch = Uint8List(4096);

void _readResultSet() {
  var s = 0;
  for (final row in _selectAll.select()) {
    s += row.columnAt(0) as int;
  }
  blackHole(s);
}

void _readCursor() {
  var s = 0;
  final cur = _selectAll.selectCursor();
  while (cur.moveNext()) {
    s += cur.current.columnAt(0) as int;
  }
  blackHole(s);
}

void _readRaw() {
  var s = 0;
  final raw = _selectAll.raw;
  while (raw.step()) {
    s += raw.columnInt64(0);
  }
  _selectAll.reset();
  blackHole(s);
}

/// The TEXT column read as a String (utf8.decode per row) ...
void _readTextAsString() {
  var n = 0;
  final raw = _selectAll.raw;
  while (raw.step()) {
    n += raw.columnText(2).length;
  }
  _selectAll.reset();
  blackHole(n);
}

/// ... vs `CAST(body AS BLOB)` + `columnBlobInto` into a reused buffer
/// (pattern from dart-rawsocket-C-Hatton: raw UTF-8 bytes straight into the
/// response).
void _readTextAsBlobInto() {
  var n = 0;
  final raw = _selectBlob.raw;
  while (raw.step()) {
    n += raw.columnBlobInto(2, _blobScratch);
  }
  _selectBlob.reset();
  blackHole(n);
}

List<Suite> suites() {
  final write = Suite('sqlite/insert 10k rows (WAL, synchronous=NORMAL)',
      sampleMillis: 1, samples: 3)
    ..add('execute(sql, args) per row, autocommit', _execPerRowAutocommit)
    ..add('prepared statement, autocommit per row', _preparedAutocommit)
    ..add(
        'prepared + batches of 100 (BEGIN/COMMIT)', () => _preparedBatches(100))
    ..add('prepared + batches of 1000', () => _preparedBatches(1000))
    ..add('prepared + one transaction (group commit)', _preparedOneTransaction);

  final read = Suite('sqlite/select 10k rows', sampleMillis: 50, samples: 5)
    ..add('select() -> ResultSet (list of Row)', _readResultSet, setup: () {
      _preparedOneTransaction();
      _selectAll =
          _db.prepare('SELECT id, user_id, body FROM t', persistent: true);
    })
    ..add('selectCursor() row by row', _readCursor)
    ..add('stmt.raw: step() + columnInt64() (zero-alloc)', _readRaw);

  final text = Suite('sqlite/read 10k TEXT columns',
      sampleMillis: 50, samples: 5)
    ..add('raw.columnText() -> String per row', _readTextAsString)
    ..add('CAST AS BLOB + raw.columnBlobInto(buffer) (zero-alloc)',
        _readTextAsBlobInto, setup: () {
      _selectBlob = _db.prepare('SELECT id, user_id, CAST(body AS BLOB) FROM t',
          persistent: true);
    });

  return [write, read, text];
}
