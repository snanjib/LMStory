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
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart'
    show StoryPersistenceService;
import 'package:uuid/uuid.dart';

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
    if (delta.entityType == null || delta.primaryName == null) {
      _logger.warn(
        'create_entity missing required fields, skipping',
        detail: 'entityType=${delta.entityType}, '
            'primaryName=${delta.primaryName}',
      );
      return null;
    }

    // 提前解析 entityType，用于标准化 attrKey
    final entityType = _parseEntityType(delta.entityType!);
    if (entityType == null) {
      _logger.warn(
        'Unknown entity type, skipping',
        detail: 'entityType=${delta.entityType}',
      );
      return null;
    }

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

    // 防护：检查 primaryName 是否已存在
    final existing = await _repository.findByName(
      sessionId,
      [delta.primaryName!],
    );
    if (existing.isNotEmpty) {
      final existingEntity = existing.first;

      // 撞名导入实体（worldbook/card）走统一转换（演变/别名），不转 create
      //（2026-09-14 只读语义 2.0：世界书与角色卡同为属性级只读基线）。

      // 2026-07-22 修复：实体已存在 + 携带 attrKey/value → 转 update_attr
      // 保留 LLM 想要更新的属性信息，不再丢弃。
      // 2026-08-23 修订：value 兜底键按已存实体的真实类型计算（delta 的
      // entityType 可能缺失或与既有实体不一致）。
      if (delta.value != null) {
        final attrKey = normalizedAttrKey ??
            AttributeSchema.fallbackDescriptionKey(existingEntity.type);
        _logger.info(
          'Entity already exists, converting to update_attr',
          detail: 'primaryName=${delta.primaryName}, '
              'existingEntityId=${existingEntity.entityId}, '
              'attrKey=${delta.attrKey} → $attrKey',
        );
        final updateDelta = FactsDelta(
          action: FactAction.updateAttr,
          entityId: existingEntity.entityId,
          attrKey: attrKey,
          value: delta.value,
          confidence: delta.confidence,
          reason: delta.reason,
        );
        return _applyUpdateAttr(sessionId, updateDelta, turnNumber, config);
      }

      // 实体已存在 + 无 value → 改为 addAlias（DOC-11 §10.3 原逻辑）
      _logger.info(
        'Entity already exists, converting to add_alias',
        detail: 'primaryName=${delta.primaryName}, '
            'existingEntityId=${existingEntity.entityId}',
      );
      final aliasDelta = FactsDelta(
        action: FactAction.addAlias,
        entityId: existingEntity.entityId,
        value: delta.primaryName,
        confidence: delta.confidence,
      );
      return _applyAddAlias(sessionId, aliasDelta, turnNumber, config);
    }

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

    // → ：主名是身份
    // 标识，不可被改名——统一不分 source（原 auto 实体改 name 只写属性行
    // 造成主名双源分叉：注入行同屏两名/检索按旧名）。改名意图一律转为
    // 别名追加，旧主名保留；回滚天然覆盖（别名分支）。
    if (attrKey == 'name') {
      _logger.info(
        'rename on imported entity, converting to add_alias',
        detail: 'entityId=${delta.entityId}, source=${entity.source.name}',
      );
      final aliasDelta = FactsDelta(
        action: FactAction.addAlias,
        entityId: delta.entityId,
        value: delta.value,
        confidence: delta.confidence,
      );
      return _applyAddAlias(sessionId, aliasDelta, turnNumber, config);
    }

    // schema 白名单检查（整理型写入豁免：归并搬移的键来自源实体既有行，
    // 键本身已在源侧成立，跨类型归并时目标类型白名单可能不含该键）
    if (!delta.isCuration &&
        !AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      _logger.warn(
        'attrKey not in schema whitelist, skipping',
        detail: 'entityType=${entity.type.name}, attrKey=$attrKey',
      );
      return null;
    }

    // 属性值长度上限检查
    if (delta.value!.length > config.maxAttrValueLength) {
      _logger.warn(
        'Attribute value too long, skipping',
        detail: 'attrKey=$attrKey, '
            'valueLength=${delta.value!.length}, '
            'maxLength=${config.maxAttrValueLength}',
      );
      return null;
    }

    // 更新频率限制（整理型写入豁免：归并是确定性知识搬迁，非演化抖动）
    if (!delta.isCuration) {
      final recentUpdates = await _repository.countRecentUpdates(
        delta.entityId!,
        fromTurn: turnNumber - 2, // 最近 3 轮（含本轮）
      );
      if (recentUpdates >= config.maxUpdatesPer3Turns) {
        _logger.warn(
          'Entity updated too frequently recently, skipping',
          detail: 'entityId=${delta.entityId}, '
              'recentUpdates=$recentUpdates, '
              'maxAllowed=${config.maxUpdatesPer3Turns}',
        );
        return null;
      }
    }

    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );
    final attr = _autoRowOf(rows);

    // 只读基线不覆盖：无 auto 行且新值与只读基线值相同 → 跳过（避免重复创建 auto 行）
    if (attr == null && rows.any((r) => r.value == delta.value)) {
      _logger.info(
        'Value unchanged (matches read-only baseline), skipping',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
    }

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

    // 值必须真的不同
    if (attr.value == delta.value) {
      _logger.info(
        'Value unchanged, skipping',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
    }

    // 关键属性（importance>=4）需要高置信度（整理型写入豁免）
    if (!delta.isCuration &&
        attr.isKeyAttribute &&
        delta.confidence < config.modifyConfidenceThreshold) {
      _logger.warn(
        'Low confidence modification of key attribute rejected',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey, '
            'confidence=${delta.confidence}, '
            'required=${config.modifyConfidenceThreshold}',
      );
      return null;
    }

    // schema 白名单：single 类型只能 update，list 类型不允许 update（应 append）
    if (attr.valueType == AttributeValueType.list) {
      _logger.warn(
        'Cannot update_attr on list type, use append_list instead. Skipping.',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
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

    // schema 白名单检查（整理型写入豁免，同 _applyUpdateAttr）
    if (!delta.isCuration &&
        !AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      _logger.warn(
        'attrKey not in schema whitelist, skipping',
        detail: 'entityType=${entity.type.name}, attrKey=$attrKey',
      );
      return null;
    }

    // 属性值长度上限检查（单个值）
    if (delta.value!.length > config.maxAttrValueLength) {
      _logger.warn(
        'Append value too long, skipping',
        detail: 'attrKey=$attrKey, '
            'valueLength=${delta.value!.length}',
      );
      return null;
    }

    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );
    final attr = _autoRowOf(rows);

    // 属性不存在 → 创建新属性（list 类型）
    if (attr == null) {
      // 只读基线为 single 类型时，append_list 重定向为 update_attr（写入 auto 行）
      final baselineSingle = rows.any(
        (r) =>
            r.source != FactualSource.auto &&
            r.valueType == AttributeValueType.single,
      );
      if (baselineSingle) {
        _logger.info(
          'Converting append_list to update_attr (read-only single baseline)',
          detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
        );
        final updateDelta = FactsDelta(
          action: FactAction.updateAttr,
          entityId: delta.entityId,
          attrKey: attrKey,
          value: delta.value,
          reason: delta.reason,
          confidence: delta.confidence,
          isCuration: delta.isCuration,
        );
        return _applyUpdateAttr(sessionId, updateDelta, turnNumber, config);
      }

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

    // single 类型收到 append_list → 自动转为 update_attr（覆盖）
    if (attr.valueType == AttributeValueType.single) {
      _logger.info(
        'Converting append_list to update_attr (single type)',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      final updateDelta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: delta.entityId,
        attrKey: attrKey,
        value: delta.value,
        reason: delta.reason,
        confidence: delta.confidence,
        isCuration: delta.isCuration,
      );
      return _applyUpdateAttr(sessionId, updateDelta, turnNumber, config);
    }

    // list 类型：精确去重
    final list = attr.listValue;
    if (list.contains(delta.value)) {
      _logger.info(
        'Skip duplicate value (exact match)',
        detail: 'entityId=${delta.entityId}, '
            'attrKey=$attrKey, value=${delta.value}',
      );
      return null;
    }

    // list 类型：语义相似度去重
    if (_isSemanticallySimilar(delta.value!, list)) {
      _logger.info(
        'Skip semantically similar value',
        detail: 'entityId=${delta.entityId}, '
            'attrKey=$attrKey, value=${delta.value}',
      );
      return null;
    }

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

    if (!AttributeSchema.isAttrKeyAllowed(entity.type, attrKey)) {
      return null;
    }

    final rows = await _repository.getAttributesByKey(
      delta.entityId!,
      attrKey,
    );
    final attr = _autoRowOf(rows);
    // 只读基线不可移除（DOC-15 §8.1）：无 auto 行（仅基线或属性不存在）→ 跳过
    if (attr == null || attr.valueType != AttributeValueType.list) {
      _logger.warn(
        'No mutable auto attribute or not list type, skipping remove_from_list',
        detail: 'entityId=${delta.entityId}, attrKey=$attrKey',
      );
      return null;
    }

    final list = attr.listValue;
    if (!list.contains(delta.value)) {
      _logger.info(
        'Value not in list, skipping remove_from_list',
        detail: 'entityId=${delta.entityId}, '
            'attrKey=$attrKey, value=${delta.value}',
      );
      return null;
    }

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
  /// 防口径漂移。
  static const int kMaxAliasesPerEntity = 10;
  static const int _kMaxAliasesPerEntity = kMaxAliasesPerEntity;

  /// 应用 add_alias 动作
  Future<FactualMemoryHistory?> _applyAddAlias(
    String sessionId,
    FactsDelta delta,
    int turnNumber,
    FactualConfig config,
  ) async {
    if (delta.entityId == null || delta.value == null) {
      _logger.warn(
        'add_alias missing required fields, skipping',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    // trim/长度防线——改名转别名转换分支
    // 先于 update_attr 的长度检查（:411 转换在 :437 之前），超长/空白别名
    // 此前直落 known_entities 行渲染。
    final alias = delta.value!.trim();
    if (alias.isEmpty) {
      _logger.info('Empty alias after trim, skipping');
      return null;
    }
    if (alias.length > config.maxAttrValueLength) {
      _logger.warn(
        'Alias too long, skipping',
        detail: 'entityId=${delta.entityId}, '
            'valueLength=${alias.length}, '
            'maxLength=${config.maxAttrValueLength}',
      );
      return null;
    }

    final entity = await _repository.getEntityById(delta.entityId!);
    if (entity == null) {
      _logger.warn(
        'Entity not found, skipping add_alias',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    // 别名不能与主名冲突
    if (entity.primaryName == alias) {
      _logger.info(
        'Alias same as primaryName, skipping',
        detail: 'entityId=${delta.entityId}, value=$alias',
      );
      return null;
    }

    // 别名不能与已有别名冲突
    if (entity.aliases.contains(alias)) {
      _logger.info(
        'Alias already exists, skipping',
        detail: 'entityId=${delta.entityId}, value=$alias',
      );
      return null;
    }

    // 这是最终守卫——暂存端（agent_session_tools 归并
    // 预演）与手动预览端已按同常量提前披露，此处静默跳过仅剩同轮竞争窗口
    // 内的极端到达（检查与提交之间又有他轮写入）。
    if (entity.aliases.length >= _kMaxAliasesPerEntity) {
      _logger.warn(
        'Too many aliases, skipping',
        detail: 'entityId=${delta.entityId}, '
            'count=${entity.aliases.length}, max=$_kMaxAliasesPerEntity',
      );
      return null;
    }

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
    if (delta.entityId == null) {
      _logger.warn(
        'archive_entity missing entityId, skipping',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    final entity = await _repository.getEntityById(delta.entityId!);
    if (entity == null) {
      _logger.warn(
        'Entity not found, skipping archive_entity',
        detail: 'entityId=${delta.entityId}',
      );
      return null;
    }

    if (entity.isArchived) {
      _logger.info(
        'Entity already archived, skipping',
        detail: 'entityId=${delta.entityId}',
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

  // ==================== 语义相似度去重（DOC-11 §7.4.4）====================

  /// 检查新值与现有列表是否语义相似
  ///
  /// 使用编辑距离 + 包含关系检测，**不调 embedding API**（成本太高）。
  /// 满足以下任一条件即视为相似：
  /// - 编辑距离 <= 2（如"温顺" vs "温驯"）
  /// - 一个包含另一个（如"金毛犬" vs "金毛"）
  bool _isSemanticallySimilar(String newValue, List<String> existing) {
    for (final v in existing) {
      if (_editDistance(newValue, v) <= 2) return true;
      if (v.contains(newValue) || newValue.contains(v)) return true;
    }
    return false;
  }

  /// 计算两个字符串的编辑距离（Levenshtein）
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
}

/// 属性 schema 白名单（DOC-11 §7.4.2）
///
/// 每种实体类型预定义固定的属性集合，LLM 只能使用预定义的 attrKey。
/// 描述性属性（personality/description/background）强制 single 类型，
/// 只能 update 不能 append，避免"温顺"+"乖巧"近义词堆积。
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
