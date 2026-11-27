import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart'
    show FactApplier;
import 'package:meta/meta.dart';

/// 事实层变更展示记录（事实层变更小窗用，DOC-11 §4 配套）
///
/// 由 [FactApplier.applyDeltas] 在应用每条 [FactsDelta] 后合成，持久化到
/// `intermediate_round_artifacts.factsChanges`，供「事实层变更小窗」展示
/// 本轮发生的新增 / 更新 / 追加 / 移除 / 别名 / 归档。
///
/// 与 [FactsDelta]（LLM 意图）和 [FactualMemoryHistory]（审计日志）的区别：
/// - [FactsDelta]：LLM 想做什么（含实体名 / 类型 / 属性 / 新值，无旧值）。
/// - [FactualMemoryHistory]：实际落到数据库的审计（含旧值 / 新值，
///   但无实体名 / 类型 / 属性名，只有 entityId / attributeId）。
/// - [FactsChangeRecord]：二者合并的 UI 友好视图——一条记录同时携带
///   实体名 / 类型 / 属性名（来自 delta）与变更前 / 变更后（来自 history）。
///
/// 合成规则（见 [FactApplier._buildChangeRecord]）：
/// - [action]：取实际落库动作（[FactualMemoryHistory.action]），以反映
///   create_entity 被转写为 update_attr / add_alias 等场景的真实结果。
/// - [entityType]：成功应用后取自会话中的目标实体。
/// - [primaryName] / [attrKey]：取自原始 [FactsDelta]，
///   保留 LLM 视角的实体与属性描述；内置属性标签由界面选择语言。
/// - [oldValue] / [newValue]：取自 [FactualMemoryHistory]；create_entity /
///   add_alias 无旧值，archive_entity 无新旧值（仅 reason）。
/// - [entityId]：优先取 [FactualMemoryHistory.entityId]（create_entity 时
///   delta.entityId 为 null，但 history 携带新建的 entityId）。
@immutable
class FactsChangeRecord {
  const FactsChangeRecord({
    required this.action,
    required this.confidence,
    this.entityId,
    this.entityType,
    this.primaryName,
    this.attrKey,
    this.oldValue,
    this.newValue,
    this.reason,
  });

  /// 从 JSON 反序列化（用于 artifacts 表 factsChanges 列读取）
  factory FactsChangeRecord.fromJson(Map<String, dynamic> json) =>
      FactsChangeRecord(
        action: FactAction.fromString(json['action'] as String),
        confidence: (json['confidence'] as num).toInt(),
        entityId: json['entityId'] as String?,
        entityType: json['entityType'] as String?,
        primaryName: json['primaryName'] as String?,
        attrKey: json['attrKey'] as String?,
        oldValue: json['oldValue'] as String?,
        newValue: json['newValue'] as String?,
        reason: json['reason'] as String?,
      );

  /// 从原始 [FactsDelta] 构造"应用中"预览记录（[oldValue] 为 null）。
  ///
  /// 用于 summarizing 阶段：事实层尚未应用，无法提供变更前值，UI 据此显示
  /// "应用中"。persist 完成后由 [FactApplier] 产出的完整记录（含 oldValue）
  /// 替换。此处直接沿用 delta 的动作语义（未经转写），仅作过渡展示。
  factory FactsChangeRecord.fromDelta(FactsDelta delta) => FactsChangeRecord(
        action: delta.action,
        entityId: delta.entityId,
        entityType: delta.entityType,
        primaryName: delta.primaryName,
        attrKey: delta.attrKey,
        newValue: delta.action == FactAction.setImportance
            ? delta.importance?.toString()
            : delta.value,
        reason: delta.reason,
        confidence: delta.confidence,
      );

  /// 实际落库的动作（可能与原始 delta 动作不同，如 create→update 转写）
  final FactAction action;

  /// 实体 ID（来自审计记录；create_entity 时为新建的 entityId）
  final String? entityId;

  /// 实体类型。旧记录可缺失，尚在应用的预览取自 delta。
  ///
  /// 取值：`character` / `location` / `item` / `lore` / `organization` / `misc`
  final String? entityType;

  /// 主名（来自原始 delta；update / append 等场景下可能为 null）
  final String? primaryName;

  /// 属性名（来自原始 delta，未标准化的 LLM 原始字段）
  final String? attrKey;

  /// 变更前旧值（来自审计记录；create_entity / add_alias / archive_entity 为 null）
  final String? oldValue;

  /// 变更后新值（来自审计记录；archive_entity 为 null）
  final String? newValue;

  /// 修改原因（来自审计记录或原始 delta）
  final String? reason;

  /// LLM 置信度 1-5（来自原始 delta）
  final int confidence;

  /// 序列化为 JSON（用于 artifacts 表 factsChanges 列写入）
  Map<String, dynamic> toJson() => {
        'action': action.toJsonString(),
        'confidence': confidence,
        if (entityId != null) 'entityId': entityId,
        if (entityType != null) 'entityType': entityType,
        if (primaryName != null) 'primaryName': primaryName,
        if (attrKey != null) 'attrKey': attrKey,
        if (oldValue != null) 'oldValue': oldValue,
        if (newValue != null) 'newValue': newValue,
        if (reason != null) 'reason': reason,
      };

  /// 从 JSON 数组反序列化
  static List<FactsChangeRecord> listFromJson(List<dynamic> jsonList) =>
      jsonList
          .map((e) => FactsChangeRecord.fromJson(e as Map<String, dynamic>))
          .toList();

  /// 序列化为 JSON 数组
  static List<Map<String, dynamic>> listToJson(
    List<FactsChangeRecord> records,
  ) =>
      records.map((r) => r.toJson()).toList();
}
