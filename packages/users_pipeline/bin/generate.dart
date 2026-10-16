/// Generates data/users_10k.json (deterministically, seed 42).
///   dart run bin/generate.dart [count] [out]
library;

import 'dart:io';

import 'package:users_pipeline/users_pipeline.dart';

void main(List<String> args) {
  final count = args.isNotEmpty ? int.parse(args[0]) : 10000;
  final out = args.length > 1 ? args[1] : 'data/users_${count ~/ 1000}k.json';
  final bytes = generateUsersJson(count);
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  stdout.writeln(
      'saved $out: $count users, ${(bytes.length / 1024).toStringAsFixed(0)} KB');
}
