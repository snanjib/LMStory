import 'dart:convert';

import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';

/// 合并后的记忆条目（新增）
///
/// 由 [MemoryConsolidator] 调用 LLM 合并多条低重要性事件摘要后产出。
/// 调用方（Controller）负责为其分配 turnNumber、生成 embedding，并交由
/// 持久化服务写入 experiential_memories + memories_fts。
class ConsolidatedMemory {
  const ConsolidatedMemory({
    required this.summary,
    required this.tags,
    required this.importance,
  });

  /// 合并后的剧情节点描述（"主语+动作+对象+后果"式）
  final String summary;

  /// 合并后的标签（1-3 个）
  final List<String> tags;

  /// 合并后的重要性（通常 3-5，达到存储门槛后建索引）
  final int importance;
}

/// 按需批量记忆提炼服务（新增）
///
/// 将若干条低重要性（未建 FTS5 索引）的事件摘要交由 LLM 合并为高重要性
/// 剧情节点记忆，避免大模型在相近轮次重复提取相似事件。
///
/// 设计要点：
/// - 使用 [LlmService.chat]（非流式），复用统一 LLM 调用层
/// - 输出 JSON `{"consolidated":[{summary,tags,importance}]}`，可为空数组
/// - 失败时返回空列表（调用方走 warn 日志，不阻塞主流程）
/// - 超时 30 秒（合并任务比标题生成重，给更长时间）
///
/// 权威设计：DOC-09A §4（批量提炼流程）、DOC-09B §10（配置参数）。
class MemoryConsolidator {
  MemoryConsolidator({required LlmService llmService})
      : _llmService = llmService;

  final LlmService _llmService;

  /// 合并 [memories] 为高重要性记忆列表。
  ///
  /// [namingConfig] 提供 baseUrl / apiKey / modelId。
  /// [consolidationPrompt] 为系统提示词（取自 PromptsConfig.consolidationPrompt）。
  ///
  /// 返回合并后的记忆列表；LLM 失败/超时/JSON 解析失败 → 返回空列表。
  Future<List<ConsolidatedMemory>> consolidate({
    required List<ExperientialMemory> memories,
    required NamingConfig namingConfig,
    required String consolidationPrompt,
  }) async {
    if (memories.isEmpty) return const [];

    final userContent = _buildUserContent(memories);
    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: [
        {'role': 'system', 'content': consolidationPrompt},
        {'role': 'user', 'content': userContent},
      ],
      temperature: resolveAuxiliaryTemperature(
        modelId: namingConfig.modelId,
        configuredTemperature: namingConfig.auxiliaryTemperature,
        providerOptions: namingConfig.providerOptions,
        baseUrl: namingConfig.baseUrl,
      ),
      maxTokens: 1500,
      modelMaxOutputTokens: namingConfig.maxOutputTokens,
      stream: false,
      responseFormat: const LlmResponseFormatJsonObject(),
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      // 2026-07-28 修复：后台合并任务不需要思考，显式禁用避免思考模型白白消耗 token
      // 不传时 reasoningEffort=null，ThinkingParamBuilder 走"未配置"分支不发参数，
      // 对 DeepSeek-V3.1+/Qwen3 等默认开启思考的模型会触发不必要思考
      reasoningEffort: ReasoningEffort.disabled,
    );

    try {
      final response =
          await _llmService.chat(request).timeout(const Duration(seconds: 30));
      return _parseConsolidated(response.content);
    } catch (_) {
      // LLM 调用失败/超时 → 返回空列表，调用方记 warn 日志
      return const [];
    }
  }

  /// 构造 user 消息内容：按时间顺序列出待合并记忆。
  ///
  /// 格式：
  /// ```text
  /// 1. [轮次3] importance:2 summary: 勇者走进酒馆 tags: 酒馆,勇者
  /// 2. [轮次5] importance:2 summary: 勇者与酒馆老板交谈 tags: 酒馆老板,交谈
  /// ```
  String _buildUserContent(List<ExperientialMemory> memories) {
    final buffer = StringBuffer()
      ..writeln('以下是 ${memories.length} 条低重要性的事件摘要（按时间顺序）：');
    for (var i = 0; i < memories.length; i++) {
      final m = memories[i];
      final tagsStr = m.tags.join(',');
      buffer.writeln(
        '${i + 1}. [轮次${m.turnNumber}] importance:${m.importance} '
        'summary: ${m.summary} tags: $tagsStr',
      );
    }
    buffer.writeln('请按合并规则输出 JSON。');
    return buffer.toString();
  }

  /// 解析 LLM 输出为合并记忆列表。
  ///
  /// 容错策略：
  /// - 容忍 JSON 前后的说明文字（截取首个 `{` 到末尾 `}`）
  /// - 字段类型修复：importance 字符串→int，tags 非 List→空数组
  /// - 跳过缺 summary 或 importance 越界的条目
  List<ConsolidatedMemory> _parseConsolidated(String raw) {
    final json = _extractJsonObject(raw);
    if (json == null) return const [];

    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return const [];

    final consolidated = decoded['consolidated'];
    if (consolidated is! List) return const [];

    final result = <ConsolidatedMemory>[];
    for (final item in consolidated) {
      if (item is! Map<String, dynamic>) continue;
      final summary = (item['summary'] ?? '').toString().trim();
      if (summary.isEmpty) continue;
      final importance = _parseIntSafe(item['importance']);
      if (importance < 1 || importance > 5) continue;
      final tags = _parseTags(item['tags']);
      result.add(
        ConsolidatedMemory(
          summary: summary,
          tags: tags,
          importance: importance,
        ),
      );
    }
    return result;
  }

  /// 截取首个 `{` 到末尾 `}` 的子串（容忍 JSON 前后说明文字）。
  String? _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    final end = raw.lastIndexOf('}');
    if (end <= start) return null;
    return raw.substring(start, end + 1);
  }

  /// 安全解析 importance（容忍字符串 "3" 或小数 3.0）。
  int _parseIntSafe(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// 解析 tags（容忍 null / 非 List / 元素非 String）。
  List<String> _parseTags(Object? value) {
    if (value is! List) return const [];
    return value
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
