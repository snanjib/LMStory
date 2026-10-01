/// token 数通用格式化（全仓唯一入口）。
///
/// 口径：
/// <1 万原样、≥1 万缩写 k、≥100 万缩写 M，小数去尾零（10.8 万 → 108k、
/// 1.0M → 1M）；tokens 单位由调用方/i18n 模板拼接，本函数只产数字部分。
///
/// 历史上圆环/详情面板、供应商模型 chips、上下文预算滑块各持一份实现
///（大小写、缩写阈值、尾零行为互不一致），2026-09-06 收敛至此。
library;

/// 格式化 token 数为紧凑人读文本。
String formatTokenCount(int tokens) {
  if (tokens >= 1000000) return _scale(tokens, 1000000, 'M');
  if (tokens >= 10000) return _scale(tokens, 1000, 'k');
  return tokens.toString();
}

String _scale(int tokens, int unit, String suffix) {
  final value = tokens / unit;
  final text = value >= 100
      ? value.round().toString()
      : _trimTrailingZero(value.toStringAsFixed(1));
  return '$text$suffix';
}

String _trimTrailingZero(String text) =>
    text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
