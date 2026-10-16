/// Wariant 🐢 "jak każdy": tak wygląda typowa warstwa danych w aplikacji
/// Flutter — i nie jest to zły kod. Jest po prostu napisany bez myślenia
/// o tym, co dzieje się na stercie.
library;

import 'dart:convert';

import 'model.dart';

/// `response.body` (String) -> jsonDecode -> `List<Map>` -> `List<User>`.
List<User> decodeSlow(String body) {
  final list = jsonDecode(body) as List<dynamic>;
  return list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
}

/// where/sort/take/map — idiomatyczne łańcuchy kolekcji.
PipelineResult querySlow(List<User> users, UserQuery q) {
  final matching = users
      .where((u) =>
          u.country == q.country &&
          u.isActive &&
          u.premium &&
          u.age >= q.minAge &&
          u.age <= q.maxAge &&
          u.score >= q.minScore &&
          u.createdAt.isAfter(q.createdAfter))
      .toList();
  matching.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  final top = matching.take(q.top).toList();
  final names = top.map((u) => u.fullName).toList();

  final perCountry = <String, int>{};
  for (final u in users) {
    if (u.isActive) perCountry[u.country] = (perCountry[u.country] ?? 0) + 1;
  }
  final sorted = Map.fromEntries(
      perCountry.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));

  final encoded = utf8.encode(jsonEncode(top.map((u) => u.toJson()).toList()));
  return PipelineResult(names, sorted, encoded);
}
