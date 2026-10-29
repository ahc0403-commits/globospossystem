import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unlike a logical widget rect, this also respects clipped scroll viewports.
Rect visiblePaintRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  var visible = MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
  RenderObject? ancestor = box.parent;
  while (ancestor != null) {
    if (ancestor is RenderBox &&
        (ancestor is RenderAbstractViewport ||
            ancestor is RenderClipRect ||
            ancestor is RenderClipRRect ||
            ancestor is RenderClipPath)) {
      visible = visible.intersect(
        MatrixUtils.transformRect(
          ancestor.getTransformTo(null),
          Offset.zero & ancestor.size,
        ),
      );
    }
    ancestor = ancestor.parent;
  }
  return visible;
}
