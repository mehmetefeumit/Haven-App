import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';

/// Guards the committed dart-define template so a real Stadia key can never be
/// pasted into it by accident. `flutter test` runs with the package root
/// (`haven/`) as the working directory, so the relative path resolves.
void main() {
  group('dart_defines/secrets.example.json', () {
    final file = File('dart_defines/secrets.example.json');

    test('is committed and present', () {
      expect(
        file.existsSync(),
        isTrue,
        reason: 'the committed template must exist for the build docs to work',
      );
    });

    test('holds ONLY the placeholder key (no real key committed)', () {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['STADIA_API_KEY'], stadiaApiKeyPlaceholder);
    });

    test('contains no UUID-shaped token (Stadia keys are UUIDs)', () {
      final uuid = RegExp(
        '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        '[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      );
      expect(uuid.hasMatch(file.readAsStringSync()), isFalse);
    });
  });
}
