import 'package:lmstory/features/advanced/domain/entities/agent_prose_contract.dart';

/// 导演模式直播时间线的内容块类型（opencode 式 part 分段）
enum AgentLiveBlockKind {
  /// 思考/推理增量（折叠展示）
  thinking,

  /// Assistant speech or explicitly delivered manuscript text.
  text,
}

/// A text block keeps its producer even before the round is complete.
enum AgentTextSource { assistant, finishRoundProse, confirmedFallback }

/// 导演模式直播时间线的单个内容块
///
/// Ordinary assistant speech stays backstage. Only explicit prose or a
/// confirmed terminal fallback belongs to the manuscript surface.
class AgentLiveBlock {
  const AgentLiveBlock({
    required this.kind,
    required this.stepIndex,
    this.text = '',
    this.source = AgentTextSource.assistant,
    this.order,
    this.startMs,
    this.endMs,
  });

  final AgentLiveBlockKind kind;

  /// 产生该块的模型请求序号（同 step 同类型的增量追加进同一块）
  final int stepIndex;

  final String text;
  final AgentTextSource source;

  /// First-arrival order, shared with tool steps; null for legacy blocks.
  final int? order;

  bool get isManuscript =>
      kind == AgentLiveBlockKind.text &&
      source != AgentTextSource.assistant &&
      !isEmpty;

  /// 块首/末增量的绝对时刻（事件流 at，epoch 毫秒；缺省 null）
  ///
  /// 对话流计划 §4.2：装配轮时间线时换算为相对轮起点毫秒，供
  /// 「思考 · 持续 N 秒」等时长标题使用。
  final int? startMs;
  final int? endMs;

  bool get isEmpty => text.trim().isEmpty;
}

/// 直播分段的纯函数助手（无状态，便于单测）
///
/// 分段规则：末块为同类型且同 step 时追加替换，否则新开一块——这保证
/// 跨 step 的思考/正文不再串行拼接（2026-08-23 修复的两全局字符串缺陷）。
abstract final class AgentLiveTranscript {
  /// 追加思考增量，返回新列表（不入原列表）
  static List<AgentLiveBlock> appendThinking(
    List<AgentLiveBlock> blocks,
    int stepIndex,
    String delta, {
    int? atMs,
    int? order,
  }) =>
      _append(
        blocks,
        AgentLiveBlockKind.thinking,
        stepIndex,
        delta,
        atMs,
        order: order,
      );

  /// Append text without mixing assistant speech and delivered prose.
  static List<AgentLiveBlock> appendText(
    List<AgentLiveBlock> blocks,
    int stepIndex,
    String delta, {
    int? atMs,
    int? order,
    AgentTextSource source = AgentTextSource.assistant,
  }) =>
      _append(
        blocks,
        AgentLiveBlockKind.text,
        stepIndex,
        delta,
        atMs,
        source: source,
        order: order,
      );

  /// 本轮正文的收割判据（正文交付契约 §5.2：通道 B/C 共享纯函数）
  ///
  /// 优先级：explicitReply（prose 参数交付，promotedIndex 为 null——全部
  /// 自由文本进播报）> 最后一个 ≥[kProseThreshold] 字文本块（达标正文，
  /// 跳过更晚的过渡话）> 最后一个非空文本块（短正文也是交付，
  /// [allowShortText] 关闭时此级跳过——预算/doom 尾巴不许过渡话冒充正文）。
  /// 返回 null = 全程零正文（唯一 EAGENT 场景）。
  static ({String text, int? promotedIndex})? pickReplyBlock({
    required List<AgentLiveBlock> blocks,
    String? explicitReply,
    bool allowShortText = true,
  }) {
    final explicit = explicitReply?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return (text: explicit, promotedIndex: null);
    }
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.kind == AgentLiveBlockKind.text &&
          block.text.trim().length >= kProseThreshold) {
        return (text: block.text.trim(), promotedIndex: i);
      }
    }
    if (allowShortText) {
      for (var i = blocks.length - 1; i >= 0; i--) {
        final block = blocks[i];
        if (block.kind == AgentLiveBlockKind.text &&
            block.text.trim().isNotEmpty) {
          return (text: block.text.trim(), promotedIndex: i);
        }
      }
    }
    return null;
  }

  /// 清除指定 step 的全部直播块（正文交付契约 §7.1：step 请求失败重试时，
  /// 失败尝试的半截文本/思考不得与重试全文拼进同一块污染稿件卡候选）
  static List<AgentLiveBlock> removeStep(
    List<AgentLiveBlock> blocks,
    int stepIndex,
  ) {
    if (!blocks.any((b) => b.stepIndex == stepIndex)) return blocks;
    return [
      for (final block in blocks)
        if (block.stepIndex != stepIndex) block,
    ];
  }

  /// Replace only explicit prose, preserving same-step assistant speech.
  static List<AgentLiveBlock> replaceStepText(
    List<AgentLiveBlock> blocks,
    int stepIndex,
    String text, {
    int? atMs,
    int? order,
  }) {
    final index = blocks.lastIndexWhere(
      (b) =>
          b.stepIndex == stepIndex &&
          b.kind == AgentLiveBlockKind.text &&
          b.source == AgentTextSource.finishRoundProse &&
          (order == null || b.order == order),
    );
    if (index < 0) {
      return _append(
        blocks,
        AgentLiveBlockKind.text,
        stepIndex,
        text,
        atMs,
        source: AgentTextSource.finishRoundProse,
        order: order,
      );
    }
    final old = blocks[index];
    return [
      ...blocks.sublist(0, index),
      AgentLiveBlock(
        kind: old.kind,
        stepIndex: old.stepIndex,
        text: text,
        source: old.source,
        order: old.order ?? order,
        startMs: old.startMs,
        endMs: atMs ?? old.endMs,
      ),
      ...blocks.sublist(index + 1),
    ];
  }

  /// Promote a fallback only after the existing terminal delivery check accepts it.
  static List<AgentLiveBlock> confirmFallback(
    List<AgentLiveBlock> blocks,
    int index,
  ) {
    final old = blocks[index];
    return [
      ...blocks.sublist(0, index),
      AgentLiveBlock(
        kind: old.kind,
        stepIndex: old.stepIndex,
        text: old.text,
        source: AgentTextSource.confirmedFallback,
        order: old.order,
        startMs: old.startMs,
        endMs: old.endMs,
      ),
      ...blocks.sublist(index + 1),
    ];
  }

  static int manuscriptIndex(List<AgentLiveBlock> blocks) =>
      blocks.lastIndexWhere((b) => b.isManuscript);

  /// 全部非空思考段按序以空行连接（落库 thinkingContent；无则空串）
  static String joinedThinking(List<AgentLiveBlock> blocks) {
    final parts = [
      for (final block in blocks)
        if (block.kind == AgentLiveBlockKind.thinking &&
            block.text.trim().isNotEmpty)
          block.text.trim(),
    ];
    return parts.join('\n\n');
  }

  static List<AgentLiveBlock> _append(
    List<AgentLiveBlock> blocks,
    AgentLiveBlockKind kind,
    int stepIndex,
    String delta,
    int? atMs, {
    AgentTextSource source = AgentTextSource.assistant,
    int? order,
  }) {
    if (source == AgentTextSource.finishRoundProse && order != null) {
      final index = blocks.lastIndexWhere(
        (b) =>
            b.kind == kind &&
            b.stepIndex == stepIndex &&
            b.source == source &&
            b.order == order,
      );
      if (index >= 0) {
        final old = blocks[index];
        return [
          ...blocks.sublist(0, index),
          AgentLiveBlock(
            kind: kind,
            stepIndex: stepIndex,
            text: old.text + delta,
            source: source,
            order: order,
            startMs: old.startMs,
            endMs: atMs ?? old.endMs,
          ),
          ...blocks.sublist(index + 1),
        ];
      }
    }
    if (blocks.isNotEmpty) {
      final last = blocks.last;
      if (last.kind == kind &&
          last.stepIndex == stepIndex &&
          last.source == source &&
          last.order == order) {
        return [
          ...blocks.sublist(0, blocks.length - 1),
          AgentLiveBlock(
            kind: kind,
            stepIndex: stepIndex,
            text: last.text + delta,
            source: source,
            order: last.order,
            startMs: last.startMs,
            endMs: atMs ?? last.endMs,
          ),
        ];
      }
    }
    return [
      ...blocks,
      AgentLiveBlock(
        kind: kind,
        stepIndex: stepIndex,
        text: delta,
        source: source,
        order: order,
        startMs: atMs,
        endMs: atMs,
      ),
    ];
  }
}
