/// Realistyczny pipeline "10k użytkowników z JSON": fetch -> decode ->
/// filter/sort/group -> encode, w wariantach od idiomatycznego do
/// kolumnowego zero-alloc. Zobacz README.md tego pakietu.
library;

export 'src/bench.dart';
export 'src/columnar.dart';
export 'src/fetch.dart';
export 'src/generator.dart';
export 'src/json_scanner.dart';
export 'src/model.dart';
export 'src/pipeline_fast.dart';
export 'src/pipeline_slow.dart';
