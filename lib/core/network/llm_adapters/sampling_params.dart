/// 采样参数出网前的统一清洗。
///
/// 设置界面的滑块按「min + 段长 × 档位」离散化取值，双精度段长乘法会留下
/// 浮点尾差（如拖到 0.57 实际写入 0.5700000000000001）；数字输入框也允许
/// 手输任意位数小数。这类值持久化后原样进入请求体，部分厂商校验小数位数
/// 并直接 400（如「top_p参数非法：限制小数点[2]位」）。
///
/// 各设置界面均按 0.01 步进展示与存储语义，出网前统一取整到 2 位小数
/// 不损失有效精度。
library;

/// 将采样参数取整到 2 位小数；null 原样返回，负零归一为 0.0。
double? sanitizeSamplingParam(double? value) {
  if (value == null) return null;
  final rounded = (value * 100).roundToDouble() / 100;
  return rounded == 0 ? 0.0 : rounded;
}
