import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/region.dart';

void main() {
  test('value equality by name (lets discovery dedupe replies)', () {
    expect(const Region('oki'), const Region('oki'));
    expect(const Region('oki').hashCode, const Region('oki').hashCode);
    expect(const Region('oki') == const Region('ked'), isFalse);
    final duplicates = [const Region('oki'), const Region('oki')];
    expect(duplicates.toSet().length, 1);
  });

  test('derives its 16-byte transport key', () {
    final key = const Region('oki').transportKey;
    expect(key, isNotNull);
    expect(key!.length, 16);
  });

  test('flags wildcard and private regions', () {
    expect(const Region('*').isWildcard, isTrue);
    expect(const Region(r'$secret').isPrivate, isTrue);
    expect(const Region('oki').isWildcard, isFalse);
    expect(const Region('oki').isPrivate, isFalse);
    expect(const Region(r'$secret').transportKey, isNull);
  });
}
