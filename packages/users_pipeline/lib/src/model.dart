/// Idiomatyczny model danych — tak wygląda 95 % aplikacji Dart/Flutter.
/// Każdy `User` to ~10 obiektów na stercie (sam obiekt, 6 Stringów, DateTime,
/// lista tagów, Address). 10 000 użytkowników = ~100 000 obiektów.
library;

class Address {
  final String street;
  final String zip;
  const Address({required this.street, required this.zip});

  factory Address.fromJson(Map<String, dynamic> j) =>
      Address(street: j['street'] as String, zip: j['zip'] as String);

  Map<String, dynamic> toJson() => {'street': street, 'zip': zip};
}

class User {
  final int id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final int age;
  final String country;
  final String city;
  final bool isActive;
  final bool premium;
  final double score;
  final double balance;
  final DateTime createdAt;
  final List<String> tags;
  final Address address;

  const User({
    required this.id,
    required this.username,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.age,
    required this.country,
    required this.city,
    required this.isActive,
    required this.premium,
    required this.score,
    required this.balance,
    required this.createdAt,
    required this.tags,
    required this.address,
  });

  String get fullName => '$firstName $lastName';

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        username: j['username'] as String,
        email: j['email'] as String,
        firstName: j['firstName'] as String,
        lastName: j['lastName'] as String,
        age: j['age'] as int,
        country: j['country'] as String,
        city: j['city'] as String,
        isActive: j['isActive'] as bool,
        premium: j['premium'] as bool,
        score: (j['score'] as num).toDouble(),
        balance: (j['balance'] as num).toDouble(),
        createdAt: DateTime.parse(j['createdAt'] as String),
        tags: (j['tags'] as List).cast<String>(),
        address: Address.fromJson(j['address'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'firstName': firstName,
        'lastName': lastName,
        'age': age,
        'country': country,
        'city': city,
        'isActive': isActive,
        'premium': premium,
        'score': score,
        'balance': balance,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'tags': tags,
        'address': address.toJson(),
      };
}

/// Parametry filtra używane przez wszystkie warianty.
class UserQuery {
  final String country;
  final int minAge;
  final int maxAge;
  final double minScore;
  final DateTime createdAfter;
  final int top;

  const UserQuery({
    this.country = 'PL',
    this.minAge = 25,
    this.maxAge = 45,
    this.minScore = 40.0,
    required this.createdAfter,
    this.top = 100,
  });

  static final UserQuery standard =
      UserQuery(createdAfter: DateTime.utc(2021, 1, 1));
}

/// Wynik pipeline'u — w tej samej postaci dla każdego wariantu, żeby test
/// mógł sprawdzić, że wszystkie liczą to samo.
class PipelineResult {
  /// Pełne imiona top N dopasowanych użytkowników (score malejąco, przy
  /// równym score — id rosnąco).
  final List<String> topNames;

  /// Liczba aktywnych użytkowników per kraj (posortowana po kodzie kraju).
  final Map<String, int> activePerCountry;

  /// Zakodowana odpowiedź (top N jako JSON).
  final List<int> encoded;

  const PipelineResult(this.topNames, this.activePerCountry, this.encoded);
}
