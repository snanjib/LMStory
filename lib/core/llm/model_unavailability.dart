// 模型不可用错误识别（chat 与故事侧共享口径）
//
// 各家网关在模型下线/无可用通道时返回 400 + 文案（实测 AG 返回
// "Upstream request failed: Model is unavailable"），与上下文超限同构——
// 状态码判不出，须匹配响应文本。此类错误网络正常：归 network 会误导用户
// 排查 Wi-Fi；归 server（等待重试/更换模型）才符合实际。
// 故事失败分类器与 chat 失败分类器共用本口径，勿在任一侧另造第二套模式
// （先例：context_overflow.dart）。

/// 模型不可用文案特征（网关 400 响应实测）
bool isModelUnavailableText(String text) {
  final lower = text.toLowerCase();
  return lower.contains('model is unavailable') ||
      lower.contains('model_not_found') ||
      lower.contains('no allowed providers') ||
      lower.contains('no endpoints found');
}
