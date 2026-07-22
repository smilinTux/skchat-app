import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/safety_number.dart';

void main() {
  test('symmetric: order of the two fingerprints does not matter', () {
    expect(safetyNumber('aaa', 'bbb'), safetyNumber('bbb', 'aaa'));
    expect(safetyCompareCode('aaa', 'bbb'), safetyCompareCode('bbb', 'aaa'));
  });

  test('format: 60 digits in 12 space-separated groups of 5', () {
    final s = safetyNumber('aaa', 'bbb');
    final groups = s.split(' ');
    expect(groups.length, 12);
    expect(groups.every((g) => g.length == 5), isTrue);
    expect(s.replaceAll(' ', '').length, 60);
    expect(RegExp(r'^[0-9 ]+$').hasMatch(s), isTrue);
  });

  test('different fingerprints produce different numbers', () {
    expect(safetyNumber('aaa', 'bbb'), isNot(safetyNumber('aaa', 'ccc')));
  });

  test('compare code is 8 uppercase hex chars', () {
    expect(RegExp(r'^[0-9A-F]{8}$').hasMatch(safetyCompareCode('aaa', 'bbb')),
        isTrue);
  });

  test('the last four groups are not a copy of the first four (no wrap dup)',
      () {
    final groups = safetyNumber('aaa', 'bbb').split(' ');
    expect(groups.length, 12);
    // Old sha256+wrap made groups[8..11] == groups[0..3]; the fix must
    // break that.
    expect(groups.sublist(8, 12), isNot(groups.sublist(0, 4)));
  });
}
