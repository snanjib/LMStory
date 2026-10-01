import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 经历记忆 Tab（记忆查看器）。
///
/// 展示会话内全部经历类记忆（按轮次升序），支持：
/// - 关键字搜索（summary + 5W1E 字段全文匹配）
/// - 点击条目查看详情
/// - 编辑（summary + 5W1E + importance + tags）
/// - 删除（带确认）
/// - 新增（手动添加一条事件）
///
/// 视觉：时间线式列表，每条记忆一个紧凑卡片，展示 displayText + 轮次 + 重要性。
class ExperienceMemoryTab extends ConsumerStatefulWidget {
  const ExperienceMemoryTab({
    required this.sessionId,
    super.key,
  });

  final String sessionId;

  @override
  ConsumerState<ExperienceMemoryTab> createState() =>
      _ExperienceMemoryTabState();
}

class _ExperienceMemoryTabState extends ConsumerState<ExperienceMemoryTab> {
  final _logger = const Logger('ExperienceMemoryTab');
  final _searchController = TextEditingController();

  List<ExperientialMemory> _allMemories = [];
  List<ExperientialMemory> _filteredMemories = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _searchQuery = '';

  // 筛选状态
  bool _filterExpanded = false; // 筛选栏展开/折叠
  int _typeFilter = 0; // 0=全部, 1=段落摘要, 2=事件记忆
  int _importanceFilter = 0; // 0=全部, 1=五星, 2=四星及以上, 3=三星及以下
  // 归档筛选——归档记忆不参与检索
  //（FTS/向量两通道均排除），此前浏览器无标识也无筛选，看得见却搜不到
  int _archiveFilter = 0; // 0=全部, 1=活跃, 2=已归档

  // 排序状态
  int _sortBy = 0; // 0=轮次, 1=重要性, 2=创建时间

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadMemories();
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
      _applyFilter();
    });
  }

  Future<void> _loadMemories() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final repo = ref.read(experienceRepositoryProvider);
      final memories = await repo.getAllExperiences(widget.sessionId);
      setState(() {
        _allMemories = memories;
        _applyFilter();
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load experiential memories',
        error: e,
        stackTrace: stackTrace,
      );
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  void _applyFilter() {
    // 1. 搜索过滤
    var filtered = _allMemories.where((m) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      return (m.summary?.toLowerCase().contains(query) ?? false) ||
          (m.when?.toLowerCase().contains(query) ?? false) ||
          (m.where?.toLowerCase().contains(query) ?? false) ||
          (m.who?.toLowerCase().contains(query) ?? false) ||
          (m.what?.toLowerCase().contains(query) ?? false) ||
          (m.significance?.toLowerCase().contains(query) ?? false) ||
          (m.extra?.toLowerCase().contains(query) ?? false) ||
          m.tags.any((t) => t.toLowerCase().contains(query));
    }).toList();

    // 2. 类型筛选：1=段落摘要(isMacro), 2=事件记忆(!isMacro)
    if (_typeFilter == 1) {
      filtered = filtered.where((m) => m.isMacro).toList();
    } else if (_typeFilter == 2) {
      filtered = filtered.where((m) => !m.isMacro).toList();
    }

    // 3. 重要性筛选
    if (_importanceFilter == 1) {
      filtered = filtered.where((m) => m.importance == 5).toList();
    } else if (_importanceFilter == 2) {
      filtered = filtered.where((m) => m.importance >= 4).toList();
    } else if (_importanceFilter == 3) {
      filtered = filtered.where((m) => m.importance <= 3).toList();
    }

    // 3.5 归档筛选
    if (_archiveFilter == 1) {
      filtered = filtered.where((m) => !m.isArchived).toList();
    } else if (_archiveFilter == 2) {
      filtered = filtered.where((m) => m.isArchived).toList();
    }

    // 4. 排序
    switch (_sortBy) {
      case 0:
        filtered.sort((a, b) => a.turnNumber.compareTo(b.turnNumber));
      case 1:
        filtered.sort((a, b) => b.importance.compareTo(a.importance));
      case 2:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    _filteredMemories = filtered;
  }

  /// 当前是否有任意筛选条件生效（用于过滤按钮颜色）。
  bool get _hasActiveFilter =>
      _typeFilter != 0 || _importanceFilter != 0 || _archiveFilter != 0;

  Future<void> _onDeleteMemory(ExperientialMemory memory) async {
    final t = Translations.of(context);
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
              .deleteExperienceConfirm(turn: memory.turnNumber),
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
      final repo = ref.read(experienceRepositoryProvider);
      await repo.deleteExperienceById(
        memory.memoryId,
        sessionId: widget.sessionId,
      );
      await _loadMemories();
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
        'Failed to delete experiential memory',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('${t.intermediate.memoryBrowser.deleteFailed}: $e'),
          ),
        );
      }
    }
  }

  /// 归档/恢复经历记忆——可逆轻操作不弹确认，
  /// 直接落库+重载+floating SnackBar 反馈。
  Future<void> _onArchiveMemory(ExperientialMemory memory) async {
    final t = Translations.of(context);
    try {
      final repo = ref.read(experienceRepositoryProvider);
      await repo.setExperienceArchived(
        memory.memoryId,
        sessionId: widget.sessionId,
        archived: !memory.isArchived,
      );
      await _loadMemories();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              memory.isArchived
                  ? t.intermediate.memoryBrowser.unarchiveMemoryDone
                  : t.intermediate.memoryBrowser.archiveMemoryDone,
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Archive/unarchive experience failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.archiveMemoryFailed),
          ),
        );
      }
    }
  }

  Future<void> _onEditMemory(ExperientialMemory memory) async {
    final t = Translations.of(context);
    final result = await showLmDialog<_EditResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ExperienceEditDialog(
        memory: memory,
        title: t.intermediate.memoryBrowser.editExperienceTitle,
      ),
    );
    if (result == null) return;

    try {
      final repo = ref.read(experienceRepositoryProvider);
      await repo.updateExperience(
        memoryId: memory.memoryId,
        sessionId: memory.sessionId,
        summary: result.summary,
        when: result.when,
        where: result.where,
        who: result.who,
        what: result.what,
        significance: result.significance,
        extra: result.extra,
        importance: result.importance,
        tags: result.tags,
      );
      await _loadMemories();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saved),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to update experiential memory',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('${t.intermediate.memoryBrowser.saveFailed}: $e'),
          ),
        );
      }
    }
  }

  Future<void> _onAddMemory() async {
    final t = Translations.of(context);
    final nextTurn = _allMemories.isEmpty
        ? 1
        : _allMemories
                .map((m) => m.turnNumber)
                .reduce((a, b) => a > b ? a : b) +
            1;
    final result = await showLmDialog<_EditResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ExperienceEditDialog(
        memory: null,
        nextTurn: nextTurn,
        title: t.intermediate.memoryBrowser.addExperienceTitle,
      ),
    );
    if (result == null) return;

    try {
      final repo = ref.read(experienceRepositoryProvider);
      await repo.appendExperience(
        sessionId: widget.sessionId,
        summary: result.summary,
        importance: result.importance ?? 3,
        tags: result.tags ?? const [],
        turnNumber: result.turnNumber ?? nextTurn,
        when: result.when,
        where: result.where,
        who: result.who,
        what: result.what,
        significance: result.significance,
        extra: result.extra,
        // 手动新增标记 manual，重生成/删除本轮不随 turn 窗吞删
        source: 'manual',
      );
      await _loadMemories();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.memoryBrowser.saved),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to add experiential memory',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('${t.intermediate.memoryBrowser.saveFailed}: $e'),
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
      return _buildErrorState(colors, t, _errorMessage!);
    }

    return Column(
      children: [
        _buildStatsBar(colors, t),
        _buildSearchBar(colors, t),
        _buildFilterChips(colors, t),
        Expanded(child: _buildList(colors, t)),
      ],
    );
  }

  Widget _buildSearchBar(LmPalette colors, Translations t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sLg,
        LmSpacing.sSm,
        LmSpacing.sLg,
        LmSpacing.sSm,
      ),
      color: colors.bg,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
              decoration: InputDecoration(
                hintText: t.intermediate.memoryBrowser.searchHint,
                hintStyle:
                    LmNarrativeTextStyles.input.copyWith(color: colors.muted),
                prefixIcon: Icon(Icons.search, color: colors.muted, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colors.muted, size: 18),
                        tooltip: t.common.clear,
                        onPressed: _searchController.clear,
                      )
                    : null,
                filled: true,
                fillColor: colors.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: LmSpacing.sMd,
                  vertical: LmSpacing.sSm,
                ),
              ),
            ),
          ),
          const SizedBox(width: LmSpacing.sSm),
          _buildSortButton(colors, t),
          IconButton(
            icon: Icon(
              _filterExpanded ? Icons.filter_list : Icons.filter_list_outlined,
              color: _hasActiveFilter ? colors.primary : colors.muted,
              size: 20,
            ),
            tooltip: t.intermediate.memoryBrowser.filterToggle,
            onPressed: () => setState(() => _filterExpanded = !_filterExpanded),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            color: colors.primary,
            tooltip: t.intermediate.memoryBrowser.addExperienceTitle,
            onPressed: _onAddMemory,
          ),
        ],
      ),
    );
  }

  Widget _buildStatsBar(LmPalette colors, Translations t) {
    final total = _allMemories.length;
    final macroCount = _allMemories.where((m) => m.isMacro).length;
    final microCount = total - macroCount;
    final filteredCount = _filteredMemories.length;
    // 补归档筛选—— 加归档三档时
    // 改了筛选按钮高亮口径（_hasActiveFilter 含 _archiveFilter），统计栏
    // 「显示 X / N」切换漏跟；选「已归档」时统计栏仍显示全量摘要。
    final isFiltered = _searchQuery.isNotEmpty ||
        _typeFilter != 0 ||
        _importanceFilter != 0 ||
        _archiveFilter != 0;

    final statsText = isFiltered
        ? '${t.intermediate.memoryBrowser.statsSummary(n: total, macro: macroCount, micro: microCount)} · ${t.intermediate.memoryBrowser.statsFiltered(shown: filteredCount, total: total)}'
        : t.intermediate.memoryBrowser
            .statsSummary(n: total, macro: macroCount, micro: microCount);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sLg,
        LmSpacing.sSm,
        LmSpacing.sLg,
        0,
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              statsText,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips(LmPalette colors, Translations t) {
    return AnimatedSize(
      duration: LmMotion.base,
      curve: LmMotion.easeBoth,
      child: _filterExpanded
          ? Padding(
              padding: const EdgeInsets.fromLTRB(
                LmSpacing.sLg,
                LmSpacing.sXs,
                LmSpacing.sLg,
                LmSpacing.sSm,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // ── 类型筛选 ──
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterAll,
                      selected: _typeFilter == 0,
                      colors: colors,
                      onTap: () => setState(() {
                        _typeFilter = 0;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterMacro,
                      selected: _typeFilter == 1,
                      colors: colors,
                      onTap: () => setState(() {
                        _typeFilter = 1;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterMicro,
                      selected: _typeFilter == 2,
                      colors: colors,
                      onTap: () => setState(() {
                        _typeFilter = 2;
                        _applyFilter();
                      }),
                    ),
                    // 竖线分隔
                    const SizedBox(width: LmSpacing.sSm),
                    SizedBox(
                      width: 1,
                      height: 20,
                      child: VerticalDivider(color: colors.divider),
                    ),
                    const SizedBox(width: LmSpacing.sSm),
                    // ── 重要性筛选 ──
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterAll,
                      selected: _importanceFilter == 0,
                      colors: colors,
                      onTap: () => setState(() {
                        _importanceFilter = 0;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterImportance5,
                      selected: _importanceFilter == 1,
                      colors: colors,
                      onTap: () => setState(() {
                        _importanceFilter = 1;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterImportance4Plus,
                      selected: _importanceFilter == 2,
                      colors: colors,
                      onTap: () => setState(() {
                        _importanceFilter = 2;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label:
                          t.intermediate.memoryBrowser.filterImportance3Minus,
                      selected: _importanceFilter == 3,
                      colors: colors,
                      onTap: () => setState(() {
                        _importanceFilter = 3;
                        _applyFilter();
                      }),
                    ),
                    // 竖线分隔
                    const SizedBox(width: LmSpacing.sSm),
                    SizedBox(
                      width: 1,
                      height: 20,
                      child: VerticalDivider(color: colors.divider),
                    ),
                    const SizedBox(width: LmSpacing.sSm),
                    // ── 归档筛选──
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterAll,
                      selected: _archiveFilter == 0,
                      colors: colors,
                      onTap: () => setState(() {
                        _archiveFilter = 0;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterActive,
                      selected: _archiveFilter == 1,
                      colors: colors,
                      onTap: () => setState(() {
                        _archiveFilter = 1;
                        _applyFilter();
                      }),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildFilterChip(
                      label: t.intermediate.memoryBrowser.filterArchived,
                      selected: _archiveFilter == 2,
                      colors: colors,
                      onTap: () => setState(() {
                        _archiveFilter = 2;
                        _applyFilter();
                      }),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required LmPalette colors,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.s2xs,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accent : Colors.transparent,
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
          ),
          borderRadius:
              BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        ),
        child: Text(
          label,
          style: LmNarrativeTextStyles.caption.copyWith(
            color: selected ? colors.bg : colors.muted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildSortButton(LmPalette colors, Translations t) {
    return PopupMenuButton<int>(
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sort, color: colors.muted, size: 20),
          Icon(
            _sortBy == 0 ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12,
            color: colors.muted,
          ),
        ],
      ),
      tooltip: t.intermediate.memoryBrowser.sortBy,
      onSelected: (value) {
        setState(() {
          _sortBy = value;
          _applyFilter();
        });
      },
      itemBuilder: (context) => [
        _buildSortMenuItem(
          0,
          t.intermediate.memoryBrowser.sortByTurn,
          colors,
        ),
        _buildSortMenuItem(
          1,
          t.intermediate.memoryBrowser.sortByImportance,
          colors,
        ),
        _buildSortMenuItem(
          2,
          t.intermediate.memoryBrowser.sortByCreatedAt,
          colors,
        ),
      ],
    );
  }

  PopupMenuItem<int> _buildSortMenuItem(
    int value,
    String label,
    LmPalette colors,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: _sortBy == value
                ? Icon(Icons.check, size: 16, color: colors.primary)
                : null,
          ),
          const SizedBox(width: LmSpacing.sXs),
          Flexible(
            child: Text(
              label,
              style: LmNarrativeTextStyles.bodyUi.copyWith(color: colors.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(LmPalette colors, Translations t) {
    if (_filteredMemories.isEmpty) {
      return _buildEmptyState(colors, t);
    }

    return RefreshIndicator(
      color: colors.primary,
      onRefresh: _loadMemories,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          LmSpacing.sLg,
          LmSpacing.sSm,
          LmSpacing.sLg,
          LmSpacing.sXl,
        ),
        itemCount: _filteredMemories.length,
        separatorBuilder: (_, __) => const SizedBox(height: LmSpacing.sSm),
        itemBuilder: (context, index) {
          final memory = _filteredMemories[index];
          return _MemoryCard(
            memory: memory,
            colors: colors,
            t: t,
            onEdit: () => _onEditMemory(memory),
            onDelete: () => _onDeleteMemory(memory),
            onArchive: () => _onArchiveMemory(memory),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(LmPalette colors, Translations t) {
    // 居中布局防护（项目规则 §9/§10）：本 tab 含搜索框（TextField），
    // 键盘弹出时 Expanded 可视高度减少 30%-50%，裸 Center+Column 会溢出。
    // 使用 LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) 模式。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sXl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _searchQuery.isEmpty
                        ? Icons.history_toggle_off_outlined
                        : Icons.search_off,
                    size: 48,
                    color: colors.faint,
                  ),
                  const SizedBox(height: LmSpacing.sMd),
                  Text(
                    _searchQuery.isEmpty
                        ? t.intermediate.memoryBrowser.experienceEmpty
                        : t.intermediate.memoryBrowser.searchEmpty,
                    style: LmNarrativeTextStyles.bodyUi.copyWith(
                      color: colors.muted,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorState(
    LmPalette colors,
    Translations t,
    String message,
  ) {
    // 居中布局防护（项目规则 §9/§10）：同 _buildEmptyState。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sXl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: colors.error),
                  const SizedBox(height: LmSpacing.sMd),
                  Text(
                    message,
                    style: LmNarrativeTextStyles.bodyUi.copyWith(
                      color: colors.ink,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: LmSpacing.sMd),
                  OutlinedButton(
                    onPressed: _loadMemories,
                    child: Text(
                      t.common.retry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 单条经历记忆卡片。
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.memory,
    required this.colors,
    required this.t,
    required this.onEdit,
    required this.onDelete,
    this.onArchive,
  });

  final ExperientialMemory memory;
  final LmPalette colors;
  final Translations t;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// 归档/恢复（null=不显示按钮）。
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.sMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              // 叙事时间（narrativeTime 非空才展示，兼容旧数据）
              if (_hasNarrativeTime) ...[
                const SizedBox(height: LmSpacing.sXs),
                _buildNarrativeTime(),
              ],
              const SizedBox(height: LmSpacing.sXs),
              _buildContent(),
              if (memory.tags.isNotEmpty) ...[
                const SizedBox(height: LmSpacing.sXs),
                _buildTags(),
              ],
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  /// 是否有叙事时间（非空且非空字符串）
  bool get _hasNarrativeTime {
    final v = memory.narrativeTime;
    return v != null && v.isNotEmpty;
  }

  /// 叙事时间展示行：钟表图标 + "叙事时间：xxx"
  Widget _buildNarrativeTime() {
    return Row(
      children: [
        Icon(Icons.schedule, size: 12, color: colors.muted),
        const SizedBox(width: LmSpacing.s2xs),
        Expanded(
          child: Text(
            '${t.intermediate.memoryBrowser.narrativeTime}：${memory.narrativeTime}',
            style: LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sXs,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: colors.primaryDim,
            borderRadius: BorderRadius.circular(LmRadius.rXs),
          ),
          child: Text(
            t.intermediate.memoryBrowser.turnLabel(turn: memory.turnNumber),
            style:
                LmNarrativeTextStyles.caption.copyWith(color: colors.primary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: LmSpacing.sXs),
        if (memory.isMacro) ...[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LmSpacing.sXs,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.accentDim,
              borderRadius: BorderRadius.circular(LmRadius.rXs),
            ),
            child: Text(
              t.intermediate.memoryBrowser.macroLabel,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.accent),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: LmSpacing.sXs),
        ],
        // 归档标识——归档记忆不参与检索（两通道均排除），
        // 此前浏览器无标识，用户会以为"库里有却搜不到"是缺陷
        if (memory.isArchived) ...[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LmSpacing.sXs,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(LmRadius.rXs),
              border: Border.all(color: colors.divider),
            ),
            child: Text(
              t.intermediate.memoryBrowser.archivedBadge,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: LmSpacing.sXs),
        ],
        Row(
          children: List.generate(
            5,
            (i) => Icon(
              i < memory.importance ? Icons.star : Icons.star_border,
              size: 12,
              color: i < memory.importance ? colors.primary : colors.faint,
            ),
          ),
        ),
        const Spacer(),
        if (memory.hasEmbedding)
          Icon(Icons.bolt_outlined, size: 14, color: colors.success),
      ],
    );
  }

  Widget _buildContent() {
    return Text(
      memory.displayText,
      style: LmNarrativeTextStyles.narrativeBody.copyWith(color: colors.ink),
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildTags() {
    return Wrap(
      spacing: LmSpacing.s2xs,
      runSpacing: 2,
      children: memory.tags.map((tag) {
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.s2xs,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(LmRadius.rXs),
          ),
          child: Text(
            tag,
            style: LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 18),
          color: colors.muted,
          tooltip: t.common.edit,
          onPressed: onEdit,
          visualDensity: VisualDensity.compact,
        ),
        if (onArchive != null) ...[
          IconButton(
            icon: Icon(
              memory.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              size: 18,
            ),
            color: colors.muted,
            tooltip: memory.isArchived
                ? t.intermediate.memoryBrowser.unarchiveMemory
                : t.intermediate.memoryBrowser.archiveMemory,
            onPressed: onArchive,
            visualDensity: VisualDensity.compact,
          ),
        ],
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          color: colors.error,
          tooltip: t.common.delete,
          onPressed: onDelete,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// 编辑/新增对话框的返回结果。
class _EditResult {
  _EditResult({
    this.summary,
    this.when,
    this.where,
    this.who,
    this.what,
    this.significance,
    this.extra,
    this.importance,
    this.tags,
    this.turnNumber,
  });

  final String? summary;
  final String? when;
  final String? where;
  final String? who;
  final String? what;
  final String? significance;
  final String? extra;
  final int? importance;
  final List<String>? tags;
  final int? turnNumber;
}

/// 经历记忆编辑/新增对话框。
class _ExperienceEditDialog extends StatefulWidget {
  const _ExperienceEditDialog({
    required this.memory,
    required this.title,
    this.nextTurn,
  });

  final ExperientialMemory? memory;
  final String title;
  final int? nextTurn;

  @override
  State<_ExperienceEditDialog> createState() => _ExperienceEditDialogState();
}

class _ExperienceEditDialogState extends State<_ExperienceEditDialog> {
  late final TextEditingController _summaryController;
  late final TextEditingController _whenController;
  late final TextEditingController _whereController;
  late final TextEditingController _whoController;
  late final TextEditingController _whatController;
  late final TextEditingController _significanceController;
  late final TextEditingController _extraController;
  late final TextEditingController _tagsController;
  late int _importance;
  late int _turnNumber;

  @override
  void initState() {
    super.initState();
    final m = widget.memory;
    _summaryController = TextEditingController(text: m?.summary ?? '');
    _whenController = TextEditingController(text: m?.when ?? '');
    _whereController = TextEditingController(text: m?.where ?? '');
    _whoController = TextEditingController(text: m?.who ?? '');
    _whatController = TextEditingController(text: m?.what ?? '');
    _significanceController =
        TextEditingController(text: m?.significance ?? '');
    _extraController = TextEditingController(text: m?.extra ?? '');
    _tagsController = TextEditingController(text: m?.tags.join(', ') ?? '');
    _importance = m?.importance ?? 3;
    _turnNumber = m?.turnNumber ?? widget.nextTurn ?? 1;
  }

  @override
  void dispose() {
    _summaryController.dispose();
    _whenController.dispose();
    _whereController.dispose();
    _whoController.dispose();
    _whatController.dispose();
    _significanceController.dispose();
    _extraController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return AlertDialog(
      title: Text(
        widget.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildField(
                controller: _summaryController,
                label: t.intermediate.memoryBrowser.fieldSummary,
                maxLines: 3,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _whatController,
                label: t.intermediate.memoryBrowser.fieldWhat,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _whoController,
                label: t.intermediate.memoryBrowser.fieldWho,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _whenController,
                label: t.intermediate.memoryBrowser.fieldWhen,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _whereController,
                label: t.intermediate.memoryBrowser.fieldWhere,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _significanceController,
                label: t.intermediate.memoryBrowser.fieldSignificance,
                maxLines: 2,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _extraController,
                label: t.intermediate.memoryBrowser.fieldExtra,
                maxLines: 2,
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                controller: _tagsController,
                label: t.intermediate.memoryBrowser.fieldTags,
                hint: t.intermediate.memoryBrowser.fieldTagsHint,
              ),
              const SizedBox(height: LmSpacing.sSm),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      t.intermediate.memoryBrowser.fieldImportance,
                      style: LmNarrativeTextStyles.label
                          .copyWith(color: colors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _importance.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      label: '$_importance',
                      activeColor: colors.primary,
                      onChanged: (v) => setState(() => _importance = v.round()),
                    ),
                  ),
                  Text(
                    '$_importance',
                    style: LmNarrativeTextStyles.label
                        .copyWith(color: colors.primary),
                  ),
                ],
              ),
              if (widget.memory == null) ...[
                const SizedBox(height: LmSpacing.sSm),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.intermediate.memoryBrowser.fieldTurn,
                        style: LmNarrativeTextStyles.label
                            .copyWith(color: colors.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: LmSpacing.sMd),
                    Expanded(
                      child: TextFormField(
                        initialValue: _turnNumber.toString(),
                        keyboardType: TextInputType.number,
                        style: LmNarrativeTextStyles.input
                            .copyWith(color: colors.ink),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: colors.surfaceVariant,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.md),
                            ),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: LmSpacing.sMd,
                            vertical: LmSpacing.sSm,
                          ),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n > 0) {
                            setState(() => _turnNumber = n);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t.common.cancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: _onSave,
          child: Text(
            t.common.save,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
  }) {
    final colors = context.lm.palette;
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
        hintText: hint,
        hintStyle: LmNarrativeTextStyles.input.copyWith(color: colors.muted),
        filled: true,
        fillColor: colors.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sMd,
          vertical: LmSpacing.sSm,
        ),
      ),
    );
  }

  void _onSave() {
    final tags = _tagsController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    Navigator.pop(
      context,
      _EditResult(
        summary: _blankToNull(_summaryController.text),
        when: _blankToNull(_whenController.text),
        where: _blankToNull(_whereController.text),
        who: _blankToNull(_whoController.text),
        what: _blankToNull(_whatController.text),
        significance: _blankToNull(_significanceController.text),
        extra: _blankToNull(_extraController.text),
        importance: _importance,
        tags: tags,
        turnNumber: widget.memory == null ? _turnNumber : null,
      ),
    );
  }
}
