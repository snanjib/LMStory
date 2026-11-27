import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';

/// 同一只读事务取得的事实流水、当前会话对象和当前稿证据。
///
/// 查询工具使用它避免把实体、属性、历史和正文/变体摘要分别读取后拼成
/// 一个无法核对的结果。`currentFactsChangesByTurn` 只来自当前稿指针对应的
/// artifacts 行，缺行时不提供正文回读资格。
class FactualMemoryChangesSnapshot {
  const FactualMemoryChangesSnapshot({
    required this.entities,
    required this.attributes,
    required this.history,
    required this.currentFactsChangesByTurn,
    required this.currentVariantByTurn,
    required this.storyRoundsByTurn,
    required this.storyRevision,
  });

  final List<FactualEntity> entities;
  final List<FactualAttribute> attributes;
  final List<FactualMemoryHistory> history;

  /// 当前稿每轮的 facts_changes JSON。空数组仍表示当前稿明确没有事实证据。
  final Map<int, String> currentFactsChangesByTurn;

  /// 当前稿每轮的变体指针。null 表示单版本或旧存档。
  final Map<int, int?> currentVariantByTurn;

  /// 当前稿正文、用户输入和最终回复的同事务快照，按入账轮号索引。
  final Map<int, FactualMemoryStoryRound> storyRoundsByTurn;

  /// 在同一读事务中取得的当前稿/正文摘要原料。
  final String storyRevision;
}

/// 事实变更查询用于资格判断的当前稿轮次快照。
class FactualMemoryStoryRound {
  const FactualMemoryStoryRound({
    required this.turnNumber,
    required this.createdAt,
    this.userText,
    this.narrativeText,
    this.replyText,
    this.eventSummaryText,
  });

  final int turnNumber;
  final DateTime createdAt;
  final String? userText;
  final String? narrativeText;
  final String? replyText;
  final String? eventSummaryText;
}
