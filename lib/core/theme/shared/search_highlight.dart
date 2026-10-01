// 搜索关键字高亮共享工具（2026-09-08 搜索体验修复）
//
// 两个消费方：
// - 全局搜索结果预览（GlobalSearchDialog._SearchResultItem）
// - 对话模式会话内搜索命中条（SimpleMessageBubble 搜索命中上下文条）
//
// 统一口径：与 SQL `LIKE '%q%'` 对齐——ASCII 大小写不敏感
// （toLowerCase 定位），非 ASCII 按原文匹配。

import 'package:flutter/material.dart';

/// 在 [content] 中定位 [query]（大小写不敏感）
///
/// 返回首个命中下标；未命中返回 -1（SQL LIKE 命中但 Dart 定位失败的
/// Unicode 折叠差异场景由调用方回退全文展示）。
int findQueryIndex(String content, String query) {
  if (query.isEmpty) return -1;
  final idx = content.toLowerCase().indexOf(query.toLowerCase());
  if (idx >= 0) return idx;
  return content.indexOf(query);
}

/// 构造带关键字高亮的 [TextSpan]
///
/// [text] 内所有命中片段（大小写不敏感）以 [highlightStyle] 渲染，
/// 其余部分用 [baseStyle]。query 为空或未命中时返回单段 baseStyle。
TextSpan buildSearchHighlightSpans({
  required String text,
  required String query,
  required TextStyle baseStyle,
  required TextStyle highlightStyle,
}) {
  if (query.isEmpty || text.isEmpty) {
    return TextSpan(text: text, style: baseStyle);
  }
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (start < text.length) {
    final idx = lowerText.indexOf(lowerQuery, start);
    if (idx == -1) {
      spans.add(TextSpan(text: text.substring(start), style: baseStyle));
      break;
    }
    if (idx > start) {
      spans.add(
        TextSpan(text: text.substring(start, idx), style: baseStyle),
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(idx, idx + query.length),
        style: highlightStyle,
      ),
    );
    start = idx + query.length;
  }
  return TextSpan(children: spans);
}

/// 围绕首个命中构造上下文摘要片段（前后省略号标注截断）
///
/// [index] 为 [findQueryIndex] 的返回值（须 ≥ 0）。关键字始终完整包含
/// 在片段内——避免「预览不含搜索词」（短多行消息被 maxLines 截断时，
/// 关键字可能落在第 3 行之后完全不显示）。
String buildContextSnippet(
  String content,
  int index,
  int queryLength, {
  int before = 40,
  int after = 80,
}) {
  final start = (index - before).clamp(0, content.length);
  final end = (index + queryLength + after).clamp(0, content.length);
  return '${start > 0 ? '...' : ''}'
      '${content.substring(start, end)}'
      '${end < content.length ? '...' : ''}';
}
