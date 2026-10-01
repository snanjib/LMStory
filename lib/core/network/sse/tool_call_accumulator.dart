import 'dart:convert';

/// Tool Call 参数 JSON 修复器
/// 处理 SSE 流中截断的 JSON：自动闭合括号、移除尾逗号
class ToolCallAccumulator {
  /// 修复可能截断的 JSON 字符串
  /// 操作顺序（对齐 DOC-04 Section 917-936）：
  /// 1. 去空白
  /// 2. 尝试直接解析
  /// 3. 统计括号并补全闭合
  /// 4. 闭合后再次移除尾逗号
  /// 5. 处理截断字符串
  /// 6. 最终解析
  static String repairJson(String rawJson) {
    if (rawJson.trim().isEmpty) return '{}';

    var json = rawJson.trim();

    // 尝试直接解析，如果成功则无需修复
    try {
      jsonDecode(json);
      return json;
    } catch (_) {
      // 需要修复
    }

    // 计算未闭合的括号
    var openBraces = 0;
    var openBrackets = 0;
    var inString = false;
    var escape = false;

    for (var i = 0; i < json.length; i++) {
      final char = json[i];

      if (escape) {
        escape = false;
        continue;
      }

      if (char == r'\' && inString) {
        escape = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (inString) continue;

      if (char == '{') openBraces++;
      if (char == '}') openBraces--;
      if (char == '[') openBrackets++;
      if (char == ']') openBrackets--;
    }

    // 下界保护：多余闭合括号时计数器可能为负
    if (openBraces < 0) openBraces = 0;
    if (openBrackets < 0) openBrackets = 0;

    // 如果在字符串中间截断，关闭字符串
    final suffix = StringBuffer();
    if (inString) {
      // 如果末尾是不完整的转义序列，移除反斜杠
      if (escape) {
        json = json.substring(0, json.length - 1);
      }
      suffix.write('"');
    }

    // 闭合未关闭的括号
    for (var i = 0; i < openBrackets; i++) {
      suffix.write(']');
    }
    for (var i = 0; i < openBraces; i++) {
      suffix.write('}');
    }

    json += suffix.toString();

    // 闭合后再次移除尾逗号（关键：修复 {"key":"value",} 这类模式）
    json = json.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (m) => m[1]!,
    );

    // 最终尝试解析
    try {
      jsonDecode(json);
      return json;
    } catch (_) {
      // 如果仍然失败，返回空对象
      return '{}';
    }
  }

  /// 解析修复后的 JSON
  static Map<String, dynamic> parseAndRepair(String rawJson) {
    final repaired = repairJson(rawJson);
    try {
      return jsonDecode(repaired) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
