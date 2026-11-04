import 'dart:async';

import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart'
    show LlmAdapterFactory;
import 'package:lmstory/core/network/sse/raw_sse_chunk_parser.dart'
    show RawSseChunkParser;
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart'
    show LlmRemoteDataSource;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart'
    show ApiPreset;

/// LLM 协议适配器抽象接口
///
/// 每种协议（OpenAI 兼容 / Anthropic / Gemini / Responses）实现此接口，
/// 负责构造请求 URL/Header/Body + 解析响应/SSE。运行时由 [LlmAdapterFactory]
/// 按 [ApiPreset.protocol] 字段选择对应适配器实例。
///
/// 设计原则：
/// - 接口仅做"协议转换"职责，不含业务逻辑
/// - 调用方（[LlmRemoteDataSource]）零感知协议差异
/// - SSE 解析分两层：底层 [RawSseChunkParser] 共享切分，协议层独立解析事件格式
///
/// 实现依据：DOC-12 §5.1。
abstract class LlmProtocolAdapter {
  /// 构造完整请求 URL（含路径）
  ///
  /// [baseUrl] 为供应商根 URL（如 `https://api.openai.com`）
  /// [modelId] 用于 Gemini 等需要把模型名拼到路径里的协议
  /// [stream] 区分流式/非流式端点（如 Gemini `:streamGenerateContent`）
  String buildUrl(String baseUrl, String modelId, {required bool stream});

  /// 构造请求头（含认证 + 协议特有 header）
  ///
  /// [request] 提供完整请求上下文：
  /// - `request.apiKey`：认证凭据
  /// - `request.providerOptions['extra_headers']`：协议特有 header
  ///   （如 OpenRouter 的 HTTP-Referer/X-Title）
  /// - `request.providerOptions['anthropic_beta']`：Anthropic beta 特性标识
  ///   （如 `interleaved-thinking-2025-05-14`）
  ///
  /// 适配器自行决定需要注入哪些协议 header（如 Anthropic 始终注入
  /// `anthropic-version: 2023-06-01`），调用方无需感知协议差异。
  ///
  /// [extra] 可选额外头（向后兼容 v0.1 调用方），与 providerOptions
  /// 中的 extra_headers 合并，extra 优先级更高。
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  });

  /// 构造请求体 JSON
  ///
  /// 将统一的 [LlmRequest] 转换为协议特定的请求体结构：
  /// - OpenAI: `{model, messages, stream, ...}`
  /// - Anthropic: `{model, messages, system, max_tokens, ...}`
  /// - Gemini: `{contents, systemInstruction, generationConfig, ...}`
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  });

  /// 解析流式响应为统一事件流
  ///
  /// 输入为原始 SSE 字符串流，输出为 [LlmStreamEvent] 统一事件。
  /// 实现应内部使用 [RawSseChunkParser] 切分事件块，再按协议格式解析。
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream);

  /// 解析非流式响应
  ///
  /// 输入为 HTTP 响应 body 的 JSON Map，输出为统一的 [LlmResponse]。
  LlmResponse parseResponse(Map<String, dynamic> body);

  /// 获取模型列表的端点 URL（用于"获取模型"功能）
  ///
  /// OpenAI 兼容: `{baseUrl}/models`（版本号由 ApiUrlResolver 管理）
  /// Anthropic: `{baseUrl}/models`
  /// Gemini: `{baseUrl}/v1beta/models`
  String buildModelsUrl(String baseUrl);
}
