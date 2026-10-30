import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/widgets.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/shared/components/streaming_reveal_pacer.dart';
import 'package:lmstory/core/theme/shared/streaming_markdown_blocks.dart';

///  批2：冻结前缀流式 Markdown 渲染壳（三模式共享）
///
/// 每个 32ms 合帧 delta 到达时，流式气泡的累计全文重解析是长会话卡顿
/// 主源（基线实测占单帧成本 ~85%，且随正文长度线性恶化）。本组件把
/// 累计全文按 [markdownBlockStarts] 切块：除尾部 [unstableTailBlocks]
/// 块外全部「冻结」——每个冻结块只经 [blockBuilder] 构建一次，缓存
/// widget 实例直接复用（identical → Flutter 剪枝整棵子树）；每帧只
/// 重解析尾部未闭合窗口（O(尾块) 而非 O(全文)）。
///
/// 用法：流式中的气泡用本组件包裹该模式的 Markdown 组件作为
/// [blockBuilder]；流式结束后父级换回该模式的整文组件（一次终解析，
/// 由各模式自己的 memo 接管）。跨块的链接引用定义会失效（取舍见
/// streaming_markdown_blocks.dart 注释）。
///
/// 纯文本快速路径：叙事散文常无空行 → 全文一整块 →
/// 永远只有活跃块、切块冻结失效。此时若尾段经 `looksLikePlainText`
/// 判纯（无任何 Markdown 特征字符），改用 `Text` 直渲（样式经
/// [plainTextStyle] 传入，与模式 paragraph 款同源），消灭每 32ms 的
/// 全文 Markdown 重解析（O(n²) 主源）。详见 `_buildTail`。
///
/// [blockBuilder] 闭包每次 build 都是新实例（无法用 == 比较），影响
/// 渲染结果的输入（字体缩放/亮度等）须经 [cacheKey] 传入——变化时
/// 冻结缓存整体失效重建。
///
/// 参考：opencode markdown-stream / deepseek-harness IncrementalMarkdown
/// Parser 的「冻结前缀 + 尾部重解析」模式（本地克隆实读，见设计文档
///§二）。
class StreamingMarkdownBody extends StatefulWidget {
  const StreamingMarkdownBody({
    required this.data,
    required this.blockBuilder,
    required this.blockGap,
    this.cacheKey,
    this.unstableTailBlocks = 2,
    this.plainTextStyle,
    this.revealPacing = false,
    super.key,
  });

  /// 累计全文（流式增长，只追加）。非追加变化（编辑/重生成替换）会
  /// 整体失效重建。
  final String data;

  /// 把一段块文本渲染成该模式的 Markdown widget（chat 传
  /// SimpleMarkdownBody、故事/导演传 IntermediateMarkdownBody 的闭包）。
  final Widget Function(String segment) blockBuilder;

  /// 块间距：与各模式 stylesheet 的 blockSpacing 一致（分块渲染时段间
  /// 距由本组件承担，整文渲染时由 MarkdownBody 内部承担，两边视觉对齐）。
  final double blockGap;

  /// 渲染输入签名（字体缩放/亮度等会影响 blockBuilder 输出的值）。
  /// 变化时冻结缓存整体失效。
  final Object? cacheKey;

  /// 尾部不稳定窗口（除最后 N 块外全部冻结）。deepseek-harness 同款
  /// 保守值 2：末块仍在变化，倒数第二块可能因未闭合标记回卷。
  final int unstableTailBlocks;

  /// 纯文本快速路径的段落样式：取该模式
  /// MarkdownStyleSheet 的 paragraph 款（由三模式接线方传入，皮肤域
  /// 参数——行为参数不得模式私有调参）。null 时快速路径禁用（防御
  /// 默认，未接线的调用方行为与改造前完全一致）。
  final TextStyle? plainTextStyle;

  /// 平滑揭示配速：由**流式调用方**显式开启（三模式
  /// 主正文与各辅助流式面均已开启，R1）。默认关闭——本组件只负责「渲染
  /// 给定的文本」，是否需要把「已到达的文本」按平滑速率放出是流式显示
  /// 策略，不属于渲染职责；非流式用途（完成态/静态渲染）保持即时。
  /// 语义与常量见 streaming_reveal_pacer.dart。
  final bool revealPacing;

  @override
  State<StreamingMarkdownBody> createState() => _StreamingMarkdownBodyState();
}

class _StreamingMarkdownBodyState extends State<StreamingMarkdownBody>
    with SingleTickerProviderStateMixin {
  /// 已冻结块的起始偏移（与 [_frozenWidgets] 一一对应，append-only）
  final List<int> _frozenStarts = [];
  final List<Widget> _frozenWidgets = [];

  /// 切块扫描增量化（批2）：append 流式下每帧只扫新增行，
  /// 替换/收缩自动全量重建（见 MarkdownBlockStartsTracker）。
  final MarkdownBlockStartsTracker _startsTracker =
      MarkdownBlockStartsTracker();

  /// 判纯增量化（批2）：尾窗「是否全纯」按行缓存，失败行
  /// O(1) 短路（见 StreamingPlainTextGate）。
  final StreamingPlainTextGate _plainGate = StreamingPlainTextGate();

  /// 冻结前缀覆盖长度（= 最后一个冻结块结束偏移；0 = 无冻结）
  int _frozenPrefixEnd = 0;

  /// 上一帧**到达**的全文（替换/收缩判定依据，与揭示进度无关）。
  String _lastFull = '';
  Object? _lastCacheKey;

  /// 平滑揭示配速：把已到达的文本按平滑速率放出。
  /// 全部下游逻辑（切块/冻结边界/尾段/淡入）都以「已揭示文本」为输入，
  /// 因此冻结与淡入不会超前于显示，换行也不会成批跳动。
  final StreamingRevealPacer _pacer = StreamingRevealPacer();

  /// 揭示未完成期间的帧驱动。
  late final Ticker _revealDriver;
  Duration? _lastAdvanceStamp;

  @override
  void initState() {
    super.initState();
    _revealDriver = createTicker(_onRevealTick);
  }

  @override
  void dispose() {
    _revealDriver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.data;

    // 源文本替换/收缩（重生成、编辑）→ 整体失效并立即对齐揭示进度
    //（替换文本不是「正在写入」，不该逐帧放出）。
    final isSourceExtension =
        full.length >= _lastFull.length && full.startsWith(_lastFull);
    if (!isSourceExtension) {
      _reset();
      _pacer.snapTo(full.length);
    } else if (widget.cacheKey != _lastCacheKey) {
      _reset();
    }
    _lastCacheKey = widget.cacheKey;
    _lastFull = full;

    if (!widget.revealPacing) {
      // 未开启配速（默认/非流式用途）：立即到位，不做揭示滞后。
      _pacer.snapTo(full.length);
    }
    _advanceReveal();
    final revealed =
        _pacer.revealed > full.length ? full.length : _pacer.revealed;
    final data = revealed >= full.length ? full : full.substring(0, revealed);
    _syncRevealDriver(hasPending: revealed < full.length);
    if (data.isEmpty) {
      _reset();
      return const SizedBox.shrink();
    }

    final starts = _startsTracker.scan(data);
    final tailBlockCount = widget.unstableTailBlocks < starts.length
        ? widget.unstableTailBlocks
        : starts.length;
    // 冻结边界 = 倒数第 tailBlockCount 块的起始偏移（0 = 全部不稳定）
    final newPrefixEnd = starts.length > tailBlockCount
        ? starts[starts.length - tailBlockCount]
        : 0;

    // 追加语义下冻结边界单调不回退；防御性钳制（切分器规则变更时兜底）
    final targetEnd =
        newPrefixEnd < _frozenPrefixEnd ? _frozenPrefixEnd : newPrefixEnd;

    // 新冻结块：从上一个冻结块之后到 targetEnd 之间的完整块
    //（块 i 的结束 = 块 i+1 的起始；末块无后续偏移，恒属不稳定窗口）
    var i = 0;
    while (i + 1 < starts.length && starts[i + 1] <= targetEnd) {
      final start = starts[i];
      if (start >= _frozenPrefixEnd) {
        _frozenStarts.add(start);
        _frozenWidgets.add(
          KeyedSubtree(
            key: ValueKey('frozen-$start'),
            child: widget.blockBuilder(data.substring(start, starts[i + 1])),
          ),
        );
      }
      i++;
    }
    _frozenPrefixEnd = targetEnd;

    final tail = data.substring(_frozenPrefixEnd);
    // 尾窗块起点由全文 starts 推导（块起点处扫描器状态与尾串新起扫描
    // 等价：inFence/inMath 恒 false、延续判定不吃前文状态），消灭单块
    // 超长文的每帧二次全文扫描。防御回退：frozenPrefixEnd 不在 starts
    // 中（追加语义破坏，理论不可达）时按原路现扫。
    final tailStarts = _deriveTailStarts(starts, tail);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var b = 0; b < _frozenWidgets.length; b++) ...[
          if (b > 0) SizedBox(height: widget.blockGap),
          _frozenWidgets[b],
        ],
        if (_frozenWidgets.isNotEmpty) SizedBox(height: widget.blockGap),
        KeyedSubtree(
          key: const ValueKey('streaming-tail'),
          child: _buildTail(data, tail, tailStarts),
        ),
      ],
    );
  }

  /// 尾窗块起点（尾坐标，首元素恒 0）。frozenPrefixEnd ∈ starts 时由全文
  /// starts 偏移推导（与 markdownBlockStarts(tail) 恒等），否则回退现扫。
  List<int> _deriveTailStarts(List<int> starts, String tail) {
    final base = _frozenPrefixEnd;
    // starts 升序，二分找 base
    var lo = 0;
    var hi = starts.length;
    var idx = -1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] < base) {
        lo = mid + 1;
      } else if (starts[mid] > base) {
        hi = mid;
      } else {
        idx = mid;
        break;
      }
    }
    if (idx < 0) return markdownBlockStarts(tail);
    return [
      0,
      for (var k = idx + 1; k < starts.length; k++) starts[k] - base,
    ];
  }

  ///  纯文本快速路径 +  新增段淡入 + R2（2026-09-10 复验修复二）：
  /// **正在写入的尾块**只要无任何 Markdown 特征字符，就走 Text 快速路径
  /// （叙事散文单块 = 每 32ms Markdown 全文重解析的 O(n²) 主源）。
  ///
  /// 门槛曾经是「全文尚为一整段」（tailBlockCount == 1）。小说正文几乎必然
  /// 空行分段，于是**一次空行之后整个消息就永久失去快速路径与淡入**——复验
  /// 反馈的「开头有一点淡入、后面全在蹦字」即由此而来（思考块直连
  /// StreamingFadeText、不经此门槛，所以同一轮里思考块有改善而正文没有）。
  /// 现改为按**尾窗自身的块数**判定：
  /// - 尾窗单块：整段走快速路径（原行为，切换基准见同数据 Text vs
  ///   MarkdownBody 的高度/字号一致性用例）；
  /// - 尾窗多块：较早的块仍交 `blockBuilder`（已被空行终结、下一帧即冻结），
  ///   只有最后一个块——用户注视的「正在写入的段落」——走快速路径；块间
  ///   间距用同一 `blockGap`（与冻结块之间的间距同源）。
  ///
  /// 其余语义不变：尾随空白裁剪（Markdown 忽略尾随空行，Text 不裁剪会多出
  /// 空行高度）；特征字符一旦出现当帧切回 `blockBuilder`；`plainTextStyle`
  /// 为 null 时整段禁用。冻结块一律走 `blockBuilder`（历史块只构建一次）。
  /// 淡入为布局中性实现（R，无占位盒/无盒预算），无障碍
  /// （disableAnimations）与重生成替换不淡入。
  Widget _buildTail(String data, String tail, List<int> tailStarts) {
    final plainStyle = widget.plainTextStyle;
    if (plainStyle != null) {
      if (tailStarts.length <= 1) {
        final plainTail = tail.trim();
        if (plainTail.isNotEmpty &&
            _plainGate.isPlainFrom(data, _frozenPrefixEnd)) {
          return _buildPlainTail(plainTail, plainStyle);
        }
      } else {
        final lastStart = tailStarts.last;
        final lastBlock = tail.substring(lastStart).trim();
        if (lastBlock.isNotEmpty &&
            _plainGate.isPlainFrom(data, _frozenPrefixEnd + lastStart)) {
          final head = tail.substring(0, lastStart);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (head.trim().isNotEmpty) ...[
                widget.blockBuilder(head),
                SizedBox(height: widget.blockGap),
              ],
              _buildPlainTail(lastBlock, plainStyle),
            ],
          );
        }
      }
    }
    return widget.blockBuilder(tail);
  }

  /// 纯文本快速路径渲染——新增段淡入委托给 [StreamingFadeText]
  ///（抽取的共享载体，思考区/压缩流式区同款，R1 单源）。重生成
  /// 替换不重放淡入由其内部 tracker 语义保证（对齐 chatbox）。
  Widget _buildPlainTail(String plainTail, TextStyle plainStyle) {
    // pace: false —— 本壳（StreamingMarkdownBody）已在上游做揭示配速，
    // 同一条链上不能配速两次。
    // pace 保持默认 false——同链不双配速（上游壳已做揭示配速）。
    return StreamingFadeText(
      data: plainTail,
      style: plainStyle,
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

  /// 揭示未完成期间驱动帧；揭完即停（空闲期零帧开销）。
  void _syncRevealDriver({required bool hasPending}) {
    if (hasPending) {
      if (!_revealDriver.isActive) {
        _revealDriver.start();
      }
      return;
    }
    if (_revealDriver.isActive) {
      _revealDriver.stop();
    }
  }

  void _onRevealTick(Duration _) {
    if (mounted) {
      setState(() {});
    }
  }

  void _reset() {
    _frozenStarts.clear();
    _frozenWidgets.clear();
    _frozenPrefixEnd = 0;
    // 扫描/判纯缓存随冻结缓存一并失效（tracker 自身可检测替换，这里
    // 显式重置保持语义单一：_reset 之后两者都回到首观察态）。
    _startsTracker.reset();
    _plainGate.reset();
  }
}
