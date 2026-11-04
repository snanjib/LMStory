import 'dart:convert';

import 'package:lmstory/features/memory/domain/entities/factual_entity.dart'
    show FactualEntity;
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:meta/meta.dart';

/// 事实层属性值类型（DOC-11 §3.2）
///
/// 决定 value 字段的解析方式。每种属性在 schema 白名单中预定义 valueType
/// （DOC-11 §7.4.2）。
enum AttributeValueType {
  /// 单值属性（如 species="金毛"、age="3个月"）
  ///
  /// 只能 UPDATE_ATTR，不能 APPEND_LIST。
  /// 描述性属性（personality/description/background）强制 single 类型，
  /// 避免"温顺"+"乖巧"近义词堆积。
  single,

  /// 列表属性（如 skills='["接飞盘", "握手"]'）
  ///
  /// 只能 APPEND_LIST / REMOVE_FROM_LIST，不能 UPDATE_ATTR。
  list,

  /// 字典属性（如 relationships='{"朋友": "李逍遥", "敌人": "魔王"}'）
  ///
  /// 允许 UPDATE_ATTR（整体覆盖）和 APPEND_LIST（添加新 key）。
  dict;

  /// 从数据库字符串解析
  static AttributeValueType fromString(String value) {
    switch (value) {
      case 'list':
        return AttributeValueType.list;
      case 'dict':
        return AttributeValueType.dict;
      case 'single':
      default:
        return AttributeValueType.single;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() => name;
}

/// 事实层属性（DOC-11 §3.2、§11.3）
///
/// 对应 `factual_attributes` 表，与 [FactualEntity] 配合实现"实体 + 属性"
/// 双表结构。每个属性一条记录，用 entityId 隔离不同实体的同名属性。
///
/// 属性 schema 白名单（DOC-11 §7.4.2）：每种实体类型预定义固定的 attrKey
/// 集合，LLM 只能使用预定义的 attrKey，不能发明新的。
///
/// 写入时机：summarizing 阶段 LLM 产出 UPDATE_ATTR/APPEND_LIST/
/// REMOVE_FROM_LIST 动作时，由 FactApplier 在 persisting 事务内写入。
/// 读取时机：retrieving 阶段 FactContextBuilder 批量加载命中实体的所有属性。
///
///  持久化设计：本类支持 toJson/fromJson，用于 intermediate_round_artifacts
/// 表持久化检索结果列表（与 ExperientialMemory 同模式）。
@immutable
class FactualAttribute {
  const FactualAttribute({
    required this.attributeId,
    required this.entityId,
    required this.sessionId,
    required this.attrKey,
    required this.value,
    required this.importance,
    required this.createdAt,
    this.valueType = AttributeValueType.single,
    this.source = FactualSource.auto,
    this.updatedAt,
    this.updatedTurn,
    this.updateReason,
  });

  /// 从 JSON 反序列化
  factory FactualAttribute.fromJson(Map<String, dynamic> json) =>
      FactualAttribute(
        attributeId: json['attributeId'] as String,
        entityId: json['entityId'] as String,
        sessionId: json['sessionId'] as String,
        attrKey: json['attrKey'] as String,
        value: json['value'] as String,
        importance: json['importance'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        valueType: AttributeValueType.fromString(
          json['valueType'] as String? ?? 'single',
        ),
        source: FactualSource.fromString(json['source'] as String? ?? 'auto'),
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'] as String)
            : null,
        updatedTurn: json['updatedTurn'] as int?,
        updateReason: json['updateReason'] as String?,
      );

  /// 业务主键 UUID
  final String attributeId;

  /// 指向 FactualEntity.entityId
  final String entityId;

  /// 所属会话（冗余，加速查询，避免 JOIN）
  final String sessionId;

  /// 属性名（如 `species` / `age` / `skills` / `personality`）
  ///
  /// 必须在实体类型的属性 schema 白名单内（DOC-11 §7.4.2）。
  final String attrKey;

  /// 属性值
  ///
  /// 单值属性存字符串（如 "金毛"）。
  /// 列表属性存 JSON 数组字符串（如 '["接飞盘", "握手"]'）。
  /// 字典属性存 JSON 对象字符串（如 '{"朋友": "李逍遥"}'）。
  ///
  /// 长度上限 500 字（DOC-11 §7.4.6）。
  final String value;

  /// 值类型
  final AttributeValueType valueType;

  /// 属性重要性 1-5
  ///
  /// 关键属性（>= 4）如角色名、种族等，修改需要高置信度（>= 4）
  /// （DOC-11 §7.2 三重防护）。
  final int importance;

  /// 来源（DOC-15 §8.1）：`auto` / `worldbook` / `card`
  ///
  /// `source != auto` 即只读基线。
  final FactualSource source;

  /// 创建时间
  final DateTime createdAt;

  /// 最后修改时间（nullable）
  final DateTime? updatedAt;

  /// 最后修改轮次（nullable）
  final int? updatedTurn;

  /// 修改原因（审计用，UPDATE_ATTR 必填）
  final String? updateReason;

  /// 是否为关键属性（importance >= 4，修改需高置信度）
  bool get isKeyAttribute => importance >= 4;

  /// 解析为列表值（仅 valueType == list 时有意义）
  ///
  /// 解析失败时返回空列表（容错）。
  List<String> get listValue {
    if (valueType != AttributeValueType.list) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.cast<String>();
      }
    } on FormatException {
      // 容错：旧数据可能存了非 JSON 字符串
    }
    return const [];
  }

  /// 用于 UI 展示的简要描述
  ///
  /// 例：`物种：金毛` / `技能：接飞盘, 握手` / `年龄：3个月`
  String get displayText {
    switch (valueType) {
      case AttributeValueType.single:
        return '$attrKey：$value';
      case AttributeValueType.list:
        final list = listValue;
        if (list.isEmpty) return '$attrKey：无';
        return '$attrKey：${list.join(', ')}';
      case AttributeValueType.dict:
        // 字典类型直接展示原始 JSON（简化处理）
        return '$attrKey：$value';
    }
  }

  /// 序列化为 JSON（用于 intermediate_round_artifacts 持久化）
  Map<String, dynamic> toJson() => {
        'attributeId': attributeId,
        'entityId': entityId,
        'sessionId': sessionId,
        'attrKey': attrKey,
        'value': value,
        'valueType': valueType.toDbString(),
        'importance': importance,
        'source': source.toDbString(),
        'createdAt': createdAt.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (updatedTurn != null) 'updatedTurn': updatedTurn,
        if (updateReason != null) 'updateReason': updateReason,
      };

  /// 从 JSON 字符串列表反序列化（便捷方法）
  static List<FactualAttribute> listFromJsonString(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => FactualAttribute.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 序列化列表为 JSON 字符串（便捷方法）
  static String listToJsonString(List<FactualAttribute> attributes) {
    return jsonEncode(attributes.map((a) => a.toJson()).toList());
  }
}
