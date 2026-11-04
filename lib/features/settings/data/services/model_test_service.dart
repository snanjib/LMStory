import 'package:dio/dio.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型能力实测结果
class ModelTestResult {
  const ModelTestResult({
    this.visionSupported,
    this.toolUseSupported,
    this.error,
  });

  /// 是否支持视觉（null 表示未测试或测试失败）
  final bool? visionSupported;

  /// 是否支持工具调用
  final bool? toolUseSupported;

  /// 错误信息（基础测试失败时）
  final String? error;

  bool get hasError => error != null;
}

/// 模型能力实测服务
///
/// 对标 ChatBox 的 model-tester.ts。通过发送实际请求探测模型能力：
/// - 基础测试：发 "Hi" 验证模型可用
/// - 视觉测试：发 1x1 像素 PNG 图片，验证 vision
/// - 工具测试：发带 tool 定义的请求，验证 tool_use
class ModelTestService {
  ModelTestService({
    required ApiPresetRepository presetRepo,
    required ApiKeyDatasource apiKeyDatasource,
    required DioClient dioClient,
    required LlmAdapterFactory adapterFactory,
    SettingsRepository? settingsRepository,
  })  : _presetRepo = presetRepo,
        _apiKeyDatasource = apiKeyDatasource,
        _dioClient = dioClient,
        _adapterFactory = adapterFactory,
        _settingsRepository = settingsRepository;

  final ApiPresetRepository _presetRepo;
  final ApiKeyDatasource _apiKeyDatasource;
  final DioClient _dioClient;
  final LlmAdapterFactory _adapterFactory;

  /// 模型实测的用户超时来源（null=构造默认超时）
  final SettingsRepository? _settingsRepository;

  /// 1x1 像素透明 PNG 的 base64
  static const _pixelPngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

  /// 测试模型能力
  Future<ModelTestResult> testModel({
    required String presetId,
    required String modelId,
  }) async {
    final preset = await _presetRepo.getPreset(presetId);
    final apiKey = await _apiKeyDatasource.read(presetId);

    // 1. 基础测试：验证模型可用
    final basicOk = await _sendBasicTest(preset, apiKey, modelId);
    if (!basicOk) {
      // G5 修复：走 slang 而非硬编码中文（多语言即碎点）
      return ModelTestResult(
        error: t.settings.provider.testModelUnavailable,
      );
    }

    // 2. 并发测试 vision 和 tool_use
    final results = await Future.wait([
      _testVision(preset, apiKey, modelId),
      _testToolUse(preset, apiKey, modelId),
    ]);

    return ModelTestResult(
      visionSupported: results[0],
      toolUseSupported: results[1],
    );
  }

  Future<bool> _sendBasicTest(
    ApiPreset preset,
    String? apiKey,
    String modelId,
  ) async {
    try {
      final response = await _postChat(
        preset,
        apiKey,
        modelId,
        messages: [
          {'role': 'user', 'content': 'Hi'},
        ],
        maxTokens: 1,
      );
      return response.isSuccessful;
    } on Exception {
      return false;
    }
  }

  Future<bool> _testVision(
    ApiPreset preset,
    String? apiKey,
    String modelId,
  ) async {
    try {
      final response = await _postChat(
        preset,
        apiKey,
        modelId,
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'What is in this image?'},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/png;base64,$_pixelPngBase64',
                },
              },
            ],
          },
        ],
        maxTokens: 10,
      );
      return response.isSuccessful;
    } on Exception {
      return false;
    }
  }

  Future<bool> _testToolUse(
    ApiPreset preset,
    String? apiKey,
    String modelId,
  ) async {
    try {
      final response = await _postChat(
        preset,
        apiKey,
        modelId,
        messages: [
          {'role': 'user', 'content': "What's the weather?"},
        ],
        maxTokens: 50,
        tools: [
          const ToolDefinition(
            name: 'get_weather',
            description: 'Get weather for a location',
            parameters: {
              'type': 'object',
              'properties': {
                'location': {'type': 'string'},
              },
              'required': ['location'],
            },
          ),
        ],
      );
      return response.isSuccessful;
    } on Exception {
      return false;
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> _postChat(
    ApiPreset preset,
    String? apiKey,
    String modelId, {
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
    List<ToolDefinition>? tools,
  }) async {
    // 通过适配器工厂按 protocol 分发，获取正确的 URL 和 headers
    // 修复：原硬编码 /chat/completions + OpenAI 认证头，导致 Anthropic/Gemini
    // 等非标准协议供应商测试连接失败
    final adapter = _adapterFactory.getAdapter(
      protocol: preset.protocol,
      baseUrl: preset.baseUrl,
      modelId: modelId,
    );
    final url = adapter.buildUrl(preset.baseUrl, modelId, stream: false);

    // 请求体也走 adapter.buildRequestBody——此前 URL/
    // headers 已修但 body 仍手拼 OpenAI 格式，anthropic 的 vision（image_url
    // vs image/source）与 tool（function 包装 vs 顶层 name/input_schema）探测
    // 必 400 误判"不支持"，gemini 的基础测试必失败报"模型不可用"。
    final request = LlmRequest(
      baseUrl: preset.baseUrl,
      modelId: modelId,
      messages: messages,
      apiKey: apiKey,
      maxTokens: maxTokens,
      tools: tools,
      protocol: preset.protocol,
      providerOptions: preset.providerOptions,
    );
    final headers = adapter.buildHeaders(request);
    final body = adapter.buildRequestBody(request, stream: false);
    // 用户 network.* 超时对模型实测生效
    Duration? connectTimeout;
    Duration? receiveTimeout;
    final settings = _settingsRepository;
    if (settings != null) {
      try {
        final network = (await settings.getResolvedConfig()).network;
        connectTimeout = network.connectTimeout;
        receiveTimeout = network.receiveTimeout;
      } on Exception {
        // 解析失败回退 DioClient 构造默认值
      }
    }
    return _dioClient.post<Map<String, dynamic>>(
      url,
      data: body,
      options: Options(headers: headers),
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
    );
  }
}

/// 将测试结果转换为能力列表（用于自动勾选）
List<ModelCapability> capabilitiesFromTestResult(ModelTestResult result) {
  final caps = <ModelCapability>[];
  if (result.visionSupported ?? false) caps.add(ModelCapability.vision);
  if (result.toolUseSupported ?? false) caps.add(ModelCapability.toolUse);
  return caps;
}
