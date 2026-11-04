/// 流式增量 JSON 字段提取器（新增）
///
/// 用于 JSON 模式下的流式显示：从**不完整的** JSON 字符串中实时提取
/// 某个字符串字段的当前值，让用户在 LLM 流式输出过程中即可看到
/// draft/reply 正文（而不是等到完整 JSON 接收后才开始显示）。
///
/// **设计权衡**：未引入完整 JSON 解析器（如 `json_parse_stream` 包），
/// 因为本解析器只需提取**字符串字段**的当前值，不需要处理对象/数组嵌套。
/// 简化版正则匹配 + 转义处理足够，且零依赖。
///
/// **算法**：
/// 1. 用正则匹配 `"fieldName"\s*:\s*"` 定位字段值起始位置
/// 2. 从起始位置开始，逐字符跟踪，处理 `\n` `\"` `\\` `\uXXXX` 等转义
/// 3. 遇到未转义的 `"` 表示字段值结束（完整返回）
/// 4. 流未结束时（无闭合 `"`）返回已累积的部分（流式显示用）
///
/// **限制**：
/// - 只支持字符串字段（draft/reply 都是字符串）
/// - 不验证 JSON 整体结构（由 `parseDraftJsonResult` / `parseReviseJsonResult` 流结束后做）
/// - 如果 fieldName 在 JSON 中出现多次，返回第一个匹配
///
/// 关联设计` §3.1.4
class IncrementalJsonParser {
  const IncrementalJsonParser._();

  /// 从部分 JSON 字符串中提取 [fieldName] 字符串字段的当前值
  ///
  /// 返回值语义：
  /// - `null`：字段尚未出现，或已开始但还未产生任何字符（如 `"draft":` 后尚无 `"`）
  /// - 非空字符串：字段值的当前累积（流式中可能不完整，结尾不带闭合 `"`）
  /// - 完整字符串：字段值已闭合（结尾字符是流中字段值的最后字符，不含闭合 `"`）
  ///
  /// 示例：
  /// ```dart
  /// extractStringField('{"draft":"主角来到', 'draft')  → '主角来到'
  /// extractStringField('{"draft":"主角来到"', 'draft')  → '主角来到'
  /// extractStringField('{"draft":', 'draft')           → null
  /// extractStringField('{"keywords":[]}', 'draft')     → null
  /// ```
  static String? extractStringField(String partialJson, String fieldName) {
    // 定位 "fieldName":" 模式（容忍字段名与值之间的空白）
    final pattern = RegExp('"$fieldName"\\s*:\\s*"');
    final match = pattern.firstMatch(partialJson);
    if (match == null) return null;

    final start = match.end;
    final buf = StringBuffer();
    var i = start;
    while (i < partialJson.length) {
      final ch = partialJson[i];
      if (ch == r'\') {
        // 转义序列：需要至少 2 个字符
        if (i + 1 >= partialJson.length) {
          // 流末尾刚好是反斜杠，无法判断转义内容，丢弃这次累积
          break;
        }
        final next = partialJson[i + 1];
        switch (next) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case '"':
            buf.write('"');
          case r'\':
            buf.write(r'\');
          case '/':
            buf.write('/');
          case 'b':
            buf.write('\b');
          case 'f':
            buf.write('\f');
          case 'u':
            // \uXXXX：需要 4 个十六进制字符
            if (i + 6 <= partialJson.length) {
              final hex = partialJson.substring(i + 2, i + 6);
              final code = int.tryParse(hex, radix: 16);
              if (code != null) {
                buf.write(String.fromCharCode(code));
                i += 6;
                continue;
              }
            }
            // 不完整的 \uXXXX，丢弃累积
            return buf.toString();
          default:
            // 未知转义，按字面量处理（容错）
            buf.write(next);
        }
        i += 2;
      } else if (ch == '"') {
        // 字段值闭合，返回完整值
        return buf.toString();
      } else {
        buf.write(ch);
        i++;
      }
    }
    // 字段值尚未闭合（流式中），返回已累积部分
    return buf.isEmpty ? null : buf.toString();
  }
}
