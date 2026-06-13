import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/spaces_directory_screen.dart";

SpaceSummary _summary({
  required String id,
  required String title,
  bool recording = false,
}) {
  return SpaceSummary(
    spaceId: id,
    title: title,
    hostFqid: "host@dk.skworld",
    status: "live",
    speakers: const ["host@dk.skworld"],
    recording: recording,
  );
}

Widget _wrap(List<SpaceSummary> spaces) {
  final router = GoRouter(
    initialLocation: "/spaces",
    routes: [
      GoRoute(
        path: "/spaces",
        builder: (context, state) => const SpacesDirectoryScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      spacesDirectoryProvider.overrideWith((ref) => Stream.value(spaces)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets("renders both live Space titles + a REC badge", (tester) async {
    await tester.pumpWidget(_wrap([
      _summary(id: "s1", title: "SKWorld Town Hall", recording: true),
      _summary(id: "s2", title: "Daily Standup"),
    ]));
    await tester.pump();

    expect(find.text("SKWorld Town Hall"), findsOneWidget);
    expect(find.text("Daily Standup"), findsOneWidget);
    // The recording Space shows a REC badge; both show LIVE.
    expect(find.text("REC"), findsOneWidget);
    expect(find.text("LIVE"), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, "Join"), findsNWidgets(2));
  });

  testWidgets("shows empty state when no Spaces are live", (tester) async {
    await tester.pumpWidget(_wrap(const []));
    await tester.pump();
    expect(find.text("No live Spaces"), findsOneWidget);
  });
}
