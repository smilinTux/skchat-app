import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/screen_awake.dart";

class FakeBackend implements ScreenAwakeBackend {
  final List<bool> calls = [];
  Object? throwOnNext;

  @override
  Future<void> toggle(bool enable) async {
    calls.add(enable);
    final t = throwOnNext;
    if (t != null) {
      throwOnNext = null;
      throw t;
    }
  }
}

void main() {
  late FakeBackend backend;
  late ScreenAwake awake;

  setUp(() {
    backend = FakeBackend();
    awake = ScreenAwake(backend: backend);
  });

  test("the first acquire turns the lock on", () async {
    await awake.acquire();
    expect(backend.calls, [true]);
    expect(awake.holders, 1);
  });

  test("the last release turns it off", () async {
    await awake.acquire();
    await awake.release();
    expect(backend.calls, [true, false]);
    expect(awake.holders, 0);
  });

  test("a second room does not re-toggle, and does not drop the lock when it "
      "leaves first", () async {
    // A 1:1 call can be answered from inside a Space. A plain boolean would
    // blank the screen the moment either one ended, while the other was still
    // running.
    await awake.acquire();
    await awake.acquire();
    expect(backend.calls, [true], reason: "no redundant second toggle");

    await awake.release();
    expect(backend.calls, [true],
        reason: "one room left, the other is still watching");
    expect(awake.holders, 1);

    await awake.release();
    expect(backend.calls, [true, false]);
  });

  test("an unbalanced release cannot poison the next acquire", () async {
    // A disconnect racing a manual leave runs teardown twice. If that drove
    // the count negative, the NEXT room could never get back to 1 and the
    // screen would silently stop staying awake, which looks exactly like the
    // feature not existing.
    await awake.release();
    await awake.release();
    expect(awake.holders, 0);
    expect(backend.calls, isEmpty);

    await awake.acquire();
    expect(backend.calls, [true]);
  });

  test("a refused lock never escapes to the caller", () async {
    // Browsers gate this on a secure context and can refuse outright; desktop
    // may have no implementation. Failing to keep a screen awake must not take
    // a call down with it.
    backend.throwOnNext = Exception("NotAllowedError");
    await awake.acquire();
    expect(awake.holders, 1);
  });

  test("a refused release still balances the count", () async {
    await awake.acquire();
    backend.throwOnNext = Exception("gone");
    await awake.release();

    expect(awake.holders, 0);
    // And the count being right is what lets the next room work normally.
    await awake.acquire();
    expect(backend.calls.last, isTrue);
  });
}
