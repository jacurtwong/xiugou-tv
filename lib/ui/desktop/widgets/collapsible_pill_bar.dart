import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'filter_pill.dart';

/// 一个分类胶囊的描述（标签 + 是否选中 + 点击回调）。
class PillItem {
  const PillItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

/// 分类条：横向铺满、按窗口宽度自动换行；**默认最多 [collapsedRows] 行**（按截图口径 3 行），
/// 放不下的部分折叠，并在最后一行末尾放一个虚线胶囊「展开全部 N 个 / 收起」。
///
/// 为什么要自己算行：折叠后「展开」按钮必须落在**当前行末尾**（用户 2026-11-19 截图口径），
/// 光靠 `Wrap` 做不到——它不知道哪个子项会落到第几行。这里用 `TextPainter` 量每个胶囊的
/// 文字宽度（加上 `FilterPill` 的固定内边距）来模拟换行。
class CollapsiblePillBar extends StatefulWidget {
  const CollapsiblePillBar({
    super.key,
    required this.items,
    this.collapsedRows = 3,
    this.spacing = 8,
    this.runSpacing = 8,
  });

  final List<PillItem> items;
  final int collapsedRows;
  final double spacing;
  final double runSpacing;

  @override
  State<CollapsiblePillBar> createState() => _CollapsiblePillBarState();
}

class _CollapsiblePillBarState extends State<CollapsiblePillBar> {
  bool _expanded = false;

  /// `FilterPill` 的水平内边距（左右各 16）+ 两侧各 1px 边框。
  static const double _pillHorizontalPadding = 34;

  @override
  void didUpdateWidget(covariant CollapsiblePillBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换站点/换分类集合时收回两行，别把「展开」状态带过去。
    if (oldWidget.items.length != widget.items.length) {
      _expanded = false;
    }
  }

  double _pillWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(fontSize: AppType.body)),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    return painter.width + _pillHorizontalPadding;
  }

  /// 给 [count] 个胶囊按 [maxWidth] 换行，返回 (行数, 最后一行的已用宽度)。
  ({int rows, double lastRowUsed}) _flow(
    List<double> widths,
    int count,
    double maxWidth,
  ) {
    var rows = 1;
    var used = 0.0;
    for (var i = 0; i < count; i++) {
      final width = widths[i];
      final gap = used > 0 ? widget.spacing : 0.0;
      if (used + gap + width > maxWidth && used > 0) {
        rows++;
        used = width;
      } else {
        used += gap + width;
      }
    }
    return (rows: rows, lastRowUsed: used);
  }

  /// 折叠时最多显示几个胶囊（末行还要给「展开」胶囊留位置）。
  int _collapsedCount(List<double> widths, double maxWidth, double chipWidth) {
    final total = widget.items.length;
    var count = total;
    while (count > 0) {
      final layout = _flow(widths, count, maxWidth);
      if (layout.rows > widget.collapsedRows) {
        count--;
        continue;
      }
      // 末行放得下「展开」胶囊就到此为止；放不下就再少显示一个。
      final needGap = layout.lastRowUsed > 0 ? widget.spacing : 0.0;
      if (layout.lastRowUsed + needGap + chipWidth <= maxWidth) return count;
      count--;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final widths = [
          for (final item in widget.items) _pillWidth(context, item.label),
        ];
        final expandLabel = '展开全部 ${widget.items.length} 个';
        final chipWidth = math.max(
          _pillWidth(context, expandLabel),
          _pillWidth(context, '收起'),
        );

        var visible = widget.items.length;
        var collapsed = false;
        if (!_expanded && widget.items.isNotEmpty) {
          final fit = _flow(widths, widget.items.length, maxWidth);
          if (fit.rows > widget.collapsedRows) {
            visible = _collapsedCount(widths, maxWidth, chipWidth);
            collapsed = visible < widget.items.length;
          }
        }
        final shown = widget.items.take(visible).toList(growable: false);

        return Wrap(
          spacing: widget.spacing,
          runSpacing: widget.runSpacing,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final item in shown)
              FilterPill(
                label: item.label,
                isSelected: item.selected,
                onTap: item.onTap,
              ),
            if (collapsed)
              _ExpandChip(
                label: expandLabel,
                onTap: () => setState(() => _expanded = true),
              )
            else if (visible == widget.items.length && _expanded)
              _ExpandChip(
                label: '收起',
                onTap: () => setState(() => _expanded = false),
              ),
          ],
        );
      },
    );
  }
}

/// 虚线边框的「展开全部 / 收起」胶囊。
class _ExpandChip extends StatelessWidget {
  const _ExpandChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: palette.textSub.withValues(alpha: 0.45),
            radius: AppRadii.pill,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppType.body,
                    color: palette.textSub,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.expand_more_rounded,
                    size: 16, color: palette.textSub),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 4.0;
      const gap = 3.0;
      while (distance < metric.length) {
        final end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
