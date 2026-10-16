import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:users_pipeline/users_pipeline.dart';

void main() {
  final bytes = generateUsersJson(2000, seed: 7);

  test('generator is deterministic', () {
    expect(generateUsersJson(100, seed: 1),
        equals(generateUsersJson(100, seed: 1)));
    expect(generateUsersJson(100, seed: 1),
        isNot(equals(generateUsersJson(100, seed: 2))));
  });

  test('byte scanner reads the same fields as jsonDecode', () {
    final t = decodeColumnar(bytes);
    final list = jsonDecode(utf8.decode(bytes)) as List;
    expect(t.length, list.length);
    for (var i = 0; i < t.length; i++) {
      final m = list[i] as Map<String, dynamic>;
      expect(t.id[i], m['id']);
      expect(t.age[i], m['age']);
      expect(t.country(i), m['country']);
      expect(t.isActive(i), m['isActive']);
      expect(t.isPremium(i), m['premium']);
      expect(t.score[i], (m['score'] as num).toDouble());
      expect(t.balance[i], (m['balance'] as num).toDouble());
      expect(t.createdAtMs[i],
          DateTime.parse(m['createdAt'] as String).millisecondsSinceEpoch);
      expect(t.tagCount[i], (m['tags'] as List).length);
      expect(t.username(i), m['username']);
      expect(t.email(i), m['email']);
      expect(t.firstName(i), m['firstName']);
      expect(t.lastName(i), m['lastName']);
      expect(t.city(i), m['city']);
    }
  });

  test('all variants produce the same result', () {
    assertVariantsAgree(bytes);
    assertVariantsAgree(bytes,
        query: UserQuery(
            createdAfter: DateTime.utc(2019), country: 'DE', top: 10));
  });

  test('pack/unpack preserves data', () {
    final t = decodeColumnar(bytes);
    final u = UserTable.unpack(t.packContiguous().buffer);
    expect(u.length, t.length);
    for (var i = 0; i < t.length; i += 97) {
      expect(u.id[i], t.id[i]);
      expect(u.score[i], t.score[i]);
      expect(u.fullName(i), t.fullName(i));
    }
  });

  test('scanner skips unknown fields and handles escape/unicode', () {
    final json = utf8.encode(
        '[{"id":1,"extra":{"a":[1,2,{"b":null}],"c":"x\\"y"},"firstName":"Zo\\u00eb \\"Q\\"","lastName":"Łukasz",'
        '"username":"u","email":"e","age":30,"country":"PL","city":"c","isActive":true,"premium":false,'
        '"score":1.5e1,"balance":-2.25,"createdAt":"2024-02-29T23:59:59.999Z","tags":[],"address":{}}]');
    final t = decodeColumnar(Uint8List.fromList(json));
    expect(t.length, 1);
    expect(t.firstName(0), 'Zoë "Q"');
    expect(t.lastName(0), 'Łukasz');
    expect(t.score[0], 15.0);
    expect(t.balance[0], -2.25);
    expect(t.createdAtMs[0],
        DateTime.utc(2024, 2, 29, 23, 59, 59, 999).millisecondsSinceEpoch);
  });

  test('scanner rejects broken JSON', () {
    expect(() => decodeColumnar(Uint8List.fromList(utf8.encode('[{"id":1,}]'))),
        throwsFormatException);
    expect(() => decodeColumnar(Uint8List.fromList(utf8.encode('[{"id":1}'))),
        throwsFormatException);
  });
}
