/// Sekcja 2 przewodnika: Group Commit / batching w SQLite przez
/// `package:sqlite3` (FFI). Pokazuje, dlaczego 10 000 osobnych
/// auto-commitów trwa sekundy (każdy COMMIT = fsync WAL przy
/// synchronous=FULL, a przy NORMAL i tak pełny cykl pager/lock), a jedna
/// transakcja z prepared statement trwa milisekundy.
///
/// Warianty:
///  1. `db.execute('INSERT ... VALUES (?, ?)', [a, b])` per rekord, autocommit:
///     kompilacja SQL + bind + COMMIT na każdy wiersz.
///  2. Prepared statement, autocommit: bez kompilacji, nadal COMMIT per wiersz.
///  3. Prepared statement w jednej transakcji (BEGIN ... COMMIT): group commit.
///  4. Jak 3, ale w paczkach po 500 (kompromis latencja/przepustowość —
///     tak działa serwer: zbiera żądania z jednej iteracji pętli zdarzeń
///     i commituje raz).
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

/// Odczyt: `select()` buduje `ResultSet` (lista `List<Object?>` + `Row`
/// tworzony przy każdym dostępie), `selectCursor()` czyta wiersz po wierszu
/// (nadal `Row` + lista per wiersz), a `stmt.raw` (`RawPreparedStatement`,
/// sqlite3 >= 3.5) to bezpośrednie `sqlite3_step`/`sqlite3_column_int64`
/// bez żadnego obiektu na stercie Darta. `columnBlobInto` (>= 3.7) czyta
/// BLOB do reużywanego bufora zamiast alokować `Uint8List` per wartość.
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

/// Kolumna TEXT czytana jako String (utf8.decode per wiersz) ...
void _readTextAsString() {
  var n = 0;
  final raw = _selectAll.raw;
  while (raw.step()) {
    n += raw.columnText(2).length;
  }
  _selectAll.reset();
  blackHole(n);
}

/// ... vs `CAST(body AS BLOB)` + `columnBlobInto` do reużywanego bufora
/// (wzorzec z dart-rawsocket-C-Hatton: surowe bajty UTF-8 prosto do odpowiedzi).
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
  final write = Suite('sqlite/insert 10k wierszy (WAL, synchronous=NORMAL)',
      sampleMillis: 1, samples: 3)
    ..add('execute(sql, args) per wiersz, autocommit', _execPerRowAutocommit)
    ..add('prepared statement, autocommit per wiersz', _preparedAutocommit)
    ..add(
        'prepared + paczki po 100 (BEGIN/COMMIT)', () => _preparedBatches(100))
    ..add('prepared + paczki po 1000', () => _preparedBatches(1000))
    ..add(
        'prepared + jedna transakcja (group commit)', _preparedOneTransaction);

  final read = Suite('sqlite/select 10k wierszy', sampleMillis: 50, samples: 5)
    ..add('select() -> ResultSet (lista Row)', _readResultSet, setup: () {
      _preparedOneTransaction();
      _selectAll =
          _db.prepare('SELECT id, user_id, body FROM t', persistent: true);
    })
    ..add('selectCursor() wiersz po wierszu', _readCursor)
    ..add('stmt.raw: step() + columnInt64() (zero-alloc)', _readRaw);

  final text = Suite('sqlite/read 10k kolumn TEXT',
      sampleMillis: 50, samples: 5)
    ..add('raw.columnText() -> String per wiersz', _readTextAsString)
    ..add('CAST AS BLOB + raw.columnBlobInto(bufor) (zero-alloc)',
        _readTextAsBlobInto, setup: () {
      _selectBlob = _db.prepare('SELECT id, user_id, CAST(body AS BLOB) FROM t',
          persistent: true);
    });

  return [write, read, text];
}
