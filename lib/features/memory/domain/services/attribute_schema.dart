import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart'
    show AttributeValueType;
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart'
    show FactualEntityType;

/// 属性 schema 白名单（DOC-11 §7.4.2）
///
/// 每种实体类型预定义固定的属性集合，LLM 只能使用预定义的 attrKey。
/// 描述性属性（personality/description/background）强制 single 类型，
/// 只能 update 不能 append，避免"温顺"+"乖巧"近义词堆积。
///
/// 2026-10-15 从 fact_applier.dart 拆出（监督审批投影器需要同一套
/// schema 判定，拆独立文件避免 services 层内循环 import）；
/// fact_applier.dart 通过 export 保持既有引用路径不变。
class AttributeSchema {
  const AttributeSchema._();

  /// 各实体类型的属性 schema 映射
  ///
  /// key: 实体类型，value: {attrKey: valueType}
  ///
  /// character / lore 类型额外允许白名单外的自定义属性名（[isAttrKeyAllowed]
  /// 对 character/lore 放宽验证），此处仅列出核心属性。
  static const Map<FactualEntityType, Map<String, AttributeValueType>> _schema =
      {
    FactualEntityType.character: {
      'name': AttributeValueType.single,
      'personality': AttributeValueType.single,
      'background': AttributeValueType.single,
      'relationships': AttributeValueType.dict,
      'skills': AttributeValueType.list,
    },
    FactualEntityType.location: {
      'name': AttributeValueType.single,
      'description': AttributeValueType.single,
      'features': AttributeValueType.list,
    },
    FactualEntityType.item: {
      'name': AttributeValueType.single,
      'description': AttributeValueType.single,
      'owner': AttributeValueType.single,
    },
    FactualEntityType.lore: {
      'name': AttributeValueType.single,
      'description': AttributeValueType.single,
      'category': AttributeValueType.single,
    },
    FactualEntityType.organization: {
      'name': AttributeValueType.single,
      'description': AttributeValueType.single,
      'leader': AttributeValueType.single,
      'members': AttributeValueType.list,
      'background': AttributeValueType.single,
    },
    FactualEntityType.misc: {
      'name': AttributeValueType.single,
      'description': AttributeValueType.single,
      'category': AttributeValueType.single,
    },
  };

  /// 各 attrKey 的默认重要性
  ///
  /// 关键属性（name）默认 importance=5，修改需高置信度。
  /// 描述性属性（personality/description/background）默认 importance=4。
  /// 其他属性默认 importance=3。
  static const Map<String, int> _defaultImportance = {
    'name': 5,
    'personality': 4,
    'description': 4,
    'background': 4,
    'skills': 3,
    'features': 3,
    'relationships': 3,
    'owner': 3,
    'category': 4,
    'leader': 3,
    'members': 3,
  };

  /// 各 attrKey 的中文友好标签（UI 展示用，DOC-11 §6.1）
  ///
  /// 与 [_schema] 结构一致，按 entityType -> {attrKey -> 中文标签}。
  /// 用于实体编辑界面下拉选择，让用户看到中文名称而非英文 attrKey。
  /// name 在不同实体类型下翻译不同（角色=姓名，物品=物品名，地点=地点名）。
  ///
  /// 2026-07-25 新增：配合实体编辑界面优化，属性键改为下拉选择。
  static const Map<FactualEntityType, Map<String, String>> _labels = {
    FactualEntityType.character: {
      'name': '姓名',
      'personality': '性格',
      'background': '背景',
      'relationships': '关系',
      'skills': '技能',
    },
    FactualEntityType.location: {
      'name': '地点名',
      'description': '描述',
      'features': '特征',
    },
    FactualEntityType.item: {
      'name': '物品名',
      'description': '描述',
      'owner': '所有者',
    },
    FactualEntityType.lore: {
      'name': '设定名',
      'description': '设定描述',
      'category': '分类',
    },
    FactualEntityType.organization: {
      'name': '组织名',
      'description': '组织描述',
      'leader': '首领',
      'members': '成员',
      'background': '背景',
    },
    FactualEntityType.misc: {
      'name': '名称',
      'description': '描述',
      'category': '分类',
    },
  };

  /// 属性键别名映射（用于兼容 LLM 产出的非标准字段）
  ///
  /// 某些模型（如 agnes-2.0-flash）不严格遵守 schema 白名单，会使用
  /// `description` 等非标准字段描述角色。本映射将这些别名自动
  /// 映射到标准字段，避免属性丢失。
  ///
  /// 映射原则：
  /// - character 无 description 字段，LLM 用的 description 映射到 background
  /// - location/item 已有 description 字段，无需映射
  ///
  /// 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）。
  static const Map<FactualEntityType, Map<String, String>> _attrKeyAliases = {
    FactualEntityType.character: {
      'description': 'background',
      'history': 'background',
    },
  };

  /// 检查 attrKey 是否在实体类型的 schema 白名单内
  ///
  /// character / lore 允许自定义属性名（核心属性在白名单内，其他自定义
  /// 属性也接受）。
  static bool isAttrKeyAllowed(
    FactualEntityType entityType,
    String attrKey,
  ) {
    if (entityType == FactualEntityType.character) {
      return attrKey.isNotEmpty;
    }
    if (entityType == FactualEntityType.lore) {
      // lore 放宽自定义键（对齐 character）——
      // 世界书条目是最需要自由扩展的实体类型（状态/下落/归属等）。
      return attrKey.isNotEmpty;
    }
    final schema = _schema[entityType];
    return schema != null && schema.containsKey(attrKey);
  }

  /// 将 LLM 产出的 attrKey 标准化
  ///
  /// 兼容非标准字段（如 `description` → `background`），用于适配不严格遵守
  /// schema 白名单的模型。调用流程：
  /// 1. 若 attrKey 已在白名单内，原样返回
  /// 2. 若 attrKey 是已知别名，返回对应的标准字段
  /// 3. 若 attrKey 未知，返回原值（后续 [isAttrKeyAllowed] 会拒绝）
  ///
  /// 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）。
  /// 2026-08-06 修订：别名检查优先于白名单检查，修复 character 的
  /// description 别名映射被自定义属性逻辑短路的问题。
  static String normalizeAttrKey(
    FactualEntityType entityType,
    String attrKey,
  ) {
    final alias = _attrKeyAliases[entityType]?[attrKey];
    if (alias != null) {
      return alias;
    }
    if (isAttrKeyAllowed(entityType, attrKey)) {
      return attrKey;
    }
    return attrKey;
  }

  /// 获取 attrKey 的 valueType
  ///
  /// 调用方需先通过 [isAttrKeyAllowed] 确认 attrKey 在白名单内。
  static AttributeValueType valueTypeOf(
    FactualEntityType entityType,
    String attrKey,
  ) {
    return _schema[entityType]?[attrKey] ?? AttributeValueType.single;
  }

  /// 裸 value 兜底键：delta 只带 value 不带 attrKey 时的默认描述属性
  ///
  /// 2026-08-23 新增（导演模式裸实体修复）：模型常把实体描述直接放进
  /// value 而省略 attrKey，原实现静默丢弃导致实体永远无属性。character
  /// 的 description 经 [_attrKeyAliases] 映射为 background，其余类型均为
  /// 白名单内的 description。
  static String fallbackDescriptionKey(FactualEntityType entityType) =>
      normalizeAttrKey(entityType, 'description');

  /// 获取 attrKey 的默认重要性
  static int defaultImportance(
    FactualEntityType entityType,
    String attrKey,
  ) {
    return _defaultImportance[attrKey] ?? 3;
  }

  /// 获取 attrKey 的中文友好标签
  ///
  /// 用于 UI 展示。若 attrKey 不在预定义白名单内（自定义属性），
  /// 返回 null，调用方可显示 attrKey 原文并标注"自定义"。
  ///
  /// 2026-07-25 新增：配合实体编辑界面优化。
  static String? labelFor(
    FactualEntityType entityType,
    String attrKey,
  ) {
    return _labels[entityType]?[attrKey];
  }

  /// 获取某实体类型的所有预定义 attrKey 列表
  ///
  /// 用于实体编辑界面的属性键下拉选择。返回顺序与 schema 定义顺序一致。
  ///
  /// 2026-07-25 新增：配合实体编辑界面优化。
  static List<String> attrKeysFor(FactualEntityType entityType) {
    final schema = _schema[entityType];
    if (schema == null) return const [];
    return schema.keys.toList();
  }
}
