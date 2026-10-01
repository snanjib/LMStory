import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/i18n/strings.g.dart';

// ignore: depend_on_referenced_packages, directives_ordering
import 'package:flutter_highlighting/themes/github-dark.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_highlighting/themes/github.dart';
// ignore: depend_on_referenced_packages
import 'package:highlighting/highlighting.dart';
// ignore: depend_on_referenced_packages, unused_import
import 'package:highlighting/languages/all.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

/// 代码块折叠阈值（对标 ChatBox CODE_BLOCK_COLLAPSE_LINE_THRESHOLD = 7）
const int kCodeBlockCollapseThreshold = 7;

/// Mermaid 语言标识
const String kMermaidLanguage = 'mermaid';

/// Simple 模式代码块 MarkdownElementBuilder。
///
/// 对标 ChatBox BlockCode：
/// - 语法高亮（flutter_highlighting，github/github-dark 主题）
/// - 语言标签（顶部栏左侧，大写）
/// - 复制按钮（顶部栏右侧）
/// - 折叠/展开（>7 行）
/// - Mermaid 降级提示（Flutter 无原生 Mermaid 支持）
class SimpleCodeBlockBuilder extends MarkdownElementBuilder {
  SimpleCodeBlockBuilder({required this.brightness, required this.colors});

  final Brightness brightness;
  final LmPalette colors;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final (language, code) = _extractLanguageAndCode(element);
    return SimpleCodeBlock(
      code: code,
      language: language,
      brightness: brightness,
      colors: colors,
    );
  }

  /// 从 pre 元素中提取语言标签和代码内容。
  /// pre 元素结构：<pre><code class="language-dart">code</code></pre>
  (String?, String) _extractLanguageAndCode(md.Element element) {
    String? language;
    for (final child in element.children ?? <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        final match = RegExp(r'language-(\w+)').firstMatch(cls);
        if (match != null) {
          language = match.group(1);
        }
      }
    }
    return (language, element.textContent);
  }
}

/// Simple 模式代码块 Widget。
class SimpleCodeBlock extends StatefulWidget {
  const SimpleCodeBlock({
    required this.code,
    required this.brightness,
    required this.colors,
    this.language,
    super.key,
  });

  final String code;
  final String? language;
  final Brightness brightness;
  final LmPalette colors;

  @override
  State<SimpleCodeBlock> createState() => _SimpleCodeBlockState();
}

class _SimpleCodeBlockState extends State<SimpleCodeBlock> {
  bool _isCollapsed = true;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final t = Translations.of(context);
    final isDark = widget.brightness == Brightness.dark;
    final theme = isDark ? githubDarkTheme : githubTheme;
    final isMermaid = widget.language?.toLowerCase() == kMermaidLanguage;

    final lines = widget.code.split('\n');
    final isLongCode = lines.length > kCodeBlockCollapseThreshold;
    final showCollapsed = _isCollapsed && isLongCode;
    final displayCode = showCollapsed
        ? lines.take(kCodeBlockCollapseThreshold).join('\n')
        : widget.code;

    final languageLabel = (widget.language ?? 'text').toUpperCase();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: LmSpacing.s2xs),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(colors, t, languageLabel, isLongCode),
          if (isMermaid) _buildMermaidHint(colors, t),
          _buildCodeArea(colors, theme, displayCode, isDark),
        ],
      ),
    );
  }

  Widget _buildHeader(
    LmPalette colors,
    Translations t,
    String languageLabel,
    bool isLongCode,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sMd,
        LmSpacing.sXs,
        LmSpacing.s2xs,
        LmSpacing.sXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              languageLabel,
              style: LmUiTextStyles.bodySm.copyWith(
                color: colors.muted,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isLongCode)
            _IconButton(
              icon: _isCollapsed ? Icons.expand_more : Icons.expand_less,
              color: colors.muted,
              tooltip: _isCollapsed
                  ? t.chat.messageActions.codeExpand
                  : t.chat.messageActions.codeCollapse,
              onTap: () => setState(() => _isCollapsed = !_isCollapsed),
            ),
          _CopyCodeButton(code: widget.code, colors: colors),
        ],
      ),
    );
  }

  Widget _buildMermaidHint(LmPalette colors, Translations t) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        LmSpacing.sMd,
        0,
        LmSpacing.sMd,
        LmSpacing.sXs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: colors.primary),
          const SizedBox(width: LmSpacing.s2xs),
          Expanded(
            child: Text(
              t.chat.messageActions.mermaidNotSupported,
              style: LmUiTextStyles.bodySm.copyWith(color: colors.primary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeArea(
    LmPalette colors,
    Map<String, TextStyle> theme,
    String displayCode,
    bool isDark,
  ) {
    final spans = _buildHighlightedSpans(
      displayCode,
      widget.language,
      theme,
      isDark,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sMd,
        LmSpacing.sXs,
        LmSpacing.sMd,
        LmSpacing.sMd,
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText.rich(
            TextSpan(
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: theme['root']?.color ?? colors.ink,
              ),
              children: spans,
            ),
          ),
        ),
      ),
    );
  }

  /// 递归构建高亮 TextSpan（带 LRU 缓存以避免滚动重绘时昂贵的正则高亮重算）。
  List<InlineSpan> _buildHighlightedSpans(
    String code,
    String? language,
    Map<String, TextStyle> theme,
    bool isDark,
  ) {
    final key = _CodeHighlightCacheKey(
      code: code,
      language: language,
      isDark: isDark,
    );
    final cached = _CodeHighlightCache.instance.get(key);
    if (cached != null) return cached;

    // ignore: invalid_use_of_internal_member
    final result = highlight.highlight(language ?? '', code, true);
    final nodes = result.nodes ?? [];
    final spans = nodes.map((node) => _nodeToSpan(node, theme)).toList();
    _CodeHighlightCache.instance.put(key, spans);
    return spans;
  }

  InlineSpan _nodeToSpan(Node node, Map<String, TextStyle> theme) {
    if (node.value != null) {
      return TextSpan(text: node.value, style: theme[node.className]);
    }
    return TextSpan(
      style: theme[node.className],
      children: node.children.map((n) => _nodeToSpan(n, theme)).toList(),
    );
  }
}

/// 代码高亮 LRU 缓存 Key
@immutable
class _CodeHighlightCacheKey {
  const _CodeHighlightCacheKey({
    required this.code,
    required this.language,
    required this.isDark,
  });

  final String code;
  final String? language;
  final bool isDark;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CodeHighlightCacheKey &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          language == other.language &&
          isDark == other.isDark;

  @override
  int get hashCode => Object.hash(code, language, isDark);
}

/// 代码高亮结果的全局 LRU 缓存，容量为 200 项。
class _CodeHighlightCache {
  _CodeHighlightCache._();
  static final _CodeHighlightCache instance = _CodeHighlightCache._();

  static const int _maxEntries = 200;
  final LinkedHashMap<_CodeHighlightCacheKey, List<InlineSpan>> _cache =
      LinkedHashMap<_CodeHighlightCacheKey, List<InlineSpan>>();

  List<InlineSpan>? get(_CodeHighlightCacheKey key) {
    final value = _cache.remove(key);
    if (value != null) {
      _cache[key] = value;
      return value;
    }
    return null;
  }

  void put(_CodeHighlightCacheKey key, List<InlineSpan> spans) {
    if (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = spans;
  }
}

/// 小图标按钮（折叠/展开等）
class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.s2xs),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}

/// 代码复制按钮
class _CopyCodeButton extends StatefulWidget {
  const _CopyCodeButton({required this.code, required this.colors});

  final String code;
  final LmPalette colors;

  @override
  State<_CopyCodeButton> createState() => _CopyCodeButtonState();
}

class _CopyCodeButtonState extends State<_CopyCodeButton> {
  bool _justCopied = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Tooltip(
      message: t.common.copy,
      child: InkWell(
        onTap: _copy,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.s2xs),
          child: Icon(
            _justCopied ? Icons.check : Icons.copy_outlined,
            size: 16,
            color: widget.colors.muted,
          ),
        ),
      ),
    );
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t.chat.messageActions.copySuccess),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
    setState(() => _justCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _justCopied = false);
    });
  }
}
