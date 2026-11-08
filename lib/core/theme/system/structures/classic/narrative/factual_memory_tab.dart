import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_attribute_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_edit_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_entity_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_filter_chips.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_force_inject_bar.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_merge_dialogs.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_search_header.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_state_views.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_stats_bar.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_utils.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/facts_merge_service.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

// 拆分说明：本文件原为 ~3600 行巨型组件，已按职责物理拆解到
// factual_memory/ 子目录（各拆分文件 < 600 行），本文件只保留
// FactualMemoryTab 主容器骨架（State 生命周期/数据加载/过滤装配与回调
// 接线）。为保持外部 import 路径与符号不变，下方 export 转发全部拆分
// 产物；实体/属性 CRUD 与归并流程两组 State 动作以 part + extension
// 拆出（同 advanced_chat_controller.dart 先例，方法仍属本 State），
// 子文件禁止反向 import 本文件。
export 'factual_memory/factual_attribute_dialog.dart';
export 'factual_memory/factual_attribute_row.dart';
export 'factual_memory/factual_edit_dialog.dart';
export 'factual_memory/factual_entity_card.dart';
export 'factual_memory/factual_filter_chips.dart';
export 'factual_memory/factual_force_inject_bar.dart';
export 'factual_memory/factual_merge_dialogs.dart';
export 'factual_memory/factual_search_header.dart';
export 'factual_memory/factual_state_views.dart';
export 'factual_memory/factual_stats_bar.dart';
export 'factual_memory/factual_utils.dart';

part 'factual_memory/factual_entity_actions.dart';
part 'factual_memory/factual_merge_flow.dart';

/// 事实记忆 Tab（记忆查看器）。
///
/// 展示会话内全部事实层实体（按类型分组），支持：
/// - 关键字搜索（实体名 + 别名 + 属性值）
/// - 点击实体卡片展开/折叠属性列表
/// - 编辑实体基本信息（primaryName / type / importance / category / isArchived）
/// - 编辑/新增/删除属性
/// - 新增/删除实体
///
/// 视觉：实体卡片 + 属性展开列表。
class FactualMemoryTab extends ConsumerStatefulWidget {
  const FactualMemoryTab({
    required this.sessionId,
    this.mergeService,
    this.resolveMergeNamingConfig,
    this.initialMultiSelect = false,
    this.preselectEntityIds = const <String>{},
    this.readOnly = false,
    super.key,
  });

  final String sessionId;

  /// 手动归并服务（null = 不提供"AI 合并"入口）
  final FactsMergeService? mergeService;

  /// 归并调用的模型配置解析（null 视为未配置，引导去设置）
  final Future<NamingConfig?> Function()? resolveMergeNamingConfig;

  /// 打开即进入多选模式并预选实体（外部入口
  /// （找相似/疑似重复）跳转归并预选用）；预选 id 在数据加载后应用
  final bool initialMultiSelect;
  final Set<String> preselectEntityIds;
  final bool readOnly;

  @override
  ConsumerState<FactualMemoryTab> createState() => _FactualMemoryTabState();
}

class _FactualMemoryTabState extends ConsumerState<FactualMemoryTab> {
  final _logger = const Logger('FactualMemoryTab');
  final _searchController = TextEditingController();

  List<FactualEntity> _allEntities = [];
  Map<String, List<FactualAttribute>> _attributesByEntity = {};
  bool _isLoading = true;
  final bool _includeArchived = true;
  String? _errorMessage;
  String _searchQuery = '';

  // 筛选状态
  bool _filterExpanded = false; // 筛选栏展开/折叠
  int _typeFilter =
      0; // 0=全部, 1=character, 2=location, 3=item, 4=lore, 5=organization, 6=misc
  int _importanceFilter = 0; // 0=全部, 1=关键(4-5), 2=普通(1-3)
  // 2026-09-03 用户反馈：归并/ARCHIVE_ENTITY 后归档实体混在列表里显得乱，
  // 默认只显示活跃实体（0=全部, 1=活跃, 2=已归档），经筛选栏可切换。
  int _archiveFilter = 1;

  // 排序状态
  int _sortBy = 0; // 0=重要性, 1=名称, 2=创建时间

  // 强制注入多选状态（v0.2.3）
  bool _multiSelectMode = false;
  final Set<String> _selectedEntityIds = {};

  /// 构造参数携带的预选（首次 _loadData 完成后应用一次）
  Set<String>? _pendingPreselect;

  /// AI 合并流程重入护栏：确认弹窗关闭到
  /// 加载遮罩压栈之间存在无模态窗口，重入会叠起第二条 LLM 调用。
  bool _isMerging = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (widget.preselectEntityIds.isNotEmpty || widget.initialMultiSelect) {
      _pendingPreselect = widget.preselectEntityIds;
    }
    _loadData();
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _searchQuery) return;
    setState(() {
      _searchQuery = query;
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final repo = ref.read(factualRepositoryProvider);
      final entities = await repo.getEntities(
        widget.sessionId,
        includeArchived: _includeArchived,
      );
      final attributes = await repo.getAttributes(
        widget.sessionId,
        entities.map((e) => e.entityId).toList(),
      );
      final attrMap = <String, List<FactualAttribute>>{};
      for (final attr in attributes) {
        attrMap.putIfAbsent(attr.entityId, () => []).add(attr);
      }
      // 按 importance 降序、attrKey 字典序排序属性
      for (final list in attrMap.values) {
        list.sort((a, b) {
          final imp = b.importance.compareTo(a.importance);
          if (imp != 0) return imp;
          return a.attrKey.compareTo(b.attrKey);
        });
      }
      setState(() {
        _allEntities = entities;
        _attributesByEntity = attrMap;
        _isLoading = false;
        // 外部跳转预选——首次加载后进多选并勾选
        if (_pendingPreselect != null) {
          _multiSelectMode = true;
          _selectedEntityIds
            ..clear()
            ..addAll(_pendingPreselect!);
          _pendingPreselect = null;
        }
      });
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load factual memories',
        error: e,
        stackTrace: stackTrace,
      );
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  List<FactualEntity> get _filteredEntities => factualFilterAndSortEntities(
        allEntities: _allEntities,
        searchQuery: _searchQuery,
        typeFilter: _typeFilter,
        importanceFilter: _importanceFilter,
        archiveFilter: _archiveFilter,
        sortBy: _sortBy,
        attributesByEntity: _attributesByEntity,
      );

  /// 当前是否有任意筛选条件生效（用于统计栏切换文案）
  bool get _hasActiveFilter =>
      _searchQuery.isNotEmpty ||
      _typeFilter > 0 ||
      _importanceFilter > 0 ||
      _archiveFilter > 0;

  /// 勾选/取消勾选实体（强制注入多选，v0.2.3）
  void _onToggleEntitySelect(FactualEntity entity) {
    setState(() {
      if (!_selectedEntityIds.add(entity.entityId)) {
        _selectedEntityIds.remove(entity.entityId);
      }
    });
  }

  Future<void> _applyForceInject(ForceInjectTarget target) async {
    final t = Translations.of(context);
    if (_selectedEntityIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.intermediate.memoryBrowser.forceInjectNoneSelected),
        ),
      );
      return;
    }
    try {
      final repo = ref.read(factualRepositoryProvider);
      await repo.batchUpdateForceInject(_selectedEntityIds.toList(), target);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.forceInjectApplied),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to set force injection in bulk',
        error: e,
        stackTrace: stackTrace,
      );
      // forceInject 是「每轮必进上下文」的关键操作，
      // 失败静默 = 承诺落空无感知——与同文件删除/编辑/归并的失败反馈对齐
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.forceInjectFailed),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: colors.primary),
      );
    }

    if (_errorMessage != null) {
      return FactualErrorStateView(
        colors: colors,
        t: t,
        message: _errorMessage!,
        onRetry: _loadData,
      );
    }

    return Column(
      children: [
        FactualStatsBar(
          colors: colors,
          t: t,
          allEntities: _allEntities,
          filteredCount: _filteredEntities.length,
          hasActiveFilter: _hasActiveFilter,
        ),
        FactualSearchHeader(
          colors: colors,
          t: t,
          searchController: _searchController,
          searchQuery: _searchQuery,
          sortBy: _sortBy,
          filterExpanded: _filterExpanded,
          hasActiveFilter: _hasActiveFilter,
          multiSelectMode: _multiSelectMode,
          onSortChanged: (value) => setState(() => _sortBy = value),
          onToggleFilterExpanded: () =>
              setState(() => _filterExpanded = !_filterExpanded),
          onFindSimilar: _onFindSimilar,
          onToggleMultiSelect: () => setState(() {
            _multiSelectMode = !_multiSelectMode;
            _selectedEntityIds.clear();
          }),
          onAddEntity: _onAddEntity,
          readOnly: widget.readOnly,
        ),
        FactualFilterChips(
          colors: colors,
          t: t,
          expanded: _filterExpanded,
          typeFilter: _typeFilter,
          importanceFilter: _importanceFilter,
          archiveFilter: _archiveFilter,
          onTypeFilterChanged: (value) => setState(() => _typeFilter = value),
          onImportanceFilterChanged: (value) =>
              setState(() => _importanceFilter = value),
          onArchiveFilterChanged: (value) =>
              setState(() => _archiveFilter = value),
        ),
        Expanded(child: _buildEntityList(colors, t)),
        if (_multiSelectMode)
          FactualForceInjectBar(
            colors: colors,
            t: t,
            selectedCount: _selectedEntityIds.length,
            showMergeAction: widget.mergeService != null,
            onAiMergeSelected: _onAiMergeSelected,
            onApplyForceInject: _applyForceInject,
          ),
      ],
    );
  }

  Widget _buildEntityList(LmPalette colors, Translations t) {
    final entities = _filteredEntities;
    if (entities.isEmpty) {
      return FactualEmptyStateView(
        colors: colors,
        t: t,
        searchQuery: _searchQuery,
      );
    }

    // 按 type 分组
    final grouped = <FactualEntityType, List<FactualEntity>>{};
    for (final entity in entities) {
      grouped.putIfAbsent(entity.type, () => []).add(entity);
    }
    // 按 type 顺序：character/location/item/lore/organization/misc
    const typeOrder = [
      FactualEntityType.character,
      FactualEntityType.location,
      FactualEntityType.item,
      FactualEntityType.lore,
      FactualEntityType.organization,
      FactualEntityType.misc,
    ];

    return RefreshIndicator(
      color: colors.primary,
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          LmSpacing.sLg,
          LmSpacing.sSm,
          LmSpacing.sLg,
          LmSpacing.sXl,
        ),
        itemCount: grouped.length,
        itemBuilder: (context, index) {
          final type = typeOrder.where(grouped.containsKey).toList()[index];
          final list = grouped[type]!;
          return FactualEntityTypeGroup(
            type: type,
            entities: list,
            attributesByEntity: _attributesByEntity,
            colors: colors,
            t: t,
            onEditEntity: _onEditEntity,
            onDeleteEntity: _onDeleteEntity,
            onRestoreEntity: _onRestoreEntity,
            onArchiveEntity: _onArchiveEntity,
            onToggleEntityInjection: _onToggleEntityInjection,
            onEditAttribute: _onEditAttribute,
            onDeleteAttribute: _onDeleteAttribute,
            selectedIds: _multiSelectMode ? _selectedEntityIds : null,
            onToggleSelect: _multiSelectMode ? _onToggleEntitySelect : null,
            readOnly: widget.readOnly,
            isFirstGroup: index == 0,
          );
        },
      ),
    );
  }
}
