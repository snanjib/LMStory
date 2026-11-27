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

  /// 按对象关系属性键前缀：`relationship:<对象名>`
  ///
  /// 与具体角色的关系各占一条 single 属性（update 维护完整当前描述，
  /// 历史可回溯）；群体/笼统关系（如「与师门众人交恶」）仍走通用
  /// relationships dict 属性。关系有方向（属性挂在陈述方实体上），
  /// 不自动推断对方对称。
  static const String relationshipKeyPrefix = 'relationship:';

  /// 解析按对象关系键中的对象名；非该前缀键返回 null
  static String? relationshipObjectOf(String attrKey) {
    if (!attrKey.startsWith(relationshipKeyPrefix)) return null;
    final object = attrKey.substring(relationshipKeyPrefix.length).trim();
    return object.isEmpty ? null : object;
  }

  /// 构造按对象关系键
  static String buildRelationshipAttrKey(String objectName) =>
      '$relationshipKeyPrefix$objectName';

  /// 获取 attrKey 的默认重要性
  static int defaultImportance(
    FactualEntityType entityType,
    String attrKey,
  ) {
    return _defaultImportance[attrKey] ?? 3;
  }

  /// 该键是否是此类实体的预定义属性。
  static bool isBuiltInAttrKey(
    FactualEntityType entityType,
    String attrKey,
  ) =>
      _schema[entityType]?.containsKey(attrKey) ?? false;

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
