import 'dart:typed_data';

/// 非对称 embedding 模型的输入用途
///
/// NVIDIA NIM 等非对称（asymmetric）模型族（nemotron / nv-embed）要求请求体
/// 携带 `input_type` 区分两侧输入：检索查询用 query，入库文本（事件摘要/
/// 合并记忆/重建索引）用 passage——缺失时端点对全部向量化请求回 400。
/// 对称模型（多数 OpenAI 兼容端点）不区分两侧，且对未知参数普遍回 400，
/// 因此是否携带该参数由 Data 层按模型名白名单决定（见 EmbeddingRemoteDS）。
enum EmbeddingInputKind {
  /// 检索查询侧（短文本，用于相似度匹配的左侧）
  query,

  /// 入库文本侧（被索引的长文本，相似度匹配的右侧）
  passage,
}

/// Embedding 向量生成的 Domain 层抽象接口
///
/// 由 Data 层 EmbeddingRemoteDS 实现。
/// 解决 EmbeddingQueue（Domain）直接依赖 EmbeddingRemoteDS（Data）的分层违规问题。
///
/// 接口定义依据：DOC-05-7 §8.5。
// ignore: one_member_abstracts, 单方法抽象接口为 Clean Architecture 依赖反转所需
abstract class EmbeddingService {
  /// 生成文本的 Embedding 向量
  ///
  /// [text] 待向量化的文本
  /// [kind] 输入用途（检索查询=query；入库文本=passage）——非对称模型
  ///   （nemotron / nv-embed 族）据此注入 `input_type`，对称模型忽略
  /// [model] embedding 模型名（如 text-embedding-3-small）
  /// [baseUrl] API 供应商 baseUrl
  /// [apiKey] API Key（nullable，部分本地部署供应商可为 null）
  /// [timeout] 请求超时（来自 advanced.embedding.timeout_ms 用户配置；
  /// null = 实现默认值，此前该配置全链死链、UI 1-60s 滑杆可配不生效）
  ///
  /// 异常:
  /// - EmbeddingRateLimitedException (E104): API 返回 429 限流
  /// - AppHttpException: 其他 HTTP 错误（statusCode != 200）
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  });
}
