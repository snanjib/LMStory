import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/network/request_scope.dart';
import 'package:lmstory/core/network/transport_client_native.dart'
    if (dart.library.html) 'package:lmstory/core/network/transport_client_web.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// LLM API 数据源（Data 层实现）
///
/// 实现 [LlmService] Domain 层抽象接口，通过 [LlmAdapterFactory] 按协议类型
/// 分发到对应的适配器（OpenAI/Anthropic/Gemini/Responses），自身不再感知协议差异。
///
/// - 流式（[streamChat]）：调 [HttpClient.streamPost] → adapter.parseStream
///   → 映射为 [LlmStreamEvent]
/// - 非流式（[chat]）：用 `package:http` 直接 POST，adapter.parseResponse 解析
///
/// 实现依据：DOC-05-8 §9.x + DOC-12 §5.3。
class LlmRemoteDataSource implements LlmService {
  LlmRemoteDataSource({
    required HttpClient httpClient,
    required LlmAdapterFactory adapterFactory,
    Logger? logger,
    http.Client? chatClient,
  })  : _httpClient = httpClient,
        _adapterFactory = adapterFactory,
        _logger = logger,
        _chatClient = chatClient;

  final HttpClient _httpClient;
  final LlmAdapterFactory _adapterFactory;
  final Logger? _logger;

  /// 非流式 chat 的 HTTP 客户端（测试注入点）
  ///
  /// null 时每次请求新建 `http.Client()`；测试注入 [http.Client] mock
  /// 以验证取消令牌与超时行为。
  final http.Client? _chatClient;

  /// 记录请求体中的思考相关字段，便于排查"禁用思考不生效"等问题。
  void _logThinkingParams(String body, String modelId) {
    if (_logger == null) return;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final thinkingKeys = [
        'reasoning_effort',
        'thinking',
        'enable_thinking',
        'thinking_budget',
        'chat_template_kwargs',
        'reasoning',
      ];
      final params = <String, dynamic>{};
      for (final key in thinkingKeys) {
        if (json.containsKey(key)) {
          params[key] = json[key];
        }
      }
      _logger.info(
        'LLM request thinking params',
        detail: 'model=$modelId, params=${jsonEncode(params)}',
      );
    } catch (_) {
      // 日志失败不影响正常流程
    }
  }

  /// 记录采样参数被省略的请求，便于确认严格中转站兼容策略是否生效。
  ///
  /// 只在实际发生省略时输出：请求本来要带 temperature/topP，但供应商开关
  /// 或模型能力判定要求省略；普通请求零新增日志。
  void _logSamplingOmission(LlmRequest request) {
    final logger = _logger;
    if (logger == null) return;
    if (request.temperature == null && request.topP == null) return;
    if (!shouldOmitSamplingParams(
      modelId: request.modelId,
      providerOptions: request.providerOptions,
      baseUrl: request.baseUrl,
    )) {
      return;
    }
    logger.info(
      'LLM request sampling params omitted',
      detail: 'model=${request.modelId}',
    );
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) async* {
    final adapter = _adapterFactory.getAdapter(
      protocol: request.protocol,
      baseUrl: request.baseUrl,
      modelId: request.modelId,
    );
    final url = adapter.buildUrl(
      request.baseUrl,
      request.modelId,
      stream: true,
    );
    final headers = adapter.buildHeaders(request);
    final body = jsonEncode(adapter.buildRequestBody(request, stream: true));
    _logThinkingParams(body, request.modelId);
    _logSamplingOmission(request);

    final rawStream = _httpClient.streamPost(
      url,
      headers,
      body: body,
      cancelToken: request.cancelToken,
      connectTimeout: request.connectTimeout,
      readTimeout: request.readTimeout,
      responseStartTimeout: request.responseStartTimeout,
    );

    yield* adapter.parseStream(rawStream);
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    final adapter = _adapterFactory.getAdapter(
      protocol: request.protocol,
      baseUrl: request.baseUrl,
      modelId: request.modelId,
    );
    final url = adapter.buildUrl(
      request.baseUrl,
      request.modelId,
      stream: false,
    );
    final headers = adapter.buildHeaders(request);
    final body = jsonEncode(adapter.buildRequestBody(request, stream: false));
    _logThinkingParams(body, request.modelId);
    _logSamplingOmission(request);

    // 请求前检查取消信号（与 stream_post_native 同款样板）——
    // 会话被删除/用户取消后，标题生成、建议回复等非流式调用不再占用连接。
    if (request.cancelToken?.isCancelled ?? false) {
      throw const CancelledException(
        'Chat request was cancelled before sending',
      );
    }

    // 超时拆 connect/read 两段，与流式路径对齐（连接默认 15s）
    final connectTimeout =
        request.connectTimeout ?? const Duration(seconds: 15);
    final readTimeout = request.readTimeout ?? const Duration(seconds: 60);

    final scope = RequestScope(
      uri: Uri.parse(url),
      cancelToken: request.cancelToken,
      responseStartTimeout: request.responseStartTimeout,
      totalTimeout: request.nonStreamingTimeout,
    );
    final httpRequest = http.AbortableRequest(
      'POST',
      Uri.parse(url),
      abortTrigger: scope.abortTrigger,
    )
      ..headers.addAll(headers)
      ..body = body;
    final client = _chatClient ?? transportClient(connectTimeout);
    final http.Response response;
    try {
      var sending = client.send(httpRequest);
      if (request.responseStartTimeout == null &&
          request.nonStreamingTimeout == null) {
        sending = sending.timeout(
          connectTimeout,
          onTimeout: () {
            final error = AppHttpException(
              'Chat connection timed out after ${connectTimeout.inSeconds}s',
              code: 'connection_timeout',
              uri: Uri.parse(url),
            );
            scope.fail(error);
            throw error;
          },
        );
      }
      final streamed = await scope.wait(sending);
      final reading = http.Response.fromStream(
        http.StreamedResponse(
          scope.body(streamed),
          streamed.statusCode,
          headers: streamed.headers,
          request: streamed.request,
        ),
      );
      response = await scope.wait(
        request.nonStreamingTimeout == null
            ? reading.timeout(
                readTimeout,
                onTimeout: () {
                  final error = AppHttpException(
                    'Chat request timed out after ${readTimeout.inSeconds}s',
                    code: 'receive_timeout',
                    uri: Uri.parse(url),
                  );
                  scope.fail(error);
                  throw error;
                },
              )
            : reading,
      );
      scope.check();
    } finally {
      scope.dispose();
    }

    if (response.statusCode != 200) {
      throw AppHttpException(
        'Chat request failed with status ${response.statusCode}',
        statusCode: response.statusCode,
        uri: Uri.parse(url),
        responseBody: response.body,
        // 拾取 Retry-After 子集，限流冷却贯穿重试链路
        headers: HttpErrorHeaders.fromMap(response.headers),
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return adapter.parseResponse(json);
  }
}
