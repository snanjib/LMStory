/// JSON 嵌套深度守卫：字符串感知的括号计数（跳过字符串字面量与转义），
/// 只跟踪最大嵌套深度，不构建树。
///
/// 真实角色卡/世界书/数据备份的深度 < 20，此上限只拦恶意或意外构造的
/// 深嵌套输入。dart 的 jsonDecode 为递归下降解析，极深输入会栈溢出——
/// UI 层 catch-all 能兜住不崩溃，但守卫前置可给出明确错误信息并避免
/// 解析器空转。资源导入与数据备份导入共用本口径。
library;

/// JSON 嵌套深度上限
const int maxJsonDepth = 500;

/// 内容是否超过 JSON 嵌套深度上限。
bool exceedsMaxDepth(String source) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final codeUnit in source.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5C) {
        escaped = true; // 反斜杠转义
      } else if (codeUnit == 0x22) {
        inString = false; // 引号闭合
      }
      continue;
    }
    if (codeUnit == 0x22) {
      inString = true;
    } else if (codeUnit == 0x7B || codeUnit == 0x5B) {
      // { [
      depth++;
      if (depth > maxJsonDepth) return true;
    } else if (codeUnit == 0x7D || codeUnit == 0x5D) {
      // } ]
      if (depth > 0) depth--;
    }
  }
  return false;
}
