import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_prose_contract.dart';

/// 展示层正文去重（正文交付契约设计 §6：保险层，harness 为主）
///
/// 数据层正文只有 prose 一份，重复只发生在直播区（模型把正文又写进
/// content）。两层防御：
/// - **L2 直播早折叠**：参数流开头与最近一个 ≥200 字 content 块前缀
///   重合即折叠该块为占位行——正文只在稿件卡出字，双显窗口压到秒级。
/// - **L3 终局折叠**：权威 prose 到达后对本轮所有 ≥200 字 content 块做
///   近拷贝检测（长度比 + 首/中/尾锚窗），命中折叠。部分复制不算
///  （残留当播报，不误伤）。直播态与 AgentTimelineAssembler 装配态
///   同源共用本函数。
abstract final class AgentProseDedup {
  /// L2 触发线：prose 流开头累计到此长度（归一化后）才开始前缀比对
  ///（设计 §6.1「参数流开头约 60 字」）
  static const int _earlyHeadThreshold = 60;

  /// L2 比对长度：归一化后取前 40 字
  static const int _earlyHeadLength = 40;

  /// L3 锚窗长度：首/中/尾各 32 字
  static const int _anchorWindow = 32;

  /// L3 长度比可接受区间 [minRatio, maxRatio]
  static const double _minRatio = 0.6;
  static const double _maxRatio = 1.6;

  /// L2 前缀比对（§6.1）：[proseHead] 为提取器累计输出；命中条件 =
  /// 归一化后 head ≥[_earlyHeadThreshold] 且 content 块归一化文本以
  /// head 前 [_earlyHeadLength] 字开头（空白差异已归一）。
  static bool earlyMatch(String proseHead, AgentLiveBlock contentBlock) {
    if (contentBlock.kind != AgentLiveBlockKind.text ||
        contentBlock.source != AgentTextSource.assistant) {
      return false;
    }
    final head = _normalize(proseHead);
    if (head.length < _earlyHeadThreshold) return false;
    return _normalize(contentBlock.text).startsWith(
      head.substring(0, _earlyHeadLength),
    );
  }

  /// L2 接线形态：命中即把最近一个 ≥[kProseThreshold] 字 content 块
  /// 折叠为占位行；明确正文来源永不作为候选。
  /// 无命中原样返回同一列表实例。
  static List<AgentLiveBlock> earlyFold(
    List<AgentLiveBlock> blocks,
    String proseHead,
    String placeholder, {
    required int streamingStepIndex,
  }) {
    final index = _latestContentIndex(blocks, streamingStepIndex);
    if (index < 0) return blocks;
    if (!earlyMatch(proseHead, blocks[index])) return blocks;
    return [
      for (var i = 0; i < blocks.length; i++)
        if (i == index) _folded(blocks[i], placeholder) else blocks[i],
    ];
  }

  /// L3 终局折叠（§6.2）：对本轮所有 ≥[kProseThreshold] 字文本块做近拷贝
  /// 检测——归一化长度比在 [_minRatio, _maxRatio] 且首/中/尾
  /// [_anchorWindow] 字锚窗任一为对方子串 → 折叠为占位行。部分复制
  /// （比或锚窗不达标）保留原文。[prose] 为空/过短原样返回（同实例）。
  ///
  /// [keepIndices] 为保护下标（不折叠）：权威替换时点传刚落的权威块——
  /// 直播稿件卡还要显示它；终局装配时点不传——正文已归消息，时间线
  /// 只留占位行（终局干净）。
  static List<AgentLiveBlock> finalFold(
    String? prose,
    List<AgentLiveBlock> blocks,
    String placeholder, {
    Set<int> keepIndices = const {},
  }) {
    final normalized = prose == null ? '' : _normalize(prose);
    if (normalized.length < kProseThreshold) return blocks;
    final result = List<AgentLiveBlock>.of(blocks);
    var changed = false;
    for (var i = 0; i < result.length; i++) {
      if (keepIndices.contains(i)) continue;
      final block = result[i];
      if (block.kind == AgentLiveBlockKind.text &&
          block.source == AgentTextSource.assistant &&
          _nearCopy(normalized, _normalize(block.text))) {
        result[i] = _folded(block, placeholder);
        changed = true;
      }
    }
    return changed ? result : blocks;
  }

  /// 找 L2 候选：从尾部起第一个 ≥[kProseThreshold] 字文本块；末块若属
  /// 于正在追加的流 step 则跳过（那是 prose 本体不是 content 副本）
  static int _latestContentIndex(List<AgentLiveBlock> blocks, int streaming) {
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.kind != AgentLiveBlockKind.text) continue;
      if (block.source != AgentTextSource.assistant) continue;
      if (block.text.trim().length >= kProseThreshold) return i;
    }
    return -1;
  }

  /// 近拷贝判定：长度比达标 + 任一锚窗子串命中
  static bool _nearCopy(String normalizedProse, String normalizedBlock) {
    if (normalizedBlock.length < kProseThreshold) return false;
    final ratio = normalizedBlock.length / normalizedProse.length;
    if (ratio < _minRatio || ratio > _maxRatio) return false;
    for (final window in _anchorWindows(normalizedProse)) {
      if (normalizedBlock.contains(window)) return true;
    }
    return false;
  }

  /// 首/中/尾三个 [_anchorWindow] 字锚窗（不足整窗时取现有全长）
  static List<String> _anchorWindows(String text) {
    if (text.length <= _anchorWindow) return [text];
    final mid = text.length ~/ 2;
    return [
      text.substring(0, _anchorWindow),
      text.substring(mid - _anchorWindow ~/ 2, mid + _anchorWindow ~/ 2),
      text.substring(text.length - _anchorWindow),
    ];
  }

  static AgentLiveBlock _folded(AgentLiveBlock block, String placeholder) {
    return AgentLiveBlock(
      kind: block.kind,
      stepIndex: block.stepIndex,
      text: placeholder,
      source: block.source,
      order: block.order,
      startMs: block.startMs,
      endMs: block.endMs,
    );
  }

  /// 归一化：删除全部空白（§6.2「去连续空白差异」——中文正文里空白是
  /// 纯装饰，content 与 prose 的换行/空格差异不应干扰比对）
  static String _normalize(String text) {
    return text.replaceAll(RegExp(r'\s+'), '');
  }
}
