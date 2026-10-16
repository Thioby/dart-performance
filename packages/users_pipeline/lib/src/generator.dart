/// Deterministic test data generator (same seed = same bytes), so that the
/// benchmark is repeatable and the `data/users_10k.json` file can be
/// regenerated. The data is "ugly" like real data: non-ASCII characters in names,
/// escaped quotes in street names, varying tag lengths, numbers with
/// fractions.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const countries = [
  'PL',
  'DE',
  'FR',
  'ES',
  'IT',
  'GB',
  'US',
  'CA',
  'BR',
  'MX',
  'JP',
  'KR',
  'IN',
  'AU',
  'NL',
  'SE',
  'NO',
  'FI',
  'CZ',
  'SK',
  'UA',
  'PT',
  'IE',
  'CH',
];

const _firstNames = [
  'Anna',
  'Jan',
  'Łukasz',
  'Zoë',
  'José',
  'Müller',
  'Olga',
  'Piotr',
  'Marta',
  'Kenji',
  'Aisha',
  'Liam',
  'Noah',
  'Emma',
  'Søren',
  'Chloé',
  'Ivan',
  'Nadia',
  'Mateusz',
  'Katarzyna',
  'Tomás',
  'Ingrid',
  'Yuki',
  'Omar',
];
const _lastNames = [
  'Kowalski',
  'Nowak',
  'Schmidt',
  'García',
  'Rossi',
  'Smith',
  'Silva',
  'Tanaka',
  'Kim',
  'Patel',
  'Jansen',
  'Andersson',
  'Novák',
  'Horváth',
  'O\'Brien',
  'Dubois',
  'Wiśniewski',
  'Zieliński',
  'Fischer',
  'Costa',
];
const _cities = [
  'Warszawa',
  'Kraków',
  'Berlin',
  'Paris',
  'Madrid',
  'Roma',
  'London',
  'New York',
  'São Paulo',
  'Tokyo',
  'Seoul',
  'Mumbai',
  'Sydney',
  'Amsterdam',
  'Oslo',
  'Helsinki',
  'Praha',
  'Bratislava',
  'Kyiv',
  'Lisboa',
  'Dublin',
];
const _streets = [
  'Main St', 'Długa', 'Hauptstraße', 'Rue de la Paix', 'Gran Vía', 'Via Roma',
  'Baker "B" Street', // escaped quote in JSON
  'Rua Augusta', 'Shibuya 1-chōme', 'Marszałkowska', 'Kungsgatan',
];
const _tags = [
  'admin',
  'beta',
  'vip',
  'trial',
  'eu',
  'mobile',
  'web',
  'newsletter',
  'referral',
  'churn-risk',
  'dev',
  'support',
];

/// Generates JSON `[ {user}, {user}, ... ]` as UTF-8 bytes.
Uint8List generateUsersJson(int count, {int seed = 42}) {
  final rnd = Random(seed);
  final out = <Map<String, Object?>>[];
  for (var i = 1; i <= count; i++) {
    final first = _firstNames[rnd.nextInt(_firstNames.length)];
    final last = _lastNames[rnd.nextInt(_lastNames.length)];
    final country = countries[rnd.nextInt(countries.length)];
    final created = DateTime.utc(
        2018 + rnd.nextInt(8),
        1 + rnd.nextInt(12),
        1 + rnd.nextInt(28),
        rnd.nextInt(24),
        rnd.nextInt(60),
        rnd.nextInt(60),
        rnd.nextInt(1000));
    final tagCount = rnd.nextInt(5);
    final tags = <String>{};
    while (tags.length < tagCount) {
      tags.add(_tags[rnd.nextInt(_tags.length)]);
    }
    out.add({
      'id': i,
      'username': '${first.toLowerCase()}_$i',
      'email': '${first.toLowerCase()}.${last.toLowerCase()}$i@example.com',
      'firstName': first,
      'lastName': last,
      'age': 18 + rnd.nextInt(60),
      'country': country,
      'city': _cities[rnd.nextInt(_cities.length)],
      'isActive': rnd.nextInt(100) < 70,
      'premium': rnd.nextInt(100) < 30,
      'score': (rnd.nextDouble() * 100 * 10).roundToDouble() / 10,
      'balance': (rnd.nextDouble() * 10000 * 100).roundToDouble() / 100,
      'createdAt': created.toIso8601String(),
      'tags': tags.toList(),
      'address': {
        'street':
            '${_streets[rnd.nextInt(_streets.length)]} ${1 + rnd.nextInt(200)}',
        'zip': '${10000 + rnd.nextInt(89999)}',
      },
    });
  }
  return JsonUtf8Encoder().convert(out) as Uint8List;
}
