import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/player/player_engine.dart';
import '../../../core/player/models/player_state.dart';
import '../../theme/app_tokens.dart';

/// 播放信息 OSD（`I` 键开关）：四角只读信息，不挡鼠标、不挡控制条。
///
/// 参照 KimBoxPC 的信息层布局：
/// - 左上：剧集标题 + 分辨率
/// - 右上：当前时间（到秒）
/// - 左下：播放进度 / 总时长（直播显示「直播」+ 已播时长）
/// - 右下：瞬时下载速度 + 缓冲秒数
///
/// 速度来自 mpv `cache-speed`，构建不支持时不显示这一段——宁可不显示也不编造。
class PlaybackInfoOsd extends StatefulWidget {
  const PlaybackInfoOsd({
    super.key,
    required this.engine,
    this.fallbackTitle,
  });

  final PlayerEngine engine;

  /// `MediaPlaySpec.title` 为空时的兜底标题（通常是播放器标签）。
  final String? fallbackTitle;

  @override
  State<PlaybackInfoOsd> createState() => _PlaybackInfoOsdState();
}

class _PlaybackInfoOsdState extends State<PlaybackInfoOsd> {
  Timer? _ticker;
  DateTime _now = DateTime.now();
  double? _speed;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      final speed = await widget.engine.readNetworkSpeed();
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
        _speed = speed;
      });
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.engine.currentSpec;
    final title = (spec?.title?.trim().isNotEmpty ?? false)
        ? spec!.title!.trim()
        : (widget.fallbackTitle?.trim() ?? '');
    final dimensions = widget.engine.dimensions;
    final position = widget.engine.position;
    final duration = widget.engine.duration;
    final buffer = widget.engine.buffer;
    final isLive = spec?.isLive ?? false;

    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildTopLeft(title, dimensions, isLive)),
                _text(_clock(_now), size: AppType.label),
              ],
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: _buildProgress(position, duration, isLive)),
                _buildRightMeta(buffer, isLive),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopLeft(String title, VideoDimensions dimensions, bool isLive) {
    final resolution = dimensions.width > 0 && dimensions.height > 0
        ? '${dimensions.width} × ${dimensions.height}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty) _text(title, size: AppType.label),
        if (resolution.isNotEmpty) ...[
          const SizedBox(height: 2),
          _text(resolution, size: AppType.body, dim: true),
        ],
      ],
    );
  }

  Widget _buildProgress(Duration position, Duration duration, bool isLive) {
    final text = isLive
        ? '直播 ${_shortClock(position)}'
        : '${_shortClock(position)} / ${_shortClock(duration)}';
    return Align(
      alignment: Alignment.bottomLeft,
      child: _text(text, size: AppType.label),
    );
  }

  Widget _buildRightMeta(Duration buffer, bool isLive) {
    final parts = <String>[];
    final speed = _speed;
    if (speed != null && speed > 0) parts.add(_speedText(speed));
    if (buffer > Duration.zero) {
      parts.add('缓冲 ${(buffer.inMilliseconds / 1000).toStringAsFixed(1)}s');
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return _text(parts.join('   '), size: AppType.body);
  }

  /// 视频画面上的文字：不铺底、只加投影，避免遮挡画面内容。
  Widget _text(String text, {required double size, bool dim = false}) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white.withValues(alpha: dim ? 0.78 : 1),
        fontSize: size,
        fontWeight: dim ? FontWeight.w400 : FontWeight.w500,
        height: 1.25,
        shadows: const [
          Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }

  static String _clock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String _shortClock(Duration value) {
    final total = value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static String _speedText(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }
}
