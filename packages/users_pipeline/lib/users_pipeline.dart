/// Realistic "10k users from JSON" pipeline: fetch -> decode ->
/// filter/sort/group -> encode, in variants from idiomatic to
/// columnar zero-alloc. See this package's README.md.
library;

export 'src/bench.dart';
export 'src/columnar.dart';
export 'src/fetch.dart';
export 'src/generator.dart';
export 'src/json_scanner.dart';
export 'src/model.dart';
export 'src/pipeline_fast.dart';
export 'src/pipeline_slow.dart';
