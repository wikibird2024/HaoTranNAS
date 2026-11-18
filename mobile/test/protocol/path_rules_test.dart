// Checks pathProblem against protocol/vectors/path_rules.json (spec §10).
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/protocol/path_rules.dart';

import 'vector_files.dart';

const expectedPathCount = 20;

void main() {
  final paths = [
    for (final entry in loadVectorFile('path_rules.json')['paths'] as List)
      entry as Map<String, dynamic>,
  ];

  test('vector count: $expectedPathCount paths', () {
    expect(paths, hasLength(expectedPathCount));
  });

  for (final entry in paths) {
    final path = entry['path'] as String;
    final isValid = entry['valid'] as bool;
    final shownPath = path.length > 40
        ? '${path.substring(0, 20)}…(${path.length} chars)'
        : path;
    test('${isValid ? 'valid' : 'invalid'}: ${entry['why']} '
        '[${Uri.encodeComponent(shownPath)}]', () {
      final problem = pathProblem(path);
      if (isValid) {
        expect(problem, isNull);
      } else {
        expect(problem, isNotNull);
      }
    });
  }

  test('a lone surrogate is not a valid path', () {
    expect(pathProblem('a\uD800b'), isNotNull);
  });

  test('a 4-byte emoji counts as 4 bytes toward the 255-byte part limit', () {
    expect(pathProblem('📷' * 63), isNull); // 252 bytes
    expect(pathProblem('📷' * 64), isNotNull); // 256 bytes
  });
}
