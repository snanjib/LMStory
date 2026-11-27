import 'package:lmstory/features/memory/domain/entities/factual_entity.dart'
    show FactualEntityType;
import 'package:meta/meta.dart';

/// 事实变更动作枚举（DOC-11 §4.1）
///
/// 定义 LLM 在 summarizing 阶段通过 extract_facts 工具产出的 6 种事实变更。
///
/// MERGE_ENTITY 暂不实现（DOC-11 §4.1 注）：合并实体逻辑复杂（属性冲突
/// 解决），v0.2 阶段先不引入。若 LLM 发现同一实体被重复创建，通过
/// `addAlias` + `archiveEntity` 手动处理。
enum FactAction {
  /// 新建实体（新出现的角色/宠物/物品/地点）
  ///
  /// 必填字段：entityType, primaryName, confidence
  /// 可选字段：attrKey, value（创建时同时初始化属性）
  createEntity,

  /// 修改单值属性（如角色改名、年龄增长）
  ///
  /// 必填字段：entityId, attrKey, value, reason, confidence
  /// 防护：关键属性（importance>=4）需要 confidence>=4 才允许修改。
  updateAttr,

  /// 追加列表属性（如学会新技能、获得新物品）
  ///
  /// 必填字段：entityId, attrKey, value, confidence
  /// 防护：值不能已在列表中（精确+语义相似度去重）。
  appendList,

  /// 从列表移除（如遗忘某技能）
  ///
  /// 必填字段：entityId, attrKey, value, reason, confidence
  removeFromList,

  /// 添加别名（用户换称呼）
  ///
  /// 必填字段：entityId, value, confidence
  /// 防护：别名不能与已有主名或别名冲突。
  addAlias,

  /// 实体归档（角色死亡/物品销毁）
  ///
  /// 必填字段：entityId, reason, confidence
  /// 归档后实体不再注入 prompt，但保留记录供历史回顾。
  archiveEntity,

  /// 动态调整实体重要度（1-5）
  ///
  /// 必填字段：entityId（或按 primaryName 定位）, importance(1-5), confidence
  /// 可选字段：reason
  setImportance;

  /// 从 JSON 字符串解析（用于工具调用响应解析）
  static FactAction fromString(String value) {
    switch (value) {
      case 'create_entity':
        return FactAction.createEntity;
      case 'update_attr':
        return FactAction.updateAttr;
      case 'append_list':
        return FactAction.appendList;
      case 'remove_from_list':
        return FactAction.removeFromList;
      case 'add_alias':
        return FactAction.addAlias;
      case 'archive_entity':
        return FactAction.archiveEntity;
      case 'set_importance':
        return FactAction.setImportance;
      default:
        throw ArgumentError.value(
          value,
          'value',
          '未知的 FactAction 字符串',
        );
    }
  }

  /// 序列化为 JSON 工具调用字符串（snake_case，匹配工具定义）
  String toJsonString() {
    switch (this) {
      case FactAction.createEntity:
        return 'create_entity';
      case FactAction.updateAttr:
        return 'update_attr';
      case FactAction.appendList:
        return 'append_list';
      case FactAction.removeFromList:
        return 'remove_from_list';
      case FactAction.addAlias:
        return 'add_alias';
      case FactAction.archiveEntity:
        return 'archive_entity';
      case FactAction.setImportance:
        return 'set_importance';
    }
  }

  /// 序列化为数据库字符串（用于 factual_memory_history.action 列）
  ///
  /// 与 [toJsonString] 相同（snake_case），但语义上更明确。
  String toDbString() => toJsonString();
}

/// 事实变更单元（DOC-11 §4.2、§11.3）
///
/// 由 LLM 在 summarizing 阶段通过 extract_facts 工具产出，由 FactApplier
/// 在 persisting 事务内应用。
///
/// 各动作的字段要求见 [FactAction] 枚举文档。
///
/// 三重防护机制（DOC-11 §7.1）：
/// 1. 提示词约束：让 LLM 谨慎产出 deltas
/// 2. 冲突检测：FactApplier 自动检测 key 是否已存在 + 值是否真的不同
/// 3. 重要性阈值：importance>=4 的关键事实，confidence>=4 才允许修改
///
/// 5 层健康度防护（DOC-11 §7.4）：
/// - 属性 schema 白名单
/// - 提示词约束（临时状态≠事实）
/// - 系统级去重（精确+语义相似度）
/// - 更新频率限制（3 轮 4 次）
/// - 属性值长度上限（500 字）
@immutable
class FactsDelta {
  const FactsDelta({
    required this.action,
    required this.confidence,
    this.entityId,
    this.entityType,
    this.primaryName,
    this.attrKey,
    this.value,
    this.reason,
    this.importance,
    this.isCuration = false,
    this.skipFrequencyGuard = false,
  });

  /// 从 JSON 反序列化（用于解析 extract_facts 工具调用响应）
  factory FactsDelta.fromJson(Map<String, dynamic> json) => FactsDelta(
        action: FactAction.fromString(json['action'] as String),
        confidence: (json['confidence'] as num).toInt(),
        entityId: json['entityId'] as String?,
        entityType: json['entityType'] as String?,
        primaryName: json['primaryName'] as String?,
        attrKey: json['attrKey'] as String?,
        value: json['value'] as String?,
        reason: json['reason'] as String?,
        importance: json['importance'] as int?,
        isCuration: json['isCuration'] as bool? ?? false,
        skipFrequencyGuard: json['skipFrequencyGuard'] as bool? ?? false,
      );

  /// 动作类型
  final FactAction action;

  /// 实体 ID（update/append/remove/addAlias/archive 时必填）
  ///
  /// createEntity 时为 null（系统先生成 entityId 再创建）。
  final String? entityId;

  /// 实体类型（createEntity 时必填）
  ///
  /// 取值：`character` / `location` / `item` / `lore` / `organization` / `misc`
  /// 与 [FactualEntityType] 枚举对齐（pet/npc/rule 为旧值，fromString 自动映射）。
  final String? entityType;

  /// 主名（createEntity 时必填）
  ///
  /// 同一会话内 primaryName 唯一。若已存在同名实体，FactApplier 自动
  /// 改为 ADD_ALIAS（DOC-11 §10.3）。
  final String? primaryName;

  /// 属性名（updateAttr/appendList/removeFromList 时必填）
  ///
  /// 必须在实体类型的属性 schema 白名单内（DOC-11 §7.4.2）。
  final String? attrKey;

  /// 属性值 / 别名 / 归档原因
  ///
  /// - updateAttr/appendList/removeFromList：新属性值
  /// - addAlias：新别名
  /// - archiveEntity：可为 null（归档不强制要求值）
  final String? value;

  /// 修改原因（审计用，updateAttr/removeFromList/archiveEntity 必填）
  ///
  /// 例："用户在第8轮明确改名""剧情中角色死亡"
  final String? reason;

  /// LLM 置信度 1-5
  ///
  /// 低置信度（< 4）的修改类操作在关键属性（importance>=4）上被拒绝
  /// （DOC-11 §7.2 三重防护第三层）。
  final int confidence;

  /// LLM 评分的实体重要性 1-5（仅 create_entity 时有意义）
  ///
  /// 决定实体在检索时的注入频率：
  /// - >= keyEntityImportanceThreshold（默认5）：每轮对话强制注入
  /// - < keyEntityImportanceThreshold：仅当对话关键词命中时注入
  ///
  /// 评分核心原则：评估该实体在今后剧情中出现的可能性。
  /// null 时由系统按实体类型赋默认值（保守策略）。
  final int? importance;

  /// 整理型写入标记（实体归并搬移用，默认 false = 演化型写入）
  ///
  /// 演化型写入受 FactApplier 的防退化守卫约束（更新频率限制、关键属性
  /// 置信度门、schema 白名单）；整理型写入（merge_entities 的属性搬移）
  /// 是确定性知识搬迁，豁免这三类守卫但仍保留只读守卫、长度上限与
  /// 值类型检查。审计行照写，回滚语义不变。
  ///
  /// 不新增 FactAction 枚举值（记忆库约束），仅作为 delta 元数据。
  final bool isCuration;

  /// 仅豁免单实体 3 轮更新频率上限（用于维护阶段批量校准），
  /// 不放开 schema 白名单或关键属性置信度门。
  final bool skipFrequencyGuard;

  /// 序列化为 JSON（用于审计日志或调试输出）
  Map<String, dynamic> toJson() => {
        'action': action.toJsonString(),
        'confidence': confidence,
        if (entityId != null) 'entityId': entityId,
        if (entityType != null) 'entityType': entityType,
        if (primaryName != null) 'primaryName': primaryName,
        if (attrKey != null) 'attrKey': attrKey,
        if (value != null) 'value': value,
        if (reason != null) 'reason': reason,
        if (importance != null) 'importance': importance,
        if (isCuration) 'isCuration': isCuration,
        if (skipFrequencyGuard) 'skipFrequencyGuard': skipFrequencyGuard,
      };

  /// 从 JSON 数组反序列化（用于解析 extract_facts 工具调用的 deltas 参数）
  static List<FactsDelta> listFromJson(List<dynamic> jsonList) => jsonList
      .map((e) => FactsDelta.fromJson(e as Map<String, dynamic>))
      .toList();
}
