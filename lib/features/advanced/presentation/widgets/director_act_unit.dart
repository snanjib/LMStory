import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/utils/director_human_presenter.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_anchor_edit_sheet.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_readable_color.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_thinking_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Lightweight single-line header opening an act unit (`Act N · Story time`).
///
/// Renders a hairline 0.5px top rule to separate acts with editorial breathing
/// room, plus an optional quiet status indicator on the trailing edge.
class DirectorActHeader extends StatelessWidget {
  const DirectorActHeader({
    required this.title,
    this.statusText,
    this.isActive = false,
    this.isError = false,
    this.showTopDivider = true,
    super.key,
  });

  final String title;
  final String? statusText;
  final bool isActive;
  final bool isError;
  final bool showTopDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final tagColor =
        isError ? colors.error : directorReadableColor(colors, colors.primary);
    final metaColor = isError
        ? colors.error
        : isActive
            ? directorReadableColor(colors, colors.primary)
            : directorReadableColor(colors, colors.muted);

    return Container(
      margin: EdgeInsets.only(
        top: showTopDivider ? IntermediateSpacing.sMd : IntermediateSpacing.sXs,
        bottom: IntermediateSpacing.sSm,
      ),
      padding: EdgeInsets.only(
        top: showTopDivider ? IntermediateSpacing.sSm : 0,
      ),
      decoration: showTopDivider
          ? BoxDecoration(
              border: Border(
                top: BorderSide(color: colors.divider, width: 0.5),
              ),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: IntermediateTextStyles.captionSm.copyWith(
                color: tagColor,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.35,
              ),
            ),
          ),
          if (statusText case final status? when status.isNotEmpty) ...[
            const SizedBox(width: IntermediateSpacing.sSm),
            Flexible(
              flex: 2,
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: metaColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lightweight director instruction block replacing heavy user message bubbles.
///
/// Uses a 1px structural left rule and a quiet tinted ground; instructions
/// longer than 3 visual lines collapse with an explicit toggle. Tapping the
/// instruction (or its trailing action icon) toggles the standard user action
/// row (copy / regenerate / edit / delete round).
class DirectorDirectiveBlock extends StatefulWidget {
  const DirectorDirectiveBlock({
    required this.content,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
    this.fontScale = 1.0,
    this.actionsEnabled = true,
    this.canOperate = true,
    this.windowRounds = 5,
    this.interactive = true,
    super.key,
  });

  final String content;
  final double fontScale;
  final bool actionsEnabled;
  final bool canOperate;
  final int windowRounds;
  final bool interactive;
  final VoidCallback onCopy;
  final VoidCallback onRegenerate;
  final VoidCallback onEdit;
  final VoidCallback onDeleteRound;

  @override
  State<DirectorDirectiveBlock> createState() => _DirectorDirectiveBlockState();
}

class _DirectorDirectiveBlockState extends State<DirectorDirectiveBlock> {
  static const int _collapsedMaxLines = 3;

  var _expanded = false;
  var _showActions = false;

  bool get _canRevealActions => widget.interactive && widget.actionsEnabled;

  @override
  void didUpdateWidget(DirectorDirectiveBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_canRevealActions && _showActions) {
      _showActions = false;
    }
  }

  void _toggleActions() {
    if (!_canRevealActions) return;
    setState(() => _showActions = !_showActions);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final cornerRadius = context.lmUi.radius(LmCorner.sm);
    final textStyle = IntermediateTextStyles.bodyUi.copyWith(
      fontSize: 14 * widget.fontScale,
      height: 1.55,
      color: directorReadableColor(colors, colors.ink.withValues(alpha: 0.9)),
    );
    final ruleColor = colors.primary.withValues(alpha: 0.65);
    final surfaceColor = colors.surfaceVariant.withValues(alpha: 0.55);

    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final hasActionTrigger = _canRevealActions;
              final actionButtonAllowance = hasActionTrigger ? 44.0 : 0.0;
              final textMaxWidth = math
                  .max(
                    0,
                    constraints.maxWidth -
                        IntermediateSpacing.sMd * 2 -
                        1.0 -
                        actionButtonAllowance,
                  )
                  .toDouble();
              final overflows = _exceedsMaxLines(
                context: context,
                text: widget.content,
                style: textStyle,
                maxWidth: textMaxWidth,
              );

              return DecoratedBox(
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(cornerRadius),
                    bottomRight: Radius.circular(cornerRadius),
                  ),
                  border: Border(
                    left: BorderSide(color: ruleColor),
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _canRevealActions ? _toggleActions : null,
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(cornerRadius),
                      bottomRight: Radius.circular(cornerRadius),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        IntermediateSpacing.sMd,
                        2,
                        IntermediateSpacing.s2xs,
                        2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: IntermediateSpacing.sSm,
                                    bottom: IntermediateSpacing.sSm,
                                    right: IntermediateSpacing.sXs,
                                  ),
                                  child: Text(
                                    widget.content,
                                    style: textStyle,
                                    maxLines: overflows && !_expanded
                                        ? _collapsedMaxLines
                                        : null,
                                    overflow: overflows && !_expanded
                                        ? TextOverflow.ellipsis
                                        : TextOverflow.visible,
                                  ),
                                ),
                              ),
                              if (hasActionTrigger)
                                IconButton(
                                  key: const ValueKey(
                                    'directive-actions-toggle',
                                  ),
                                  onPressed: _toggleActions,
                                  tooltip: t.advanced.actUnit.directiveActions,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 44,
                                    minHeight: 44,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.more_horiz,
                                    size: 16,
                                    color: _showActions
                                        ? directorReadableColor(
                                            colors,
                                            colors.primary,
                                          )
                                        : colors.faint,
                                  ),
                                ),
                            ],
                          ),
                          if (overflows)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: IntermediateSpacing.s2xs,
                              ),
                              child: SizedBox(
                                width: double.infinity,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        color: colors.divider
                                            .withValues(alpha: 0.45),
                                        width: 0.5,
                                      ),
                                    ),
                                  ),
                                  child: InkWell(
                                    key: const ValueKey(
                                      'directive-expand-toggle',
                                    ),
                                    onTap: () => setState(
                                      () => _expanded = !_expanded,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      context.lmUi.radius(LmCorner.xs),
                                    ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 38,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: IntermediateSpacing.s2xs,
                                          vertical: 6,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              _expanded
                                                  ? t.advanced.actUnit
                                                      .collapseDirective
                                                  : t.advanced.actUnit
                                                      .expandDirective,
                                              style: IntermediateTextStyles
                                                  .captionSm
                                                  .copyWith(
                                                color: directorReadableColor(
                                                  colors,
                                                  colors.primary,
                                                ),
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              _expanded
                                                  ? Icons.expand_less
                                                  : Icons.expand_more,
                                              size: 16,
                                              color: directorReadableColor(
                                                colors,
                                                colors.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (_showActions && _canRevealActions)
            Padding(
              padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
              child: context.lmUi.messageActions(
                context,
                isUser: true,
                canOperate: widget.canOperate,
                windowRounds: widget.windowRounds,
                onCopy: widget.onCopy,
                onRegenerate: widget.onRegenerate,
                onEdit: widget.onEdit,
                onDeleteRound: widget.onDeleteRound,
              ),
            ),
        ],
      ),
    );
  }

  static bool _exceedsMaxLines({
    required BuildContext context,
    required String text,
    required TextStyle style,
    required double maxWidth,
  }) {
    if (text.isEmpty || maxWidth <= 0) return false;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: _collapsedMaxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return exceeded;
  }
}

/// Act-tail human-readable change pills with a one-tap expandable diff drawer.
///
/// Renders up to 3 pills plus an overflow pill; occupies zero space when there
/// are neither world changes nor backstage actions.
class DirectorChangePillsAndDrawer extends StatefulWidget {
  const DirectorChangePillsAndDrawer({
    required this.presentation,
    this.anchor,
    this.onOpenMemory,
    this.onEditAnchor,
    this.pureReading = false,
    super.key,
  });

  final DirectorRoundPresentation presentation;
  final StoryAnchor? anchor;
  final VoidCallback? onOpenMemory;
  final ValueChanged<StoryAnchor>? onEditAnchor;
  final bool pureReading;

  @override
  State<DirectorChangePillsAndDrawer> createState() =>
      _DirectorChangePillsAndDrawerState();
}

class _DirectorChangePillsAndDrawerState
    extends State<DirectorChangePillsAndDrawer> {
  var _drawerOpen = false;
  var _thinkingExpanded = false;
  var _pillsExpanded = false;
  var _pillsTrayVisible = true;
  String? _selectedPillId;

  List<DirectorChangePill> get _allEligiblePills {
    if (!widget.pureReading) return widget.presentation.allPills;
    return [
      for (final pill in widget.presentation.allPills)
        if (_isWorldPill(pill.kind)) pill,
    ];
  }

  List<DirectorChangePill> get _defaultVisiblePills {
    if (!widget.pureReading) return widget.presentation.visiblePills;
    return _allEligiblePills
        .take(DirectorHumanPresenter.defaultMaxVisiblePills)
        .toList();
  }

  int get _effectiveOverflowCount {
    final total = _allEligiblePills.length;
    final shown = _defaultVisiblePills.length;
    return total > shown ? total - shown : 0;
  }

  static bool _isWorldPill(DirectorPillKind kind) => switch (kind) {
        DirectorPillKind.factChange ||
        DirectorPillKind.foreshadow ||
        DirectorPillKind.eventMemory ||
        DirectorPillKind.maintenance =>
          true,
        DirectorPillKind.retrieval || DirectorPillKind.backstage => false,
      };

  void _onMasterTap() {
    setState(() {
      if (_drawerOpen && _selectedPillId == null) {
        _drawerOpen = false;
      } else {
        _drawerOpen = true;
        _selectedPillId = null;
      }
    });
  }

  void _onPillsChevronTap(int overflow) {
    setState(() {
      if (overflow > 0) {
        _pillsExpanded = !_pillsExpanded;
        _pillsTrayVisible = true;
      } else {
        _pillsTrayVisible = !_pillsTrayVisible;
      }
    });
  }

  void _onPillTap(String pillId) {
    setState(() {
      if (_drawerOpen && _selectedPillId == pillId) {
        _drawerOpen = false;
        _selectedPillId = null;
      } else {
        _drawerOpen = true;
        _selectedPillId = pillId;
      }
    });
  }

  DirectorChangePill? _findSelectedPill(List<DirectorChangePill> allPills) {
    final id = _selectedPillId;
    if (id == null) return null;
    for (final pill in allPills) {
      if (pill.id == id) return pill;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final presentation = widget.presentation;
    final allPills = _allEligiblePills;
    final defaultPills = _defaultVisiblePills;
    final overflow = _effectiveOverflowCount;
    final displayedPills = _pillsExpanded ? allPills : defaultPills;
    final hasDrawerBody = widget.pureReading
        ? presentation.hasWorldChanges
        : presentation.hasDrawerContent;

    if (allPills.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = context.lm.palette;
    final t = Translations.of(context);
    final pillRadius = context.lmUi.radius(LmCorner.full);
    final barRadius = context.lmUi.radius(LmCorner.sm);
    final isSharp = pillRadius == 0;
    final fullDrawerActive = _drawerOpen && _selectedPillId == null;
    final chevronExpanded = overflow > 0 ? _pillsExpanded : _pillsTrayVisible;
    final summaryCount = presentation.worldChangeCount > 0
        ? presentation.worldChangeCount
        : allPills.length;
    final masterLabel = summaryCount > 0
        ? t.advanced.actUnit.changesSummaryCount(count: summaryCount)
        : t.advanced.actUnit.changesSummaryTitle;
    final readablePrimary = directorReadableColor(colors, colors.primary);
    final readableMuted = directorReadableColor(colors, colors.muted);

    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Master full-width bar establishing clear parent -> child hierarchy.
          DecoratedBox(
            key: const ValueKey('act-changes-master-bar'),
            decoration: BoxDecoration(
              color: fullDrawerActive
                  ? colors.primary.withValues(alpha: 0.12)
                  : colors.surfaceElevated,
              borderRadius: BorderRadius.circular(barRadius),
              border: Border.all(
                color: fullDrawerActive
                    ? colors.primary.withValues(alpha: 0.45)
                    : colors.dividerStrong.withValues(alpha: 0.55),
                width: isSharp ? 1.0 : 0.6,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(barRadius),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: fullDrawerActive,
                        child: InkWell(
                          key: const ValueKey('act-changes-master-button'),
                          onTap: hasDrawerBody ? _onMasterTap : null,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 40),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: IntermediateSpacing.sMd,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: readablePrimary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(
                                    width: IntermediateSpacing.sSm,
                                  ),
                                  Expanded(
                                    child: Text(
                                      masterLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: IntermediateTextStyles.caption
                                          .copyWith(
                                        color: fullDrawerActive
                                            ? readablePrimary
                                            : directorReadableColor(
                                                colors,
                                                colors.ink,
                                              ),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (fullDrawerActive) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.unfold_less,
                                      size: 14,
                                      color: readablePrimary,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 0.5,
                      indent: 8,
                      endIndent: 8,
                      color: colors.divider,
                    ),
                    Semantics(
                      button: true,
                      expanded: chevronExpanded,
                      label: chevronExpanded
                          ? t.advanced.actUnit.collapseMorePillsTooltip
                          : t.advanced.actUnit.expandMorePillsTooltip,
                      child: Tooltip(
                        message: chevronExpanded
                            ? t.advanced.actUnit.collapseMorePillsTooltip
                            : t.advanced.actUnit.expandMorePillsTooltip,
                        child: InkWell(
                          key: const ValueKey('act-pills-expand-toggle'),
                          onTap: () => _onPillsChevronTap(overflow),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 40,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: IntermediateSpacing.sSm,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (overflow > 0 && !_pillsExpanded) ...[
                                    Text(
                                      t.advanced.actUnit.overflowPill(
                                        count: overflow,
                                      ),
                                      style: IntermediateTextStyles.captionSm
                                          .copyWith(
                                        color: readablePrimary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                  ],
                                  AnimatedRotation(
                                    turns: chevronExpanded ? 0.5 : 0,
                                    duration: LmMotion.durationFor(
                                      context,
                                      LmMotion.fast,
                                    ),
                                    curve: LmMotion.easeStandard,
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 18,
                                      color: overflow > 0 && !_pillsExpanded
                                          ? readablePrimary
                                          : readableMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Subordinate sub-title pills (1-2 rows by default; full list on chevron).
          AnimatedSize(
            duration: LmMotion.durationFor(context, LmMotion.base),
            curve: LmMotion.easeSnap,
            alignment: Alignment.topCenter,
            child: _pillsTrayVisible
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: IntermediateSpacing.sXs,
                    ),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final pill in displayedPills)
                          _ChangePillButton(
                            key: ValueKey('act-pill-${pill.id}'),
                            label: pill.label,
                            dotColor: _dotColorFor(pill.kind, colors),
                            active: _drawerOpen && _selectedPillId == pill.id,
                            showChevron:
                                _drawerOpen && _selectedPillId == pill.id,
                            isSharp: isSharp,
                            radius: pillRadius,
                            onTap: hasDrawerBody
                                ? () => _onPillTap(pill.id)
                                : null,
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: LmMotion.durationFor(context, LmMotion.base),
            curve: LmMotion.easeSnap,
            alignment: Alignment.topCenter,
            child: _drawerOpen && hasDrawerBody
                ? _buildDrawer(
                    context,
                    colors,
                    t,
                    selectedPill: _findSelectedPill(allPills),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Color _dotColorFor(DirectorPillKind kind, LmPalette colors) => switch (kind) {
        DirectorPillKind.factChange ||
        DirectorPillKind.foreshadow =>
          colors.primary,
        DirectorPillKind.retrieval ||
        DirectorPillKind.maintenance ||
        DirectorPillKind.eventMemory =>
          colors.success,
        DirectorPillKind.backstage => colors.muted,
      };

  WidgetSpan _actionDotSeparator(LmPalette colors) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Container(
          width: 5.5,
          height: 5.5,
          decoration: BoxDecoration(
            color: directorReadableColor(colors, colors.primary),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer(
    BuildContext context,
    LmPalette colors,
    Translations t, {
    DirectorChangePill? selectedPill,
  }) {
    final presentation = widget.presentation;
    final drawerRadius = context.lmUi.radius(LmCorner.md);
    final isFiltered = selectedPill != null;

    final List<DirectorWorldChangeItem> visibleWorldChanges;
    final bool showActionsSection;
    final bool showThinkingSection;

    if (selectedPill == null) {
      visibleWorldChanges = presentation.worldChanges;
      showActionsSection = !widget.pureReading &&
          (presentation.actions.isNotEmpty ||
              presentation.actionsSummaryLine != null ||
              presentation.narrations.isNotEmpty);
      showThinkingSection = !widget.pureReading && presentation.hasThinking;
    } else if (selectedPill.worldChangeIndices.isNotEmpty) {
      visibleWorldChanges = [
        for (final idx in selectedPill.worldChangeIndices)
          if (idx >= 0 && idx < presentation.worldChanges.length)
            presentation.worldChanges[idx],
      ];
      showActionsSection = false;
      showThinkingSection = false;
    } else {
      visibleWorldChanges = const [];
      showActionsSection = !widget.pureReading &&
          (presentation.actions.isNotEmpty ||
              presentation.actionsSummaryLine != null ||
              presentation.narrations.isNotEmpty);
      showThinkingSection = !widget.pureReading && presentation.hasThinking;
    }

    final showEditAnchor = !widget.pureReading &&
        widget.anchor != null &&
        widget.onEditAnchor != null &&
        (!isFiltered || selectedPill.kind == DirectorPillKind.foreshadow);
    final showMemoryLink = widget.onOpenMemory != null &&
        (!isFiltered || selectedPill.kind == DirectorPillKind.factChange);
    final headerTitle =
        isFiltered ? selectedPill.label : t.advanced.actUnit.drawerTitle;

    return Container(
      key: const ValueKey('act-diff-drawer'),
      margin: const EdgeInsets.only(
        top: IntermediateSpacing.sSm,
        bottom: IntermediateSpacing.sXs,
      ),
      padding: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(drawerRadius),
        border: Border.all(color: colors.divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drawer header: title + show-all / anchor edit / memory link
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: IntermediateSpacing.sSm,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  headerTitle,
                  style: IntermediateTextStyles.captionSm.copyWith(
                    color: directorReadableColor(colors, colors.muted),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isFiltered || showEditAnchor || showMemoryLink)
                Wrap(
                  spacing: IntermediateSpacing.s2xs,
                  children: [
                    if (isFiltered)
                      _DrawerLinkButton(
                        key: const ValueKey('act-drawer-show-all'),
                        label: t.advanced.actUnit.showAllChanges,
                        color: directorReadableColor(colors, colors.muted),
                        onTap: () => setState(() => _selectedPillId = null),
                      ),
                    if (showEditAnchor)
                      _DrawerLinkButton(
                        key: const ValueKey('act-edit-anchor'),
                        label: t.advanced.actUnit.editAnchor,
                        icon: Icons.edit_outlined,
                        color: directorReadableColor(colors, colors.muted),
                        onTap: () async {
                          final edited = await DirectorAnchorEditSheet.show(
                            context,
                            widget.anchor!,
                          );
                          if (edited != null) {
                            widget.onEditAnchor?.call(edited);
                          }
                        },
                      ),
                    if (showMemoryLink)
                      _DrawerLinkButton(
                        key: const ValueKey('act-open-memory'),
                        label: '${t.advanced.actUnit.goToMemory} →',
                        color: directorReadableColor(colors, colors.primary),
                        onTap: widget.onOpenMemory!,
                      ),
                  ],
                ),
            ],
          ),
          // World changes list (full or single-pill filtered)
          if (visibleWorldChanges.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in visibleWorldChanges)
                    _WorldChangeRow(item: item),
                ],
              ),
            ),
          // Director human actions with prominent colored dot separators
          if (showActionsSection) ...[
            if (visibleWorldChanges.isNotEmpty)
              Divider(
                height: IntermediateSpacing.sSm,
                thickness: 0.5,
                color: colors.divider,
              ),
            if (presentation.actions.isNotEmpty ||
                presentation.actionsSummaryLine != null)
              Padding(
                padding: const EdgeInsets.only(
                  top: IntermediateSpacing.s2xs,
                  bottom: IntermediateSpacing.s2xs,
                ),
                child: Text.rich(
                  TextSpan(
                    style: IntermediateTextStyles.caption.copyWith(
                      color: directorReadableColor(colors, colors.muted),
                      height: 1.55,
                    ),
                    children: [
                      TextSpan(
                        text: t.advanced.actUnit.directorActions,
                        style: TextStyle(
                          color: directorReadableColor(colors, colors.ink),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (presentation.actions.isNotEmpty)
                        for (final action in presentation.actions) ...[
                          _actionDotSeparator(colors),
                          TextSpan(text: action.formattedText(t)),
                        ]
                      else if (presentation.actionsSummaryLine
                          case final summary?) ...[
                        _actionDotSeparator(colors),
                        TextSpan(text: summary),
                      ],
                    ],
                  ),
                ),
              ),
            for (final narration in presentation.narrations)
              Padding(
                padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
                child: Container(
                  padding: const EdgeInsets.only(left: IntermediateSpacing.sSm),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.dividerStrong),
                    ),
                  ),
                  child: Text(
                    narration,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: directorReadableColor(colors, colors.muted),
                      height: 1.45,
                    ),
                  ),
                ),
              ),
          ],
          // Optional collapsible thinking notes
          if (showThinkingSection) ...[
            if (visibleWorldChanges.isNotEmpty || showActionsSection)
              Divider(
                height: IntermediateSpacing.sSm,
                thickness: 0.5,
                color: colors.divider,
              ),
            _buildThinkingDisclosure(context, colors, t, presentation),
          ],
        ],
      ),
    );
  }

  Widget _buildThinkingDisclosure(
    BuildContext context,
    LmPalette colors,
    Translations t,
    DirectorRoundPresentation presentation,
  ) {
    final segCount = presentation.thinkingSegments.length;
    final label = segCount > 1
        ? t.advanced.actUnit.thinkingNotesCount(count: segCount)
        : t.advanced.actUnit.thinkingNotes;
    final muted = directorReadableColor(colors, colors.muted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _thinkingExpanded,
          child: InkWell(
            key: const ValueKey('act-thinking-toggle'),
            onTap: () => setState(() => _thinkingExpanded = !_thinkingExpanded),
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Icon(
                    _thinkingExpanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: muted,
                  ),
                  const SizedBox(width: IntermediateSpacing.s2xs),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IntermediateTextStyles.caption.copyWith(
                        color: muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_thinkingExpanded && presentation.thinkingNotes != null)
          Padding(
            padding: const EdgeInsets.only(
              left: IntermediateSpacing.sMd,
              bottom: IntermediateSpacing.sXs,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    math.min(220, MediaQuery.sizeOf(context).height * 0.35),
              ),
              child: SingleChildScrollView(
                primary: false,
                child: SelectableText(
                  presentation.thinkingNotes!,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: muted,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChangePillButton extends StatelessWidget {
  const _ChangePillButton({
    required this.label,
    required this.active,
    required this.showChevron,
    required this.isSharp,
    required this.radius,
    required this.onTap,
    this.dotColor,
    super.key,
  });

  final String label;
  final Color? dotColor;
  final bool active;
  final bool showChevron;
  final bool isSharp;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final bgColor = active ? colors.primaryDim : colors.surfaceVariant;
    final borderColor =
        active ? colors.primary.withValues(alpha: 0.45) : colors.divider;
    final textColor = active
        ? directorReadableColor(colors, colors.primary)
        : directorReadableColor(colors, colors.muted);

    return Semantics(
      button: onTap != null,
      expanded: active,
      child: Material(
        color: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: borderColor,
            width: active ? 0.75 : 0.5,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dotColor case final dot?) ...[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: isSharp ? BoxShape.rectangle : BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IntermediateTextStyles.captionSm.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (showChevron) ...[
                    const SizedBox(width: 2),
                    Icon(
                      Icons.expand_less,
                      size: 13,
                      color: textColor,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerLinkButton extends StatelessWidget {
  const _DrawerLinkButton({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 34),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sXs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IntermediateTextStyles.captionSm.copyWith(
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorldChangeRow extends StatelessWidget {
  const _WorldChangeRow({required this.item});

  final DirectorWorldChangeItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final subjectColor = switch (item.kind) {
      DirectorWorldChangeKind.foreshadowAdded =>
        directorReadableColor(colors, colors.primary),
      DirectorWorldChangeKind.foreshadowResolved =>
        directorReadableColor(colors, colors.success),
      _ => colors.ink,
    };
    final subjectText =
        item.attributeLabel != null && item.attributeLabel!.isNotEmpty
            ? '${item.subject} · ${item.attributeLabel}'
            : item.subject;
    final oldVal = item.oldValue?.trim();
    final newVal = item.newValue?.trim();
    final hasOld = oldVal != null && oldVal.isNotEmpty;
    final hasNew = newVal != null && newVal.isNotEmpty;

    final baseStyle = IntermediateTextStyles.caption.copyWith(
      color: colors.ink,
      height: 1.5,
    );

    final spans = <InlineSpan>[
      TextSpan(
        text: subjectText,
        style: baseStyle.copyWith(
          color: subjectColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];

    if (item.kind == DirectorWorldChangeKind.foreshadowResolved && hasNew) {
      spans.addAll([
        const TextSpan(text: '  '),
        TextSpan(
          text: newVal,
          style: baseStyle.copyWith(
            color: directorReadableColor(colors, colors.muted),
            decoration: TextDecoration.lineThrough,
            decorationColor: directorReadableColor(colors, colors.muted),
          ),
        ),
      ]);
    } else if (item.kind == DirectorWorldChangeKind.foreshadowAdded && hasNew) {
      spans.addAll([
        TextSpan(
          text: '  + ',
          style: baseStyle.copyWith(
            color: directorReadableColor(colors, colors.primary),
            fontWeight: FontWeight.w600,
          ),
        ),
        TextSpan(text: newVal),
      ]);
    } else if (hasOld && hasNew) {
      spans.addAll([
        const TextSpan(text: '  '),
        TextSpan(
          text: oldVal,
          style: baseStyle.copyWith(
            color: directorReadableColor(colors, colors.muted),
            decoration: TextDecoration.lineThrough,
            decorationColor: directorReadableColor(colors, colors.muted),
          ),
        ),
        TextSpan(
          text: ' → ',
          style: baseStyle.copyWith(
            color: directorReadableColor(colors, colors.primary),
            fontWeight: FontWeight.w600,
          ),
        ),
        TextSpan(text: newVal),
      ]);
    } else if (hasNew) {
      spans.addAll([
        const TextSpan(text: '  '),
        TextSpan(text: newVal),
      ]);
    } else if (hasOld) {
      spans.addAll([
        const TextSpan(text: '  '),
        TextSpan(
          text: oldVal,
          style: baseStyle.copyWith(
            color: directorReadableColor(colors, colors.muted),
            decoration: TextDecoration.lineThrough,
          ),
        ),
      ]);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(TextSpan(style: baseStyle, children: spans)),
    );
  }
}

/// Single-line in-place live progress pulse for  (writing phase).
///
/// Collapsed by default so the reading viewport never jumps while the director
/// checks lore or thinks. Recedes into an ultra-quiet single line once prose
/// begins streaming. Tapping reveals a clean human-language step stream.
/// Any error/warning steps remain rendered verbatim via [DirectorToolCard].
class DirectorLivePulse extends StatefulWidget {
  const DirectorLivePulse({
    required this.presentation,
    required this.timeline,
    this.activity,
    this.activeStepIndex = 0,
    this.waitingUser = false,
    this.interrupted = false,
    super.key,
  });

  final DirectorLivePresentation presentation;
  final List<AgentTimelineBlock> timeline;
  final AgentActivity? activity;
  final int activeStepIndex;
  final bool waitingUser;
  final bool interrupted;

  @override
  State<DirectorLivePulse> createState() => _DirectorLivePulseState();
}

class _DirectorLivePulseState extends State<DirectorLivePulse> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final presentation = widget.presentation;
    final quiet = presentation.hasManuscriptProse;
    final hasExpandableDetails = presentation.actions.isNotEmpty ||
        presentation.latestNarration != null ||
        widget.timeline.any((b) => b.kind == AgentTimelineKind.thinking);

    final isBudgetHigh = (presentation.budgetRatio ?? 0) >= 0.8;
    final hasError = presentation.errorSteps.any((s) => s.isError);
    final hasWarning = presentation.errorSteps.any((s) => s.isWarning);

    final indicatorColor = hasError
        ? colors.error
        : hasWarning || isBudgetHigh
            ? colors.warning
            : quiet
                ? colors.faint
                : colors.primary;

    final textColor = hasError
        ? colors.error
        : isBudgetHigh
            ? colors.warning
            : quiet
                ? directorReadableColor(colors, colors.faint)
                : directorReadableColor(colors, colors.muted);

    final stepBadge = presentation.currentStep != null &&
            presentation.maxSteps != null &&
            presentation.maxSteps! > 0
        ? t.advanced.actUnit.maintenanceProgress(
            step: presentation.currentStep!,
            maxSteps: presentation.maxSteps!,
          )
        : null;

    final occurrence = <Object, int>{};

    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: hasExpandableDetails,
            expanded: _expanded,
            label: _expanded
                ? t.advanced.actUnit.pulseCollapse
                : t.advanced.actUnit.pulseExpand,
            child: InkWell(
              key: const ValueKey('live-pulse-toggle'),
              onTap: hasExpandableDetails
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: IntermediateSpacing.s2xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: Center(
                          child: presentation.isWorking && !widget.waitingUser
                              ? LmActivityDots(
                                  color: indicatorColor,
                                  dotSize: 2,
                                )
                              : widget.waitingUser
                                  ? Icon(
                                      Icons.pause_circle_outline,
                                      size: 14,
                                      color: colors.warning,
                                    )
                                  : Icon(
                                      hasError
                                          ? Icons.error_outline
                                          : hasWarning
                                              ? Icons.warning_amber_rounded
                                              : Icons.circle,
                                      size: hasError || hasWarning ? 14 : 6,
                                      color: indicatorColor,
                                    ),
                        ),
                      ),
                      const SizedBox(width: IntermediateSpacing.sSm),
                      Expanded(
                        child: presentation.isWorking &&
                                !widget.waitingUser &&
                                !quiet
                            ? ShimmerText(
                                presentation.pulseText,
                                style: IntermediateTextStyles.caption.copyWith(
                                  color: textColor,
                                ),
                              )
                            : Text(
                                presentation.pulseText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: IntermediateTextStyles.caption.copyWith(
                                  color: textColor,
                                ),
                              ),
                      ),
                      if (stepBadge != null) ...[
                        const SizedBox(width: IntermediateSpacing.sSm),
                        Text(
                          stepBadge,
                          style: IntermediateTextStyles.captionSm.copyWith(
                            color: isBudgetHigh
                                ? colors.warning
                                : directorReadableColor(colors, colors.muted),
                          ),
                        ),
                      ],
                      if (hasExpandableDetails) ...[
                        const SizedBox(width: IntermediateSpacing.s2xs),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration:
                              LmMotion.durationFor(context, LmMotion.fold),
                          curve: LmMotion.easeSnap,
                          child: Icon(
                            Icons.expand_more,
                            size: 16,
                            color: colors.faint,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Expanded human-language step stream (on demand)
          if (_expanded && hasExpandableDetails)
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sLg,
                bottom: IntermediateSpacing.sXs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final action in presentation.actions)
                    _HumanActionLine(action: action),
                  if (presentation.latestNarration case final narration?)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: IntermediateSpacing.s2xs,
                      ),
                      child: Container(
                        padding: const EdgeInsets.only(
                          left: IntermediateSpacing.sSm,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: colors.dividerStrong),
                          ),
                        ),
                        child: Text(
                          narration,
                          style: IntermediateTextStyles.caption.copyWith(
                            color: directorReadableColor(colors, colors.muted),
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                  for (final block in widget.timeline)
                    if (block.kind == AgentTimelineKind.thinking &&
                        block.text.trim().isNotEmpty)
                      DirectorThinkingBlock(
                        content: block.text,
                        duration: block.duration,
                        active: presentation.isWorking &&
                            !widget.waitingUser &&
                            widget.activity == AgentActivity.thinking &&
                            block.stepIndex == widget.activeStepIndex,
                        incomplete: widget.interrupted &&
                            widget.activity == AgentActivity.thinking &&
                            block.stepIndex == widget.activeStepIndex,
                      ),
                ],
              ),
            ),
          // Error/warning steps are always preserved verbatim via DirectorToolCard
          if ((presentation.isWorking || widget.interrupted) &&
              presentation.hasErrors)
            Padding(
              padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final step in presentation.errorSteps)
                    DirectorToolCard(
                      key: _errorStepKey(step, occurrence),
                      step: step,
                      runningEnabled:
                          presentation.isWorking && !widget.waitingUser,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Key _errorStepKey(
  AgentWorkStep step,
  Map<Object, int> occurrence,
) {
  final identity = (
    callId: step.callId,
    stepIndex: step.stepIndex,
    order: step.order,
  );
  final idx = occurrence[identity] ?? 0;
  occurrence[identity] = idx + 1;
  return ValueKey((identity, idx));
}

/// Fixed-height dashed maintenance slot rendered at the act tail during
///
/// Preserves zero layout jump while the reader reads the settled prose;
/// tapping expands human-readable maintenance actions (plus verbatim
/// [DirectorToolCard]s if any step errored or warned).
class DirectorMaintenanceSlot extends StatefulWidget {
  const DirectorMaintenanceSlot({
    required this.presentation,
    required this.maintenanceSteps,
    this.waitingUser = false,
    this.pureReading = false,
    super.key,
  });

  final DirectorLivePresentation presentation;
  final List<AgentWorkStep> maintenanceSteps;
  final bool waitingUser;
  final bool pureReading;

  @override
  State<DirectorMaintenanceSlot> createState() =>
      _DirectorMaintenanceSlotState();
}

class _DirectorMaintenanceSlotState extends State<DirectorMaintenanceSlot> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final presentation = widget.presentation;

    final errorSteps = [
      for (final step in widget.maintenanceSteps)
        if (step.isError || step.isWarning) step,
    ];
    final hasError = errorSteps.any((s) => s.isError);
    final hasWarning = errorSteps.any((s) => s.isWarning);

    if (widget.pureReading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            children: [
              if (presentation.isWorking)
                LmActivityDots(color: colors.faint, dotSize: 2)
              else
                Icon(
                  hasError
                      ? Icons.error_outline
                      : hasWarning
                          ? Icons.warning_amber_rounded
                          : Icons.circle,
                  size: hasError || hasWarning ? 14 : 6,
                  color: hasError
                      ? colors.error
                      : hasWarning
                          ? colors.warning
                          : colors.faint,
                ),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  presentation.pureReadingPulseText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: directorReadableColor(colors, colors.faint),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final dotColor = hasError
        ? colors.error
        : hasWarning
            ? colors.warning
            : colors.primary;
    final borderColor = hasError || hasWarning
        ? dotColor.withValues(alpha: 0.65)
        : colors.dividerStrong.withValues(alpha: 0.7);
    final slotRadius = context.lmUi.radius(LmCorner.sm);

    final progressLabel = presentation.currentStep != null &&
            presentation.maxSteps != null &&
            presentation.maxSteps! > 0
        ? t.advanced.actUnit.maintenanceProgress(
            step: presentation.currentStep!,
            maxSteps: presentation.maxSteps!,
          )
        : null;

    final occurrence = <Object, int>{};

    return Padding(
      padding: const EdgeInsets.only(
        top: IntermediateSpacing.sXs,
        bottom: IntermediateSpacing.sSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            painter: _DashedBorderPainter(
              color: borderColor,
              radius: slotRadius,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(slotRadius),
              child: ColoredBox(
                color: colors.surfaceVariant.withValues(alpha: 0.6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      button: true,
                      expanded: _expanded,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const ValueKey('maintenance-capsule-toggle'),
                          onTap: () => setState(() => _expanded = !_expanded),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: IntermediateSpacing.sMd,
                                vertical: IntermediateSpacing.sXs,
                              ),
                              child: Row(
                                children: [
                                  if (widget.waitingUser)
                                    Icon(
                                      Icons.pause_circle_outline,
                                      size: 14,
                                      color: colors.warning,
                                    )
                                  else if (presentation.isWorking)
                                    LmActivityDots(
                                      color: dotColor,
                                      dotSize: 2.5,
                                    )
                                  else
                                    Icon(
                                      hasError
                                          ? Icons.error_outline
                                          : hasWarning
                                              ? Icons.warning_amber_rounded
                                              : Icons.circle,
                                      size: hasError || hasWarning ? 14 : 6,
                                      color: dotColor,
                                    ),
                                  const SizedBox(
                                    width: IntermediateSpacing.sSm,
                                  ),
                                  Expanded(
                                    child: Text(
                                      presentation.pulseText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: IntermediateTextStyles.caption
                                          .copyWith(
                                        color: directorReadableColor(
                                          colors,
                                          colors.muted,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (progressLabel != null) ...[
                                    const SizedBox(
                                      width: IntermediateSpacing.sSm,
                                    ),
                                    Text(
                                      progressLabel,
                                      style: IntermediateTextStyles.captionSm
                                          .copyWith(
                                        color: directorReadableColor(
                                          colors,
                                          colors.muted,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(
                                    width: IntermediateSpacing.s2xs,
                                  ),
                                  AnimatedRotation(
                                    turns: _expanded ? 0.5 : 0,
                                    duration: LmMotion.durationFor(
                                      context,
                                      LmMotion.fold,
                                    ),
                                    curve: LmMotion.easeSnap,
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 16,
                                      color: colors.faint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: LmMotion.durationFor(context, LmMotion.base),
                      curve: LmMotion.easeSnap,
                      alignment: Alignment.topCenter,
                      child: _expanded
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Divider(
                                  height: 1,
                                  color: colors.divider.withValues(alpha: 0.6),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    IntermediateSpacing.sMd,
                                    IntermediateSpacing.sXs,
                                    IntermediateSpacing.sMd,
                                    IntermediateSpacing.sSm,
                                  ),
                                  child: presentation.maintenanceActions.isEmpty
                                      ? Text(
                                          t.advanced.maintenance.noStepsYet,
                                          style: IntermediateTextStyles.caption
                                              .copyWith(
                                            color: directorReadableColor(
                                              colors,
                                              colors.muted,
                                            ),
                                          ),
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            for (final action in presentation
                                                .maintenanceActions)
                                              _HumanActionLine(action: action),
                                          ],
                                        ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (errorSteps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final step in errorSteps)
                    DirectorToolCard(
                      key: _errorStepKey(step, occurrence),
                      step: step,
                      runningEnabled:
                          presentation.isWorking && !widget.waitingUser,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HumanActionLine extends StatelessWidget {
  const _HumanActionLine({required this.action});

  final DirectorHumanAction action;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final isSharp = context.lmUi.radius(LmCorner.sm) == 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: action.isRunning
                ? LmActivityDots(color: colors.primary, dotSize: 1.5)
                : Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.success,
                      shape: isSharp ? BoxShape.rectangle : BoxShape.circle,
                    ),
                  ),
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              action.summaryText(t),
              style: IntermediateTextStyles.caption.copyWith(
                color: directorReadableColor(colors, colors.muted),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 5.0;
    const dashGap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dashWidth, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      color != oldDelegate.color || radius != oldDelegate.radius;
}
