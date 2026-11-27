/// calc 资源上限与回显截断的单一真源。
///
/// 数值核心（fraction/calc_eval_engine）、日期核心（calc_date_engine）
/// 与工具适配层共用本文件；各处不得另建不一致的本地常量。
/// 选取口径：
/// - 表达式长度/token/深度沿用既有解析器上限；
/// - BigInt 位宽上限取 2^20 bit（约 31.6 万位十进制）：覆盖最大合法
///   单次幂 2^100000（100001 bit）与 fact(5000)（约 54662 bit），
///   同时让嵌套幂在分配前即可被位数估算拒绝；
/// - 日期/时长输入按严格 ISO/时长形状取宽裕上限；
/// - 工具层回显（成功 output/metadata 与错误信息中的输入原文）做
///   长度截断，避免大数值原文灌入模型上下文。
library;

/// calc 共享资源上限常量。
abstract final class CalcLimits {
  /// 表达式最大长度（字符）。
  static const int maxExpressionLength = 4000;

  /// 表达式 token 数上限。
  static const int maxTokens = 512;

  /// 解析器嵌套深度上限。
  static const int maxDepth = 64;

  /// 中间与最终 BigInt 位宽上限（分子/分母各自适用）。
  static const int maxBigIntBits = 1 << 20;

  /// 单次幂指数绝对值上限（沿用固定参考语义）。
  static const int maxPowExponent = 100000;

  /// 阶乘入参上限（沿用固定参考语义）。
  static const int maxFactArgument = 5000;

  /// 十进制数字面量指数绝对值上限。
  static const int maxDecimalExponent = 10000;

  /// date/add/to 单个输入字符串最大长度。
  static const int maxDateInputLength = 100;

  /// 时长数值（y/mo/d 各分量）上限。
  static const int maxDurationComponent = 100000;

  /// 工具层成功回显文本上限（超出截断并标注）。
  static const int maxEchoLength = 2000;

  /// 错误信息中回显输入原文的最大长度。
  static const int maxErrorEchoLength = 120;
}

/// 按上限截断回显文本；超限时追加「已截断」标注（含原文总长度）。
String truncateForEcho(
  String text, {
  int limit = CalcLimits.maxErrorEchoLength,
}) {
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}…（已截断，原文共 ${text.length} 字符）';
}
