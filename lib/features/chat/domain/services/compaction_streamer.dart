import 'dart:async';

import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart'
    show CompactionService;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 摘要生成所需的 API 配置
///
/// 从 [CompactionService.resolveSummaryConfig] 解析得到，传给
/// [CompactionStreamer.stream] 发起流式摘要请求。
class SummaryConfig {
  const SummaryConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
    this.protocol = LlmProtocol.openaiCompatible,
    this.providerOptions,
    this.auxiliaryTemperature = 0.3,
  });

  final String baseUrl;
  final String apiKey;
  final String modelId;

  /// LLM 协议（从 preset 透传——此前压缩请求手拼 OpenAI 格式，
  /// anthropic/gemini 供应商的对话压缩必失败）
  final LlmProtocol protocol;

  /// 协议特有参数（同 ApiPreset.providerOptions 透传）
  final Map<String, dynamic>? providerOptions;

  /// 辅助调用统一温度（common.auxiliary.temperature，缺省 0.3）
  final double auxiliaryTemperature;
}

/// 流式摘要增量回调
///
/// 回调内通常执行 DB 更新（updateMessageContent），故为 async。
/// streamer 会 `await` 每次回调，保证 DB 写入顺序与 LLM 输出顺序一致。
typedef OnCompactionDelta = Future<void> Function(String delta);

/// 流式摘要完成回调
///
/// [fullSummary] 为完整摘要文本，[tokensUsed] 来自流式响应末尾的
/// usage.total_tokens（请求 includeUsage=true）。null 表示未携带 usage。
typedef OnCompactionComplete = Future<void> Function(
  String fullSummary,
  int? tokensUsed,
);

/// 流式摘要失败回调
typedef OnCompactionError = Future<void> Function(Object error);

/// 压缩摘要提示词（对标 ChatBox summarizeConversation，prompts.ts:147-155）
///
/// 聚焦"继续对话所需的关键信息"，而非复述对话内容。
const String kCompactionSummaryPrompt =
    'Provide a detailed summary for continuing this conversation. '
    'Focus on information that would be helpful for continuing, '
    'including:\n'
    '- What we discussed and why it matters\n'
    '- Key decisions made\n'
    "- What we're working on\n"
    "- What we're going to do next\n\n"
    'The new session will not have access to our conversation '
    'history. Write in the same language as the conversation. '
    'Be concise but complete. Do NOT include prefaces or '
    'meta-commentary.';

/// 流式压缩摘要生成器
///
/// 纯 LLM 交互层，不碰数据库。改走统一
/// [LlmService.streamChat]（协议适配器构造请求体），不再手拼 OpenAI
/// 格式直发 http——anthropic/gemini 供应商由此获得与主链路一致的压缩能力。
///
/// 上层（通常是 [CompactionService.compactWithStream]）负责：
/// - 解析 [SummaryConfig]
/// - 创建占位摘要消息
/// - 在回调中更新消息内容/tokensUsed/error
/// - 成功后创建 CompactionPoint
class CompactionStreamer {
  CompactionStreamer({
    required LlmService llmService,
    Logger? logger,
  })  : _llmService = llmService,
        _logger = logger ?? const Logger('CompactionStreamer');

  final LlmService _llmService;
  final Logger _logger;

  /// 发起流式摘要请求
  ///
  /// [messages] 为待摘要的对话消息（含旧摘要，对标 ChatBox）。
  /// 成功调 [onComplete]，失败调 [onError]。请求设置 includeUsage=true
  /// 确保流末尾携带 usage。
  ///
  /// [cancelToken] 非空且被取消时静默中止——不发
  /// [onComplete] 也不发 [onError]（取消既非成功也非失败，占位摘要由
  /// controller 收尾清理）；每事件与流收尾处各查一次，双检防完成竞态。
  ///
  /// 注意：本方法不负责创建消息或 CompactionPoint，纯 LLM 交互。
  Future<void> stream({
    required SummaryConfig config,
    required List<ChatMessage> messages,
    required OnCompactionDelta onTextDelta,
    required OnCompactionComplete onComplete,
    required OnCompactionError onError,
    Duration readTimeout = const Duration(seconds: 90),
    CancellationToken? cancelToken,
  }) async {
    if (messages.isEmpty) {
      await onComplete('', null);
      return;
    }

    final request = LlmRequest(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      modelId: config.modelId,
      messages: [
        ...messages.map(
          (m) => {
            'role': m.role,
            'content': m.content ?? '',
          },
        ),
        {
          'role': 'user',
          'content': kCompactionSummaryPrompt,
        },
      ],
      temperature: resolveAuxiliaryTemperature(
        modelId: config.modelId,
        configuredTemperature: config.auxiliaryTemperature,
        providerOptions: config.providerOptions,
        baseUrl: config.baseUrl,
      ),
      includeUsage: true,
      protocol: config.protocol,
      providerOptions: config.providerOptions,
      readTimeout: readTimeout,
      cancelToken: cancelToken,
    );

    final buffer = StringBuffer();
    var streamEnded = false;
    var errorReported = false;
    var cancelled = false;
    int? tokensUsed;

    try {
      // 用 await for 保证事件顺序处理，每个回调 await 完成后再处理下一个事件
      // 避免 DB 写入乱序（onTextDelta 的 content 更新必须按 LLM 输出顺序落库）
      await for (final event in _llmService.streamChat(request)) {
        // 取消检查点①——每事件处（计划 §4 风险4 双检）
        if (cancelToken?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        switch (event) {
          case LlmTextDelta(:final content):
            buffer.write(content);
            await onTextDelta(content);
          case LlmStreamDone(:final usage):
            streamEnded = true;
            tokensUsed = usage?.totalTokens;
          case LlmStreamError(:final message):
            _logger.warn('Compaction stream error', detail: message);
            if (!errorReported) {
              errorReported = true;
              await onError(CompactionStreamException(message));
            }
          case LlmThinkingDelta():
          case LlmThinkingBlockComplete():
          case LlmContentBlockComplete():
            // 摘要生成忽略思考/有序内容块
            break;
          case LlmToolCallStart():
          case LlmToolCallArgs():
          case LlmToolCallComplete():
            // 摘要生成不应出现 tool_calls，忽略
            break;
        }
      }

      // 取消检查点②——流收尾后、onComplete 落库前最后确认
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
      }
      if (cancelled) {
        _logger.info('Compaction stream cancelled by user');
        return;
      }

      // 流正常结束，且未报错 → 调 onComplete
      if (!errorReported) {
        if (streamEnded || buffer.isNotEmpty) {
          await onComplete(buffer.toString(), tokensUsed);
        } else {
          await onError(const CompactionStreamException('压缩服务返回空响应'));
        }
      }
    } on TimeoutException {
      _logger.warn('Compaction stream timed out');
      if (!errorReported) {
        await onError(const CompactionStreamException('压缩请求超时，请稍后重试'));
      }
    } catch (e) {
      _logger.error('Compaction stream failed', detail: '$e');
      if (!errorReported) {
        await onError(
          const CompactionStreamException('压缩请求失败，请检查网络连接'),
        );
      }
    }
  }
}

/// 流式压缩异常
///
/// 携带可向用户展示的中文错误信息。
class CompactionStreamException implements Exception {
  const CompactionStreamException(this.message);

  final String message;

  @override
  String toString() => message;
}
