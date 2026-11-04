import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';

/// 事实层 delta 干跑投影器（2026-10-15 监督审批前后对比，批 A）
///
/// 把 FactApplier 落库时的转写/跳过判定提取为**无副作用纯函数**：
/// 输入「库侧当前快照（实体 + 属性行 + 更新计数）+ delta + 配置」，
/// 输出该 delta 若此刻应用会发生什么（生效 / 转写 / 跳过 + 前后值）。
///
/// **单一真源约束**：FactApplier 的判定已改为委托本求值器——
/// 「审批横幅看到的 diff」与「finish_round 实际落库」必须同源，禁止
/// 在此复制 FactApplier 规则或在 FactApplier 旁路本求值器。
///
/// 领域中立：本文件属 memory feature，不 import advanced 层；人话文案
/// 由调用方（审批展示层）按 [FactsProjectionNote] 映射，此处不放 UI 字符串。
enum FactsProjectionOutcome {
  /// 正常生效（含新建属性行/新建实体）
  applied,

  /// 被防护机制跳过（不产生任何落库）
  skipped,

  /// 转写为其他动作（rewrittenDelta 携带转写后的 delta，需再投影一层）
  converted,
}

/// 判定原因（机器可读；UI 文案由展示层映射）
enum FactsProjectionNote {
  missingFields,
  unknownEntityType,
  entityMissing,
  nameIsIdentity,
  attrKeyNotWhitelisted,
  valueTooLong,
  tooFrequent,
  valueUnchangedBaseline,
  valueUnchanged,
  confidenceGate,
  listRejectsUpdate,
  baselineSingleRedirect,
  appendOnSingleConvertsUpdate,
  duplicateExact,
  duplicateSimilar,
  noMutableList,
  valueNotInList,
  aliasEmpty,
  aliasTooLong,
  aliasSameAsPrimary,
  aliasExists,
  aliasLimit,
  alreadyArchived,
  sameNameConvertsUpdate,
  sameNameConvertsAlias,
  createsAttrRow,
}

/// 单实体别名条数软上限（只读语义 2.0）
///
/// 原定义于 FactApplier（手动归并端同源消费）；投影器需要同一上限做
/// 干跑判定，真源移到本文件，FactApplier.kMaxAliasesPerEntity 转发引用
/// 保持既有 API 不变。
const int kFactsMaxAliasesPerEntity = 10;

/// 单条 delta 的干跑投影结果
class FactsDeltaProjection {
  const FactsDeltaProjection({
    required this.source,
    required this.effectiveAction,
    required this.outcome,
    required this.entityLabel,
    this.note,
    this.before,
    this.after,
    this.rewrittenDelta,
    this.normalizedAttrKey,
  });

  /// 原始 delta（LLM 意图，含 reason/confidence 证据链）
  final FactsDelta source;

  /// 实际生效动作：applied = 自身动作；converted = 转写后动作；
  /// skipped = 原意图动作（仅展示用）
  final FactAction effectiveAction;

  final FactsProjectionOutcome outcome;

  final FactsProjectionNote? note;

  /// 变更前值（applied 时；新建类为 null；list 类为旧 JSON 字符串）
  final String? before;

  /// 变更后值（applied 时；归档类为 null；append/remove 为单条目值）
  final String? after;

  /// converted 时的转写 delta（调用方以其再投影一层得到最终效果）
  final FactsDelta? rewrittenDelta;

  /// 归一化后的 attrKey（update/append/remove 类；含别名映射如
  /// character 的 description → background）
  final String? normalizedAttrKey;

  /// 实体定位名（展示用：目标实体主名，create 类为 delta.primaryName）
  final String entityLabel;

  /// 模型修改理由（透传 source.reason）
  String? get reason => source.reason;

  /// 模型置信度 1–5（透传 source.confidence）
  int get confidence => source.confidence;
}

/// 转写判定求值器（纯函数集）
///
/// 每个方法对应一种 FactAction 的落库判定链，判定顺序与 FactApplier
/// 落库路径严格一致（先查库构造快照，再调用求值器，最后按结果写库）。
abstract final class FactsDeltaProjectionEvaluator {
  /// update_attr 判定
  ///
  /// 快照输入：[entity] 目标实体（null=不存在）、[attrRows] 同
  /// (entityId, 归一化 attrKey) 的全部属性行、[recentUpdates] 最近 3 轮
  /// 该实体的更新计数（isCuration 时调用方可传 0，判定会豁免）。
  static FactsDeltaProjection evaluateUpdateAttr({
    required FactsDelta delta,
    required FactualConfig config,
    FactualEntity? entity,
    List<FactualAttribute> attrRows = const [],
    int recentUpdates = 0,
  }) {
    final label = entity?.primaryName ?? delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.updateAttr,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      return skipped(FactsProjectionNote.missingFields);
    }
    if (entity == null) return skipped(FactsProjectionNote.entityMissing);

    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);

    // 主名是身份标识不可被改名——统一转别名追加
    if (attrKey == 'name') {
      return FactsDeltaProjection(
        source: delta,
        effectiveAction: FactAction.addAlias,
        outcome: FactsProjectionOutcome.converted,
        entityLabel: label,
        note: FactsProjectionNote.nameIsIdentity,
        after: delta.value,
        rewrittenDelta: FactsDelta(
          action: FactAction.addAlias,
          entityId: delta.entityId,
          value: delta.value,
          confidence: delta.confidence,
        ),
        normalizedAttrKey: attrKey,
      );
    }

    // schema 白名单（整理型写入豁免）
    if (!delta.isCuration &&
        !AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      return skipped(FactsProjectionNote.attrKeyNotWhitelisted);
    }

    // 属性值长度上限
    if (delta.value!.length > config.maxAttrValueLength) {
      return skipped(FactsProjectionNote.valueTooLong);
    }

    // 更新频率限制（整理型写入豁免）
    if (!delta.isCuration && recentUpdates >= config.maxUpdatesPer3Turns) {
      return skipped(FactsProjectionNote.tooFrequent);
    }

    final attr = _autoRowOf(attrRows);

    // 只读基线不覆盖：无 auto 行且新值与只读基线值相同 → 跳过
    if (attr == null && attrRows.any((r) => r.value == delta.value)) {
      return skipped(FactsProjectionNote.valueUnchangedBaseline);
    }

    // 属性不存在（或只有只读基线）→ 新建可写演变行
    if (attr == null) {
      return FactsDeltaProjection(
        source: delta,
        effectiveAction: FactAction.updateAttr,
        outcome: FactsProjectionOutcome.applied,
        entityLabel: label,
        note: FactsProjectionNote.createsAttrRow,
        before: attrRows.isNotEmpty ? attrRows.first.value : null,
        after: delta.value,
        normalizedAttrKey: attrKey,
      );
    }

    // 值必须真的不同
    if (attr.value == delta.value) {
      return skipped(FactsProjectionNote.valueUnchanged);
    }

    // 关键属性置信度门（整理型写入豁免）
    if (!delta.isCuration &&
        attr.isKeyAttribute &&
        delta.confidence < config.modifyConfidenceThreshold) {
      return skipped(FactsProjectionNote.confidenceGate);
    }

    // list 类型不允许 update（应 append）
    if (attr.valueType == AttributeValueType.list) {
      return skipped(FactsProjectionNote.listRejectsUpdate);
    }

    return FactsDeltaProjection(
      source: delta,
      effectiveAction: FactAction.updateAttr,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
      before: attr.value,
      after: delta.value,
      normalizedAttrKey: attrKey,
    );
  }

  /// append_list 判定
  static FactsDeltaProjection evaluateAppendList({
    required FactsDelta delta,
    required FactualConfig config,
    FactualEntity? entity,
    List<FactualAttribute> attrRows = const [],
    int recentUpdates = 0,
  }) {
    final label = entity?.primaryName ?? delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.appendList,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      return skipped(FactsProjectionNote.missingFields);
    }
    if (entity == null) return skipped(FactsProjectionNote.entityMissing);

    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);

    // schema 白名单（整理型写入豁免）
    if (!delta.isCuration &&
        !AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      return skipped(FactsProjectionNote.attrKeyNotWhitelisted);
    }

    // 单值长度上限
    if (delta.value!.length > config.maxAttrValueLength) {
      return skipped(FactsProjectionNote.valueTooLong);
    }

    FactsDeltaProjection converted(
      FactsProjectionNote note, {
      String? attrKeyOverride,
    }) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.updateAttr,
          outcome: FactsProjectionOutcome.converted,
          entityLabel: label,
          note: note,
          after: delta.value,
          rewrittenDelta: FactsDelta(
            action: FactAction.updateAttr,
            entityId: delta.entityId,
            attrKey: attrKeyOverride ?? attrKey,
            value: delta.value,
            reason: delta.reason,
            confidence: delta.confidence,
            isCuration: delta.isCuration,
          ),
          normalizedAttrKey: attrKey,
        );

    final attr = _autoRowOf(attrRows);

    if (attr == null) {
      // 只读基线为 single 类型 → 重定向 update_attr（写 auto 演变行）
      final baselineSingle = attrRows.any(
        (r) =>
            r.source != FactualSource.auto &&
            r.valueType == AttributeValueType.single,
      );
      if (baselineSingle) {
        return converted(FactsProjectionNote.baselineSingleRedirect);
      }
      // 无任何属性行 → 新建 list 属性
      return FactsDeltaProjection(
        source: delta,
        effectiveAction: FactAction.appendList,
        outcome: FactsProjectionOutcome.applied,
        entityLabel: label,
        note: FactsProjectionNote.createsAttrRow,
        after: delta.value,
        normalizedAttrKey: attrKey,
      );
    }

    // auto 行为 single 类型 → 转 update_attr（覆盖）
    if (attr.valueType == AttributeValueType.single) {
      return converted(FactsProjectionNote.appendOnSingleConvertsUpdate);
    }

    final list = attr.listValue;

    // 精确去重
    if (list.contains(delta.value)) {
      return skipped(FactsProjectionNote.duplicateExact);
    }

    // 语义相似度去重（编辑距离/包含关系，不调 embedding）
    if (isSemanticallySimilarValue(delta.value!, list)) {
      return skipped(FactsProjectionNote.duplicateSimilar);
    }

    return FactsDeltaProjection(
      source: delta,
      effectiveAction: FactAction.appendList,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
      before: attr.value,
      after: delta.value,
      normalizedAttrKey: attrKey,
    );
  }

  /// remove_from_list 判定（注意：白名单检查无 isCuration 豁免，
  /// 与 FactApplier 落库路径一致）
  static FactsDeltaProjection evaluateRemoveFromList({
    required FactsDelta delta,
    FactualEntity? entity,
    List<FactualAttribute> attrRows = const [],
  }) {
    final label = entity?.primaryName ?? delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.removeFromList,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      return skipped(FactsProjectionNote.missingFields);
    }
    if (entity == null) return skipped(FactsProjectionNote.entityMissing);

    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);

    if (!AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      return skipped(FactsProjectionNote.attrKeyNotWhitelisted);
    }

    final attr = _autoRowOf(attrRows);
    // 只读基线不可移除：无 auto 行或非 list 类型 → 跳过
    if (attr == null || attr.valueType != AttributeValueType.list) {
      return skipped(FactsProjectionNote.noMutableList);
    }

    final list = attr.listValue;
    if (!list.contains(delta.value)) {
      return skipped(FactsProjectionNote.valueNotInList);
    }

    return FactsDeltaProjection(
      source: delta,
      effectiveAction: FactAction.removeFromList,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
      before: attr.value,
      after: delta.value,
      normalizedAttrKey: attrKey,
    );
  }

  /// add_alias 判定
  static FactsDeltaProjection evaluateAddAlias({
    required FactsDelta delta,
    required FactualConfig config,
    FactualEntity? entity,
  }) {
    final label = entity?.primaryName ?? delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.addAlias,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityId == null || delta.value == null) {
      return skipped(FactsProjectionNote.missingFields);
    }

    final alias = delta.value!.trim();
    if (alias.isEmpty) return skipped(FactsProjectionNote.aliasEmpty);
    if (alias.length > config.maxAttrValueLength) {
      return skipped(FactsProjectionNote.aliasTooLong);
    }

    if (entity == null) return skipped(FactsProjectionNote.entityMissing);
    if (entity.primaryName == alias) {
      return skipped(FactsProjectionNote.aliasSameAsPrimary);
    }
    if (entity.aliases.contains(alias)) {
      return skipped(FactsProjectionNote.aliasExists);
    }
    if (entity.aliases.length >= kFactsMaxAliasesPerEntity) {
      return skipped(FactsProjectionNote.aliasLimit);
    }

    return FactsDeltaProjection(
      source: delta,
      effectiveAction: FactAction.addAlias,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
      after: alias,
    );
  }

  /// archive_entity 判定
  static FactsDeltaProjection evaluateArchiveEntity({
    required FactsDelta delta,
    FactualEntity? entity,
  }) {
    final label = entity?.primaryName ?? delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.archiveEntity,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityId == null) {
      return skipped(FactsProjectionNote.missingFields);
    }
    if (entity == null) return skipped(FactsProjectionNote.entityMissing);
    if (entity.isArchived) return skipped(FactsProjectionNote.alreadyArchived);

    return FactsDeltaProjection(
      source: delta,
      effectiveAction: FactAction.archiveEntity,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
    );
  }

  /// create_entity 判定
  ///
  /// 快照输入：[sameNameEntity] 按 delta.primaryName 精确查名的命中实体
  /// （null=未撞名）。
  static FactsDeltaProjection evaluateCreateEntity({
    required FactsDelta delta,
    required FactualConfig config,
    FactualEntity? sameNameEntity,
  }) {
    const action = FactAction.createEntity;
    final label = delta.primaryName ?? '';
    FactsDeltaProjection skipped(FactsProjectionNote note) =>
        FactsDeltaProjection(
          source: delta,
          effectiveAction: action,
          outcome: FactsProjectionOutcome.skipped,
          entityLabel: label,
          note: note,
        );

    if (delta.entityType == null || delta.primaryName == null) {
      return skipped(FactsProjectionNote.missingFields);
    }
    if (_parseEntityType(delta.entityType!) == null) {
      return skipped(FactsProjectionNote.unknownEntityType);
    }

    if (sameNameEntity != null) {
      // 撞名 + 携带 value → 转 update_attr（保留 LLM 想更新的属性信息）
      if (delta.value != null) {
        final entityType = _parseEntityType(delta.entityType!)!;
        // 与 FactApplier 落库同式：value 非空保证 normalizedAttrKey 恒非 null
        //（attrKey 缺失时按 delta 类型补默认描述键），fallback 到既有实体
        // 类型的分支实际不可达，保留防御性 ??。
        final normalizedAttrKey = delta.attrKey != null
            ? AttributeSchema.normalizeAttrKey(entityType, delta.attrKey!)
            : delta.value != null
                ? AttributeSchema.fallbackDescriptionKey(entityType)
                : null;
        final attrKey = normalizedAttrKey ??
            AttributeSchema.fallbackDescriptionKey(sameNameEntity.type);
        return FactsDeltaProjection(
          source: delta,
          effectiveAction: FactAction.updateAttr,
          outcome: FactsProjectionOutcome.converted,
          entityLabel: sameNameEntity.primaryName,
          note: FactsProjectionNote.sameNameConvertsUpdate,
          after: delta.value,
          rewrittenDelta: FactsDelta(
            action: FactAction.updateAttr,
            entityId: sameNameEntity.entityId,
            attrKey: attrKey,
            value: delta.value,
            reason: delta.reason,
            confidence: delta.confidence,
          ),
          normalizedAttrKey: attrKey,
        );
      }
      // 撞名 + 无 value → 转 add_alias
      return FactsDeltaProjection(
        source: delta,
        effectiveAction: FactAction.addAlias,
        outcome: FactsProjectionOutcome.converted,
        entityLabel: sameNameEntity.primaryName,
        note: FactsProjectionNote.sameNameConvertsAlias,
        after: delta.primaryName,
        rewrittenDelta: FactsDelta(
          action: FactAction.addAlias,
          entityId: sameNameEntity.entityId,
          value: delta.primaryName,
          confidence: delta.confidence,
        ),
      );
    }

    // 正常新建（before=null；首批属性键见 normalizedAttrKey）。
    // 「新」行展示首批属性值（title 已含实体名·属性键，重报名字是冗余）；
    // 裸创建（无 value）无属性可展示，after=null 只出名字行卡。
    final entityType = _parseEntityType(delta.entityType!)!;
    final normalizedAttrKey = delta.attrKey != null
        ? AttributeSchema.normalizeAttrKey(entityType, delta.attrKey!)
        : delta.value != null
            ? AttributeSchema.fallbackDescriptionKey(entityType)
            : null;
    return FactsDeltaProjection(
      source: delta,
      effectiveAction: action,
      outcome: FactsProjectionOutcome.applied,
      entityLabel: label,
      after: delta.value,
      normalizedAttrKey: normalizedAttrKey,
    );
  }

  /// 取同 (entityId, attrKey) 属性行中的可写 auto 行（无则 null）
  ///
  /// DOC-15 §8.1 方案 A：同 attrKey 可并存「只读基线（source=card）+
  /// 可写演变（source=auto）」，只写 auto 行绝不覆盖基线。
  static FactualAttribute? _autoRowOf(List<FactualAttribute> rows) {
    for (final row in rows) {
      if (row.source == FactualSource.auto) return row;
    }
    return null;
  }

  static FactualEntityType? _parseEntityType(String value) {
    try {
      return FactualEntityType.fromString(value);
    } catch (_) {
      return null;
    }
  }
}

/// 语义相似度判定（DOC-11 §7.4.4）：编辑距离 <= 2 或包含关系，
/// **不调 embedding API**。append_list 去重用（FactApplier 与投影器同源）。
bool isSemanticallySimilarValue(String newValue, List<String> existing) {
  for (final v in existing) {
    if (_editDistance(newValue, v) <= 2) return true;
    if (v.contains(newValue) || newValue.contains(v)) return true;
  }
  return false;
}

/// Levenshtein 编辑距离
int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  final matrix = List.generate(
    a.length + 1,
    (_) => List.filled(b.length + 1, 0),
  );
  for (var i = 0; i <= a.length; i++) {
    matrix[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    matrix[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      matrix[i][j] = [
        matrix[i - 1][j] + 1, // 删除
        matrix[i][j - 1] + 1, // 插入
        matrix[i - 1][j - 1] + cost, // 替换
      ].reduce((x, y) => x < y ? x : y);
    }
  }
  return matrix[a.length][b.length];
}
