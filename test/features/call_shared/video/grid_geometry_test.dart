import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/call_shared/video/grid_geometry.dart";

void main() {
  group("computeGridDimensions", () {
    test("a single tile settles on a 1x1 grid regardless of room to spare",
        () {
      // Plenty of space to spread out, but there is only one tile: nothing
      // to shrink towards, the largest useful grid IS the smallest one.
      expect(
          computeGridDimensions(
              tileCount: 1, availableWidth: 1200, availableHeight: 800),
          (rows: 1, columns: 1));
    });

    test("shrinks by removing whichever axis keeps tiles closest to the "
        "target aspect ratio", () {
      // 5 tiles in a 1000x700 area. The largest grid that fits is 3
      // columns x 2 rows (8 x 240/320-based math), which has 6 slots for 5
      // tiles, one more than needed. Dropping a column gives tiles at
      // roughly 1.43:1 (496/346), only 0.07 off the 1.5 target; dropping a
      // row gives roughly 0.47:1 (328/700), over 1.0 off. Dropping the
      // column wins, but that would only leave 4 slots for 5 tiles, so the
      // drop is reverted and the grid stays at 3x2, six slots for five
      // tiles: as small as it can get while still holding everyone.
      expect(
          computeGridDimensions(
              tileCount: 5, availableWidth: 1000, availableHeight: 700),
          (rows: 2, columns: 3));
    });

    test("compact mode uses the smaller minimum tile size and a squarer "
        "target, fitting more tiles in the same area", () {
      const width = 800.0;
      const height = 480.0;
      // A full grid (320x240 minimum) only fits a 2x2 grid in this area.
      expect(
          computeGridDimensions(
              tileCount: 20, availableWidth: width, availableHeight: height),
          (rows: 2, columns: 2));
      // The same area in compact mode (160x120 minimum, used for a strip, a
      // sidebar rail or a phone-class stage) fits a much bigger 4x5 grid
      // instead: 800/160 columns by 480/120 rows, exactly 20 slots for 20
      // tiles, so the shrink loop never runs.
      expect(
          computeGridDimensions(
              tileCount: 20,
              availableWidth: width,
              availableHeight: height,
              compact: true),
          (rows: 4, columns: 5));
    });

    test("a resize sweep across a threshold does not oscillate when the "
        "previous dimensions are carried forward", () {
      // Pin rows to 1 with a shallow area and use enough tiles that the
      // aspect-ratio shrink loop never runs, isolating the column count so
      // this test is really only exercising the hysteresis seed.
      const height = 240.0;
      const tileCount = 10;

      // Computed with NO seed (as if every frame started from scratch, the
      // way a naive resize handler with no memory of the previous frame
      // would), 959px and 960px land on opposite sides of a single sharp
      // threshold: exactly the kind of 1px jitter a real window resize (or
      // even sub-pixel layout rounding) produces constantly.
      final noMemory959 = computeGridDimensions(
          tileCount: tileCount, availableWidth: 959, availableHeight: height);
      final noMemory960 = computeGridDimensions(
          tileCount: tileCount, availableWidth: 960, availableHeight: height);
      expect(noMemory959, (rows: 1, columns: 2));
      expect(noMemory960, (rows: 1, columns: 3));

      // Now simulate an actual resize handler: it always seeds the next
      // call with the dimensions the last call returned. Starting settled
      // at 2 columns (from being at 959px) and then jittering the width
      // back and forth across that same 959/960 boundary must NOT flip the
      // column count on every call the way the memoryless version does:
      // the seeded threshold for GROWING back to 3 columns sits a full
      // gridGap higher than 960, so alternating within that band holds
      // steady at 2.
      var dimensions = noMemory959;
      for (final width in [960.0, 959.0, 960.0, 959.0, 960.0]) {
        dimensions = computeGridDimensions(
            tileCount: tileCount,
            availableWidth: width,
            availableHeight: height,
            previousColumns: dimensions.columns,
            previousRows: dimensions.rows);
        expect(dimensions, (rows: 1, columns: 2),
            reason: "width=$width should hold at 2 columns, not flip to 3");
      }
    });

    test("zero tiles lay out on an empty grid", () {
      expect(
          computeGridDimensions(
              tileCount: 0, availableWidth: 800, availableHeight: 480),
          (rows: 0, columns: 0));
    });

    test("a negative tile count is treated the same as zero", () {
      expect(
          computeGridDimensions(
              tileCount: -3, availableWidth: 800, availableHeight: 480),
          (rows: 0, columns: 0));
    });

    test(
        "zero or negative available size never divides by zero, it falls "
        "back to a sane 1x1 grid", () {
      expect(
          computeGridDimensions(
              tileCount: 5, availableWidth: 0, availableHeight: 0),
          (rows: 1, columns: 1));
      expect(
          computeGridDimensions(
              tileCount: 5, availableWidth: -100, availableHeight: -50),
          (rows: 1, columns: 1));
    });
  });

  group("computeRowDistribution", () {
    test("7 tiles over 3 rows is 2-3-2, not 3-3-1", () {
      // Handing every leftover tile to the last row (the naive approach)
      // would produce 3-3-1: lopsided, and it reads as a grid that simply
      // ran out of tiles rather than a deliberate layout.
      expect(computeRowDistribution(7, 3), [2, 3, 2]);
    });

    test("13 tiles over 4 rows is 3-4-3-3, not 3-3-3-4", () {
      expect(computeRowDistribution(13, 4), [3, 4, 3, 3]);
    });

    test("a single tile is a single row of one", () {
      expect(computeRowDistribution(1, 1), [1]);
    });

    test("more rows than tiles never leaves a row empty: extra rows are "
        "just not used", () {
      expect(computeRowDistribution(2, 5), [1, 1]);
    });

    test("an even split needs no leftovers handed out at all", () {
      expect(computeRowDistribution(6, 3), [2, 2, 2]);
    });

    test("zero tiles or zero rows return an empty distribution rather than "
        "dividing by zero", () {
      expect(computeRowDistribution(0, 3), <int>[]);
      expect(computeRowDistribution(5, 0), <int>[]);
      expect(computeRowDistribution(0, 0), <int>[]);
    });

    test("a negative row count is treated the same as zero", () {
      expect(computeRowDistribution(5, -2), <int>[]);
    });
  });

  group("rowStartHalfColumn", () {
    test("a full row starts at half column 1: no centring needed", () {
      expect(rowStartHalfColumn(3, 3), 1);
    });

    test("a short row is centred on a half-column grid line", () {
      // 3 tile-columns wide, a row of 2: one tile column of empty space,
      // split evenly as half a column on each side, so the row starts one
      // half column in.
      expect(rowStartHalfColumn(2, 3), 2);
    });

    test("an odd leftover still lands on a real grid line, not a half "
        "pixel", () {
      // 4 tile-columns wide, a row of 3: an odd single tile-column of
      // empty space to split. The half-column grid absorbs that oddness as
      // one extra half column of padding instead of a fractional offset.
      expect(rowStartHalfColumn(3, 4), 2);
    });

    test("tileColumnSpan is 2, so tile i of a row starts at "
        "rowStartHalfColumn + i * tileColumnSpan", () {
      const columns = 4;
      const rowTileCount = 3;
      final start = rowStartHalfColumn(rowTileCount, columns);
      final tileStarts = [
        for (var i = 0; i < rowTileCount; i++) start + i * tileColumnSpan
      ];
      expect(tileStarts, [2, 4, 6]);
      // The row's tiles plus its padding must exactly fill the grid's half
      // columns: the last tile's span should end exactly at the grid's
      // total half-column count.
      expect(tileStarts.last + tileColumnSpan - 1,
          lessThanOrEqualTo(getHalfColumnCountForTest(columns)));
    });
  });

  group("isCompactStage", () {
    test("a phone-class stage is compact: a 390pt phone hands the Spaces "
        "stage 358x383 and cannot hold a 2x2 of full-size tiles", () {
      expect(isCompactStage(358, 383), isTrue);
    });

    test("a narrow but TALL box is not compact: full-size tiles stack in it "
        "perfectly well", () {
      // The regression guard on the predicate. Keying it on width alone would
      // shrink the tiles in a portrait rail for nothing, and would flip the
      // grid's own portrait case (two people stacked) into two slivers side
      // by side.
      expect(isCompactStage(400, 800), isFalse);
    });

    test("a desktop stage is never compact", () {
      expect(isCompactStage(1368, 420), isFalse);
      expect(isCompactStage(800, 600), isFalse);
    });
  });

  group("preferredGridHeight", () {
    test("the height it asks for really does hold every tile when handed "
        "back to computeGridDimensions", () {
      // The contract between the two functions, and the property whose
      // absence was the phone bug: a stage sized 16:9 asked the geometry for
      // a shape it had no room to draw, and the rows past the first were laid
      // out below the box.
      for (final compact in [false, true]) {
        for (final width in [358.0, 500.0, 800.0, 1368.0]) {
          for (final n in [2, 3, 4, 5, 6, 9]) {
            final height = preferredGridHeight(
                tileCount: n, availableWidth: width, compact: compact);
            final dims = computeGridDimensions(
                tileCount: n,
                availableWidth: width,
                availableHeight: height,
                compact: compact);
            expect(dims.rows * dims.columns, greaterThanOrEqualTo(n),
                reason: "n=$n width=$width compact=$compact asked for "
                    "$height and got ${dims.rows}x${dims.columns}, which "
                    "cannot hold everyone");
          }
        }
      }
    });

    test("three people on a phone stage want a box far taller than 16:9 of "
        "the same width", () {
      // 358pt of width at 16:9 is 201pt. Three tiles want roughly 358pt, so
      // the 16:9 box was short by more than half the content: exactly the
      // two rows that went missing on Chef's phone.
      final wanted = preferredGridHeight(
          tileCount: 3, availableWidth: 358, compact: true);
      expect(wanted, greaterThan(358 * 9 / 16 * 1.5));
    });

    test("one tile, no tiles, or a degenerate width never returns a "
        "nonsense box", () {
      expect(preferredGridHeight(tileCount: 0, availableWidth: 800), 0);
      expect(preferredGridHeight(tileCount: -3, availableWidth: 800), 0);
      expect(preferredGridHeight(tileCount: 4, availableWidth: 0), 0);
      expect(preferredGridHeight(tileCount: 4, availableWidth: double.nan), 0);
      expect(preferredGridHeight(tileCount: 1, availableWidth: 800),
          greaterThan(0));
    });
  });
}

/// Test-only helper mirroring the grid's total half-column count, kept here
/// instead of in the production module since nothing else needs it: it is
/// only used above to sanity-check that a row's tiles never overrun the
/// grid.
int getHalfColumnCountForTest(int columns) => columns * tileColumnSpan;
