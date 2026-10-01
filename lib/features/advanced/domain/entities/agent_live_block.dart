import 'package:lmstory/features/advanced/domain/entities/agent_prose_contract.dart';

/// 导演模式直播时间线的内容块类型（opencode 式 part 分段）
enum AgentLiveBlockKind {
  /// 思考/推理增量（折叠展示）
  thinking,

  /// 正文文本增量
  text,
}

/// 导演模式直播时间线的单个内容块
///
/// agent loop 的一个 step 内思考与正文各自成块；step 切换或类型切换都开
/// 新块。UI 按列表顺序渲染交错块：最后一个非空文本段进稿件卡（正文候
/// 选），其余文本段为播报（对话流计划：原过渡话术弱化展示升级为播报）。
class AgentLiveBlock {
  const AgentLiveBlock({
    required this.kind,
    required this.stepIndex,
    this.text = '',
    this.startMs,
    this.endMs,
  });

  final AgentLiveBlockKind kind;

  /// 产生该块的模型请求序号（同 step 同类型的增量追加进同一块）
  final int stepIndex;

  final String text;

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
  }) =>
      _append(blocks, AgentLiveBlockKind.thinking, stepIndex, delta, atMs);

  /// 追加正文增量，返回新列表（不入原列表）
  static List<AgentLiveBlock> appendText(
    List<AgentLiveBlock> blocks,
    int stepIndex,
    String delta, {
    int? atMs,
  }) =>
      _append(blocks, AgentLiveBlockKind.text, stepIndex, delta, atMs);

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

  /// 用权威正文整块替换该 step 的最后一个文本块（正文交付契约 §4.3：
  /// 工具调用协议解析完成后，用已解析 prose 修正流式反转义的毛刺）。
  ///
  /// 该 step 无直播文本块时（Gemini 原子到达/非流式回退没有参数增量）
  /// 直接整块出稿——稿件卡、滚动、时间线零改动。
  static List<AgentLiveBlock> replaceStepText(
    List<AgentLiveBlock> blocks,
    int stepIndex,
    String text, {
    int? atMs,
  }) {
    // 直播块按到达序追加，stepIndex 单调不减——从尾部扫到目标 step 之外
    // 即可停（目标 step 的最后一个文本块即全列表中最靠后的命中）
    var lastText = -1;
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.stepIndex < stepIndex) break;
      if (block.stepIndex == stepIndex &&
          block.kind == AgentLiveBlockKind.text) {
        lastText = i;
        break;
      }
    }
    if (lastText == -1) {
      return _append(blocks, AgentLiveBlockKind.text, stepIndex, text, atMs);
    }
    return [
      ...blocks.sublist(0, lastText),
      AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: stepIndex,
        text: text,
        startMs: blocks[lastText].startMs,
        endMs: atMs ?? blocks[lastText].endMs,
      ),
      ...blocks.sublist(lastText + 1),
    ];
  }

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
    int? atMs,
  ) {
    if (blocks.isNotEmpty) {
      final last = blocks.last;
      if (last.kind == kind && last.stepIndex == stepIndex) {
        return [
          ...blocks.sublist(0, blocks.length - 1),
          AgentLiveBlock(
            kind: kind,
            stepIndex: stepIndex,
            text: last.text + delta,
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
        startMs: atMs,
        endMs: atMs,
      ),
    ];
  }
}
