// factual_memory_tab.dart 拆分 part：手动归并流程（找相似聚类预选、
// AI 整合方案、预览确认与落库；原 _FactualMemoryTabState 方法逐字符
// 搬运，仅相似簇弹层/预览弹窗抽到 factual_merge_dialogs.dart）。
// extension 机制让方法仍属于 State 类成员、可访问主文件私有字段——
// 同仓库 advanced_chat_controller.dart 的 part 拆分先例。不引入新逻辑。
//
// extension 拆分的固有约束：setState 是 State 的 protected 成员，
// extension 内调用触发 invalid_use_of_protected_member——运行无误
// （方法调用仍绑定 State 实例），文件级忽略（同
// advanced_chat_controller_retry.dart 先例）。
// ignore_for_file: invalid_use_of_protected_member
part of '../factual_memory_tab.dart';

/// 手动归并与找相似动作（extension on _FactualMemoryTabState）。
extension _FactualMergeFlow on _FactualMemoryTabState {
  // ── 手动归并（2026-08-24：多选重复实体 → AI 整合方案 → 预览确认 → 落库）──

  // ── ：找相似——包含关系聚类 + 一键预选归并 ──────────────

  Future<void> _onFindSimilar() async {
    final t = Translations.of(context);
    final clusters = factualSimilarClusters(_allEntities);
    if (!mounted) return;
    if (clusters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.findSimilarEmpty),
        ),
      );
      return;
    }

    final selected = await showFactualSimilarClustersSheet(
      context: context,
      clusters: clusters,
    );
    if (selected == null || !mounted) return;

    setState(() {
      _multiSelectMode = true;
      _selectedEntityIds
        ..clear()
        ..addAll(selected);
    });
  }

  Future<void> _onAiMergeSelected() async {
    final t = Translations.of(context);
    final service = widget.mergeService;
    if (service == null) return;

    final selected = _allEntities
        .where((e) => _selectedEntityIds.contains(e.entityId))
        .toList();
    if (selected.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.mergeSelectAtLeastTwo),
        ),
      );
      return;
    }
    // （对齐导演 merge_entities 口径——唯一真源注释互引：
    // agent_session_tools.dart MergeEntitiesTool「source 拒只读、
    // target 拒 worldbook」）：世界书实体两角色皆不可，选中即拦；
    // 只读实体 >1 条时必有一条被吸收，也拦。单张角色卡与普通实体
    // 同选可继续（卡片为强制保留者，方案层校验 target 落卡片上）。
    final hasWorldbook =
        selected.any((e) => e.source == FactualSource.worldbook);
    final readonlyCount = selected.where((e) => e.source.isReadOnly).length;
    if (hasWorldbook || readonlyCount > 1) {
      // 合并场景专用提示：通用 readonlyHint 说"不可编辑或删除"，
      // 与合并动作不对应
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.readonlyMergeHint),
        ),
      );
      return;
    }
    // 已归档实体拦截：归档实体不进检索与
    // 注入，被选为保留者会把合并成果整体赶出上下文，且 LLM 档案不含
    // 归档状态、用户预览无从预判。
    if (selected.any((e) => e.isArchived)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.mergeArchivedBlocked),
        ),
      );
      return;
    }

    // 配置解析提前到确认弹窗之前：归并模型=会话生成模型，
    // 在弹窗中明示所用模型，不再让"用了哪个模型"对用户不可见；
    // 解析失败也可在用户确认前拦截。
    NamingConfig? namingConfig;
    try {
      namingConfig = await widget.resolveMergeNamingConfig?.call();
    } catch (e, stackTrace) {
      _logger.error(
        'Resolve merge naming config failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (!mounted) return;
    if (namingConfig == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.mergeModelNotConfigured),
        ),
      );
      return;
    }
    final config = namingConfig;

    // 步骤 1：意图确认（含所用模型）
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.intermediate.memoryBrowser.mergeConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.intermediate.memoryBrowser.mergeConfirmBody(n: selected.length),
            ),
            const SizedBox(height: LmSpacing.sSm),
            Text(
              t.intermediate.memoryBrowser
                  .mergeConfirmModel(model: config.modelId),
              style: LmNarrativeTextStyles.caption
                  .copyWith(color: Theme.of(context).hintColor),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.intermediate.memoryBrowser.mergeCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.intermediate.memoryBrowser.mergeContinue),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_isMerging) return;
    setState(() => _isMerging = true);
    try {
      await _runMergeFlow(service, t, selected, config);
    } finally {
      if (mounted) setState(() => _isMerging = false);
    }
  }

  /// 合并主流程（[[_isMerging]] 护栏内执行：LLM 方案 → 预览落库）。
  /// [namingConfig] 已由调用方在确认弹窗前解析（会话生成模型）。
  Future<void> _runMergeFlow(
    FactsMergeService service,
    Translations t,
    List<FactualEntity> selected,
    NamingConfig namingConfig,
  ) async {
    // 步骤 2：LLM 生成整合方案（加载遮罩）
    // 遮罩用 route 引用精确移除：桌面 Esc 可关掉 barrierDismissible
    // 对话框，此前的无参 pop() 会误弹下层路由（把记忆查看器页面关掉）；
    // PopScope 挡 Esc，removeRoute 只移除本遮罩。
    final overlayRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: LmSpacing.sMd),
              Text(t.intermediate.memoryBrowser.mergePlanning),
            ],
          ),
        ),
      ),
    );
    unawaited(Navigator.of(context).push(overlayRoute));
    MergePlan? plan;
    try {
      plan = await service.planMerge(
        entities: selected,
        attributesByEntity: {
          for (final e in selected)
            e.entityId: _attributesByEntity[e.entityId] ?? const [],
        },
        namingConfig: namingConfig,
      );
    } finally {
      if (mounted) {
        Navigator.of(context).removeRoute(overlayRoute);
      }
    }
    if (!mounted) return;
    if (plan == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.mergePlanFailed),
        ),
      );
      return;
    }

    // 步骤 3：预览方案，确认后落库
    final apply = await showFactualMergePreviewDialog(
      context: context,
      plan: plan,
      selected: selected,
    );
    if (apply != true || !mounted) return;
    final mergePlan = plan;
    // 改名撞名预检：
    // partial 唯一索引（WHERE is_archived=0）只约束活跃行——撞活跃名才
    // 会事务失败，提前给出可行动反馈；撞归档名合法放行。列表受"显示归档"
    // 过滤影响，须独立拉全量。
    final target =
        selected.firstWhere((e) => e.entityId == mergePlan.targetEntityId);
    if (mergePlan.primaryName != target.primaryName) {
      final activeEntities = await ref
          .read(factualRepositoryProvider)
          .getEntities(widget.sessionId);
      if (!mounted) return;
      final occupied = activeEntities
          .where((e) => e.entityId != mergePlan.targetEntityId)
          .map((e) => e.primaryName)
          .toSet();
      if (occupied.contains(mergePlan.primaryName)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              t.intermediate.memoryBrowser.mergeNameConflict(
                name: mergePlan.primaryName,
              ),
            ),
          ),
        );
        return;
      }
    }
    try {
      await _applyMergePlan(mergePlan, selected);
      await _loadData();
      if (!mounted) return;
      setState(() {
        _multiSelectMode = false;
        _selectedEntityIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.mergeApplied),
        ),
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Manual merge persist failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.mergeApplyFailed),
          ),
        );
      }
    }
  }

  /// 落库（组合既有标准动作，全部可逆；turn 沿用查看器编辑约定）
  ///
  /// 整个写序列在单一 drift 事务内：
  /// 此前 updateEntityBasic 游离在事务外且注释失实（repo 写方法按契约
  /// 均不开自身事务），事务段失败会留下"已改名未合并"的部分终态。
  Future<void> _applyMergePlan(
    MergePlan plan,
    List<FactualEntity> selected,
  ) async {
    final repo = ref.read(factualRepositoryProvider);
    final now = DateTime.now();
    final absorbed =
        selected.where((e) => e.entityId != plan.targetEntityId).toList();
    final target =
        selected.firstWhere((e) => e.entityId == plan.targetEntityId);
    final turn = target.updatedTurn ?? target.createdTurn;
    // （审计复活收窄）：归档审计行与实体 updatedTurn 用
    // 「当前会话最大轮+1」——高于任何既有轮次，重生成回滚
    // （deleteFactsByTurns 的 fromTurn ≤ 当前最大轮）不会命中复活被吸收
    // 实体。吸收侧其余审计行（别名/属性）沿用查看器编辑的历史轮号惯例。
    var maxTurn = 0;
    for (final e in _allEntities) {
      final t = e.updatedTurn ?? e.createdTurn;
      if (t > maxTurn) maxTurn = t;
    }
    final archiveTurn = maxTurn + 1;
    const reason = factualManualMergeReason;

    await repo.runInTransaction(() async {
      // 目标核心信息（改名 + 重要度）。
      // 只读保留者（角色卡）跳过——卡名/重要度
      // 是种子身份标识不可改，repo 只读守卫会让事务必然失败（此前"AI
      // 重复建档→并入卡片"主场景走完预览确认后 100% 失败且不可自救）；
      // 并入别名与 auto 属性即可满足去重目的，与导演 merge_entities 的
      // add_alias 暂存通道同口径。
      final targetIsReadonly = target.source.isReadOnly;
      if (!targetIsReadonly) {
        await repo.updateEntityBasic(
          entityId: plan.targetEntityId,
          primaryName: plan.primaryName,
          importance: plan.importance,
          updatedTurn: turn,
        );
      }

      // 别名并集 = 目标现有 + 方案别名 - 规范名自身
      //（只读保留者不改名，剔除其现名防规范名混进别名）
      // 手动归并对齐  防线——
      // 超长别名（>maxAttrValueLength，取 FactualConfig 默认值，与
      // FactApplier 同界）剔除、并集总数封顶 kMaxAliasesPerEntity
      // （先保目标现有别名，方案别名按序补位，超出静默丢弃）。
      final canonicalName =
          targetIsReadonly ? target.primaryName : plan.primaryName;
      final aliasLengthCap = const FactualConfig().maxAttrValueLength;
      final aliases = <String>{...target.aliases}..remove(canonicalName);
      for (final alias in plan.aliases) {
        if (aliases.length >= FactApplier.kMaxAliasesPerEntity) break;
        if (alias.length > aliasLengthCap) continue;
        aliases.add(alias);
      }
      final addedAliases =
          aliases.where((a) => !target.aliases.contains(a)).toList();
      await repo.updateEntityAliases(
        plan.targetEntityId,
        aliases.toList(),
        turn,
      );
      // add_alias 审计行：重生成回滚按
      // 该行撤销并入的别名（_rollbackSurvivingEntities 的 add_alias 分支），
      // 缺行则归并别名无法随回滚撤销。
      // 逐别名一行——此前 join(',') 逗号并集与回滚端
      // 的单值精确匹配格式脱节，多别名归并（最常见场景）的回滚移除数恒为 0。
      for (final alias in addedAliases) {
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: plan.targetEntityId,
            action: FactAction.addAlias,
            newValue: alias,
            reason: reason,
            turnNumber: turn,
            createdAt: now,
          ),
        );
      }

      // 属性：已有 auto 行 → 更新；无 → 新建 auto 行
      final existingAttrs =
          _attributesByEntity[plan.targetEntityId] ?? const [];
      for (final merged in plan.attributes) {
        final autoRow = existingAttrs
            .where((a) => a.attrKey == merged.attrKey)
            .where((a) => a.source == FactualSource.auto)
            .firstOrNull;
        if (autoRow != null) {
          if (autoRow.value == merged.value) continue;
          await repo.updateAttributeValue(
            autoRow.attributeId,
            merged.value,
            turn,
            reason,
          );
          await repo.insertHistory(
            FactualMemoryHistory(
              entityId: plan.targetEntityId,
              attributeId: autoRow.attributeId,
              action: FactAction.updateAttr,
              oldValue: autoRow.value,
              newValue: merged.value,
              reason: reason,
              turnNumber: turn,
              createdAt: now,
            ),
          );
        } else {
          final created = await repo.createAttribute(
            FactualAttribute(
              attributeId: 'attr_${const Uuid().v4()}',
              entityId: plan.targetEntityId,
              sessionId: widget.sessionId,
              attrKey: merged.attrKey,
              value: merged.value,
              valueType: merged.valueType,
              importance: AttributeSchema.defaultImportance(
                target.type,
                merged.attrKey,
              ),
              createdAt: now,
              updatedTurn: turn,
              updateReason: reason,
            ),
          );
          await repo.insertHistory(
            FactualMemoryHistory(
              entityId: plan.targetEntityId,
              attributeId: created.attributeId,
              action: FactAction.updateAttr,
              newValue: merged.value,
              reason: reason,
              turnNumber: turn,
              createdAt: now,
            ),
          );
        }
      }

      // 被吸收条目归档（可逆），逐条写审计行（：archiveTurn 越过
      // 当前最大轮，重生成回滚不复活）
      for (final entity in absorbed) {
        await repo.archiveEntity(entity.entityId, reason, archiveTurn);
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: entity.entityId,
            action: FactAction.archiveEntity,
            newValue: reason,
            reason: reason,
            turnNumber: archiveTurn,
            createdAt: now,
          ),
        );
      }
    });
  }
}
