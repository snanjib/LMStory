import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:meta/meta.dart';

/// 事实层操作历史记录（DOC-11 §3.3）
///
/// 对应 `factual_memory_history` 审计日志表，记录所有事实层操作的版本历史。
///
/// 用途：
/// - 审计：追溯实体/属性的修改历史
/// - 回滚：v0.3 可基于历史记录回滚到任意版本
/// - 更新频率限制（DOC-11 §7.4.5）：查询某实体最近 N 轮的更新次数
///
/// 写入时机：每次 FactApplier.apply 成功应用一个 FactsDelta 后，在同一
/// 事务内追加一条历史记录。
/// 读取时机：
/// - 更新频率限制（FactApplier 查询最近 3 轮更新次数）
/// - 审计 UI（v0.3 HUD 展示实体修改历史）
@immutable
class FactualMemoryHistory {
  const FactualMemoryHistory({
    required this.entityId,
    required this.action,
    required this.turnNumber,
    required this.createdAt,
    this.historyId,
    this.attributeId,
    this.oldValue,
    this.newValue,
    this.reason,
    this.confidence,
  });

  /// 实体 ID（指向 FactualEntity.entityId）
  final String entityId;

  /// 数据库流水行号。仅用于稳定排序与查询游标，不参与写入契约。
  final int? historyId;

  /// 属性 ID（nullable：CREATE_ENTITY / ADD_ALIAS / ARCHIVE_ENTITY 时无）
  final String? attributeId;

  /// 动作类型（与 [FactAction] 对齐）
  final FactAction action;

  /// 旧值（CREATE_ENTITY 时为 null）
  final String? oldValue;

  /// 新值（ARCHIVE_ENTITY 时可为 null）
  final String? newValue;

  /// 修改原因（审计用，UPDATE_ATTR 必填）
  final String? reason;

  /// LLM 置信度 1-5（nullable：系统自动操作时无）
  final int? confidence;

  /// 触发轮次（用于更新频率限制查询）
  final int turnNumber;

  /// 时间戳
  final DateTime createdAt;
}
