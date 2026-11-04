// factual_memory_tab.dart 拆分 part：实体/属性 CRUD 与归档/恢复/注入
// 开关动作组（原 _FactualMemoryTabState 方法逐字符搬运）。extension 机制
// 让方法仍属于 State 类成员、可访问主文件私有字段——同仓库
// advanced_chat_controller.dart 的 part 拆分先例。不引入新逻辑。
part of '../factual_memory_tab.dart';

/// 实体/属性 CRUD 动作（extension on _FactualMemoryTabState）。
extension _FactualEntityActions on _FactualMemoryTabState {
  Future<void> _onDeleteEntity(FactualEntity entity) async {
    final t = Translations.of(context);
    if (entity.source.isReadOnly) {
      _showReadonlySnack(t);
      return;
    }
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.intermediate.memoryBrowser.deleteConfirmTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.intermediate.memoryBrowser
              .deleteEntityConfirm(name: entity.primaryName),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: context.lm.palette.error,
            ),
            child: Text(
              t.common.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.deleteEntityById(entity.entityId);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.deleted),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error('Delete entity failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.deleteFailed),
          ),
        );
      }
    }
  }

  /// 活跃实体主名占用查询（口径：归档行让名，
  /// 不算占用）。手动建/改实体与归并路径共用同一判定。
  Future<bool> _activeNameOccupied({
    required String name,
    String? excludeEntityId,
  }) async {
    final activeEntities =
        await ref.read(factualRepositoryProvider).getEntities(widget.sessionId);
    return activeEntities.any(
      (e) => e.entityId != excludeEntityId && e.primaryName == name,
    );
  }

  Future<void> _onEditEntity(FactualEntity entity) async {
    final t = Translations.of(context);
    if (entity.source.isReadOnly) {
      _showReadonlySnack(t);
      return;
    }
    final result = await showLmDialog<FactualEntityEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => FactualEntityEditDialog(
        entity: entity,
        title: t.intermediate.memoryBrowser.editEntityTitle,
      ),
    );
    if (result == null) return;

    // 改名撞活跃名预检——partial 唯一索引
    // 只约束活跃行，撞名会让事务在 updateEntityBasic 处失败成泛化
    // saveFailed；提前给出可行动反馈（撞归档名合法放行，与归并预检同口径）
    if (result.primaryName != entity.primaryName) {
      final nameTaken = await _activeNameOccupied(
        excludeEntityId: entity.entityId,
        name: result.primaryName,
      );
      if (!mounted) return;
      if (nameTaken) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              t.intermediate.memoryBrowser.nameConflict(
                name: result.primaryName,
              ),
            ),
          ),
        );
        return;
      }
    }

    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.updateEntityBasic(
        entityId: entity.entityId,
        primaryName: result.primaryName != entity.primaryName
            ? result.primaryName
            : null,
        type: result.type != entity.type ? result.type : null,
        importance:
            result.importance != entity.importance ? result.importance : null,
        category: result.category != entity.category ? result.category : null,
        isArchived:
            result.isArchived != entity.isArchived ? result.isArchived : null,
        updatedTurn: entity.updatedTurn ?? entity.createdTurn,
      );
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saved),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error('Update entity failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saveFailed),
          ),
        );
      }
    }
  }

  /// 批 J-b：词条级注入停用/恢复——每轮注入的临时
  /// 开关，不动归档/审计；对齐兄弟操作的反馈口径（floating snackbar）。
  Future<void> _onToggleEntityInjection(FactualEntity entity) async {
    final t = Translations.of(context);
    final target = !entity.injectionDisabled;
    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.batchUpdateInjectionDisabled(
        [entity.entityId],
        disabled: target,
      );
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              target
                  ? t.intermediate.memoryBrowser.injectionDisabledToast
                  : t.intermediate.memoryBrowser.injectionEnabledToast,
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Batch injection toggle failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.injectionToggleFailed),
          ),
        );
      }
    }
  }

  /// 已归档实体恢复为活跃（2026-08-24：兑现"（可恢复）"文案承诺的直达入口；
  /// 审计可逆性已具备，此前只能从编辑对话框里的归档开关绕路）
  Future<void> _onRestoreEntity(FactualEntity entity) async {
    final t = Translations.of(context);
    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.updateEntityBasic(
        entityId: entity.entityId,
        isArchived: false,
        updatedTurn: entity.updatedTurn ?? entity.createdTurn,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.restoreEntityDone),
        ),
      );
    } catch (e, stackTrace) {
      _logger.error('Restore entity failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.restoreEntityFailed),
          ),
        );
      }
    }
  }

  /// 手动归档活跃实体（可逆——已归档实体走「恢复」
  /// 直达项）。auditTurn=maxTurn+1（：越过当前最大轮，重生成回滚
  /// 不复活），与手动归并的归档样板同口径。
  Future<void> _onArchiveEntity(FactualEntity entity) async {
    final t = Translations.of(context);
    try {
      final repo = ref.read(factualRepositoryProvider);
      var maxTurn = 0;
      for (final e in _allEntities) {
        final turn = e.updatedTurn ?? e.createdTurn;
        if (turn > maxTurn) maxTurn = turn;
      }
      final archiveTurn = maxTurn + 1;
      final reason = t.intermediate.memoryBrowser.archiveReason;
      final now = DateTime.now();
      await repo.runInTransaction(() async {
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
      });
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.archiveEntityDone),
        ),
      );
    } catch (e, stackTrace) {
      _logger.error('Archive entity failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.archiveEntityFailed),
          ),
        );
      }
    }
  }

  Future<void> _onAddEntity() async {
    final t = Translations.of(context);
    final result = await showLmDialog<FactualEntityEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => FactualEntityEditDialog(
        entity: null,
        title: t.intermediate.memoryBrowser.addEntityTitle,
      ),
    );
    if (result == null) return;

    // 新增撞活跃名预检（同编辑路径口径，避免落到 UNIQUE 事务失败）
    final addNameTaken = await _activeNameOccupied(
      name: result.primaryName,
    );
    if (!mounted) return;
    if (addNameTaken) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.intermediate.memoryBrowser.nameConflict(
              name: result.primaryName,
            ),
          ),
        ),
      );
      return;
    }

    try {
      final repo = ref.read(factualRepositoryProvider);
      final now = DateTime.now();
      final entity = FactualEntity(
        // F3 修复：空字符串主键第二次手动新增必撞 UNIQUE——
        // 按 repo 的约定格式（ent_/attr_ + uuid）在调用侧生成
        entityId: 'ent_${const Uuid().v4()}',
        sessionId: widget.sessionId,
        type: result.type,
        primaryName: result.primaryName,
        aliases: const [],
        importance: result.importance,
        // createdTurn=0（种子语义，与投影实体一致）。
        // 此前 maxTurn+1 指向未来轮——重生成最后一轮（fromTurn=N）时
        // deleteFactsByTurns 的 createdTurn>=fromTurn 条件会把手动实体
        // 整个删掉且无任何机制重建，"手动修记忆"在最常见操作后破灭。
        createdTurn: 0,
        createdAt: now,
        category: result.category,
        isArchived: result.isArchived,
      );
      await repo.createEntity(entity);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saved),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error('Create entity failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saveFailed),
          ),
        );
      }
    }
  }

  Future<void> _onEditAttribute(
    FactualEntity entity,
    FactualAttribute? attribute,
  ) async {
    final t = Translations.of(context);
    // 只读判定以属性级 source 为准（DOC-15 §8.2）。（只读语义 2.0）：
    // 新增属性不再看实体 source——新建行没有基线语义，手动新增也是
    // 「演变/生长」，一律落 source=auto（见下方构造处）；仅编辑既有
    // 基线行被拦截。
    if (attribute != null && attribute.source.isReadOnly) {
      _showReadonlySnack(t);
      return;
    }
    final result = await showLmDialog<FactualAttributeEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => FactualAttributeEditDialog(
        attribute: attribute,
        entityType: entity.type,
        title: attribute == null
            ? t.intermediate.memoryBrowser.addAttributeTitle
            : t.intermediate.memoryBrowser.editAttributeTitle,
      ),
    );
    if (result == null) return;

    try {
      final repo = ref.read(factualRepositoryProvider);
      if (attribute == null) {
        // 新增属性
        final newAttr = FactualAttribute(
          // F3 修复：同实体新增，见上
          attributeId: 'attr_${const Uuid().v4()}',
          entityId: entity.entityId,
          sessionId: widget.sessionId,
          attrKey: result.attrKey,
          value: result.value,
          valueType: result.valueType,
          importance: result.importance,
          createdAt: DateTime.now(),
          // （只读语义 2.0）：手动新增行显式落 auto——新建行没有基线
          // 语义（构造默认值即 auto，显式写出防未来默认值漂移）
          // ignore: avoid_redundant_argument_values
          source: FactualSource.auto,
        );
        await repo.createAttribute(newAttr);
      } else {
        // 更新属性值
        await repo.updateAttributeValue(
          attribute.attributeId,
          result.value,
          entity.updatedTurn ?? entity.createdTurn,
          factualManualEditReason,
        );
      }
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saved),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error('Save attribute failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saveFailed),
          ),
        );
      }
    }
  }

  Future<void> _onDeleteAttribute(FactualAttribute attribute) async {
    final t = Translations.of(context);
    if (attribute.source.isReadOnly) {
      _showReadonlySnack(t);
      return;
    }
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.intermediate.memoryBrowser.deleteConfirmTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.intermediate.memoryBrowser
              .deleteAttributeConfirm(key: attribute.attrKey),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: context.lm.palette.error,
            ),
            child: Text(
              t.common.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.deleteAttributeById(attribute.attributeId);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.deleted),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Delete attribute failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.deleteFailed),
          ),
        );
      }
    }
  }

  /// 只读资源守卫提示（世界书/角色卡，DOC-15 §8.2）
  void _showReadonlySnack(Translations t) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.intermediate.memoryBrowser.readonlyHint),
      ),
    );
  }
}
