import 'dart:convert';

import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart'
    show FactualAttribute;
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:meta/meta.dart';

/// 事实层实体类型（DOC-11 §3.1、§7.4.2）
///
/// 每种类型有预定义的属性 schema 白名单，LLM 只能使用预定义的 attrKey。
/// character 类型额外允许自定义属性名（白名单外的也接受）。
enum FactualEntityType {
  /// 角色（含主角、NPC、宠物、坐骑等所有角色）
  character,

  /// 地点/场景
  location,

  /// 物品/装备/道具
  item,

  /// 世界设定/知识/规则/常识/历史
  lore,

  /// 组织/势力/团体
  organization,

  /// 杂项（无法归类的持久性事实）
  misc;

  /// 从数据库字符串解析
  ///
  /// 保留向后兼容：pet/npc -> character, rule -> lore
  static FactualEntityType fromString(String value) =>
      tryFromString(value) ?? FactualEntityType.character;

  /// Resolves stored names and known legacy aliases without guessing a type.
  static FactualEntityType? tryFromString(String? value) {
    switch (value) {
      case 'character':
      case 'pet':
      case 'npc':
        return FactualEntityType.character;
      case 'location':
        return FactualEntityType.location;
      case 'item':
        return FactualEntityType.item;
      case 'rule':
      case 'lore':
        return FactualEntityType.lore;
      case 'organization':
        return FactualEntityType.organization;
      case 'misc':
        return FactualEntityType.misc;
      default:
        return null;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() => name;
}

/// 事实层实体（DOC-11 §3.1、§11.3）
///
/// 对应 `factual_entities` 表，事实层核心实体之一。
/// 每个实体（人/物/地/NPC）一条记录，与 [FactualAttribute] 配合实现
/// "实体 + 属性"双表结构，避免扁平 key 存储导致的多实例串台问题。
///
/// 写入时机：summarizing 阶段 LLM 产出 CREATE_ENTITY/ADD_ALIAS/ARCHIVE_ENTITY
/// 动作时，由 FactApplier 在 persisting 事务内写入。
/// 读取时机：retrieving 阶段 FactContextBuilder 加载关键实体 + 本轮 keywords
/// 命中实体，注入 reviewing prompt 的【世界设定】区块。
///
///  持久化设计：本类支持 toJson/fromJson，用于 intermediate_round_artifacts
/// 表持久化检索结果列表（与 ExperientialMemory 同模式）。
@immutable
class FactualEntity {
  const FactualEntity({
    required this.entityId,
    required this.sessionId,
    required this.type,
    required this.primaryName,
    required this.aliases,
    required this.importance,
    required this.createdTurn,
    required this.createdAt,
    this.category,
    this.isArchived = false,
    this.source = FactualSource.auto,
    this.sourceRef,
    this.forceInject = ForceInjectTarget.none,
    this.injectionDisabled = false,
    this.updatedAt,
    this.updatedTurn,
  });

  /// 从 JSON 反序列化
  factory FactualEntity.fromJson(Map<String, dynamic> json) => FactualEntity(
        entityId: json['entityId'] as String,
        sessionId: json['sessionId'] as String,
        type: FactualEntityType.fromString(json['type'] as String),
        primaryName: json['primaryName'] as String,
        aliases: (json['aliases'] as List<dynamic>).cast<String>(),
        importance: json['importance'] as int,
        createdTurn: json['createdTurn'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        category: json['category'] as String?,
        isArchived: json['isArchived'] as bool? ?? false,
        source: FactualSource.fromString(json['source'] as String? ?? 'auto'),
        sourceRef: json['sourceRef'] as String?,
        forceInject: ForceInjectTarget.fromString(
          json['forceInject'] as String? ?? 'none',
        ),
        injectionDisabled: json['injectionDisabled'] as bool? ?? false,
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'] as String)
            : null,
        updatedTurn: json['updatedTurn'] as int?,
      );

  /// 业务主键（如 `ent_001`），由系统生成
  final String entityId;

  /// 所属会话
  final String sessionId;

  /// 实体类型
  final FactualEntityType type;

  /// 主名（用于检索和展示）
  ///
  /// 同一会话内 primaryName 唯一（idx_factual_entities_session_name）。
  /// 用户改名时通过 UPDATE_ATTR 修改此字段（attrKey='name'）。
  final String primaryName;

  /// 别名列表（用户换称呼时追加）
  ///
  /// 检索时按 primaryName 或 aliases 匹配（DOC-11 §10.1）。
  final List<String> aliases;

  /// 分类标签（可选，如"主角宠物"）
  ///
  /// 用户自定义分类，用于 UI 分组展示，不影响检索逻辑。
  final String? category;

  /// 重要性 1-5
  ///
  /// 关键实体（>= keyEntityImportanceThreshold，默认 5）在 retrieving
  /// 阶段强制注入 prompt，无需 keywords 命中。
  final int importance;

  /// 是否归档（角色死亡/物品销毁）
  ///
  /// 归档后不再注入 prompt，但保留记录供历史回顾。
  final bool isArchived;

  /// 来源（DOC-15 §3.1）：`auto` / `worldbook` / `card`
  final FactualSource source;

  /// 来源资源引用（`cardId`/`bookId`，仅 `worldbook`/`card` 来源有值）
  final String? sourceRef;

  /// 实体强制注入开关（v0.2.3）：none / world / directive
  ///
  /// 与 importance 评分解耦的注入偏好。world=始终注入【世界设定】，
  /// directive=始终注入【常驻指令】。纯检索偏好，不影响只读/写入语义。
  final ForceInjectTarget forceInject;

  /// 批 J-b：注入停用（词条级临时关闭注入；浏览/检索不受影响）
  final bool injectionDisabled;

  /// 出现轮次（对应当前对话轮次）
  final int createdTurn;

  /// 创建时间
  final DateTime createdAt;

  /// 最后修改时间（nullable：从未修改过的实体为 null）
  final DateTime? updatedAt;

  /// 最后修改轮次（nullable：从未修改过的实体为 null）
  final int? updatedTurn;

  /// 是否为关键实体（importance >= 4）
  bool get isKeyEntity => importance >= 4;

  /// 关键实体注入优先级比较（DEC-06 消费层统一排序口径）
  ///
  /// 排序规则：importance DESC → 活跃度新者在前（updatedAt 优先，
  /// 其次 updatedTurn——活跃实体优先，不能仅按创建早晚长期占位）
  /// → entityId 升序稳定兜底（同分同活跃度时结果确定）。
  ///
  /// 消费方：FactContextBuilder.buildFactBlock / buildKnownEntitiesBlock、
  /// 导演 assembleDirectorCoreBlocks——三处取数共用同一排序，
  /// 与 keyEntityAutoCap 配套截断，保证故事模式与导演模式「同一批
  /// 关键档案」入选口径一致。仓储查询层（factual_repository_impl）
  /// 不感知此排序。
  static int compareInjectionPriority(FactualEntity a, FactualEntity b) {
    final byImportance = b.importance.compareTo(a.importance);
    if (byImportance != 0) return byImportance;
    final updatedMsA = a.updatedAt?.millisecondsSinceEpoch ?? 0;
    final updatedMsB = b.updatedAt?.millisecondsSinceEpoch ?? 0;
    if (updatedMsA != updatedMsB) return updatedMsB.compareTo(updatedMsA);
    final byUpdatedTurn = (b.updatedTurn ?? 0).compareTo(a.updatedTurn ?? 0);
    if (byUpdatedTurn != 0) return byUpdatedTurn;
    return a.entityId.compareTo(b.entityId);
  }

  /// 用于 UI 展示的简要描述
  ///
  /// 例：`角色"旺财"（别名：小金毛, 财财）`
  /// 例：`角色"王老板"`
  String get displayText {
    final typeLabel = _typeLabelZh;
    final aliasText = aliases.isEmpty ? '' : '（别名：${aliases.join(', ')}）';
    return '$typeLabel"$primaryName"$aliasText';
  }

  /// 类型对应的中文标签
  String get _typeLabelZh {
    switch (type) {
      case FactualEntityType.character:
        return '角色';
      case FactualEntityType.location:
        return '地点';
      case FactualEntityType.item:
        return '物品';
      case FactualEntityType.lore:
        return '设定';
      case FactualEntityType.organization:
        return '组织';
      case FactualEntityType.misc:
        return '杂项';
    }
  }

  /// 序列化为 JSON（用于 intermediate_round_artifacts 持久化）
  Map<String, dynamic> toJson() => {
        'entityId': entityId,
        'sessionId': sessionId,
        'type': type.toDbString(),
        'primaryName': primaryName,
        'aliases': aliases,
        'importance': importance,
        'createdTurn': createdTurn,
        'createdAt': createdAt.toIso8601String(),
        if (category != null) 'category': category,
        'isArchived': isArchived,
        'source': source.toDbString(),
        if (sourceRef != null) 'sourceRef': sourceRef,
        'forceInject': forceInject.toDbString(),
        'injectionDisabled': injectionDisabled,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (updatedTurn != null) 'updatedTurn': updatedTurn,
      };

  /// 从 JSON 字符串列表反序列化（便捷方法）
  static List<FactualEntity> listFromJsonString(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => FactualEntity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 序列化列表为 JSON 字符串（便捷方法）
  static String listToJsonString(List<FactualEntity> entities) {
    return jsonEncode(entities.map((e) => e.toJson()).toList());
  }
}
