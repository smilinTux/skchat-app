// Tests for the global error sinks installed by lib/main.dart
// (installGlobalErrorSinks / _emitLifecycleError, card 7cebe96a: Obs P1.4).
//
// `flutter test` runs with Dart asserts enabled, i.e. it behaves like a
// debug build: there is no way to flip the real `kDebugMode` to exercise
// the release branch from inside a single run. `installGlobalErrorSinks`
// therefore takes an optional `debugMode` parameter (default `kDebugMode`)
// purely so tests can drive both branches directly, the exact pattern
// test/services/diag/diag_event_test.dart already uses for the same
// asserts-vs-release limitation.
//
// FlutterError.onError and PlatformDispatcher.instance.onError are global
// statics; every test captures whatever is installed beforehand and
// restores it in tearDown so this file cannot leak state into any other
// test in the suite.
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/main.dart';
import 'package:skchat/services/diag/diag_error_sink.dart';
import 'package:skchat/services/diag/diag_event.dart';

void main() {
  late FlutterExceptionHandler? originalFlutterOnError;
  late ErrorCallback? originalPlatformOnError;
  late DiagEventSink? originalDiagEventSink;

  setUp(() {
    originalFlutterOnError = FlutterError.onError;
    originalPlatformOnError = PlatformDispatcher.instance.onError;
    originalDiagEventSink = diagEventSink;
  });

  tearDown(() {
    FlutterError.onError = originalFlutterOnError;
    PlatformDispatcher.instance.onError = originalPlatformOnError;
    diagEventSink = originalDiagEventSink;
  });

  group('AC1: both handlers emit lifecycle.error, type name only', () {
    test('FlutterError.onError emits errorType as a runtimeType name', () {
      final captured = <DiagEvent>[];
      diagEventSink = captured.add;
      installGlobalErrorSinks();

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('do not let this text reach the event'),
        ),
      );

      expect(captured, hasLength(1));
      final event = captured.single;
      expect(event.code, 'lifecycle.error');
      expect(event.category, DiagCategory.lifecycle);
      expect(event.fields['errorType'], 'StateError');
      // No key in the catalog for lifecycle.error can carry the message
      // (diag_codes.dart declares only buildId/errorType), but assert the
      // intent directly too: the secret text must not appear ANYWHERE in
      // the event's field values.
      final allValues = event.fields.values.map((v) => v.toString()).join();
      expect(allValues.contains('do not let this text reach'), isFalse);
    });

    test(
      'PlatformDispatcher.onError emits errorType as a runtimeType name',
      () {
        final captured = <DiagEvent>[];
        diagEventSink = captured.add;
        installGlobalErrorSinks();

        PlatformDispatcher.instance.onError!(
          ArgumentError('do not let this leak either'),
          StackTrace.current,
        );

        expect(captured, hasLength(1));
        final event = captured.single;
        expect(event.code, 'lifecycle.error');
        expect(event.fields['errorType'], 'ArgumentError');
        final allValues = event.fields.values.map((v) => v.toString()).join();
        expect(allValues.contains('do not let this leak'), isFalse);
      },
    );
  });

  group('AC2: a throw inside the diag sink is fail-open', () {
    test(
      'FlutterError.onError: sink throwing does not propagate and does '
      'not suppress delegation to the previous handler',
      () {
        var previousCalled = false;
        FlutterError.onError = (details) => previousCalled = true;
        diagEventSink = (event) => throw StateError('sink is broken');

        installGlobalErrorSinks(debugMode: true);

        expect(
          () => FlutterError.onError!(
            FlutterErrorDetails(exception: Exception('boom')),
          ),
          returnsNormally,
        );
        expect(
          previousCalled,
          isTrue,
          reason:
              'the app\'s own error handling must still run even though '
              'the diag sink threw',
        );
      },
    );

    test(
      'PlatformDispatcher.onError: sink throwing does not propagate and '
      'does not suppress delegation to the previous handler',
      () {
        var previousCalled = false;
        PlatformDispatcher.instance.onError = (error, stack) {
          previousCalled = true;
          return true;
        };
        diagEventSink = (event) => throw StateError('sink is broken');

        installGlobalErrorSinks(debugMode: true);

        late bool result;
        expect(() {
          result = PlatformDispatcher.instance.onError!(
            Exception('boom'),
            StackTrace.current,
          );
        }, returnsNormally);
        expect(previousCalled, isTrue);
        expect(result, isTrue);
      },
    );
  });

  group('AC3: existing error behaviour is otherwise unchanged', () {
    test(
      'release (debugMode: false): FlutterError.onError still swallows, '
      'does not call the previous handler, still emits the event',
      () {
        var previousCalled = false;
        FlutterError.onError = (details) => previousCalled = true;
        final captured = <DiagEvent>[];
        diagEventSink = captured.add;

        installGlobalErrorSinks(debugMode: false);
        FlutterError.onError!(
          FlutterErrorDetails(exception: Exception('release boom')),
        );

        expect(
          previousCalled,
          isFalse,
          reason: 'release must stay quiet, same as before this sink existed',
        );
        expect(captured, hasLength(1));
      },
    );

    test(
      'release (debugMode: false): PlatformDispatcher.onError still '
      'reports handled, does not call the previous handler, still emits',
      () {
        var previousCalled = false;
        PlatformDispatcher.instance.onError = (error, stack) {
          previousCalled = true;
          return false;
        };
        final captured = <DiagEvent>[];
        diagEventSink = captured.add;

        installGlobalErrorSinks(debugMode: false);
        final result = PlatformDispatcher.instance.onError!(
          Exception('release boom'),
          StackTrace.current,
        );

        expect(previousCalled, isFalse);
        expect(result, isTrue);
        expect(captured, hasLength(1));
      },
    );

    test(
      'debug (debugMode: true): FlutterError.onError still delegates to '
      'the previous handler, same as before this sink existed',
      () {
        var previousCalled = false;
        FlutterError.onError = (details) => previousCalled = true;
        diagEventSink = null;

        installGlobalErrorSinks(debugMode: true);
        FlutterError.onError!(
          FlutterErrorDetails(exception: Exception('debug boom')),
        );

        expect(previousCalled, isTrue);
      },
    );

    test(
      'debug (debugMode: true): PlatformDispatcher.onError still '
      'delegates to, and returns, the previous handler\'s result',
      () {
        PlatformDispatcher.instance.onError = (error, stack) => false;
        diagEventSink = null;

        installGlobalErrorSinks(debugMode: true);
        final result = PlatformDispatcher.instance.onError!(
          Exception('debug boom'),
          StackTrace.current,
        );

        expect(result, isFalse);
      },
    );
  });

  group('no diag sink target wired up yet', () {
    test('a null diagEventSink does not throw', () {
      diagEventSink = null;
      installGlobalErrorSinks();

      expect(
        () => FlutterError.onError!(
          FlutterErrorDetails(exception: Exception('no sink yet')),
        ),
        returnsNormally,
      );
    });
  });
}
