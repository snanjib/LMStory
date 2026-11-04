/// Dart 源码**文本**工具（守卫用例共用）。
///
/// 守卫里大量「数一数源码里有没有裸写某个 API」的断言都建立在同一件事上：
/// 先把注释剥掉。放在这里共用，免得每个守卫各抄一份状态机。
library;

/// 去注释（行注释 + 块注释），**字符串内容保留**——与仓库「中文字面量门禁」
/// （`tool/ci_guards/check_chinese_literals.py`）同法。
///
/// 为什么必须去注释：守卫要统计的是「源码里有没有裸写某个 API」，而文档注释里
/// 正经提到这些名字（作为「不要这么写」的反例、或说明为什么不用它）不算违规。
String stripDartComments(String source) {
  final out = StringBuffer();
  var inLineComment = false;
  var inBlockComment = false;
  var quote = '';

  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';

    if (inLineComment) {
      if (c == '\n') {
        inLineComment = false;
        out.write(c);
      }
      continue;
    }
    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        i++;
      } else if (c == '\n') {
        out.write(c);
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (c == r'\') {
        out.write(c);
        if (i + 1 < source.length) out.write(source[i + 1]);
        i++;
        continue;
      }
      if (c == quote) quote = '';
      out.write(c);
      continue;
    }
    if (c == '/' && next == '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    if (c == "'" || c == '"') quote = c;
    out.write(c);
  }
  return out.toString();
}
