import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 世界观规则生成器（一次性 LLM 调用，仿 SessionTitleGenerator 先例）。
///
/// 单次非流式调用 + 外层超时帽 + 失败/空内容返回 null（调用方走
/// 同选项本地拼装兜底，链）；不搬回合层 RetryPolicy/预算闸。
///
/// 提示词文本由 UI 层从 slang 装配注入（域层零 slang 依赖）。
class WorldPromptGenerator {
  WorldPromptGenerator({required LlmService llmService, this.logger})
      : _llmService = llmService;

  final LlmService _llmService;

  /// 失败补 warn（模型/端点/耗时/异常摘要），排障有痕。
  final Logger? logger;

  /// 外层超时帽（默认 90s；测试可注入短值）。
  static const defaultOuterTimeout = Duration(seconds: 90);

  /// readTimeout 地板：生成几百字的世界设定需要比默认读超时更宽
  /// （启动决策轮口径：connect 用解析值、read 取 max(解析, 60s)）。
  static const _readTimeoutFloor = Duration(seconds: 60);

  /// 按问卷生成世界设定正文。
  ///
  /// 返回 trim 后的正文；失败/超时/空内容返回 null（调用方兜底拼装）。
  Future<String?> generate({
    required NamingConfig namingConfig,
    required String systemPrompt,
    required String userPrompt,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? outerTimeout,
  }) async {
    final effectiveRead = readTimeout != null && readTimeout < _readTimeoutFloor
        ? _readTimeoutFloor
        : readTimeout;

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      // 世界设定是创作型任务，稍高的温度利于多样性
      temperature: 0.8,
      // 700 字中文正文的输出预算（token 上限非消耗）
      maxTokens: 2048,
      stream: false,
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      // 生成不需要思考，显式禁用避免浪费 token（对齐标题先例）
      reasoningEffort: ReasoningEffort.disabled,
      connectTimeout: connectTimeout,
      readTimeout: effectiveRead,
    );

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _llmService
          .chat(request)
          .timeout(outerTimeout ?? defaultOuterTimeout);
      final content = response.content.trim();
      if (content.isEmpty) return null;
      return content;
    } catch (e) {
      final errorText = e.toString();
      logger?.warn(
        'World prompt generation failed',
        detail: 'model=${namingConfig.modelId}, '
            'endpoint=${namingConfig.baseUrl}, '
            'elapsed=${stopwatch.elapsedMilliseconds}ms, '
            'error=${errorText.length > 200 ? errorText.substring(0, 200) : errorText}',
      );
      return null;
    }
  }
}
