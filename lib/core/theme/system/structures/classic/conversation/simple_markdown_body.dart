import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_code_block.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_latex_builder.dart';
import 'package:lmstory/i18n/strings.g.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

/// Simple mode Markdown message renderer.
///
/// 对标 ChatBox Markdown.tsx，支持：
/// - GFM 扩展语法（表格、任务列表、删除线、自动链接）
/// - 代码语法高亮（flutter_highlighting，github/github-dark 主题）
/// - 代码块语言标签、折叠（>7行）、复制按钮
/// - LaTeX 数学公式（flutter_math_fork，行内 $...$ 和块级 $$...$$）
/// - Mermaid 降级提示（Flutter 无原生 Mermaid 支持）
/// - 链接点击打开外部浏览器（url_launcher）
class SimpleMarkdownBody extends StatefulWidget {
  const SimpleMarkdownBody({
    required this.data,
    this.fontScale = 1.0,
    super.key,
  });

  /// The Markdown content to render.
  final String data;

  /// 字体缩放比例（来自设置中的字体大小选项）
  /// - small: 0.9
  /// - medium: 1.0
  /// - large: 1.15
  final double fontScale;

  /// 段落（styleSheet.p）样式——单源提取，供两处共用：
  /// `_buildStyleSheet` 的 `p` 与流式纯文本快速路径
  /// （StreamingMarkdownBody.plainTextStyle）同源，保证 Text 与
  /// MarkdownBody 切换瞬间字号/行高/颜色一致。
  static TextStyle paragraphStyle({
    required LmPalette colors,
    double fontScale = 1.0,
  }) =>
      LmUiTextStyles.body.copyWith(
        color: colors.ink,
        fontSize: (LmUiTextStyles.body.fontSize ?? 15) * fontScale,
      );

  @override
  State<SimpleMarkdownBody> createState() => _SimpleMarkdownBodyState();
}

class _SimpleMarkdownBodyState extends State<SimpleMarkdownBody> {
  ///  Markdown memo：内容未变的重建直接复用上次的 MarkdownBody 实例。
  ///
  /// 流式期间父级每帧重建（气泡列表/思考区状态变化），若每次都重建
  /// MarkdownBody 会全文重新解析；identical 实例让 Flutter 跳过其
  /// 子树重建。data/fontScale/亮度任一变化才真正重建。
  MarkdownBody? _cachedBody;
  String? _cachedData;
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
        widget.fontScale != _cachedScale ||
        brightness != _cachedBrightness ||
        tokens.structureId != _cachedStructureId ||
        tokens.paletteId != _cachedPaletteId) {
      _cachedData = widget.data;
      _cachedScale = widget.fontScale;
      _cachedBrightness = brightness;
      _cachedStructureId = tokens.structureId;
      _cachedPaletteId = tokens.paletteId;
      _cachedBody = _buildBody(context, colors, brightness);
    }
    return _cachedBody!;
  }

  MarkdownBody _buildBody(
    BuildContext context,
    LmPalette colors,
    Brightness brightness,
  ) {
    return MarkdownBody(
      data: widget.data,
      selectable: true,
      onTapLink: (text, href, title) => _onTapLink(context, text, href, title),
      extensionSet: md.ExtensionSet(
        <md.BlockSyntax>[
          ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
          LatexBlockSyntax(),
        ],
        <md.InlineSyntax>[
          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
          LatexInlineSyntax(),
        ],
      ),
      builders: {
        'pre': SimpleCodeBlockBuilder(brightness: brightness, colors: colors),
        'latex': SafeLatexElementBuilder(
          colors: colors,
          brightness: brightness,
          fontScale: widget.fontScale,
        ),
      },
      styleSheet: _buildStyleSheet(colors),
    );
  }

  MarkdownStyleSheet _buildStyleSheet(LmPalette colors) {
    return MarkdownStyleSheet(
      a: TextStyle(color: colors.primary),
      p: SimpleMarkdownBody.paragraphStyle(
        colors: colors,
        fontScale: widget.fontScale,
      ),
      pPadding: EdgeInsets.zero,
      code: LmUiTextStyles.bodySm.copyWith(
        fontFamily: 'monospace',
        backgroundColor: colors.surfaceVariant,
        fontSize: 13 * widget.fontScale,
      ),
      h1: LmUiTextStyles.title1.copyWith(
        color: colors.ink,
        fontSize: (LmUiTextStyles.title1.fontSize ?? 22) * widget.fontScale,
      ),
      h1Padding: const EdgeInsets.only(top: LmSpacing.sMd),
      h2: LmUiTextStyles.title2.copyWith(
        color: colors.ink,
        fontSize: (LmUiTextStyles.title2.fontSize ?? 18) * widget.fontScale,
      ),
      h2Padding: const EdgeInsets.only(top: LmSpacing.sMd),
      h3: LmUiTextStyles.title3.copyWith(
        color: colors.ink,
        fontSize: (LmUiTextStyles.title3.fontSize ?? 16) * widget.fontScale,
      ),
      h3Padding: const EdgeInsets.only(top: LmSpacing.sSm),
      h4: LmUiTextStyles.body.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w600,
        fontSize: (LmUiTextStyles.body.fontSize ?? 15) * widget.fontScale,
      ),
      h4Padding: const EdgeInsets.only(top: LmSpacing.sSm),
      h5: LmUiTextStyles.body.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w500,
        fontSize: (LmUiTextStyles.body.fontSize ?? 15) * widget.fontScale,
      ),
      h5Padding: const EdgeInsets.only(top: LmSpacing.s2xs),
      h6: LmUiTextStyles.bodySm.copyWith(
        color: colors.muted,
        fontWeight: FontWeight.w500,
        fontSize: (LmUiTextStyles.bodySm.fontSize ?? 14) * widget.fontScale,
      ),
      h6Padding: const EdgeInsets.only(top: LmSpacing.s2xs),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w600),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      blockquote: LmUiTextStyles.body.copyWith(color: colors.muted),
      blockquotePadding: const EdgeInsets.all(LmSpacing.sMd),
      blockquoteDecoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border(
          left: BorderSide(color: colors.primary, width: 3),
        ),
      ),
      codeblockPadding: const EdgeInsets.all(LmSpacing.sMd),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      blockSpacing: LmSpacing.s2xs,
      listIndent: LmSpacing.sLg,
      listBullet: LmUiTextStyles.body.copyWith(color: colors.ink),
      listBulletPadding: const EdgeInsets.only(right: LmSpacing.s2xs),
      tableHead: LmUiTextStyles.bodySm.copyWith(
        fontWeight: FontWeight.w600,
        color: colors.ink,
      ),
      tableBody: LmUiTextStyles.bodySm.copyWith(color: colors.ink),
      tableHeadAlign: TextAlign.left,
      tablePadding: const EdgeInsets.only(bottom: LmSpacing.s2xs),
      tableBorder: TableBorder.all(
        color: colors.divider,
      ),
      tableColumnWidth: const FlexColumnWidth(),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
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

    // 优先用 url_launcher 打开外部浏览器
    final uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return;
      } on Exception {
        // 启动失败，回退到复制到剪贴板
      }
    }

    // 非 http(s) 链接或启动失败：复制到剪贴板作为回退
    await Clipboard.setData(ClipboardData(text: href));
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.chat.messageActions.linkCopied),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
