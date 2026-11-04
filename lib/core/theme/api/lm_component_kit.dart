import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_motion_profile.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_components.dart';

enum LmCorner { xs, sm, md, lg, xl, full }

/// The visual seam used by presentation code. A structure supplies every
/// surface; callers never select a structure by id.
abstract interface class LmComponentKit {
  LmMotionProfile get motionProfile;

  bool get ownsSheetSurface;

  double radius(LmCorner corner);

  Widget venue(BuildContext context, Widget child);

  Color scaffoldBackground(BuildContext context, Color fallback);

  Color sidebarSurfaceColor(BuildContext context);

  Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    VoidCallback? onTap,
    bool selected = false,
  });

  Widget settingCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool featured = false,
    bool narrative = false,
    bool enabled = true,
  });

  Widget entryCard(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required Color fallbackColor,
    bool horizontal = false,
  });

  TextStyle entryTitleStyle(BuildContext context, TextStyle fallback);

  Widget sessionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required bool hovered,
  });

  Widget selectionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback? onTap,
    required bool selected,
  });

  Widget messageBubble(
    BuildContext context, {
    required Widget child,
    required bool isUser,
    required bool standardLayout,
    bool summary = false,
    bool narrative = false,
  });

  Widget inputArea(
    BuildContext context,
    Widget child, {
    bool narrative = false,
  });

  Color? overlayBarrierColor(BuildContext context);

  Color sheetFaceColor(BuildContext context, Color fallback);

  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback);

  Clip? sheetClipBehavior(BuildContext context, Clip? fallback);

  Color settingCardFaceColor(BuildContext context, Color fallback);

  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  });

  /// Page app bar. Returns [PreferredSizeWidget] so it can slot straight
  /// into [Scaffold.appBar].
  PreferredSizeWidget appBar(
    BuildContext context, {
    required String title,
    String? subtitle,
    List<Widget>? actions,
    Widget? leading,
    bool automaticallyImplyLeading = true,
  });

  /// Titled grouping container for settings pages.
  Widget settingSection(
    BuildContext context, {
    required String title,
    required Widget child,
  });

  /// Single-choice option row (selector entries).
  Widget selectionOption(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool isEnabled = true,
    String? disabledLabel,
  });

  /// Full-page empty state with optional action.
  Widget emptyState(
    BuildContext context, {
    required String title,
    String? subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  });

  /// Standard entrance animation wrapper for page content.
  Widget entryTransition(BuildContext context, {required Widget child});

  /// Banner nudging the user to configure the embedding model.
  Widget embeddingMissingBanner(
    BuildContext context, {
    required VoidCallback onConfigure,
    required VoidCallback onDismiss,
  });

  /// Collapsible shell for persisted round panels shown in history mode.
  Widget historyPanelShell(
    BuildContext context, {
    required String summary,
    required Widget expandedContent,
    Key? key,
    bool animateEntrance = true,
  });

  /// Toolbar above the story input (quote / parenthesis / suggest reply).
  Widget inputToolbar(
    BuildContext context, {
    required VoidCallback onAddQuote,
    required VoidCallback onAddParen,
    required VoidCallback onSuggest,
    required bool isGeneratingSuggest,
    required bool canSuggest,
    Widget? trailing,
  });

  /// Confirmation dialog. Resolves true when confirmed.
  Future<bool> confirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmLabel,
  });

  /// Message edit dialog. Resolves the edited content and resend choice.
  Future<({String content, bool resend})?> editDialog(
    BuildContext context, {
    required String initialContent,
    bool allowResend = true,
  });

  /// Markdown renderer for message content. [narrative] selects the story
  /// variant; [isUser] and [onTapText] only apply to it.
  Widget markdownBody(
    BuildContext context, {
    required String data,
    bool narrative = false,
    bool isUser = false,
    double fontScale = 1.0,
    VoidCallback? onTapText,
  });

  /// Paragraph text style for the narrative markdown body; the streaming
  /// plain-text fast path must stay in sync with it.
  TextStyle markdownParagraphStyle(
    BuildContext context, {
    required bool isUser,
    double fontScale = 1.0,
  });

  /// Floating message navigation bar. [narrative] selects the story variant.
  Widget messageNavigation(
    BuildContext context, {
    required VoidCallback onJumpToTop,
    required VoidCallback onJumpToBottom,
    required VoidCallback onPrevUserMessage,
    required VoidCallback onNextUserMessage,
    required bool visible,
    bool narrative = false,
  });

  /// Hover action row under a story message.
  Widget messageActions(
    BuildContext context, {
    required bool isUser,
    required bool canOperate,
    required int windowRounds,
    required VoidCallback onCopy,
    required VoidCallback onRegenerate,
    required VoidCallback onEdit,
    required VoidCallback onDeleteRound,
  });

  /// Persisted compaction summary card.
  Widget compactionSummaryCard(
    BuildContext context, {
    required String content,
    double fontScale = 1.0,
    bool showFloorWarning = false,
    ({int from, int to})? archivedTurnRange,
    Future<void> Function()? onUndo,
    bool undoEnabled = true,
  });

  /// Story-mode message bubble (content-driven; all primitives/callbacks).
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
  });

  /// Suggested-reply floating overlay.
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
  });

  /// Venue for floating panels that carry their own backdrop (mobile
  /// drawer): the panel floats above scrim and page instead of the shell
  /// venue.
  Widget panelVenue(BuildContext context, Widget child);
}

class LmComponents extends ThemeExtension<LmComponents> {
  const LmComponents(this.kit);

  final LmComponentKit kit;

  @override
  LmComponents copyWith({LmComponentKit? kit}) => LmComponents(kit ?? this.kit);

  @override
  LmComponents lerp(covariant LmComponents? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension LmComponentContext on BuildContext {
  LmComponentKit get lmUi {
    final theme = Theme.of(this);
    final kit = theme.extension<LmComponents>()?.kit;
    if (kit == null) {
      // Embedded widgets and legacy test hosts can supply plain ThemeData.
      // A catalog theme with tokens must always carry a matching kit.
      if (theme.extension<LmTokens>() == null) {
        return const ClassicComponents();
      }
      throw StateError('LmComponentKit is missing from the active theme');
    }
    return kit;
  }
}

/// Route and scaffold surfaces are selected by the active implementation.
extension LmVenueContext on BuildContext {
  Widget lmVenue(Widget child) => lmUi.venue(this, child);

  Color scaffoldBgOf(Color fallback) => lmUi.scaffoldBackground(this, fallback);
}
