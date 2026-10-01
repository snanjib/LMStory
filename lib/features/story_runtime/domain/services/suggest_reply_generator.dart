import 'dart:convert';

import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 推荐回复生成器（2026-07-29 新增）
///
/// 根据当前剧情上下文，调用 LLM 生成 3 条候选用户回复。
/// 供故事模式输入框"推荐回复"按钮使用。
///
/// **省 token 设计**：
/// - 单次非流式调用（`LlmService.chat`），禁用 reasoning
/// - 上下文：最近 1 轮全文（用户消息 + 最终回复）+ 前 2 轮 micro 摘要
/// - 输出：JSON 格式 `{"replies": ["...", "...", "..."]}`
/// - maxTokens=600，超时 20 秒
/// - 预估：约 500~800 token/次
///
/// 失败时返回空列表，调用方应提示用户"生成失败"。
class SuggestReplyGenerator {
  SuggestReplyGenerator({
    required LlmService llmService,
    required Logger logger,
  })  : _llmService = llmService,
        _logger = logger;

  final LlmService _llmService;
  final Logger _logger;

  /// 生成候选回复列表
  ///
  /// 参数：
  /// - [namingConfig]：模型连接配置（baseUrl/apiKey/modelId/protocol）
  /// - [systemPrompt]：系统提示词（已解析优先级链后的最终值）
  /// - [lastUserMessage]：最近一轮用户的原始消息
  /// - [lastAssistantReply]：最近一轮的回复
  /// - [prevSummaries]：前几轮的 micro 摘要列表（按时间顺序）
  /// - [temperature]：生成温度（默认 0.8）
  /// - [maxTokens]：最大 token 数（默认 600）
  /// - [candidateCount]：候选数量（默认 3）
  /// - [maxReplyLength]：单条回复最大字数（默认 150）
  ///
  /// 返回候选回复列表；失败时返回空列表。
  Future<List<String>> generate({
    required NamingConfig namingConfig,
    required String systemPrompt,
    required String lastUserMessage,
    required String lastAssistantReply,
    required List<String> prevSummaries,
    double temperature = 0.8,
    int maxTokens = 600,
    int candidateCount = 3,
    int maxReplyLength = 150,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) async {
    // 拼装用户消息（上下文）
    final prevSummariesText = prevSummaries.isEmpty
        ? '（无前序摘要）'
        : prevSummaries.asMap().entries.map((entry) {
            return '${entry.key + 1}. ${entry.value}';
          }).join('\n');

    final userContent = kSuggestReplyUserTemplate
        .replaceAll('{last_user}', lastUserMessage)
        .replaceAll('{last_reply}', lastAssistantReply)
        .replaceAll('{prev_summaries}', prevSummariesText)
        .replaceAll('{candidate_count}', candidateCount.toString())
        .replaceAll('{max_reply_length}', maxReplyLength.toString());

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userContent},
      ],
      temperature: temperature,
      maxTokens: maxTokens,
      modelMaxOutputTokens: namingConfig.maxOutputTokens,
      stream: false,
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      // 推荐回复不需要思考链，禁用 reasoning 省 token
      reasoningEffort: ReasoningEffort.disabled,
      // 强制 JSON 输出（如果模型支持）
      responseFormat: const LlmResponseFormatJsonObject(),
      // 用户 network.* 超时透传（照抄标题生成先例）
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );

    try {
      // 外层总帽 = max(20s 兜底, 用户读超时)：用户配置更长时不被截死
      final overallCap = Duration(
        milliseconds: readTimeout != null && readTimeout.inMilliseconds > 20000
            ? readTimeout.inMilliseconds
            : 20000,
      );
      final response = await _llmService.chat(request).timeout(overallCap);

      return _parseReplies(response.content, candidateCount);
    } catch (e) {
      _logger.warn(
        'SuggestReply: 生成候选回复失败',
        detail: '$e',
      );
      return [];
    }
  }

  /// 解析 LLM 返回的 JSON，提取候选回复列表
  ///
  /// 预期格式：`{"replies": ["回复1", "回复2", "回复3"]}`
  /// 容错处理：
  /// - JSON 解析失败 → 尝试提取文本中的 JSON 片段
  /// - replies 字段缺失或非数组 → 返回空列表
  /// - 数组元素非字符串 → 跳过
  /// - 超过 candidateCount → 截断
  /// - 不足 candidateCount → 返回实际解析到的数量
  List<String> _parseReplies(String content, int candidateCount) {
    final cleaned = _extractJson(content);
    if (cleaned == null) {
      _logger.warn(
        'SuggestReply: 无法从响应中提取 JSON',
        detail:
            'content: ${content.length > 200 ? '${content.substring(0, 200)}...' : content}',
      );
      return [];
    }

    try {
      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
      final repliesRaw = decoded['replies'];
      if (repliesRaw is! List) {
        _logger.warn('SuggestReply: replies 字段非数组');
        return [];
      }

      final replies = repliesRaw
          .whereType<String>()
          .map((r) => r.trim())
          .where((r) => r.isNotEmpty)
          .take(candidateCount)
          .toList();

      _logger.info(
        'SuggestReply: 成功解析 ${replies.length} 条候选回复',
      );
      return replies;
    } catch (e) {
      _logger.warn(
        'SuggestReply: JSON 解析失败',
        detail: '$e',
      );
      return [];
    }
  }

  /// 从 LLM 响应中提取 JSON 字符串
  ///
  /// 处理以下情况：
  /// 1. 响应直接是合法 JSON
  /// 2. 响应被 markdown 代码块包裹（```json ... ```）
  /// 3. 响应前后有多余文字
  String? _extractJson(String content) {
    final trimmed = content.trim();

    // 1. 直接尝试解析
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed;
    }

    // 2. 尝试提取 markdown 代码块中的 JSON
    final codeBlockMatch = RegExp(
      r'```(?:json)?\s*(\{[\s\S]*?\})\s*```',
    ).firstMatch(trimmed);
    if (codeBlockMatch != null) {
      return codeBlockMatch.group(1);
    }

    // 3. 尝试提取第一个 { ... } 块
    final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
    if (jsonMatch != null) {
      return jsonMatch.group(0);
    }

    return null;
  }
}
