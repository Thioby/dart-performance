/// Pobieranie danych: 🐢 `package:http` i `response.body` (String) vs
/// 🚀 `HttpClient` + `BytesBuilder(copy: false)` -> `Uint8List`.
///
/// Domyślny URL to surowy plik z tego repozytorium na GitHubie (odpowiednik
/// gista); można podać własny gist przez `--url`. Gdy sieć nie działa,
/// `loadLocal` czyta `packages/users_pipeline/data/users_10k.json`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const defaultUsersUrl =
    'https://raw.githubusercontent.com/Thioby/dart-performance/claude/dreamy-cerf-viyne8/packages/users_pipeline/data/users_10k.json';

/// 🐢 Tak robi większość kodu: `http.get` i `response.body`.
/// `body` dekoduje UTF-8 do Stringa (2 MB UTF-16 = 4 MB), mimo że zaraz
/// `jsonDecode` i tak przejdzie po każdym znaku.
Future<String> fetchBodyString(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return response.body;
}

/// 🚀 Strumień bajtów składany bez kopii per fragment; wynik `Uint8List`
/// idzie prosto do fused dekodera albo do parsera bajtowego.
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

/// `package:http` też potrafi oddać bajty — `bodyBytes` zamiast `body`.
/// Minimalna zmiana w istniejącym kodzie, która usuwa 4 MB Stringa.
Future<Uint8List> fetchBodyBytes(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return response.bodyBytes;
}

Uint8List loadLocal(String path) => File(path).readAsBytesSync();
