import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/presentation/utils/director_human_presenter.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_anchor_edit_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/i18n/factual_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Unified "World Status" modal sheet for compact/narrow viewports.
///
/// Surfaces the memory browser, pure-reading toggle, export, title refresh,
/// current narrative anchor (with inline edit entry), foreshadowing list, and
/// human-readable key cast & lore in one quiet editorial panel.
class DirectorWorldStatusSheet extends StatefulWidget {
  const DirectorWorldStatusSheet({
    required this.loader,
    required this.pureReading,
    required this.isGenerating,
    required this.onOpenMemory,
    required this.onTogglePureReading,
    required this.onExport,
    required this.onUpdateTitle,
    this.fallbackAnchor,
    this.fallbackNarrativeTime,
    this.entityNameMap,
    this.onEditAnchor,
    super.key,
  });

  final Future<DirectorCoreBlocksData?> Function() loader;
  final StoryAnchor? fallbackAnchor;
  final String? fallbackNarrativeTime;
  final Map<String, String>? entityNameMap;
  final bool pureReading;
  final bool isGenerating;
  final VoidCallback onOpenMemory;
  final VoidCallback onTogglePureReading;
  final VoidCallback onExport;
  final VoidCallback onUpdateTitle;
  final Future<bool> Function(StoryAnchor anchor)? onEditAnchor;

  static Future<void> show(
    BuildContext context, {
    required Future<DirectorCoreBlocksData?> Function() loader,
    required bool pureReading,
    required bool isGenerating,
    required VoidCallback onOpenMemory,
    required VoidCallback onTogglePureReading,
    required VoidCallback onExport,
    required VoidCallback onUpdateTitle,
    StoryAnchor? fallbackAnchor,
    String? fallbackNarrativeTime,
    Map<String, String>? entityNameMap,
    Future<bool> Function(StoryAnchor anchor)? onEditAnchor,
  }) {
    return showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => DirectorWorldStatusSheet(
        loader: loader,
        fallbackAnchor: fallbackAnchor,
        fallbackNarrativeTime: fallbackNarrativeTime,
        entityNameMap: entityNameMap,
        pureReading: pureReading,
        isGenerating: isGenerating,
        onOpenMemory: onOpenMemory,
        onTogglePureReading: onTogglePureReading,
        onExport: onExport,
        onUpdateTitle: onUpdateTitle,
        onEditAnchor: onEditAnchor,
      ),
    );
  }

  @override
  State<DirectorWorldStatusSheet> createState() =>
      _DirectorWorldStatusSheetState();
}

class _DirectorWorldStatusSheetState extends State<DirectorWorldStatusSheet> {
  late bool _pureReading;
  StoryAnchor? _editedAnchor;

  @override
  void initState() {
    super.initState();
    _pureReading = widget.pureReading;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.86;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: IntermediateSpacing.sSm),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.full),
                  ),
                ),
              ),
            ),
            Flexible(
              child: DirectorWorldStatusPanel(
                loader: widget.loader,
                fallbackAnchor: _editedAnchor ?? widget.fallbackAnchor,
                fallbackNarrativeTime: widget.fallbackNarrativeTime,
                entityNameMap: widget.entityNameMap,
                pureReading: _pureReading,
                isGenerating: widget.isGenerating,
                embedded: false,
                onClose: () => Navigator.of(context).pop(),
                onOpenMemory: () {
                  Navigator.of(context).pop();
                  widget.onOpenMemory();
                },
                onTogglePureReading: () {
                  setState(() => _pureReading = !_pureReading);
                  widget.onTogglePureReading();
                },
                onExport: () {
                  Navigator.of(context).pop();
                  widget.onExport();
                },
                onUpdateTitle: () {
                  Navigator.of(context).pop();
                  widget.onUpdateTitle();
                },
                onEditAnchor: widget.onEditAnchor == null
                    ? null
                    : (anchor) async {
                        final ok = await widget.onEditAnchor!(anchor);
                        if (ok && mounted) {
                          setState(() => _editedAnchor = anchor);
                        }
                        return ok;
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared World Status content panel used both inside [DirectorWorldStatusSheet]
/// on compact screens and as the docked right inspector on wide screens.
class DirectorWorldStatusPanel extends StatefulWidget {
  const DirectorWorldStatusPanel({
    required this.loader,
    required this.pureReading,
    required this.isGenerating,
    required this.onOpenMemory,
    required this.onTogglePureReading,
    required this.onExport,
    required this.onUpdateTitle,
    this.fallbackAnchor,
    this.fallbackNarrativeTime,
    this.entityNameMap,
    this.onEditAnchor,
    this.onClose,
    this.embedded = true,
    this.refreshToken,
    super.key,
  });

  final Future<DirectorCoreBlocksData?> Function() loader;
  final StoryAnchor? fallbackAnchor;
  final String? fallbackNarrativeTime;
  final Map<String, String>? entityNameMap;
  final bool pureReading;
  final bool isGenerating;
  final VoidCallback onOpenMemory;
  final VoidCallback onTogglePureReading;
  final VoidCallback onExport;
  final VoidCallback onUpdateTitle;
  final Future<bool> Function(StoryAnchor anchor)? onEditAnchor;
  final VoidCallback? onClose;

  /// True when docked as a desktop right-side inspector; false inside a sheet.
  final bool embedded;

  /// When this token changes, the panel reloads core blocks data.
  final Object? refreshToken;

  @override
  State<DirectorWorldStatusPanel> createState() =>
      _DirectorWorldStatusPanelState();
}

class _DirectorWorldStatusPanelState extends State<DirectorWorldStatusPanel> {
  static const int _openForeshadowPreviewLimit = 6;
  static const int _resolvedForeshadowPreviewLimit = 4;

  late Future<DirectorCoreBlocksData?> _future;
  bool _showAllOpen = false;
  bool _showAllResolved = false;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  @override
  void didUpdateWidget(covariant DirectorWorldStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _future = widget.loader();
    });
  }

  Future<void> _openAnchorEditor(
    StoryAnchor? currentAnchor,
    String? narrativeTime,
  ) async {
    final onEdit = widget.onEditAnchor;
    if (onEdit == null || widget.isGenerating) return;
    final seed = currentAnchor ??
        StoryAnchor(
          updatedTurn: 0,
          narrativeTime: narrativeTime,
        );
    final edited = await DirectorAnchorEditSheet.show(context, seed);
    if (edited == null || !mounted) return;
    final ok = await onEdit(edited);
    if (ok && mounted) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final surfaceColor = widget.embedded
        ? context.lmUi.sidebarSurfaceColor(context)
        : Colors.transparent;

    return ColoredBox(
      color: surfaceColor,
      child: Column(
        mainAxisSize: widget.embedded ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IntermediateSpacing.sLg,
              IntermediateSpacing.sSm,
              IntermediateSpacing.sSm,
              IntermediateSpacing.sXs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.advanced.worldSheet.title,
                    style: IntermediateTextStyles.title.copyWith(
                      fontSize: 17,
                      color: colors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('world-status-refresh'),
                  onPressed: _reload,
                  tooltip: t.advanced.worldSheet.refreshTooltip,
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: colors.muted,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    key: const ValueKey('world-status-close'),
                    onPressed: widget.onClose,
                    tooltip: t.common.close,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 19,
                      color: colors.muted,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
              ],
            ),
          ),
          // Top quick action bar: always accessible regardless of loader state.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IntermediateSpacing.sLg,
              IntermediateSpacing.s2xs,
              IntermediateSpacing.sLg,
              IntermediateSpacing.sSm,
            ),
            child: _buildQuickActions(context, colors, t),
          ),
          Divider(height: 1, thickness: 0.5, color: colors.divider),
          Flexible(
            child: FutureBuilder<DirectorCoreBlocksData?>(
              future: _future,
              builder: (context, snapshot) {
                final loading =
                    snapshot.connectionState != ConnectionState.done;
                final data = snapshot.data;
                final entityNames = _buildEntityNameLookup(data);
                final anchor = data?.anchor ?? widget.fallbackAnchor;
                final narrativeTime = _firstNonEmpty(
                  [
                    data?.narrativeTime,
                    anchor?.narrativeTime,
                    widget.fallbackNarrativeTime,
                  ],
                  t: t,
                  entityNames: entityNames,
                );
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    IntermediateSpacing.sLg,
                    IntermediateSpacing.sMd,
                    IntermediateSpacing.sLg,
                    IntermediateSpacing.sXl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildNowSection(
                        context,
                        colors: colors,
                        t: t,
                        anchor: anchor,
                        narrativeTime: narrativeTime,
                        macros: data?.latestMacros ?? const [],
                        entityNames: entityNames,
                      ),
                      const SizedBox(height: IntermediateSpacing.sXl),
                      _buildForeshadowsSection(
                        context,
                        colors: colors,
                        t: t,
                        anchor: anchor,
                        entityNames: entityNames,
                      ),
                      const SizedBox(height: IntermediateSpacing.sXl),
                      _buildEntitiesSection(
                        context,
                        colors: colors,
                        t: t,
                        loading: loading,
                        data: data,
                        entityNames: entityNames,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(
    BuildContext context,
    LmPalette colors,
    Translations t,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: IntermediateSpacing.sSm,
          runSpacing: IntermediateSpacing.sSm,
          children: [
            _QuickActionPill(
              key: const ValueKey('world-status-open-memory'),
              icon: Icons.library_books_outlined,
              label: t.advanced.worldSheet.openMemory,
              highlighted: true,
              onTap: widget.onOpenMemory,
            ),
            _QuickActionPill(
              key: const ValueKey('world-status-pure-reading'),
              icon: widget.pureReading
                  ? Icons.auto_stories
                  : Icons.auto_stories_outlined,
              label: t.advanced.pureReading.toggle,
              highlighted: widget.pureReading,
              onTap: widget.onTogglePureReading,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        Wrap(
          spacing: IntermediateSpacing.sMd,
          runSpacing: IntermediateSpacing.s2xs,
          children: [
            _SecondaryActionLink(
              key: const ValueKey('world-status-export'),
              icon: Icons.file_download_outlined,
              label: t.advanced.export.menuLabel,
              onTap: widget.onExport,
            ),
            _SecondaryActionLink(
              key: const ValueKey('world-status-update-title'),
              icon: Icons.title_outlined,
              label: t.advanced.settings.updateTitle,
              onTap: widget.isGenerating ? null : widget.onUpdateTitle,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNowSection(
    BuildContext context, {
    required LmPalette colors,
    required Translations t,
    required StoryAnchor? anchor,
    required String? narrativeTime,
    required List<ExperientialMemory> macros,
    required Map<String, String> entityNames,
  }) {
    final arc = _cleanText(anchor?.arc, t: t, entityNames: entityNames);
    final oneLiner =
        _cleanText(anchor?.oneLiner, t: t, entityNames: entityNames);
    final macroSummaries = <String>[
      for (final macro in macros.take(2))
        if (_cleanText(macro.summary, t: t, entityNames: entityNames)
            case final String text)
          text,
    ];
    final hasAny = narrativeTime != null ||
        arc != null ||
        oneLiner != null ||
        macroSummaries.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.advanced.worldSheet.sectionNow,
                style: IntermediateTextStyles.label.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.onEditAnchor != null)
              InkWell(
                key: const ValueKey('world-status-edit-anchor'),
                onTap: widget.isGenerating
                    ? null
                    : () => _openAnchorEditor(anchor, narrativeTime),
                borderRadius: BorderRadius.circular(
                  context.lmUi.radius(LmCorner.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sSm,
                    vertical: IntermediateSpacing.sXs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.edit_outlined,
                        size: 13,
                        color:
                            widget.isGenerating ? colors.faint : colors.primary,
                      ),
                      const SizedBox(width: IntermediateSpacing.s2xs),
                      Text(
                        t.advanced.anchorEdit.entry,
                        style: IntermediateTextStyles.caption.copyWith(
                          color: widget.isGenerating
                              ? colors.faint
                              : colors.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        if (!hasAny)
          Text(
            t.advanced.worldSheet.nowEmpty,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          )
        else ...[
          if (narrativeTime != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.schedule_outlined,
                    size: 14,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Expanded(
                  child: Text(
                    narrativeTime,
                    style: IntermediateTextStyles.bodyUi.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
          ],
          if (arc != null) ...[
            Text(
              t.advanced.recap.arc,
              style: IntermediateTextStyles.captionSm.copyWith(
                color: colors.muted,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.s3xs),
            Text(
              arc,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.ink,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
          ],
          if (oneLiner != null) ...[
            Text(
              t.advanced.worldSheet.oneLinerLabel,
              style: IntermediateTextStyles.captionSm.copyWith(
                color: colors.muted,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.s3xs),
            Text(
              oneLiner,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.muted,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ],
          if (macroSummaries.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.sSm),
            Text(
              t.advanced.worldSheet.storylineLabel,
              style: IntermediateTextStyles.captionSm.copyWith(
                color: colors.muted,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.s2xs),
            for (final line in macroSummaries)
              Padding(
                padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
                child: Text(
                  line,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _buildForeshadowsSection(
    BuildContext context, {
    required LmPalette colors,
    required Translations t,
    required StoryAnchor? anchor,
    required Map<String, String> entityNames,
  }) {
    final open = anchor?.openForeshadows ?? const <AnchorForeshadow>[];
    final resolved =
        anchor?.foreshadows.where((f) => f.resolved).toList(growable: false) ??
            const <AnchorForeshadow>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.worldSheet.sectionForeshadows,
          style: IntermediateTextStyles.label.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        if (open.isEmpty && resolved.isEmpty)
          Text(
            t.advanced.worldSheet.foreshadowsEmpty,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          )
        else ...[
          if (open.isNotEmpty) ...[
            _subGroupLabel(
              t.advanced.recap.foreshadowsOpen,
              count: open.length,
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            for (final item in _visibleForeshadows(
              open,
              _showAllOpen,
              _openForeshadowPreviewLimit,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: IntermediateSpacing.sSm),
                    Expanded(
                      child: Text(
                        _sanitizeHumanText(
                          item.text,
                          t: t,
                          entityNames: entityNames,
                        ),
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          color: colors.ink,
                          fontSize: 13.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (open.length > _openForeshadowPreviewLimit)
              _buildExpandToggle(
                context,
                expanded: _showAllOpen,
                hiddenCount: open.length - _openForeshadowPreviewLimit,
                colors: colors,
                t: t,
                onTap: () => setState(() => _showAllOpen = !_showAllOpen),
              ),
          ],
          if (resolved.isNotEmpty) ...[
            if (open.isNotEmpty)
              const SizedBox(height: IntermediateSpacing.sMd),
            _subGroupLabel(
              t.advanced.recap.foreshadowsResolved,
              count: resolved.length,
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            for (final item in _visibleForeshadows(
              resolved,
              _showAllResolved,
              _resolvedForeshadowPreviewLimit,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: colors.success,
                      ),
                    ),
                    const SizedBox(width: IntermediateSpacing.sXs),
                    Expanded(
                      child: Text(
                        _sanitizeHumanText(
                          item.text,
                          t: t,
                          entityNames: entityNames,
                        ),
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          color: colors.muted,
                          fontSize: 13,
                          height: 1.45,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (resolved.length > _resolvedForeshadowPreviewLimit)
              _buildExpandToggle(
                context,
                expanded: _showAllResolved,
                hiddenCount: resolved.length - _resolvedForeshadowPreviewLimit,
                colors: colors,
                t: t,
                onTap: () =>
                    setState(() => _showAllResolved = !_showAllResolved),
              ),
          ],
        ],
      ],
    );
  }

  Widget _buildEntitiesSection(
    BuildContext context, {
    required LmPalette colors,
    required Translations t,
    required bool loading,
    required DirectorCoreBlocksData? data,
    required Map<String, String> entityNames,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.worldSheet.sectionEntities,
          style: IntermediateTextStyles.label.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (data == null)
          Text(
            t.advanced.worldSheet.entitiesUnavailable,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
              height: 1.5,
            ),
          )
        else if (data.keyEntities.isEmpty && data.recentActiveEntities.isEmpty)
          Text(
            t.advanced.worldSheet.entitiesEmpty,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          )
        else ...[
          for (var i = 0; i < data.keyEntities.take(10).length; i++) ...[
            if (i > 0)
              Divider(
                height: IntermediateSpacing.sMd,
                thickness: 0.5,
                color: colors.divider,
              ),
            _buildEntityEntry(
              context,
              entity: data.keyEntities[i],
              attributes:
                  data.attributesByEntity[data.keyEntities[i].entityId] ??
                      const [],
              colors: colors,
              t: t,
              entityNames: entityNames,
            ),
          ],
          if (data.recentActiveEntities.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.sLg),
            _subGroupLabel(
              t.advanced.worldSheet.recentActiveSection,
              count: data.recentActiveEntities.length,
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            for (var i = 0; i < data.recentActiveEntities.length; i++) ...[
              if (i > 0)
                Divider(
                  height: IntermediateSpacing.sMd,
                  thickness: 0.5,
                  color: colors.divider,
                ),
              _buildEntityEntry(
                context,
                entity: data.recentActiveEntities[i],
                attributes: data.attributesByEntity[
                        data.recentActiveEntities[i].entityId] ??
                    const [],
                colors: colors,
                t: t,
                entityNames: entityNames,
              ),
            ],
          ],
        ],
      ],
    );
  }

  Widget _buildEntityEntry(
    BuildContext context, {
    required FactualEntity entity,
    required List<FactualAttribute> attributes,
    required LmPalette colors,
    required Translations t,
    required Map<String, String> entityNames,
  }) {
    final name = DirectorHumanPresenter.resolveEntityName(
      t: t,
      primaryName: entity.primaryName,
      entityId: entity.entityId,
      entityType: entity.type.name,
      entityNames: entityNames,
    );
    final typeLabel = DirectorHumanPresenter.entityTypeLabel(entity.type, t);
    final sourceLabel = switch (entity.source) {
      FactualSource.auto => null,
      FactualSource.worldbook => t.advanced.scriptBoard.sourceWorldbook,
      FactualSource.card => t.advanced.scriptBoard.sourceCard,
    };
    final coreTraits = <String>[];
    for (final attr in attributes.where((a) => a.importance >= 3).take(4)) {
      final value = _formatHumanAttributeValue(
        attr,
        t: t,
        entityNames: entityNames,
      );
      if (value == null) continue;
      final rawLabel =
          factualAttributeLabel(t, entity.type, attr.attrKey) ?? attr.attrKey;
      final cleanLabel = _sanitizeHumanText(
        rawLabel,
        t: t,
        entityNames: entityNames,
      );
      coreTraits.add(cleanLabel.isEmpty ? value : '$cleanLabel: $value');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: IntermediateSpacing.sXs,
          runSpacing: IntermediateSpacing.s3xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              name,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            _MetaTag(label: typeLabel),
            if (sourceLabel != null) _MetaTag(label: sourceLabel, accent: true),
          ],
        ),
        if (coreTraits.isNotEmpty) ...[
          const SizedBox(height: IntermediateSpacing.s2xs),
          for (final trait in coreTraits)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                trait,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _subGroupLabel(
    String label, {
    required int count,
    required LmPalette colors,
  }) {
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: IntermediateTextStyles.captionSm.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: IntermediateSpacing.sXs),
        Text(
          '$count',
          style: IntermediateTextStyles.captionSm.copyWith(
            color: colors.faint,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildExpandToggle(
    BuildContext context, {
    required bool expanded,
    required int hiddenCount,
    required LmPalette colors,
    required Translations t,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.s3xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(
          context.lmUi.radius(LmCorner.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sXs,
            vertical: IntermediateSpacing.s2xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 14,
                color: colors.primary,
              ),
              const SizedBox(width: IntermediateSpacing.s3xs),
              Flexible(
                child: Text(
                  expanded
                      ? t.advanced.recap.foreshadowsCollapse
                      : t.advanced.recap.foreshadowsExpandAll(
                          count: hiddenCount,
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<AnchorForeshadow> _visibleForeshadows(
    List<AnchorForeshadow> list,
    bool showAll,
    int limit,
  ) =>
      showAll ? list : list.take(limit).toList(growable: false);

  Map<String, String> _buildEntityNameLookup(DirectorCoreBlocksData? data) {
    final map = <String, String>{
      if (widget.entityNameMap != null) ...widget.entityNameMap!,
    };
    if (data != null) {
      for (final entity in data.keyEntities) {
        final name = entity.primaryName.trim();
        if (entity.entityId.isNotEmpty && name.isNotEmpty) {
          map[entity.entityId] = name;
        }
      }
      for (final entity in data.recentActiveEntities) {
        final name = entity.primaryName.trim();
        if (entity.entityId.isNotEmpty && name.isNotEmpty) {
          map[entity.entityId] = name;
        }
      }
    }
    return map;
  }

  String? _formatHumanAttributeValue(
    FactualAttribute attr, {
    required Translations t,
    required Map<String, String> entityNames,
  }) {
    switch (attr.valueType) {
      case AttributeValueType.list:
        final items = attr.listValue
            .map(
              (raw) => _sanitizeHumanText(raw, t: t, entityNames: entityNames),
            )
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
        if (items.isEmpty) return null;
        return items.join(' · ');
      case AttributeValueType.dict:
        try {
          final decoded = jsonDecode(attr.value);
          if (decoded is Map) {
            final pairs = <String>[];
            for (final entry in decoded.entries) {
              final key = _sanitizeHumanText(
                '${entry.key}',
                t: t,
                entityNames: entityNames,
              );
              final val = _sanitizeHumanText(
                '${entry.value}',
                t: t,
                entityNames: entityNames,
              );
              if (key.isNotEmpty && val.isNotEmpty) {
                pairs.add('$key: $val');
              } else if (val.isNotEmpty) {
                pairs.add(val);
              }
            }
            if (pairs.isNotEmpty) return pairs.join(' · ');
          }
        } on FormatException {
          // Fall back to sanitized text below.
        }
        final fallback = _sanitizeHumanText(
          attr.value,
          t: t,
          entityNames: entityNames,
        );
        return fallback.isEmpty ? null : fallback;
      case AttributeValueType.single:
        final text = _sanitizeHumanText(
          attr.value,
          t: t,
          entityNames: entityNames,
        );
        return text.isEmpty ? null : text;
    }
  }

  String _sanitizeHumanText(
    String raw, {
    required Translations t,
    required Map<String, String> entityNames,
  }) {
    return DirectorHumanPresenter.sanitizeHumanText(
      raw,
      t,
      entityNames: entityNames,
    );
  }

  String? _cleanText(
    String? raw, {
    required Translations t,
    required Map<String, String> entityNames,
  }) {
    if (raw == null) return null;
    final sanitized = _sanitizeHumanText(raw, t: t, entityNames: entityNames);
    return sanitized.isEmpty ? null : sanitized;
  }

  String? _firstNonEmpty(
    List<String?> candidates, {
    required Translations t,
    required Map<String, String> entityNames,
  }) {
    for (final candidate in candidates) {
      final cleaned = _cleanText(candidate, t: t, entityNames: entityNames);
      if (cleaned != null) return cleaned;
    }
    return null;
  }
}

class _QuickActionPill extends StatefulWidget {
  const _QuickActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  State<_QuickActionPill> createState() => _QuickActionPillState();
}

class _QuickActionPillState extends State<_QuickActionPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final radius = BorderRadius.circular(context.lmUi.radius(LmCorner.full));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: LmMotion.durationFor(context, LmMotion.micro),
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sXs,
            ),
            decoration: BoxDecoration(
              color: widget.highlighted || _hovered
                  ? colors.primaryDim
                  : colors.surfaceVariant,
              borderRadius: radius,
              border: Border.all(
                color: widget.highlighted
                    ? colors.primary.withValues(alpha: 0.38)
                    : colors.divider,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 15,
                  color: widget.highlighted ? colors.primary : colors.muted,
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: widget.highlighted ? colors.primary : colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryActionLink extends StatelessWidget {
  const _SecondaryActionLink({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final enabled = onTap != null;
    final fg = enabled ? colors.muted : colors.faint;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 34),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sXs,
            vertical: IntermediateSpacing.s2xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: IntermediateSpacing.s2xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IntermediateTextStyles.caption.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaTag extends StatelessWidget {
  const _MetaTag({
    required this.label,
    this.accent = false,
  });

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sXs,
        vertical: 1.5,
      ),
      decoration: BoxDecoration(
        color: accent ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Text(
        label,
        style: IntermediateTextStyles.captionSm.copyWith(
          color: accent ? colors.primary : colors.muted,
          fontSize: 10.5,
        ),
      ),
    );
  }
}
