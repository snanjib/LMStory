import 'dart:convert';

import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart'
    show StoryPersistenceService;
import 'package:uuid/uuid.dart';

// AttributeSchema 已拆至 attribute_schema.dart（2026-10-15，投影器同源
// 消费）；export 保持既有 `import fact_applier.dart` 引用路径不变。
export 'package:lmstory/features/memory/domain/services/attribute_schema.dart';

/// 事实变更应用服务（DOC-11 §7、§11.2）
///
/// 中级模式 Domain 层服务，负责将 summarizing 阶段 LLM 产出的
/// [FactsDelta] 列表应用到事实层数据库。
///
/// **职责边界**：
/// - 本服务含业务逻辑（三重防护 + 5 层健康度防护 + 消歧）
/// - 数据存取通过 [FactualRepository] 接口（依赖倒置）
/// - 不直接操作 drift，事务由外层 StoryPersistenceService 管理
///
/// **三重防护机制**（DOC-11 §7.1）：
/// 1. 提示词约束（在 `kExtractFactsToolPrompt` 中）
/// 2. 冲突检测（本服务实现：检测 key 是否已存在 + 值是否真的不同）
/// 3. 重要性阈值（本服务实现：importance>=4 的关键属性 confidence>=4 才允许修改）
///
/// **5 层健康度防护**（DOC-11 §7.4）：
/// 1. 属性 schema 白名单（[AttributeSchema] 类）
/// 2. 提示词约束（在 `kExtractFactsToolPrompt` 中）
/// 3. 系统级去重（本服务实现：精确+语义相似度）
/// 4. 更新频率限制（本服务实现：3 轮 4 次）
/// 5. 属性值长度上限（本服务实现：500 字）
///
/// **事务原子性**（DOC-11 §7.3，2026-07-22 修订）：
/// 本服务的 [applyDeltas] 方法**不开自身事务**，由调用方
/// （StoryPersistenceService）在 drift transaction 内调用。
/// **单变更容错**：单个 delta 抛异常时记录日志并跳过，不向上传播，
/// 不再导致整轮事务回滚。经历记忆始终能写入。
///
/// 修订原因：原设计要求任一 delta 失败则整轮回滚，但实际使用中 LLM
/// 输出的 FactsDelta 格式问题频发，整轮回滚导致经历记忆也无法写入，
/// 用户表现为"新对话记忆库一直为空"。现改为单变更容错，牺牲少量
/// 原子性换取可用性——事实层部分成功的 delta 仍保留，失败的 delta
/// 记录日志供后续排查。
class FactApplier {
  FactApplier({required FactualRepository repository, Uuid? uuidGenerator})
      : _repository = repository,
        _uuid = uuidGenerator ?? const Uuid();

  final FactualRepository _repository;
  final Uuid _uuid;
  final _logger = const Logger('FactApplier');

  /// 批量应用事实变更
  ///
  /// [sessionId] 当前会话 ID
  /// [deltas] LLM 产出的 FactsDelta 列表
  /// [turnNumber] 当前轮次号（用于审计记录和更新频率限制）
  /// [config] 事实层配置（控制防护阈值）
  ///
  /// 返回成功应用的变更展示记录列表（[FactsChangeRecord]），携带实体名 /
  /// 类型 / 属性名（来自 delta）与变更前 / 变更后（来自审计记录）。被防护
  /// 机制跳过或抛异常的 delta 不计入返回列表。
  ///
  /// 该列表由调用方（StoryPersistenceService）写入
  /// `intermediate_round_artifacts.factsChanges`，供「事实层变更小窗」展示。
  ///
  /// **单变更容错**（2026-07-22 修订）：
  /// 每个 delta 独立 try-catch，单个 delta 抛异常时记录日志并跳过，
  /// 不影响其他 delta 的应用，也不向上传播异常。
  /// 这样事实层某个变更失败不会导致整轮事务回滚（经历记忆始终能写入）。
  Future<List<FactsChangeRecord>> applyDeltas(
    String sessionId,
    List<FactsDelta> deltas,
    int turnNumber,
    FactualConfig config,
  ) async {
    if (!config.enabled || deltas.isEmpty) return const [];

    final applied = <FactsChangeRecord>[];
    for (final delta in deltas) {
      try {
        final resolved = await _resolveDeltaEntityId(sessionId, delta);
        if (resolved == null) continue;
        final history = await _applySingleDelta(
          sessionId,
          resolved,
          turnNumber,
          config,
        );
        if (history != null) {
          applied.add(_buildChangeRecord(delta, history));
        }
      } catch (e, stack) {
        _logger.error(
          'Failed to apply single delta, skipping',
          detail: 'action=${delta.action}, entityId=${delta.entityId}, '
              'attrKey=${delta.attrKey}, error=${e.runtimeType}: $e',
          error: e,
          stackTrace: stack,
        );
      }
    }
    return applied;
  }

  /// 非创建动作缺 entityId 时的按名定位兜底
  ///
  /// 导演模式没有故事模式的 {{known_entities}} 通道，模型常拿 primary_name
  /// 定位既有实体发起 update_attr 等修改。原实现硬性要求 entityId，这类
  /// delta 全部被静默跳过。现按主名（含别名）查找：唯一命中回填 entityId，
  /// 未命中或歧义命中返回 null 跳过该条（findByName 的匹配含只读实体，
  /// 后续各动作按属性级只读基线语义处理写入）。
  ///
  /// 精确名未命中时补一层主表子串兜底（≥2 字
  /// 才启用，避免"剑"这类单字误配），且仅在**唯一命中**时采用——多命中
  /// 仍判歧义跳过，不猜。
  Future<FactsDelta?> _resolveDeltaEntityId(
    String sessionId,
    FactsDelta delta,
  ) async {
    if (delta.entityId != null || delta.primaryName == null) return delta;
    if (delta.action == FactAction.createEntity) return delta;

    final name = delta.primaryName!.trim();
    if (name.isEmpty) return null;
    var matches = await _repository.findByName(sessionId, [name]);
    if (matches.isEmpty && name.runes.length >= 2) {
      final textMatches = await _repository.searchEntitiesByText(
        sessionId,
        [name],
        limit: 5,
      );
      if (textMatches.length == 1) matches = textMatches;
    }
    if (matches.length == 1) {
      return FactsDelta(
        action: delta.action,
        confidence: delta.confidence,
        entityId: matches.first.entityId,
        entityType: delta.entityType,
        primaryName: delta.primaryName,
        attrKey: delta.attrKey,
        value: delta.value,
        reason: delta.reason,
        importance: delta.importance,
        isCuration: delta.isCuration,
      );
    }
    _logger.warn(
      'Cannot resolve entity by primary_name, skipping delta',
      detail: 'action=${delta.action.name}, '
          'primaryName=${delta.primaryName}, matches=${matches.length}',
    );
    return null;
  }

  /// 删除指定轮次及下游的事实层数据（覆盖式重写场景）
  ///
  /// 供 [StoryPersistenceService.deleteRoundAndDownstream] 在外层
  /// drift transaction 内调用，保证事实层与经历层/消息层原子性一致。
  ///
  /// - 删除 createdTurn >= [fromTurn] 的实体（及其属性 + 历史）
  /// - 删除当前会话内 turnNumber >= [fromTurn] 的历史记录
  /// - 非待删实体的属性保留当前值（由新轮次 factsDeltas 覆盖）
  Future<void> deleteFactsByTurns({
    required String sessionId,
    required int fromTurn,
  }) async {
    await _repository.deleteFactsByTurns(
      sessionId: sessionId,
      fromTurn: fromTurn,
    );
  }

  /// 应用单个 delta
  ///
  /// 返回成功应用时写入的审计记录（[FactualMemoryHistory]），null 表示被
  /// 防护机制跳过。抛出异常表示硬错误（如数据库约束冲突），由 [applyDeltas]
  /// 捕获并记录日志后跳过，不再导致事务回滚。
  Future<FactualMemoryHistory?> _applySingleDelta(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    switch (delta.action) {
      case FactAction.createEntity:
        return _applyCreateEntity(sessionId, delta, turnNumber, config);
      case FactAction.updateAttr:
        return _applyUpdateAttr(sessionId, delta, turnNumber, config);
      case FactAction.appendList:
        return _applyAppendList(sessionId, delta, turnNumber, config);
      case FactAction.removeFromList:
        return _applyRemoveFromList(sessionId, delta, turnNumber, config);
      case FactAction.addAlias:
        return _applyAddAlias(sessionId, delta, turnNumber, config);
      case FactAction.archiveEntity:
        return _applyArchiveEntity(sessionId, delta, turnNumber);
    }
  }

  // ==================== 各动作应用 ====================

  /// 应用 create_entity 动作
  ///
  /// 防护：检查 primaryName 是否已存在（防重复创建）
  /// - 已存在同名实体 + 携带 value → 转为 update_attr（2026-07-22 修复，
  ///   2026-08-23 放宽为 value 兜底：attrKey 缺失时按类型补默认描述键）
  /// - 已存在同名实体 + 无 value → 改为 addAlias（DOC-11 §10.3）
  /// - 不存在 → 创建新实体（value 无 attrKey 时兜底落默认描述键）
  ///
  /// 2026-07-22 修复：原实现实体已存在时一律转 add_alias，丢弃了 LLM 通过
  /// create_entity 携带的 attrKey + value 信息。当 LLM 因 {{known_entities}}
  /// 占位符未替换而不知道 entityId 时，会尝试用 create_entity 给已存在实体
  /// 加属性，原逻辑直接丢弃属性信息，导致 factual_attributes 表永远无新记录。
  /// 现修改为：实体已存在且携带 attrKey + value 时，转为 update_attr 更新属性。
  Future<FactualMemoryHistory?> _applyCreateEntity(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    // 撞名检测（防护：primaryName 已存在时走转换分支）
    final existing = (delta.primaryName == null)
        ? const <FactualEntity>[]
        : await _repository.findByName(sessionId, [delta.primaryName!]);

    final verdict = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
      delta: delta,
      config: config,
      sameNameEntity: existing.isNotEmpty ? existing.first : null,
    );

    switch (verdict.outcome) {
      case FactsProjectionOutcome.skipped:
        _logger.warn(
          'create_entity skipped by guard',
          detail: 'note=${verdict.note?.name}, '
              'entityType=${delta.entityType}, '
              'primaryName=${delta.primaryName}',
        );
        return null;
      case FactsProjectionOutcome.converted:
        final existingEntity = existing.first;
        // 撞名导入实体（worldbook/card）走统一转换（演变/别名），不转 create
        //（2026-09-14 只读语义 2.0：世界书与角色卡同为属性级只读基线）。
        final rewritten = verdict.rewrittenDelta!;
        if (rewritten.action == FactAction.updateAttr) {
          _logger.info(
            'Entity already exists, converting to update_attr',
            detail: 'primaryName=${delta.primaryName}, '
                'existingEntityId=${existingEntity.entityId}, '
                'attrKey=${delta.attrKey} → ${rewritten.attrKey}',
          );
          return _applyUpdateAttr(sessionId, rewritten, turnNumber, config);
        }
        _logger.info(
          'Entity already exists, converting to add_alias',
          detail: 'primaryName=${delta.primaryName}, '
              'existingEntityId=${existingEntity.entityId}',
        );
        return _applyAddAlias(sessionId, rewritten, turnNumber, config);
      case FactsProjectionOutcome.applied:
        break;
    }

    final entityType = _parseEntityType(delta.entityType!)!;

    // 标准化 attrKey（兼容 LLM 产出的非标准字段，如 description → background）
    // 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）
    //
    // 裸 value 兜底：模型常把实体描述
    // 放进 value 而不带 attrKey，原实现静默丢弃导致记忆库实体永远无属性。
    // 有 value 无 attrKey 时按类型补默认描述键（character→background，
    // 其余→description），属性照常落库。
    final normalizedAttrKey = delta.attrKey != null
        ? AttributeSchema.normalizeAttrKey(entityType, delta.attrKey!)
        : delta.value != null
            ? AttributeSchema.fallbackDescriptionKey(entityType)
            : null;

    // 相似名告警（只告警不转换）：精确查重未命中时，检测包含关系候选
    // （如"庄园"⊂"边境庄园"）。抽取提示词已有去重规则但属软约束，且低
    // 重要度实体不进已知实体列表，重复创建仍会发生；此处让重复可观测。
    // 是否归并由人工（记忆查看器合并）或导演模式 merge_entities 工具决策，
    // 不做自动合并——中文短名包含关系存在误判空间（"剑"≠"断水剑"）。
    await _warnIfSimilarNameExists(sessionId, delta.primaryName!);

    // 创建新实体
    final entityId = _generateEntityId();
    final now = DateTime.now();
    // importance 优先使用 LLM 评分，未提供时按类型赋保守默认值
    final importance = delta.importance != null
        ? delta.importance!.clamp(1, 5)
        : _defaultImportanceForType(entityType);
    final entity = FactualEntity(
      entityId: entityId,
      sessionId: sessionId,
      type: entityType,
      primaryName: delta.primaryName!,
      aliases: const [],
      importance: importance,
      createdTurn: turnNumber,
      createdAt: now,
    );
    await _repository.createEntity(entity);

    // 同时初始化属性（delta 带 attrKey + value，或裸 value 兜底默认描述键）
    if (normalizedAttrKey != null && delta.value != null) {
      await _createAttributeForEntity(
        entityId: entityId,
        sessionId: sessionId,
        entityType: entityType,
        attrKey: normalizedAttrKey,
        value: delta.value!,
        turnNumber: turnNumber,
        now: now,
      );
    }

    // 写审计日志
    final history = FactualMemoryHistory(
      entityId: entityId,
      action: FactAction.createEntity,
      newValue: delta.primaryName,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: now,
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 应用 update_attr 动作
  ///
  /// 三重防护：
  /// 1. 实体必须存在
  /// 2. 值必须真的不同
  /// 3. 关键属性（importance>=4）需要 confidence>=4
  ///
  /// 5 层健康度防护：
  /// - schema 白名单检查
  /// - 属性值长度上限
  /// - 更新频率限制
  Future<FactualMemoryHistory?> _applyUpdateAttr(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      _logger.warn(
        'update_attr missing required fields, skipping',
        detail: 'entityId=${delta.entityId}, attrKey=${delta.attrKey}',
      );
      return null;
    }

    final entity = await _repository.getEntityById(delta.entityId!);
    if (entity == null) {
      _logger.warn(
        'Entity not found, skipping update_attr',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    // 标准化 attrKey（兼容 LLM 产出的非标准字段，如 description → background）
    // 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）
    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);
    if (attrKey != delta.attrKey) {
      _logger.info(
        'attrKey normalized',
        detail: 'entityType=${entity.type.name}, '
            'original=${delta.attrKey} → normalized=$attrKey',
      );
    }

    // 查库构造判定快照（与干跑投影器同一输入 → 看到的判定 = 落库判定）
    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );
    final recentUpdates = delta.isCuration
        ? 0
        : await _repository.countRecentUpdates(
            delta.entityId!,
            fromTurn: turnNumber - 2, // 最近 3 轮（含本轮）
          );

    final verdict = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
      delta: delta,
      config: config,
      entity: entity,
      attrRows: rows,
      recentUpdates: recentUpdates,
    );

    switch (verdict.outcome) {
      case FactsProjectionOutcome.skipped:
        _logger.warn(
          'update_attr skipped by guard',
          detail: 'note=${verdict.note?.name}, '
              'entityId=${delta.entityId}, attrKey=$attrKey',
        );
        return null;
      case FactsProjectionOutcome.converted:
        // name 是身份标识 → 转别名追加（判定与日志见原分支）
        _logger.info(
          'rename on imported entity, converting to add_alias',
          detail: 'entityId=${delta.entityId}, source=${entity.source.name}',
        );
        return _applyAddAlias(
          sessionId,
          verdict.rewrittenDelta!,
          turnNumber,
          config,
        );
      case FactsProjectionOutcome.applied:
        break;
    }

    final attr = _autoRowOf(rows);

    // 属性不存在（或只有只读基线）→ 创建新 auto 属性（基线不覆盖，DOC-15 §8.1）
    if (attr == null) {
      final createdAttrId = await _createAttributeForEntity(
        entityId: delta.entityId!,
        sessionId: sessionId,
        entityType: entity.type,
        attrKey: attrKey,
        value: delta.value!,
        turnNumber: turnNumber,
        now: DateTime.now(),
        updateReason: delta.reason,
        skipWhitelist: delta.isCuration,
      );
      // 只读语义 2.0：世界书实体新建演变 description 行后，
      // 重建该实体的 factual_fts 行（：统一走 repository 单点重建，
      // 取值口径与 memory_fts_rebuilder 对齐——基线行存在时取基线）。
      if (createdAttrId != null &&
          entity.source == FactualSource.worldbook &&
          attrKey == 'description') {
        await _repository.rebuildEntityFts(delta.entityId!);
      }
      final history = FactualMemoryHistory(
        entityId: delta.entityId!,
        attributeId: createdAttrId,
        action: FactAction.updateAttr,
        newValue: delta.value,
        reason: delta.reason,
        confidence: delta.confidence,
        turnNumber: turnNumber,
        createdAt: DateTime.now(),
      );
      await _repository.insertHistory(history);
      return history;
    }

    final oldValue = attr.value;
    await _repository.updateAttributeValue(
      attr.attributeId,
      delta.value!,
      turnNumber,
      delta.reason,
    );

    // 原地更新已有 description 行（世界书
    // 实体的演变行改值）后同步 factual_fts——此前同步只覆盖「新建」路径，
    // 索引留旧值导致 lore 触发按已改掉的文本召回。
    if (entity.source == FactualSource.worldbook && attrKey == 'description') {
      await _repository.rebuildEntityFts(delta.entityId!);
    }

    // 写审计日志
    final history = FactualMemoryHistory(
      entityId: delta.entityId!,
      attributeId: attr.attributeId,
      action: FactAction.updateAttr,
      oldValue: oldValue,
      newValue: delta.value,
      reason: delta.reason,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: DateTime.now(),
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 应用 append_list 动作
  ///
  /// 防护：
  /// - schema 白名单检查（必须是 list 类型）
  /// - single 类型收到 append_list 自动转为 update_attr（覆盖）
  /// - 精确去重 + 语义相似度去重
  Future<FactualMemoryHistory?> _applyAppendList(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      _logger.warn(
        'append_list missing required fields, skipping',
        detail: 'entityId=${delta.entityId}, attrKey=${delta.attrKey}',
      );
      return null;
    }

    final entity = await _repository.getEntityById(delta.entityId!);
    if (entity == null) {
      _logger.warn(
        'Entity not found, skipping append_list',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    // 标准化 attrKey（兼容 LLM 产出的非标准字段，如 description → background）
    // 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）
    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);
    if (attrKey != delta.attrKey) {
      _logger.info(
        'attrKey normalized',
        detail: 'entityType=${entity.type.name}, '
            'original=${delta.attrKey} → normalized=$attrKey',
      );
    }

    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );

    final verdict = FactsDeltaProjectionEvaluator.evaluateAppendList(
      delta: delta,
      config: config,
      entity: entity,
      attrRows: rows,
    );

    if (verdict.outcome == FactsProjectionOutcome.skipped) {
      _logger.warn(
        'append_list skipped by guard',
        detail: 'note=${verdict.note?.name}, '
            'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
    }
    if (verdict.outcome == FactsProjectionOutcome.converted) {
      _logger.info(
        'Converting append_list to update_attr',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey, '
            'note=${verdict.note?.name}',
      );
      return _applyUpdateAttr(
        sessionId,
        verdict.rewrittenDelta!,
        turnNumber,
        config,
      );
    }

    final attr = _autoRowOf(rows);

    // 属性不存在 → 创建新属性（list 类型）
    if (attr == null) {
      final now = DateTime.now();
      final newAttr = FactualAttribute(
        attributeId: _generateAttributeId(),
        entityId: delta.entityId!,
        sessionId: sessionId,
        attrKey: attrKey,
        value: jsonEncode([delta.value]),
        valueType: AttributeValueType.list,
        importance: AttributeSchema.defaultImportance(
          entity.type,
          attrKey,
        ),
        createdAt: now,
        updatedAt: now,
        updatedTurn: turnNumber,
        updateReason: delta.reason,
      );
      await _repository.createAttribute(newAttr);
      final history = FactualMemoryHistory(
        entityId: delta.entityId!,
        attributeId: newAttr.attributeId,
        action: FactAction.appendList,
        newValue: delta.value,
        reason: delta.reason,
        confidence: delta.confidence,
        turnNumber: turnNumber,
        createdAt: now,
      );
      await _repository.insertHistory(history);
      return history;
    }

    // list 类型：精确/语义去重由求值器判定（applied 才会到这里）
    final list = attr.listValue;
    final newList = [...list, delta.value!];
    final newValue = jsonEncode(newList);
    final oldValue = attr.value;
    await _repository.updateAttributeValue(
      attr.attributeId,
      newValue,
      turnNumber,
      delta.reason,
    );

    final history = FactualMemoryHistory(
      entityId: delta.entityId!,
      attributeId: attr.attributeId,
      action: FactAction.appendList,
      oldValue: oldValue,
      newValue: delta.value,
      reason: delta.reason,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: DateTime.now(),
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 应用 remove_from_list 动作
  Future<FactualMemoryHistory?> _applyRemoveFromList(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    if (delta.entityId == null ||
        delta.attrKey == null ||
        delta.value == null) {
      _logger.warn(
        'remove_from_list missing required fields, skipping',
        detail: 'entityId=${delta.entityId}, attrKey=${delta.attrKey}',
      );
      return null;
    }

    final entity = await _repository.getEntityById(delta.entityId!);
    if (entity == null) return null;

    // 标准化 attrKey（兼容 LLM 产出的非标准字段，如 description → background）
    // 2026-07-26 新增：模型适配兼容（DOC-11 §7.4.2 修订）
    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);
    if (attrKey != delta.attrKey) {
      _logger.info(
        'attrKey normalized',
        detail: 'entityType=${entity.type.name}, '
            'original=${delta.attrKey} → normalized=$attrKey',
      );
    }

    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );

    final verdict = FactsDeltaProjectionEvaluator.evaluateRemoveFromList(
      delta: delta,
      entity: entity,
      attrRows: rows,
    );
    if (verdict.outcome != FactsProjectionOutcome.applied) {
      _logger.warn(
        'remove_from_list skipped by guard',
        detail: 'note=${verdict.note?.name}, '
            'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
    }

    final attr = _autoRowOf(rows)!;
    final list = attr.listValue;
    final newList = list.where((v) => v != delta.value).toList();
    final newValue = jsonEncode(newList);
    final oldValue = attr.value;
    await _repository.updateAttributeValue(
      attr.attributeId,
      newValue,
      turnNumber,
      delta.reason,
    );

    final history = FactualMemoryHistory(
      entityId: delta.entityId!,
      attributeId: attr.attributeId,
      action: FactAction.removeFromList,
      oldValue: oldValue,
      newValue: delta.value,
      reason: delta.reason,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: DateTime.now(),
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 单实体别名条数软上限：只读语义 2.0
  /// 把「对导入实体改名」转为高频合法动作（每轮换称呼都累积一条），无上限
  /// 通道会让 known_entities 行持续膨胀。超限静默跳过，与同文件守卫口径一致。
  ///
  /// 公开共享：记忆查看器手动归并的别名并集
  /// （factual_memory_tab._applyMergePlan）用同一上限——两入口防线同源，
  /// 防口径漂移。2026-10-15 起真源在投影器（干跑判定同限），此处转发。
  static const int kMaxAliasesPerEntity = kFactsMaxAliasesPerEntity;

  /// 应用 add_alias 动作
  Future<FactualMemoryHistory?> _applyAddAlias(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    final entity0 = delta.entityId == null
        ? null
        : await _repository.getEntityById(delta.entityId!);

    final verdict = FactsDeltaProjectionEvaluator.evaluateAddAlias(
      delta: delta,
      config: config,
      entity: entity0,
    );
    if (verdict.outcome != FactsProjectionOutcome.applied) {
      _logger.warn(
        'add_alias skipped by guard',
        detail: 'note=${verdict.note?.name}, entityId=${delta.entityId}',
      );
      return null;
    }
    final entity = entity0!;
    final alias = delta.value!.trim();
    final newAliases = [...entity.aliases, alias];
    await _repository.updateEntityAliases(
      delta.entityId!,
      newAliases,
      turnNumber,
    );

    final history = FactualMemoryHistory(
      entityId: delta.entityId!,
      action: FactAction.addAlias,
      newValue: alias,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: DateTime.now(),
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 应用 archive_entity 动作
  Future<FactualMemoryHistory?> _applyArchiveEntity(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
  ) async {
    final entity = delta.entityId == null
        ? null
        : await _repository.getEntityById(delta.entityId!);

    final verdict = FactsDeltaProjectionEvaluator.evaluateArchiveEntity(
      delta: delta,
      entity: entity,
    );
    if (verdict.outcome != FactsProjectionOutcome.applied) {
      _logger.warn(
        'archive_entity skipped by guard',
        detail: 'note=${verdict.note?.name}, entityId=${delta.entityId}',
      );
      return null;
    }

    await _repository.archiveEntity(
      delta.entityId!,
      delta.reason ?? 'unknown',
      turnNumber,
    );

    final history = FactualMemoryHistory(
      entityId: delta.entityId!,
      action: FactAction.archiveEntity,
      reason: delta.reason,
      confidence: delta.confidence,
      turnNumber: turnNumber,
      createdAt: DateTime.now(),
    );
    await _repository.insertHistory(history);
    return history;
  }

  /// 将原始 [FactsDelta]（LLM 意图）与应用后的 [FactualMemoryHistory]（审计
  /// 记录）合成为 UI 友好的 [FactsChangeRecord]，供「事实层变更小窗」展示。
  ///
  /// 合成规则（详见 [FactsChangeRecord] 类文档）：
  /// - [FactsChangeRecord.action] / [FactsChangeRecord.oldValue] /
  ///   [FactsChangeRecord.newValue]：取实际落库结果（来自 [history]），以
  ///   反映 create_entity 被转写为 update_attr / add_alias 等场景的真实动作。
  /// - [FactsChangeRecord.entityType] / [FactsChangeRecord.primaryName] /
  ///   [FactsChangeRecord.attrKey]：取自原始 [delta]，保留 LLM 视角的实体与
  ///   属性描述；UI 展示属性名时可再经 `AttributeSchema.labelFor` 标准化。
  /// - [FactsChangeRecord.entityId]：取 `history.entityId`（create_entity 时
  ///   delta.entityId 为 null，但 history 携带新建的 entityId）。
  FactsChangeRecord _buildChangeRecord(
    FactsDelta delta,
    FactualMemoryHistory history,
  ) {
    return FactsChangeRecord(
      action: history.action,
      entityId: history.entityId,
      entityType: delta.entityType,
      primaryName: delta.primaryName,
      attrKey: delta.attrKey,
      oldValue: history.oldValue,
      newValue: history.newValue,
      reason: history.reason ?? delta.reason,
      confidence: delta.confidence,
    );
  }

  // ==================== 辅助方法 ====================

  /// 取同 (entityId, attrKey) 属性行中的可写 auto 行（无则 null）
  ///
  /// DOC-15 §8.1 方案 A：同 attrKey 可并存「只读基线（source=card）+ 可写演变
  /// （source=auto）」。FactApplier 只写 auto 行，绝不覆盖基线。
  FactualAttribute? _autoRowOf(List<FactualAttribute> rows) {
    for (final row in rows) {
      if (row.source == FactualSource.auto) return row;
    }
    return null;
  }

  /// 为实体创建属性（create_entity 时初始化 OR update_attr/append_list 时属性不存在）
  ///
  /// **前置条件**：调用方应先通过 [AttributeSchema.normalizeAttrKey] 标准化
  /// attrKey（兼容 LLM 产出的非标准字段，如 description → background）。
  /// 本方法不再做标准化，直接使用传入的 attrKey。
  ///
  /// 返回新建属性的 attributeId（供审计历史回填真实 attributeId，DOC-15 §8.2
  /// delta 行回滚依赖它）；白名单拒绝时返回 null。
  ///
  /// [skipWhitelist]：整理型写入（归并搬移）豁免白名单——键来自源实体
  /// 既有行，跨类型归并时目标类型 schema 可能不含该键。
  Future<String?> _createAttributeForEntity({
    required String entityId,
    required String sessionId,
    required FactualEntityType entityType,
    required String attrKey,
    required String value,
    required int turnNumber,
    required DateTime now,
    String? updateReason,
    bool skipWhitelist = false,
  }) async {
    if (!skipWhitelist &&
        !AttributeSchema.isAttrKeyAllowed(entityType, attrKey)) {
      _logger.warn(
        'attrKey not in schema whitelist, skipping attribute creation',
        detail: 'entityType=${entityType.name}, attrKey=$attrKey',
      );
      return null;
    }

    final valueType = AttributeSchema.valueTypeOf(entityType, attrKey);
    final String serializedValue;
    switch (valueType) {
      case AttributeValueType.single:
        serializedValue = value;
      case AttributeValueType.list:
        serializedValue = jsonEncode([value]);
      case AttributeValueType.dict:
        // 简化：dict 类型 create_entity 时存原始字符串（LLM 应输出 JSON 字符串）
        serializedValue = value;
    }

    final attr = FactualAttribute(
      attributeId: _generateAttributeId(),
      entityId: entityId,
      sessionId: sessionId,
      attrKey: attrKey,
      value: serializedValue,
      valueType: valueType,
      importance: AttributeSchema.defaultImportance(entityType, attrKey),
      createdAt: now,
      updatedAt: now,
      updatedTurn: turnNumber,
      updateReason: updateReason,
    );
    await _repository.createAttribute(attr);
    return attr.attributeId;
  }

  /// 解析实体类型字符串
  FactualEntityType? _parseEntityType(String value) {
    try {
      return FactualEntityType.fromString(value);
    } catch (_) {
      return null;
    }
  }

  /// 实体类型默认重要性（保守策略，仅当 LLM 未提供 importance 时使用）
  ///
  /// 2026-08-06 修订：从"角色=5，设定=4"改为更保守的默认值。
  /// 原因：系统自动赋高 importance 会导致配角/一次性NPC被每轮强制注入，
  /// 浪费上下文。现在 importance 优先由 LLM 评分（评估今后出现可能性），
  /// 仅当 LLM 未提供时才使用此默认值。
  int _defaultImportanceForType(FactualEntityType type) {
    switch (type) {
      case FactualEntityType.character:
        return 3; // 默认3分（常驻配角），主角应由 LLM 主动打4-5分
      case FactualEntityType.location:
      case FactualEntityType.item:
        return 2;
      case FactualEntityType.lore:
        return 3; // 通识性设定默认3分，具体规则应由 LLM 打2分
      case FactualEntityType.organization:
        return 2;
      case FactualEntityType.misc:
        return 1;
    }
  }

  /// 生成新 entityId
  ///
  /// 使用 uuid v4 保证全局唯一性，前缀 'ent_' 便于识别。
  /// ID 生成逻辑保留在 Domain 层，避免依赖 Data 层具体实现（依赖倒置）。
  String _generateEntityId() => 'ent_${_uuid.v4()}';

  /// 生成新 attributeId
  String _generateAttributeId() => 'attr_${_uuid.v4()}';

  // ==================== 相似名告警（实体归并前置观测）====================

  /// create_entity 落库前检测会话内与 [primaryName] 存在包含关系的既有实体，
  /// 命中则记 warn 日志。只告警，不改变创建行为——归并决策交给记忆查看器
  /// 手动合并或导演模式 merge_entities 工具。
  Future<void> _warnIfSimilarNameExists(
    String sessionId,
    String primaryName,
  ) async {
    try {
      final entities = await _repository.getEntities(sessionId);
      final candidates = <String>[];
      for (final entity in entities) {
        final names = [entity.primaryName, ...entity.aliases];
        for (final name in names) {
          if (!FactApplier.isNameContainmentSimilar(primaryName, name)) {
            continue;
          }
          candidates.add('${entity.primaryName}($name)');
          break;
        }
      }
      if (candidates.isNotEmpty) {
        _logger.warn(
          'create_entity created a name similar to existing entities, '
          'possible duplicate',
          detail: 'primaryName=$primaryName, '
              'candidates=${candidates.join(', ')}',
        );
      }
    } catch (e) {
      // 告警失败不影响创建主流程
      _logger.info('similar-name warning scan failed', detail: '$e');
    }
  }

  /// 包含关系判定：互为包含且较短名长度 >= 2
  ///
  /// 排除单字符名（"剑"包含于大量武器名，无区分价值）。
  /// 起公开：记忆库「找相似」聚类复用同一口径（此前仅测试
  /// 可见）。
  static bool isNameContainmentSimilar(String a, String b) {
    if (a.isEmpty || b.isEmpty || a == b) return false;
    if (a.contains(b) || b.contains(a)) {
      return (a.length <= b.length ? a : b).length >= 2;
    }
    return false;
  }

  // 语义相似度去重（DOC-11 §7.4.4）2026-10-15 起真源在投影器
  // （isSemanticallySimilarValue，干跑判定同源），本类经求值器间接消费。
}
