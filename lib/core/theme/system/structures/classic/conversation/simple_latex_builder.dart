import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

/// 安全的 LaTeX 元素构建器。
///
/// 包装 flutter_markdown_latex 的渲染逻辑，添加 try-catch 降级：
/// - 公式渲染成功：显示 Math.tex 渲染结果
/// - 公式渲染失败（如 mhchem `\ce{}` 等不支持的命令）：降级为纯文本显示
///
/// 注意：flutter_math_fork 不支持 mhchem（`\ce{}` `\pu{}`）等 KaTeX 扩展，
/// 遇到不支持的命令会抛异常，必须 catch 降级避免整个消息渲染崩溃。
class SafeLatexElementBuilder extends MarkdownElementBuilder {
  SafeLatexElementBuilder({
    required this.brightness,
    required this.colors,
    this.fontScale = 1.0,
  });

  final Brightness brightness;
  final LmPalette colors;
  final double fontScale;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (text.isEmpty) return const SizedBox();

    final mathStyle = element.attributes['MathStyle'] == 'display'
        ? MathStyle.display
        : MathStyle.text;

    try {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.antiAlias,
        child: Math.tex(
          text,
          textStyle: LmUiTextStyles.body.copyWith(
            color: colors.ink,
            fontSize: (LmUiTextStyles.body.fontSize ?? 15) * fontScale,
          ),
          mathStyle: mathStyle,
          textScaleFactor: fontScale,
        ),
      );
    } on Exception {
      // 渲染失败（如不支持的 LaTeX 命令）：降级为纯文本显示
      return Text(
        text,
        style: LmUiTextStyles.body.copyWith(
          color: colors.muted,
          fontFamily: 'monospace',
          fontSize: (LmUiTextStyles.body.fontSize ?? 15) * fontScale,
        ),
      );
    }
  }
}
