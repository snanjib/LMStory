import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/api/lm_motion_profile.dart';
import 'package:lmstory/core/theme/shared/components/composer_surface.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_app_bar.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_empty_state.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_navigation.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_section.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/embedding_missing_banner.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/entry_transition.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/history_panel_shell.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/input_toolbar.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_compaction_summary_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_confirm_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_edit_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_navigation.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/suggest_reply_overlay.dart';
import 'package:lmstory/core/theme/system/structures/panel_venue.dart';

/// Preserves the established classic surfaces while giving them the same
/// interface as every other structure. Other structures extend this class to
/// inherit the established look for surfaces they do not differentiate.
class ClassicComponents implements LmComponentKit {
  const ClassicComponents();

  @override
  LmMotionProfile get motionProfile => const LmMotionProfile();

  @override
  double radius(LmCorner corner) => switch (corner) {
        LmCorner.xs => LmRadius.rXs,
        LmCorner.sm => LmRadius.rSm,
        LmCorner.md => LmRadius.rMd,
        LmCorner.lg => LmRadius.rLg,
        LmCorner.xl => LmRadius.rXl,
        LmCorner.full => LmRadius.rFull,
      };

  @override
  bool get ownsSheetSurface => false;

  @override
  Widget venue(BuildContext context, Widget child) => child;

  @override
  Color scaffoldBackground(BuildContext context, Color fallback) => fallback;

  @override
  Color sidebarSurfaceColor(BuildContext context) => context.lm.palette.surface;

  @override
  Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(LmSpacing.sLg),
    VoidCallback? onTap,
    bool selected = false,
  }) {
    final colors = context.lm.palette;
    return Material(
      color: selected ? colors.primaryDim : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(LmRadius.rLg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LmRadius.rLg),
        child: Padding(padding: padding, child: child),
      ),
    );
  }

  @override
  Widget settingCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool featured = false,
    bool narrative = false,
    bool enabled = true,
  }) =>
      narrative
          ? ClassicNarrativeSettingCard(
              icon: icon,
              title: title,
              subtitle: subtitle,
              onTap: onTap,
              enabled: enabled,
            )
          : ClassicSettingCard(
              icon: icon,
              title: title,
              subtitle: subtitle,
              onTap: onTap,
              enabled: enabled,
            );

  @override
  Widget entryCard(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required Color fallbackColor,
    bool horizontal = false,
  }) =>
      Material(
        color: fallbackColor,
        borderRadius: BorderRadius.circular(LmRadius.rLg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LmRadius.rLg),
          child: Padding(
            padding: const EdgeInsets.all(LmSpacing.sMd),
            child: child,
          ),
        ),
      );

  @override
  TextStyle entryTitleStyle(BuildContext context, TextStyle fallback) =>
      fallback;

  @override
  Widget sessionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required bool hovered,
  }) {
    final colors = context.lm.palette;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: selected
            ? colors.primaryDim
            : hovered
                ? colors.surfaceVariant
                : Colors.transparent,
        borderRadius: BorderRadius.circular(LmRadius.rSm),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LmRadius.rSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sMd,
            vertical: LmSpacing.sSm,
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget selectionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback? onTap,
    required bool selected,
  }) {
    final colors = context.lm.palette;
    final radius = BorderRadius.circular(LmRadius.rMd);
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.s3xs,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.sMd - LmSpacing.s3xs,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.primaryDim : Colors.transparent,
          borderRadius: radius,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget messageBubble(
    BuildContext context, {
    required Widget child,
    required bool isUser,
    required bool standardLayout,
    bool summary = false,
    bool narrative = false,
  }) {
    final colors = context.lm.palette;
    if (narrative) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sLg,
          vertical: LmSpacing.sMd,
        ),
        decoration: BoxDecoration(
          color: isUser ? colors.primaryDim : Colors.transparent,
          borderRadius: BorderRadius.circular(LmRadius.rMd),
        ),
        child: child,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: standardLayout
            ? Colors.transparent
            : isUser
                ? colors.primary
                : colors.surfaceVariant,
        borderRadius: standardLayout
            ? BorderRadius.circular(LmRadius.rLg)
            : BorderRadius.only(
                topLeft: const Radius.circular(LmRadius.rLg),
                topRight: const Radius.circular(LmRadius.rLg),
                bottomLeft: Radius.circular(
                  isUser ? LmRadius.rLg : LmRadius.rXs,
                ),
                bottomRight: Radius.circular(
                  isUser ? LmRadius.rXs : LmRadius.rLg,
                ),
              ),
        border: summary
            ? Border(left: BorderSide(color: colors.accent, width: 3))
            : null,
      ),
      child: child,
    );
  }

  @override
  Widget inputArea(
    BuildContext context,
    Widget child, {
    bool narrative = false,
  }) {
    final colors = context.lm.palette;
    return ComposerSurface(
      color: colors.surfaceElevated,
      borderColor: colors.divider,
      child: child,
    );
  }

  @override
  Color? overlayBarrierColor(BuildContext context) => null;

  @override
  Color sheetFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback) =>
      fallback;

  @override
  Clip? sheetClipBehavior(BuildContext context, Clip? fallback) => fallback;

  @override
  Color settingCardFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  }) =>
      child;

  @override
  PreferredSizeWidget appBar(
    BuildContext context, {
    required String title,
    String? subtitle,
    List<Widget>? actions,
    Widget? leading,
    bool automaticallyImplyLeading = true,
  }) =>
      SimpleAppBar(
        title: title,
        subtitle: subtitle,
        actions: actions,
        leading: leading,
        automaticallyImplyLeading: automaticallyImplyLeading,
      );

  @override
  Widget settingSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) =>
      SimpleSettingSection(title: title, child: child);

  @override
  Widget selectionOption(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool isEnabled = true,
    String? disabledLabel,
  }) =>
      SimpleSelectionOption(
        label: label,
        isSelected: isSelected,
        onTap: onTap,
        isEnabled: isEnabled,
        disabledLabel: disabledLabel,
      );

  @override
  Widget emptyState(
    BuildContext context, {
    required String title,
    String? subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      SimpleEmptyState(
        title: title,
        subtitle: subtitle,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  @override
  Widget entryTransition(
    BuildContext context, {
    required Widget child,
  }) =>
      EntryTransition(child: child);

  @override
  Widget embeddingMissingBanner(
    BuildContext context, {
    required VoidCallback onConfigure,
    required VoidCallback onDismiss,
  }) =>
      EmbeddingMissingBanner(onConfigure: onConfigure, onDismiss: onDismiss);

  @override
  Widget historyPanelShell(
    BuildContext context, {
    required String summary,
    required Widget expandedContent,
    Key? key,
    bool animateEntrance = true,
  }) =>
      HistoryPanelShell(
        key: key,
        summary: summary,
        expandedContent: expandedContent,
        animateEntrance: animateEntrance,
      );

  @override
  Widget inputToolbar(
    BuildContext context, {
    required VoidCallback onAddQuote,
    required VoidCallback onAddParen,
    required VoidCallback onSuggest,
    required bool isGeneratingSuggest,
    required bool canSuggest,
    Widget? trailing,
  }) =>
      InputToolbar(
        onAddQuote: onAddQuote,
        onAddParen: onAddParen,
        onSuggest: onSuggest,
        isGeneratingSuggest: isGeneratingSuggest,
        canSuggest: canSuggest,
        trailing: trailing,
      );

  @override
  Future<bool> confirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmLabel,
  }) =>
      IntermediateConfirmDialog.show(
        context: context,
        title: title,
        content: content,
        confirmLabel: confirmLabel,
      );

  @override
  Future<({String content, bool resend})?> editDialog(
    BuildContext context, {
    required String initialContent,
    bool allowResend = true,
  }) =>
      IntermediateEditDialog.show(
        context,
        initialContent: initialContent,
        allowResend: allowResend,
      );

  @override
  Widget markdownBody(
    BuildContext context, {
    required String data,
    bool narrative = false,
    bool isUser = false,
    double fontScale = 1.0,
    VoidCallback? onTapText,
  }) =>
      narrative
          ? IntermediateMarkdownBody(
              data: data,
              isUser: isUser,
              fontScale: fontScale,
              onTapText: onTapText,
            )
          : SimpleMarkdownBody(data: data, fontScale: fontScale);

  @override
  TextStyle markdownParagraphStyle(
    BuildContext context, {
    required bool isUser,
    double fontScale = 1.0,
  }) =>
      IntermediateMarkdownBody.paragraphStyle(
        colors: context.lm.palette,
        isUser: isUser,
        fontScale: fontScale,
      );

  @override
  Widget messageNavigation(
    BuildContext context, {
    required VoidCallback onJumpToTop,
    required VoidCallback onJumpToBottom,
    required VoidCallback onPrevUserMessage,
    required VoidCallback onNextUserMessage,
    required bool visible,
    bool narrative = false,
  }) =>
      narrative
          ? IntermediateMessageNavigation(
              onJumpToTop: onJumpToTop,
              onJumpToBottom: onJumpToBottom,
              onPrevUserMessage: onPrevUserMessage,
              onNextUserMessage: onNextUserMessage,
              visible: visible,
            )
          : SimpleMessageNavigation(
              onJumpToTop: onJumpToTop,
              onJumpToBottom: onJumpToBottom,
              onPrevUserMessage: onPrevUserMessage,
              onNextUserMessage: onNextUserMessage,
              visible: visible,
            );

  @override
  Widget messageActions(
    BuildContext context, {
    required bool isUser,
    required bool canOperate,
    required int windowRounds,
    required VoidCallback onCopy,
    required VoidCallback onRegenerate,
    required VoidCallback onEdit,
    required VoidCallback onDeleteRound,
  }) =>
      IntermediateMessageActions(
        isUser: isUser,
        canOperate: canOperate,
        windowRounds: windowRounds,
        onCopy: onCopy,
        onRegenerate: onRegenerate,
        onEdit: onEdit,
        onDeleteRound: onDeleteRound,
      );

  @override
  Widget compactionSummaryCard(
    BuildContext context, {
    required String content,
    double fontScale = 1.0,
    bool showFloorWarning = false,
    ({int from, int to})? archivedTurnRange,
    Future<void> Function()? onUndo,
    bool undoEnabled = true,
  }) =>
      IntermediateCompactionSummaryCard(
        content: content,
        fontScale: fontScale,
        showFloorWarning: showFloorWarning,
        archivedTurnRange: archivedTurnRange,
        onUndo: onUndo,
        undoEnabled: undoEnabled,
      );

  @override
  Widget narrativeBubble(
    BuildContext context, {
    required String content,
    required bool isUser,
    VoidCallback? onCopy,
    VoidCallback? onRegenerate,
    VoidCallback? onEdit,
    VoidCallback? onDeleteRound,
    String? thinkingContent,
    bool isStreaming = false,
    bool isLastAssistantMessage = false,
    bool canOperate = true,
    int windowRounds = 5,
    bool actionsEnabled = true,
    bool animateEntrance = true,
    double fontScale = 1.0,
    Key? key,
  }) =>
      IntermediateMessageBubble(
        key: key,
        content: content,
        isUser: isUser,
        thinkingContent: thinkingContent,
        isStreaming: isStreaming,
        isLastAssistantMessage: isLastAssistantMessage,
        canOperate: canOperate,
        windowRounds: windowRounds,
        actionsEnabled: actionsEnabled,
        animateEntrance: animateEntrance,
        fontScale: fontScale,
        onCopy: onCopy ?? _noop,
        onRegenerate: onRegenerate ?? _noop,
        onEdit: onEdit ?? _noop,
        onDeleteRound: onDeleteRound ?? _noop,
      );

  static void _noop() {}

  @override
  Widget suggestReplyOverlay(
    BuildContext context, {
    required List<String> replies,
    required bool isGenerating,
    required bool isExpanded,
    required void Function(int index) onSelect,
    required VoidCallback onClose,
    required VoidCallback onToggle,
    bool isFailed = false,
    Future<bool> Function()? onRetry,
  }) =>
      SuggestReplyOverlay(
        replies: replies,
        isGenerating: isGenerating,
        isExpanded: isExpanded,
        onSelect: onSelect,
        onClose: onClose,
        onToggle: onToggle,
        isFailed: isFailed,
        onRetry: onRetry,
      );

  @override
  Widget panelVenue(BuildContext context, Widget child) =>
      structurePanelVenue(context, child);
}
