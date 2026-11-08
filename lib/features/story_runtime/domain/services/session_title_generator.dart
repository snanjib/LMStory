import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 会话标题生成器（新增）
///
/// 根据首轮对话内容（用户消息 + 助手回复）调用 LLM 生成简短标题。
/// 供 Simple / Intermediate 模式在首轮 persist 成功后调用。
///
/// 设计要点：
/// - 使用 [LlmService.chat]（非流式），复用统一 LLM 调用层（不绕过到 http.post）
/// - 提示词要求 4-12 字、不加引号、使用对话相同语言
/// - 失败时返回 null，调用方走 fallback（截取第一条用户消息前 20 字符）
/// - 超时 15 秒，避免阻塞 UI
///
/// 权威设计：DOC-09B §10（配置参数）。
class SessionTitleGenerator {
  SessionTitleGenerator({required LlmService llmService, this.logger})
      : _llmService = llmService;

  final LlmService _llmService;

  /// 标题失败
  /// 此前 catch-all 零日志——9 例复现的「自动命名不回写」在 app.log 无痕
  /// 迹，无法定界。失败补 warn（模型/端点/耗时/异常摘要）。
  final Logger? logger;

  /// 根据 [userMessage] + [assistantReply] 生成简短标题。
  ///
  /// [namingConfig] 提供 baseUrl / apiKey / modelId。
  /// [connectTimeout]/[readTimeout]：——透传用户配置的超时
  /// （network.*），此前标题/建议回复等后台调用一律吃数据源默认值。
  /// 返回生成的标题；失败时返回 null（调用方走 fallback）。
  Future<String?> generate({
    required String userMessage,
    required String assistantReply,
    required NamingConfig namingConfig,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) async {
    // 截取前 200 字符，避免请求体过大
    final userTruncated = userMessage.length > 200
        ? '${userMessage.substring(0, 200)}...'
        : userMessage;
    final replyTruncated = assistantReply.length > 200
        ? '${assistantReply.substring(0, 200)}...'
        : assistantReply;

    final conversationText =
        '用户: $userTruncated\n---------\n助手: $replyTruncated';

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: [
        {
          'role': 'system',
          'content': '根据以下对话内容，为这个会话生成一个简短的标题。'
              '要求：4-12个字，不要加引号，直接输出标题文本，不要任何额外说明。'
              '使用与对话相同的语言。',
        },
        {'role': 'user', 'content': conversationText},
      ],
      temperature: resolveAuxiliaryTemperature(
        modelId: namingConfig.modelId,
        configuredTemperature: namingConfig.auxiliaryTemperature,
        providerOptions: namingConfig.providerOptions,
        baseUrl: namingConfig.baseUrl,
      ),
      // 50→256——部分端点对 disabled 不发思考参数（方言路由），
      // 思考模型默认开思考时 50 token 全烧在 reasoning 上，content 为空
      // → 永远走兜底命名。maxTokens 是上限非消耗，非思考模型不受影响。
      maxTokens: 256,
      stream: false,
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      // 2026-07-28 修复：标题生成只需 4-12 字，不需要思考，显式禁用避免浪费 token
      reasoningEffort: ReasoningEffort.disabled,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      purpose: LlmPurposes.sessionTitle,
    );

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _llmService.chat(request).timeout(
            const Duration(seconds: 15),
          );

      var title = response.content.trim();

      // 清理标题：去除引号、换行、Markdown 粗体标记
      title = title
          .replaceAll(RegExp(r'["""\u201C\u201D]'), '')
          .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
          .replaceAll(RegExp(r'[\n\r]'), ' ')
          .trim();

      if (title.isEmpty) return null;

      // 限制标题长度（最多 30 字符）
      if (title.length > 30) {
        title = '${title.substring(0, 30)}...';
      }

      return title;
    } catch (e) {
      // LLM 调用失败（网络/超时/HTTP 错误等）→ 返回 null，调用方走 fallback
      final errorText = e.toString();
      logger?.warn(
        'Session title generation failed',
        detail: 'model=${namingConfig.modelId}, '
            'endpoint=${namingConfig.baseUrl}, '
            'elapsed=${stopwatch.elapsedMilliseconds}ms, '
            'error=${errorText.length > 200 ? errorText.substring(0, 200) : errorText}',
      );
      return null;
    }
  }

  /// Fallback：截取第一条用户消息前 20 字符作为标题。
  ///
  /// 当 [generate] 返回 null 或失败时使用。
  /// [defaultTitle] 为全空时的兜底名（由 UI/控制器层传入 i18n 资源，
  /// 域层不直接依赖 slang，必须显式传入避免空标题）。
  static String fallbackTitle(
    String userMessage, {
    required String defaultTitle,
  }) {
    var title =
        userMessage.length > 20 ? userMessage.substring(0, 20) : userMessage;
    title = title.replaceAll(RegExp(r'[\n\r]'), ' ').trim();
    return title.isEmpty ? defaultTitle : title;
  }
}
