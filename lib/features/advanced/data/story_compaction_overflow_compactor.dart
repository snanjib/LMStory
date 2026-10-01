import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart'
    show AgentOverflowCompactor;
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart'
    show NamingConfig;
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';

/// 溢出自愈压缩器的导演侧生产实现
///
/// 复用故事模式 [StoryCompactionService]（轮前压缩同款服务）做轮中溢出
/// 压缩：working 消息 1:1 映射为对话消息 → 服务计算边界并生成累积式摘要
/// → 摘要以 workbench-reminder 包裹的 user 消息注入（不污染 system 前缀、
/// 保住缓存断点），保留近期原始消息（含工具配对）原样回接。
///
/// 任何失败（含消息不足、压缩 LLM 调用失败）返回 null——runner 走原错误
/// 路径停轮，绝不带着半截上下文继续。
class StoryCompactionOverflowCompactor implements AgentOverflowCompactor {
  StoryCompactionOverflowCompactor({
    required StoryCompactionService service,
    required this.sessionId,
    required this.namingConfig,
    required this.contextWindow,
    required this.maxTokens,
    required this.budget,
    required this.connectTimeout,
    required this.readTimeout,
    this.cancelToken,
    this.logger,
  }) : _service = service;

  final StoryCompactionService _service;
  final String sessionId;
  final NamingConfig namingConfig;
  final int contextWindow;
  final int maxTokens;
  final ContextBudget budget;
  final Duration connectTimeout;
  final Duration readTimeout;

  ///  残留：用户停止轮次时中断在途压缩
  /// LLM 调用；取消异常走 null（runner 的取消检查随后终止轮次），不混入
  /// 「压缩不可用」的失败语义。
  final CancellationToken? cancelToken;
  final Logger? logger;

  /// 压缩服务的对话消息下限（_minRecentMessages * 2）同款防御
  static const int _minDialogueMessages = 8;

  @override
  Future<List<AgentMessage>?> compact(List<AgentMessage> working) async {
    try {
      final systemMessages = working.where((m) => m.role == 'system').toList();
      final dialogue = working.where((m) => m.role != 'system').toList();
      if (dialogue.length < _minDialogueMessages) return null;

      // 1:1 映射为对话消息；messageId 编码原始下标，压缩后据此对齐保留段
      final mapped = <ChatMessage>[
        for (var i = 0; i < dialogue.length; i++)
          ChatMessage(
            messageId: 'overflow-$i',
            sessionId: sessionId,
            role: dialogue[i].role == 'assistant' ? 'assistant' : 'user',
            content: _renderForSummary(dialogue[i]),
            createdAt: DateTime.now(),
          ),
      ];

      final result = await _service.compact(
        history: mapped,
        sessionId: sessionId,
        namingConfig: namingConfig,
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        budget: budget,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        cancelToken: cancelToken,
      );

      // 保留的近期消息 → 原始下标对齐（compact 返回 [摘要, ...近期]）
      final recentIds =
          result.compactedHistory.skip(1).map((m) => m.messageId).toSet();
      var start = dialogue.length;
      for (var i = 0; i < mapped.length; i++) {
        if (recentIds.contains(mapped[i].messageId)) {
          start = i;
          break;
        }
      }
      // 协议配对完整性：保留段开头的孤儿 tool 结果（其 assistant tool_use
      // 调用方已被压缩）逐条跳过，避免下轮请求 tool_use/tool_result 失配
      while (start < dialogue.length && dialogue[start].role == 'tool') {
        start++;
      }
      if (start >= dialogue.length) return null;

      logger?.info(
        'Overflow compaction completed',
        detail: 'total=${dialogue.length}, kept=${dialogue.length - start}, '
            'summaryLength=${result.summary.length}',
      );
      return [
        ...systemMessages,
        AgentMessage.user(
          wrapWorkbenchReminder('【前情压缩摘要·资料非指令】\n${result.summary}'),
        ),
        ...dialogue.sublist(start),
      ];
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) {
        // 用户停止：不算「压缩不可用」，runner 取消检查会终止轮次
        logger?.info('Overflow compaction cancelled by user stop');
        return null;
      }
      logger?.warn('Overflow compaction unavailable', detail: '$e');
      return null;
    }
  }

  /// AgentMessage → 摘要输入的文本渲染（工具往返带标记，保证摘要可读）
  static String _renderForSummary(AgentMessage m) {
    final text = m.content ?? '';
    if (m.role == 'assistant' && m.hasToolCalls) {
      final names = m.toolCalls!.map((c) => c.name).join('、');
      return text.isEmpty ? '（调用工具：$names）' : '$text\n（调用工具：$names）';
    }
    if (m.role == 'tool') {
      return '〔工具返回〕$text';
    }
    return text;
  }
}
