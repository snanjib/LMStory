import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:url_launcher/url_launcher.dart';

/// 故事模式有限 Markdown 渲染器（DOC-06B §6.1）。
///
/// 与 Simple 模式的差异：
/// - 仅启用 CommonMark 基础语法（加粗/斜体/行内代码/引用/列表/分隔线/链接）
/// - 不启用 GFM 扩展（无表格、任务列表、删除线）
/// - 不启用 LaTeX 公式 / 代码块语法高亮（叙事场景不需要）
/// - 双字体策略：助手消息用衬线（narrativeBody），用户消息用无衬线（bodyUi）
///
/// 设计动机：用户反馈"星号问题"——LLM 输出 `*斜体*` `**加粗**` 时，
/// 纯 SelectableText 会原样显示星号。引入有限 Markdown 渲染即可消解。
///
/// impeccable 约束：
/// - blockquote 不用 border-left 侧条（AI slop 禁令），改用 surfaceVariant
///   底色 + 全圆角 + 斜体字体实现引用块
/// - 不使用渐变文字、glassmorphism 等装饰
class IntermediateMarkdownBody extends StatefulWidget {
  const IntermediateMarkdownBody({
    required this.data,
    required this.isUser,
    this.fontScale = 1.0,
    this.softLineBreak = false,
    this.onTapText,
    super.key,
  });

  /// 消息文本（可能包含未闭合的 Markdown 标记，流式生成时常见）
  final String data;

  /// 是否为用户消息
  /// - true：使用无衬线 bodyUi 字体（UI 操作感）
  /// - false：使用衬线 narrativeBody 字体（叙事感）
  final bool isUser;

  /// 字体缩放比例（与宿主气泡共享）
  /// 应用到正文 narrativeBody（16px）/ bodyUi（15px）与引用的字号
  final double fontScale;

  final bool softLineBreak;

  /// Called when the user taps non-link message text. Markdown's selectable
  /// text owns the gesture arena, so the outer bubble cannot observe this tap.
  final VoidCallback? onTapText;

  /// 段落（styleSheet.p）样式——单源提取，供两处共用：
  /// styleSheet 构建处的 `p` 与流式纯文本快速路径
  /// （StreamingMarkdownBody.plainTextStyle）同源，保证 Text 与
  /// MarkdownBody 切换瞬间字号/行高/颜色一致。
  static TextStyle paragraphStyle({
    required LmPalette colors,
    required bool isUser,
    double fontScale = 1.0,
  }) {
    final baseStyle = isUser
        ? LmNarrativeTextStyles.bodyUi
        : LmNarrativeTextStyles.narrativeBody;
    return baseStyle.copyWith(
      color: colors.ink,
      fontSize: (baseStyle.fontSize ?? (isUser ? 15 : 16)) * fontScale,
    );
  }

  @override
  State<IntermediateMarkdownBody> createState() =>
      _IntermediateMarkdownBodyState();
}

class _IntermediateMarkdownBodyState extends State<IntermediateMarkdownBody> {
  /// data-identical memo：照抄 chat 侧
  /// SimpleMarkdownBody 的  模式。流式期间父级每帧重建（气泡列表/
  /// 思考区状态变化），若每次都重建 MarkdownBody 会全文重新解析；
  /// identical 实例让 Flutter 跳过其子树重建。
  /// data/isUser/fontScale/亮度任一变化才真正重建。
  MarkdownBody? _cachedBody;
  String? _cachedData;
  bool? _cachedIsUser;
  bool? _cachedSoftLineBreak;
  double? _cachedScale;
  Brightness? _cachedBrightness;
  String? _cachedStructureId;
  String? _cachedPaletteId;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final brightness = Theme.of(context).brightness;
    final tokens = context.lm;

    if (_cachedBody == null ||
        widget.data != _cachedData ||
        widget.isUser != _cachedIsUser ||
        widget.softLineBreak != _cachedSoftLineBreak ||
        widget.fontScale != _cachedScale ||
        brightness != _cachedBrightness ||
        tokens.structureId != _cachedStructureId ||
        tokens.paletteId != _cachedPaletteId) {
      _cachedData = widget.data;
      _cachedIsUser = widget.isUser;
      _cachedSoftLineBreak = widget.softLineBreak;
      _cachedScale = widget.fontScale;
      _cachedBrightness = brightness;
      _cachedStructureId = tokens.structureId;
      _cachedPaletteId = tokens.paletteId;
      _cachedBody = _buildBody(colors);
    }
    return _cachedBody!;
  }

  MarkdownBody _buildBody(LmPalette colors) {
    return MarkdownBody(
      data: widget.data,
      selectable: true,
      softLineBreak: widget.softLineBreak,
      onTapLink: (text, href, title) => _onTapLink(context, text, href, title),
      onTapText: widget.onTapText,
      // 不传 extensionSet → 使用 ExtensionSet.none（CommonMark 基础语法）
      // 故事场景不需要 GFM 表格/任务列表/删除线，也不需要 LaTeX/代码高亮
      styleSheet: _buildStyleSheet(colors),
    );
  }

  MarkdownStyleSheet _buildStyleSheet(LmPalette colors) {
    // 双字体策略（DOC-06B §4.1）：助手衬线 / 用户无衬线
    final baseNarrative = IntermediateMarkdownBody.paragraphStyle(
      colors: colors,
      isUser: widget.isUser,
      fontScale: widget.fontScale,
    );

    return MarkdownStyleSheet(
      // 链接：琥珀金 + 下划线
      a: TextStyle(
        color: colors.primary,
        decoration: TextDecoration.underline,
        decorationColor: colors.primary.withValues(alpha: 0.6),
      ),
      // 段落：跟随角色字体（衬线/无衬线）
      p: baseNarrative,
      pPadding: EdgeInsets.zero,
      // 行内代码：monospace + surfaceVariant 底色（低调区分正文）
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 14 * widget.fontScale,
        color: colors.ink,
        backgroundColor: colors.surfaceVariant,
      ),
      // 不渲染标题层级（H1-H6 落到 base 字体族但弱化字号差异）
      // 故事场景不应出现标题，但若 LLM 误输出，统一渲染为加粗段落，避免视觉断层
      h1: baseNarrative.copyWith(fontWeight: FontWeight.w600),
      h2: baseNarrative.copyWith(fontWeight: FontWeight.w600),
      h3: baseNarrative.copyWith(fontWeight: FontWeight.w600),
      h4: baseNarrative.copyWith(fontWeight: FontWeight.w600),
      h5: baseNarrative.copyWith(fontWeight: FontWeight.w600),
      h6: baseNarrative.copyWith(
        fontWeight: FontWeight.w600,
        color: colors.muted,
      ),
      h1Padding: const EdgeInsets.only(top: LmSpacing.sSm),
      h2Padding: const EdgeInsets.only(top: LmSpacing.sSm),
      h3Padding: const EdgeInsets.only(top: LmSpacing.sXs),
      h4Padding: const EdgeInsets.only(top: LmSpacing.sXs),
      h5Padding: EdgeInsets.zero,
      h6Padding: EdgeInsets.zero,
      // 强调：保留原字体族，仅字重/字形变化
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w600),
      // 引用：surfaceVariant 底色 + 全圆角 + 斜体
      // 不用 border-left 侧条（impeccable 禁令）
      // 用户消息也用斜体（无衬线斜体），保持引用语义一致
      blockquote: baseNarrative.copyWith(
        fontStyle: FontStyle.italic,
        color: colors.muted,
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sMd,
        vertical: LmSpacing.sSm,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      // 代码块：surfaceVariant 底色 + 圆角（无语法高亮，故事场景降级）
      codeblockPadding: const EdgeInsets.all(LmSpacing.sMd),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      blockSpacing: LmSpacing.s2xs,
      listIndent: LmSpacing.sLg,
      listBullet: baseNarrative.copyWith(color: colors.muted),
      listBulletPadding: const EdgeInsets.only(right: LmSpacing.s2xs),
      // 分隔线：divider 色 1px
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.divider),
        ),
      ),
    );
  }

  Future<void> _onTapLink(
    BuildContext context,
    String text,
    String? href,
    String title,
  ) async {
    if (href == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = Translations.of(context);

    final uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return;
      } on Exception {
        // 启动失败回退到剪贴板
      }
    }

    // 非 http(s) 或启动失败：复制到剪贴板
    await Clipboard.setData(ClipboardData(text: href));
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.intermediate.chat.messageActions.linkCopied),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
