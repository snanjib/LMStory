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
///
/// 冻结窗口（2026-10-05）：超长文本的每帧 `Text.rich` 全文重排版
/// 是快速路径残余的 O(n) 地板（16k 码元 ≈ 8-13ms/帧，线性外推 64k 超出
/// 32ms 合帧预算）。本载体在淡入/配速语义之外追加**行对齐冻结前缀**：
/// 已越过淡入留存窗口的完整行按 [streamingFadeFreezeChunkCodeUnits] 粒度
/// 切成 `Text` 缓存实例（identical → Flutter 跳过整棵子树重建与重排版），
/// 每帧只对尾部活窗（冻结块余量 + 当前未完行 + 淡入留存窗）做活排版。
///
/// 视觉零变化的依据（与上面「布局中性」同一条红线）：
/// - 只在**硬换行行界**（`\n` 之后）切分——Paragraph 内每个硬行独立软换行、
///   行高只由样式决定，多个 `Text` 与单 `Text.rich` 的排版逐像素等价；
///   切分剥掉分隔 `\n` 本身（「abc\n」比「abc」多渲染一个空行），全文化整
///   为零后总行数恒等；
/// - **绝不在行中切**（会产生原全文不存在的换行机会）：无 `\n` 的单行
///   超长文不冻结，维持现状渲染（诚实退化路径）；边界 `\n` 前是 `\r`
///   （CRLF 被切开会产生裸 `\r` 块尾，与整文渲染不等价）时该处不切、
///   其后全部留活窗——纯 CRLF 文本自然全程不冻结；
/// - 冻结边界永不进入活跃淡入段（段龄 < 留存窗时 alpha 仍在变，冻结会
///   烙下半透明残影）——淡入段恒落在活窗内，per-span alpha 语义不变。
///
/// 失效（整体重建，对齐 StreamingMarkdownBody 的 `_reset` 语义）：数据
/// 替换/收缩（重生成、编辑）与样式变化（含主题色，TextStyle 值语义比对）。
/// 短文/无行界/reducedMotion 路径树形与冻结引入前完全一致（单 Text.rich）。
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

/// 冻结块的目标粒度（码元）。取 384 ≈ 短文段落一对（中文行 ~20-50 字 ×
/// 8-16 行）：太小则 Column 子件数随长度线性膨胀，太大则活窗排版下限抬
/// 高；64k 码元全文 ≈ 170 块，Column 常数开销可忽略。首块门槛即激活门槛
/// ——短于此的文本（绝大多数既有测试数据）树形与冻结引入前完全一致。
const int streamingFadeFreezeChunkCodeUnits = 384;

class _StreamingFadeTextState extends State<StreamingFadeText>
    with SingleTickerProviderStateMixin {
  final StreamingFadeSegmentTracker _tracker = StreamingFadeSegmentTracker();

  /// 平滑揭示配速：把已到达的文本按平滑速率放出，
  /// 消除「模型输出快 → 每 32ms 一整批字同时上屏」的蹦字感。
  final StreamingRevealPacer _pacer = StreamingRevealPacer();

  /// 上一帧时间戳（配速按帧推进；同一帧内多次 build 不重复推进）。
  Duration? _lastAdvanceStamp;

  /// 冻结前缀（冻结窗口）：已定稿的行组 Text 缓存实例与已覆盖
  /// 长度（data 坐标，行对齐、单调前进）。identical 实例让 Flutter 剪枝
  /// 整棵子树——这正是「只许变快」的来源。
  final List<Text> _frozenChunks = [];
  int _frozenEnd = 0;

  /// 冻结块所用样式（值语义比对；主题色/字号变化 → 冻结缓存整体失效）。
  TextStyle? _frozenStyle;

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
      // 无障碍降级：既不淡入也不配速（也不冻结），文本即时全量呈现。
      _pacer.snapTo(full.length);
      _syncDriver(hasPending: false);
      _resetFrozen();
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
    final updateKind = _tracker.update(data, now);
    final segments = _tracker.segments;
    _syncDriver(
      hasPending: revealed < full.length ||
          segments.any((s) => streamingFadeProgress(s, now) < 1),
    );

    // 冻结失效：替换/收缩（重生成、编辑）整体重建；样式变化同。样式含
    // 基色解析结果，主题切换在此被捕获；textScaler 变化经 MediaQuery
    // Inherited 依赖驱动冻结 Text 自身重建，不需显式失效。
    if (updateKind == StreamingFadeUpdateKind.replacement) {
      _resetFrozen();
    }
    if (_frozenStyle != style) {
      _resetFrozen();
      _frozenStyle = style;
    }

    // 冻结边界推进。safeOffset = 最老活跃淡入段起点（无段 = 全文）：
    // 冻结不得覆盖任何 alpha 仍在变的区间。
    var freezeTarget = 0;
    {
      final safeOffset = segments.isEmpty ? data.length : segments.first.start;
      if (safeOffset > 0 && safeOffset >= _frozenEnd) {
        // 最大行对齐前缀 ≤ safeOffset；且不给「结尾恰为 \n」的尾巴留空
        // 活窗——那会把末尾空行从渲染里吃掉（活窗至少含最后的内容行）。
        var bound = data.lastIndexOf('\n', safeOffset - 1) + 1;
        if (bound == data.length && bound > 0) {
          bound = data.lastIndexOf('\n', bound - 2) + 1;
        }
        freezeTarget = bound > _frozenEnd ? bound : _frozenEnd;
      } else if (safeOffset < _frozenEnd) {
        // 防御（append-only 下不可达）：回退重来，宁可冻结失效不渲染旧文。
        _resetFrozen();
      }
    }

    // 按目标粒度落块：边界取「≥ 冻结端 + 粒度」的最小行界；块文本不含
    // 边界分隔 \n（见类文档「视觉零变化的依据」）。边界前一个字符是 \r
    // （CRLF 被切开：块尾剩裸 \r，与整文渲染不等价）时停止冻结——其余
    // 部分留活窗按原样渲染，CRLF 文本自然全程不冻结。
    while (freezeTarget - _frozenEnd >= streamingFadeFreezeChunkCodeUnits) {
      final nl = data.indexOf(
        '\n',
        _frozenEnd + streamingFadeFreezeChunkCodeUnits - 1,
      );
      if (nl < 0 || nl + 1 > freezeTarget) break;
      if (nl > 0 && data.codeUnitAt(nl - 1) == 0x0D) break;
      _frozenChunks.add(Text(data.substring(_frozenEnd, nl), style: style));
      _frozenEnd = nl + 1;
    }

    final liveStart = _frozenEnd;
    final live = liveStart == 0 ? data : data.substring(liveStart);

    Widget liveWidget;
    if (segments.isEmpty) {
      liveWidget = Text.rich(TextSpan(text: live), style: style);
    } else {
      final spans = <InlineSpan>[];
      var cursor = 0;
      for (final segment in segments) {
        final start = segment.start < liveStart ? liveStart : segment.start;
        final localStart = start - liveStart;
        if (localStart > cursor) {
          spans.add(TextSpan(text: live.substring(cursor, localStart)));
        }
        final text = live.substring(localStart, segment.end - liveStart);
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
        cursor = segment.end - liveStart;
      }
      if (cursor < live.length) {
        spans.add(TextSpan(text: live.substring(cursor)));
      }
      liveWidget = Text.rich(TextSpan(children: spans), style: style);
    }

    if (_frozenChunks.isEmpty) {
      return liveWidget;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [..._frozenChunks, liveWidget],
    );
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

  void _resetFrozen() {
    _frozenChunks.clear();
    _frozenEnd = 0;
  }
}
