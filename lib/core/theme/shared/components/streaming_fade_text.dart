import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/widgets.dart';
import 'package:lmstory/core/theme/shared/components/streaming_reveal_pacer.dart';
import 'package:lmstory/core/theme/shared/components/streaming_text_fade.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 新增段淡入的独立文本载体（R1 单源实现）
///
/// 把 [data] 用 [style] 渲染为 `Text.rich`；最近 350ms 留存窗口内的新增段
/// 用**颜色 alpha** 表达淡入（300ms 由透明推进到完全不透明，常量单源见
/// streaming_text_fade.dart），窗口外与历史文字零动画。语义对齐 chatbox
/// streaming-text-fade.ts：只认追加增长（替换/收缩不重放）；首观察只淡入
/// 尾部窗口；`MediaQuery.disableAnimations` 时降级直渲。
///
/// R（2026-09-10 复验修复）——布局中性是本实现的核心约束：
/// - 渲染树在「有淡入段」与「无淡入段」下结构一致（同一个 `Text.rich`、
///   同一份文本、只在段边界切 span），段落换行点与行高与纯文本逐字符
///   一致。此前用 `WidgetSpan` 原子盒承载动画时，不可断行的盒子会被整体
///   挤到下一行、到期又缩回上一行——观感即复验反馈的「文字位置/换行
///   在跳」与「尾行下方闪动半透明幽灵」。
/// - 盒预算（8）小于留存窗口内的段数（350ms ÷ 32ms 合帧 ≈ 11），超预算的
///   段整段直出不淡入 → 观感即「开头有淡入、后面一次蹦出好几个字」。
///   颜色 alpha 方案没有盒子也没有预算，两类现象一并消除。
/// - 段龄到期不再是「拆盒重组」，只是 span 边界回并（文字与样式均已
///   恒等）→ 回收瞬间零视觉变化。
/// - 代价：放弃 chatbox 的 2px 上浮（上浮需要逐段变换，只能靠占位盒或
///   逐字重排实现，与布局中性不可兼得）。chatbox 手感的主体是透明度
///   浮现，故取舍为上浮让位于换行稳定。
///
/// 帧驱动：只有存在未完成淡入时才驱动 ticker（帧回调触发 rebuild），
/// 流停顿期间也能把最后一段推进到不透明，不会留下半透明残影；全部完成
/// 即停，空闲期不占帧。淡入推进按帧时间戳计算（单调时钟，测试可用
/// `pump(duration)` 推进），不依赖墙钟。
///
/// 使用方（R1 单源，行为与动效参数零模式差异）：
/// - StreamingMarkdownBody 纯文本快速路径（三模式主正文）；
/// - chat 思考区展开文本（SimpleMessageBubble）；
/// - story 思考区展开文本（IntermediateMessageBubble）；
/// - 导演思考块展开文本（DirectorWorkGroup）与手动压缩流式区
///   （ContextUsageDetailSheet，story/导演共用）。
class StreamingFadeText extends StatefulWidget {
  const StreamingFadeText({
    required this.data,
    required this.style,
    this.pace = false,
    super.key,
  });

  /// 流式增长的累计文本（只追加；替换/收缩不淡入）。
  final String data;

  /// 渲染样式（调用方传各自的段落/思考款式——皮肤域参数，行为参数
  /// 不得模式私有调参）。
  final TextStyle style;

  /// 是否在本载体内部做平滑揭示配速（：由**流式调用方**
  /// 显式开启，直连本载体的思考区/压缩流式区传 true，R1）。
  ///
  /// 默认关闭：上游若已经配速（StreamingMarkdownBody 的尾块就是这种情况）
  /// 必须关闭——同一条链上配速两次会让揭示叠一层滞后。
  final bool pace;

  @override
  State<StreamingFadeText> createState() => _StreamingFadeTextState();
}

class _StreamingFadeTextState extends State<StreamingFadeText>
    with SingleTickerProviderStateMixin {
  final StreamingFadeSegmentTracker _tracker = StreamingFadeSegmentTracker();

  /// 平滑揭示配速：把已到达的文本按平滑速率放出，
  /// 消除「模型输出快 → 每 32ms 一整批字同时上屏」的蹦字感。
  final StreamingRevealPacer _pacer = StreamingRevealPacer();

  /// 上一帧时间戳（配速按帧推进；同一帧内多次 build 不重复推进）。
  Duration? _lastAdvanceStamp;

  /// 淡入未完成或揭示未完成期间的帧驱动（见类文档「帧驱动」）。
  late final Ticker _driver;

  @override
  void initState() {
    super.initState();
    _driver = createTicker(_onDriverTick);
  }

  @override
  void dispose() {
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.data;
    final base = widget.style.color ??
        DefaultTextStyle.of(context).style.color ??
        context.lm.palette.ink;
    final style = widget.style.copyWith(color: base);
    if (LmMotion.reducedMotion(context)) {
      // 无障碍降级：既不淡入也不配速，文本即时全量呈现。
      _pacer.snapTo(full.length);
      _syncDriver(hasPending: false);
      return Text(full, style: style);
    }
    if (!widget.pace) {
      // 上游已配速：本载体只做淡入，不再叠加一层揭示滞后。
      _pacer.snapTo(full.length);
    }
    _advanceReveal();
    final revealed =
        _pacer.revealed > full.length ? full.length : _pacer.revealed;
    final data = revealed >= full.length ? full : full.substring(0, revealed);
    final now = DateTime.fromMicrosecondsSinceEpoch(
      SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds,
    );
    _tracker.update(data, now);
    final segments = _tracker.segments;
    _syncDriver(
      hasPending: revealed < full.length ||
          segments.any((s) => streamingFadeProgress(s, now) < 1),
    );

    if (segments.isEmpty) {
      return Text.rich(TextSpan(text: data), style: style);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final segment in segments) {
      final start = segment.start < cursor ? cursor : segment.start;
      if (start > cursor) {
        spans.add(TextSpan(text: data.substring(cursor, start)));
      }
      final text = data.substring(start, segment.end);
      final progress = streamingFadeProgress(segment, now);
      // progress 达 1 时发普通 span（与静态文字完全同构）——淡入结束到
      // 段龄回收之间因此没有任何可感知变化。
      spans.add(
        progress >= 1
            ? TextSpan(text: text)
            : TextSpan(
                text: text,
                style: style.copyWith(
                  color: base.withValues(alpha: base.a * progress),
                ),
              ),
      );
      cursor = segment.end;
    }
    if (cursor < data.length) {
      spans.add(TextSpan(text: data.substring(cursor)));
    }
    return Text.rich(TextSpan(children: spans), style: style);
  }

  /// 按帧推进揭示进度（同一帧内多次 build 不重复推进）。
  void _advanceReveal() {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (now == _lastAdvanceStamp) {
      return;
    }
    final dt =
        _lastAdvanceStamp == null ? Duration.zero : now - _lastAdvanceStamp!;
    _lastAdvanceStamp = now;
    _pacer.advance(widget.data, dt);
  }

  /// 只在有未完成淡入或未揭示完的文本时驱动帧；全部完成即停
  /// （空闲期零帧开销）。
  void _syncDriver({required bool hasPending}) {
    if (hasPending) {
      if (!_driver.isActive) {
        _driver.start();
      }
      return;
    }
    if (_driver.isActive) {
      _driver.stop();
    }
  }

  void _onDriverTick(Duration _) {
    if (mounted) {
      setState(() {});
    }
  }
}
