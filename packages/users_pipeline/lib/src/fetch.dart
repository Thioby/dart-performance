/// Fetching data: 🐢 `package:http` and `response.body` (String) vs
/// 🚀 `HttpClient` + `BytesBuilder(copy: false)` -> `Uint8List`.
///
/// The default URL is a raw file from this repository on GitHub (the equivalent
/// of a gist); a custom gist can be passed via `--url`. When the network is down,
/// `loadLocal` reads `packages/users_pipeline/data/users_10k.json`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const defaultUsersUrl =
    'https://raw.githubusercontent.com/Thioby/dart-performance/claude/dreamy-cerf-viyne8/packages/users_pipeline/data/users_10k.json';

/// 🐢 This is what most code does: `http.get` and `response.body`.
/// `body` decodes UTF-8 into a String (2 MB UTF-16 = 4 MB), even though
/// `jsonDecode` is about to walk every character anyway.
Future<String> fetchBodyString(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return response.body;
}

/// 🚀 Byte stream assembled without a copy per chunk; the resulting `Uint8List`
/// goes straight to the fused decoder or to the byte parser.
Future<Uint8List> fetchBytes(Uri url, {HttpClient? client}) async {
  final c = client ?? HttpClient();
  try {
    final req = await c.getUrl(url);
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bb = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bb.add(chunk);
    }
    return bb.takeBytes();
  } finally {
    if (client == null) c.close();
  }
}

/// `package:http` can also return bytes — `bodyBytes` instead of `body`.
/// A minimal change to existing code that removes the 4 MB String.
Future<Uint8List> fetchBodyBytes(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return response.bodyBytes;
}

Uint8List loadLocal(String path) => File(path).readAsBytesSync();
