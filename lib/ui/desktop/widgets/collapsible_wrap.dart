import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 按宽度自动换行的标签组，**默认最多显示 [collapsedRows] 行**，超出时给出「展开全部 / 收起」。
///
/// 背景（用户 2026-11-19 口径）：站点分类常有几十个，全展开会把首页海报区挤走；
/// 但只给一行横向滚动又看不全。默认两行 + 折叠开关是折中。
///
/// 溢出判定做法：把 `Wrap` 放进 `OverflowBox(maxHeight: ∞)`，让它按真实高度布局，
/// 再用 key 读它的实际高度和「两行限制」比较——比自己按文字宽度估行数可靠。
class CollapsibleWrap extends StatefulWidget {
  const CollapsibleWrap({
    super.key,
    required this.children,
    this.spacing = 8,
    this.runSpacing = 8,
    this.collapsedRows = 2,
    this.rowHeight = 34,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;
  final int collapsedRows;

  /// 单行高度（按标签按钮的固定高度算，用于算两行的上限）。
  final double rowHeight;

  @override
  State<CollapsibleWrap> createState() => _CollapsibleWrapState();
}

class _CollapsibleWrapState extends State<CollapsibleWrap> {
  final GlobalKey _wrapKey = GlobalKey();
  bool _expanded = false;
  bool _overflow = false;

  double get _collapsedHeight =>
      widget.rowHeight * widget.collapsedRows +
      widget.runSpacing * (widget.collapsedRows - 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant CollapsibleWrap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.children.length != widget.children.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  void _measure() {
    if (!mounted) return;
    final size = _wrapKey.currentContext?.size;
    if (size == null) return;
    final overflow = size.height > _collapsedHeight + 0.5;
    if (overflow != _overflow) {
      setState(() => _overflow = overflow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wrap = Wrap(
          key: _wrapKey,
          spacing: widget.spacing,
          runSpacing: widget.runSpacing,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: widget.children,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_expanded && _overflow)
              // 折叠：固定两行高度并裁掉溢出部分；OverflowBox 让 Wrap 仍按真实高度排版，
              // 这样才能量到「总共需要几行」。
              ClipRect(
                child: SizedBox(
                  height: _collapsedHeight,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxHeight: double.infinity,
                    maxWidth: constraints.maxWidth,
                    child: SizedBox(width: constraints.maxWidth, child: wrap),
                  ),
                ),
              )
            else
              SizedBox(width: constraints.maxWidth, child: wrap),
            if (_overflow)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextButton.icon(
                  key: const ValueKey('category-expand-toggle'),
                  onPressed: () {
                    setState(() => _expanded = !_expanded);
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _measure());
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: palette.textSub,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                  ),
                  label: Text(
                    _expanded ? '收起' : '展开全部（${widget.children.length}）',
                    style: const TextStyle(fontSize: AppType.caption),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}