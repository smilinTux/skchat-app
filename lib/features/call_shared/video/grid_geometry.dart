/// Pure video grid geometry for call layouts.
///
/// This is a Dart port of Nextcloud Talk's `gridLayout.ts` (the grid used by
/// its CallView). Like `watch_drift.dart`, the whole "how many rows and
/// columns, and which tile goes where" decision lives here as plain
/// functions of plain numbers, with no Flutter, no `dart:ui`, and no widget
/// in sight, so the layout math can be unit tested exhaustively without a
/// widget tester and reused by any renderer that needs it. Widgets call this
/// module and paint what it returns; they do not make layout decisions of
/// their own.
library;

/// Gap between tiles, in logical pixels. Matches `--grid-gap` in Talk's
/// CallView stylesheet, which is where this port's constants are drawn from.
const double gridGap = 8;

/// Minimum tile size for a full grid, in logical pixels.
const double minTileWidth = 320;
const double minTileHeight = 240;

/// Minimum tile size for a "compact" grid: a strip or a sidebar rail, where
/// tiles are shown much smaller than in the main call view.
const double minTileWidthCompact = 200;
const double minTileHeightCompact = 150;

/// Target tile aspect ratio (width / height) for a full grid. Talk tunes the
/// shrink algorithm below towards this ratio because it is close to the
/// aspect ratio most webcams and shared screens actually produce, so tiles
/// end up looking like video rather than tall or wide letterboxed slabs.
const double targetAspectRatio = 1.5;

/// Target tile aspect ratio for a compact strip, where tiles are closer to
/// square so more of them fit across a narrow rail.
const double targetAspectRatioCompact = 1.0;

/// The resulting shape of a video grid.
typedef GridDimensions = ({int rows, int columns});

/// Number of tiles the maximum grid that fits [size] px along one axis can
/// hold, given a minimum tile size of [minSize] and the tile count the grid
/// currently has along that axis ([currentCount], 0 if there is no previous
/// layout to seed from).
///
/// This carries the hysteresis seed described on [computeGridDimensions]:
/// it first checks whether [currentCount] tiles, with the gaps that many
/// tiles actually have between them, still fit in [size]. Only when they no
/// longer do (or there was no previous count to check) does it fall back to
/// computing a fresh maximum from scratch. Checking the current count's own
/// fit first, rather than always recomputing from zero, is what keeps a
/// slow resize from flipping the tile count back and forth by a pixel or two
/// right at the boundary between two counts: the two computations use a
/// slightly different number of gaps (`currentCount - 1` for "does the
/// current layout still fit" versus `currentCount` for "could one more
/// tile fit"), which is enough slack to stop a resize from re-crossing the
/// same threshold on the next frame.
int _computeAxisMax(double size, double minSize, int currentCount) {
  final approxMax = ((size - gridGap * (currentCount - 1)) / minSize).floor();
  final hypotheticalMax = ((size - gridGap * currentCount) / minSize).floor();
  final axisMax = approxMax == currentCount ? approxMax : hypotheticalMax;
  // Always show at least one tile slot along the axis, even when the
  // available size is zero or negative (not yet measured, hidden, or a
  // caller passing bad input): a 1x1 grid is a sane fallback, a negative or
  // zero tile count along an axis is not.
  return axisMax < 1 ? 1 : axisMax;
}

/// Compute the number of rows and columns a grid of [tileCount] tiles should
/// use inside an area of [availableWidth] by [availableHeight] px.
///
/// The algorithm starts from the largest grid that fits the available space
/// (see [_computeAxisMax]), then shrinks it one row or column at a time,
/// each time removing whichever of the two keeps the resulting tile's
/// aspect ratio closest to the target for the mode ([targetAspectRatio] for
/// a full grid, [targetAspectRatioCompact] for [compact]), until the grid is
/// just big enough to hold every tile and no bigger.
///
/// [compact] switches both the minimum tile size and the target aspect
/// ratio: a strip or sidebar rail uses the smaller minimum
/// ([minTileWidthCompact] / [minTileHeightCompact]) so more, smaller tiles
/// fit, and a squarer target ([targetAspectRatioCompact]) because a strip is
/// usually narrow in one dimension, where a 1.5 target would force tiles
/// down to a single row too eagerly.
///
/// [previousRows] and [previousColumns] are the hysteresis seed: pass in the
/// grid's current dimensions (0 if there is none yet) and the result stays
/// on them when the available size is still within roughly one [gridGap] of
/// the threshold for the current tile count. Without this, dragging a
/// window's edge back and forth across that threshold makes the grid
/// reshuffle every frame, which is the kind of layout flicker users notice
/// immediately, far more than they notice a tile being a few pixels smaller
/// than the ideal minimum.
///
/// Returns `(rows: 0, columns: 0)` for [tileCount] <= 0: there is nothing to
/// lay out. A non-positive [availableWidth] or [availableHeight] never
/// divides by zero or goes negative; it falls back to a 1x1 grid via
/// [_computeAxisMax]'s floor of 1, same as a grid that has not been measured
/// yet.
GridDimensions computeGridDimensions({
  required int tileCount,
  required double availableWidth,
  required double availableHeight,
  bool compact = false,
  int previousRows = 0,
  int previousColumns = 0,
}) {
  if (tileCount <= 0) {
    return (rows: 0, columns: 0);
  }

  final minWidth = compact ? minTileWidthCompact : minTileWidth;
  final minHeight = compact ? minTileHeightCompact : minTileHeight;
  final target = compact ? targetAspectRatioCompact : targetAspectRatio;

  var columns = _computeAxisMax(availableWidth, minWidth, previousColumns);
  var rows = _computeAxisMax(availableHeight, minHeight, previousRows);

  // A single tile has nowhere smaller to shrink to.
  if (rows == 1 && columns == 1) {
    return (rows: rows, columns: columns);
  }

  var currentSlots = rows * columns;

  // Only shrink while there are more slots than tiles. If the tiles already
  // fill the grid exactly (or the grid can't even hold them all), there is
  // nothing to gain by shrinking further.
  while (tileCount < currentSlots) {
    final rowsBefore = rows;
    final columnsBefore = columns;

    // Current tile size.
    final tileWidth = (availableWidth - gridGap * (columns - 1)) / columns;
    final tileHeight = (availableHeight - gridGap * (rows - 1)) / rows;

    // Hypothetical tile size with one column, or one row, less.
    final widthOneColumnLess =
        (availableWidth - gridGap * (columns - 2)) / (columns - 1);
    final heightOneRowLess =
        (availableHeight - gridGap * (rows - 2)) / (rows - 1);

    // Hypothetical resulting aspect ratio for each option.
    final aspectOneColumnLess = widthOneColumnLess / tileHeight;
    final aspectOneRowLess = tileWidth / heightOneRowLess;

    final deltaColumnLess = (aspectOneColumnLess - target).abs();
    final deltaRowLess = (aspectOneRowLess - target).abs();

    if (deltaColumnLess <= deltaRowLess) {
      if (columns >= 2) columns--;
      currentSlots = rows * columns;
      if (tileCount > currentSlots) {
        // Removing that column left too few slots: put it back and stop.
        columns++;
        break;
      }
    } else {
      if (rows >= 2) rows--;
      currentSlots = rows * columns;
      if (tileCount > currentSlots) {
        rows++;
        break;
      }
    }

    // Neither axis could shrink (both already at their floor of 1): stop
    // instead of spinning forever.
    if (rowsBefore == rows && columnsBefore == columns) {
      break;
    }
  }

  return (rows: rows, columns: columns);
}

/// Number of tiles in each row of a grid of [rows] rows holding [tileCount]
/// tiles in total, from the first row to the last.
///
/// Tiles are spread as evenly as possible: every row gets
/// `tileCount ~/ rows` tiles, and the `tileCount % rows` leftover tiles are
/// handed out one at a time. The leftovers go from the second row downward,
/// the first row last, so a lopsided remainder does not pile up in whichever
/// row happens to be filled first. Handing every extra tile to the last row
/// (the naive approach) would lay 7 tiles over 3 rows out as 3-3-1; handing
/// them out from the second row down instead gives 2-3-2, which reads as a
/// deliberate, centred shape instead of a grid that ran out of tiles.
/// Likewise 13 tiles over 4 rows is 3-4-3-3, not 3-3-3-4.
///
/// If [rows] is greater than [tileCount], only [tileCount] rows are used
/// (one tile each); a grid never has more rows than it has tiles to put in
/// them. Returns an empty list for [tileCount] <= 0 or [rows] <= 0.
List<int> computeRowDistribution(int tileCount, int rows) {
  final usedRows = tileCount < rows ? tileCount : rows;
  if (usedRows <= 0) {
    return const [];
  }

  final base = tileCount ~/ usedRows;
  final remainder = tileCount % usedRows;

  final distribution = List<int>.filled(usedRows, base);
  for (var i = 0; i < remainder; i++) {
    final row = (i + 1) % usedRows;
    distribution[row] = base + 1;
  }
  return distribution;
}

/// Number of grid columns a single tile spans.
///
/// The grid is laid out in half columns rather than whole ones, purely so a
/// row that leaves an odd number of empty tile columns can be centred
/// exactly: starting it half a column further right lands it on a real grid
/// line, instead of a widget having to nudge it by half a pixel by hand. A
/// full tile always spans two of these half columns.
const int tileColumnSpan = 2;

/// The 1-based half column at which a row of [rowTileCount] tiles should
/// start so it sits centred in a grid that is [columns] tile columns wide.
///
/// A grid [columns] tiles wide has `columns * tileColumnSpan` half columns
/// in total (see [tileColumnSpan]). A row of [rowTileCount] tiles leaves
/// `columns - rowTileCount` tile columns empty; centring the row means
/// splitting that gap evenly on both sides. `columns - rowTileCount + 1` is
/// that split expressed directly as a 1-based half-column start: it holds
/// regardless of whether the empty gap is an even or an odd number of tile
/// columns, because the half-column grid absorbs the odd case as one extra
/// half column of padding rather than a fractional one.
///
/// A caller places the tiles of a row (as produced by
/// [computeRowDistribution]) starting at this half column, one tile every
/// [tileColumnSpan] half columns: tile `i` (0-based) of the row starts at
/// `rowStartHalfColumn(rowTileCount, columns) + i * tileColumnSpan`.
///
/// Worked example: a grid 3 tile-columns wide (6 half columns) with a row of
/// 2 tiles. `rowStartHalfColumn(2, 3)` is `3 - 2 + 1 = 2`: the row starts at
/// half column 2, leaving half column 1 as padding on the left and half
/// column 6 as padding on the right, with the two tiles occupying half
/// columns 2 to 3 and 4 to 5.
int rowStartHalfColumn(int rowTileCount, int columns) {
  return columns - rowTileCount + 1;
}
