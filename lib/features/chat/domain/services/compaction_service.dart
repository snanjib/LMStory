import 'dart:async';
import 'dart:math' as math;

import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:uuid/uuid.dart';

/// 压缩异常
///
/// 压缩过程中发生的可向用户展示的错误。消息使用通俗语言，
/// 不暴露技术细节。
class CompactionException implements Exception {
  const CompactionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 压缩服务
///
/// 实现 CompactionPoint 上下文压缩策略：
/// 1. 当上下文 token 数超过阈值时触发压缩
/// 2. 调用 LLM 生成摘要
/// 3. 创建压缩点记录
/// 4. 保留摘要 + 压缩点之后的消息
class CompactionService {
  CompactionService({
    required ChatRepository chatRepository,
    required TokenCounter tokenCounter,
    required SettingsRepository settingsRepository,
    required ApiPresetRepository presetRepository,
    required CompactionStreamer streamer,
    required LlmService llmService,
    Logger? logger,
  })  : _chatRepository = chatRepository,
        _tokenCounter = tokenCounter,
        _settingsRepository = settingsRepository,
        _presetRepository = presetRepository,
        _streamer = streamer,
        _llmService = llmService,
        _logger = logger ?? const Logger('CompactionService'),
        _uuid = const Uuid();

  final ChatRepository _chatRepository;
  final TokenCounter _tokenCounter;
  final SettingsRepository _settingsRepository;
  final ApiPresetRepository _presetRepository;
  final CompactionStreamer _streamer;

  /// 统一 LLM 调用层（协议适配），非流式摘要请求走这里
  final LlmService _llmService;
  final Logger _logger;
  final Uuid _uuid;

  /// 压缩触发线 token（圆环满刻度口径）。
  ///
  /// 与 [shouldCompact] 同公式同值：availableWindow =
  /// max(contextWindow - 32000, floor(contextWindow × 0.5))，
  /// 触发线 = floor(availableWindow × [threshold])。
  /// contextWindow 未知/非正，或 availableWindow ≤ 0 时返回 null
  /// （圆环无满刻度可画，画空轨道）。
  static int? compactionTriggerTokens({
    required int? contextWindow,
    required double threshold,
  }) {
    if (contextWindow == null || contextWindow <= 0) return null;
    final availableWindow = math.max(
      contextWindow - 32000,
      (contextWindow * 0.5).floor(),
    );
    if (availableWindow <= 0) return null;
    return (availableWindow * threshold).floor();
  }

  /// 检查是否需要压缩（仅判断阈值，不执行压缩）
  ///
  /// 阈值公式（对标 ChatBox compaction-detector.ts）：
  /// ```text
  /// availableWindow = max(contextWindow - 32000, floor(contextWindow × 0.5))
  /// thresholdTokens = floor(availableWindow × threshold)
  /// isOverflow = (currentTokens > thresholdTokens)
  /// ```
  /// 当 contextWindow 未知（null）时，返回 false（对标 ChatBox）。
  ///
  /// 公开方法：供 controller 在自动压缩前预检，
  /// 命中后由 controller 走流式压缩路径（compactWithStream），
  /// 以便 UI 展示摘要横幅的流式生成过程。
  Future<bool> shouldCompact({
    required List<ChatMessage> messages,
    required double threshold,
    required int? contextWindow,
  }) async {
    if (messages.isEmpty) return false;
    // 对标 ChatBox：contextWindow 未知时不触发自动压缩
    final thresholdTokens = compactionTriggerTokens(
      contextWindow: contextWindow,
      threshold: threshold,
    );
    if (thresholdTokens == null) return false;

    final tokenCount = await _tokenCounter.countTokensForMessages(
      messages.where((m) => m.content != null).map((m) => m.content!).toList(),
    );

    return tokenCount > thresholdTokens;
  }

  /// 检查并执行压缩（非流式路径）
  ///
  /// [messages] 当前会话的有效上下文消息（通过 getCompressedMessages 获取）。
  /// [threshold] 压缩阈值百分比（0.4-0.9），对标 ChatBox compactionThreshold。
  /// [contextWindow] 模型上下文窗口大小（token），未知时传 null。
  /// [force] 是否强制压缩（忽略阈值检查）。
  ///
  /// 注意：本方法走非流式 [_generateSummary]，UI 无法展示流式生成过程。
  /// 自动压缩场景应改用 [shouldCompact] + controller 的流式压缩路径，
  /// 以便 UI 展示摘要横幅的实时生成动画。本方法保留用于兼容旧调用方。
  /// 返回是否执行了压缩。
  Future<bool> checkAndCompact({
    required String sessionId,
    required List<ChatMessage> messages,
    required double threshold,
    required int? contextWindow,
    bool force = false,
  }) async {
    if (messages.isEmpty) return false;

    // force 模式（手动压缩）直接执行，不检查阈值
    if (!force) {
      if (!await shouldCompact(
        messages: messages,
        threshold: threshold,
        contextWindow: contextWindow,
      )) {
        return false;
      }
    }

    await _compact(sessionId, messages);
    return true;
  }

  /// 执行压缩操作（对标 ChatBox runCompactionWithStreaming）
  ///
  /// 压缩范围：全部当前上下文消息（含旧摘要），生成一条新摘要。
  /// boundary：最后一条非摘要消息（对标 ChatBox lastNonSummaryMessage）。
  /// 压缩后上下文 = [新摘要]（boundary 之后无消息，直到用户继续发消息）。
  ///
  /// 注意：传给 LLM 的消息包含旧摘要，这样 LLM 能基于旧摘要+新消息生成
  /// 连贯的新摘要（对标 ChatBox，避免摘要断裂）。
  Future<void> _compact(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    // boundary = 最后一条非摘要消息（对标 ChatBox lastNonSummaryMessage）
    final nonSummaryMessages = messages.where((m) => !m.isSummary).toList();
    if (nonSummaryMessages.length < 2) return;
    final boundaryMessage = nonSummaryMessages.last;

    // 传给 LLM 的消息 = 全部当前上下文（含旧摘要），对标 ChatBox
    final messagesToSummarize = messages;

    final summary = await _generateSummary(sessionId, messagesToSummarize);

    final summaryMessage = ChatMessage(
      messageId: _uuid.v4(),
      sessionId: sessionId,
      role: 'system',
      content: summary,
      isSummary: true,
      createdAt: DateTime.now(),
    );

    await _chatRepository.addMessage(summaryMessage);

    await _chatRepository.addCompactionPoint(
      sessionId: sessionId,
      summaryMessageId: summaryMessage.messageId,
      boundaryMessageId: boundaryMessage.messageId,
      createdAt: DateTime.now(),
    );
  }

  /// 生成摘要
  ///
  /// 调用 LLM API 生成对话摘要。失败时抛出异常，不使用回退策略，
  /// 让调用方决定如何向用户展示错误（对标 ChatBox：压缩失败显示错误）。
  Future<String> _generateSummary(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    if (messages.isEmpty) return '';

    final config = await resolveSummaryConfig(sessionId);
    if (config == null) {
      throw const CompactionException(
        '无法解析压缩所需的 API 配置，请检查模型和供应商设置',
      );
    }

    // 改走统一 LlmService（协议适配器构造请求体）。
    // 此前手拼 OpenAI 格式直发 http——anthropic/gemini 供应商的对话压缩必失败。
    // 提示词与 CompactionStreamer 共用（kCompactionSummaryPrompt），
    // 消除此前两份拷贝的漂移风险。
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
      stream: false,
      protocol: config.protocol,
      providerOptions: config.providerOptions,
      readTimeout: const Duration(seconds: 60),
    );

    try {
      final response =
          await _llmService.chat(request).timeout(const Duration(seconds: 60));
      final content = response.content.trim();
      if (content.isEmpty) {
        _logger.warn('LLM summary response has no content');
        throw const CompactionException('压缩服务未返回有效内容');
      }
      return content;
    } on TimeoutException {
      _logger.warn('LLM summary request timed out');
      throw const CompactionException('压缩请求超时，请稍后重试');
    } on CompactionException {
      rethrow;
    } catch (e) {
      _logger.error('LLM summary request failed', detail: '$e');
      throw const CompactionException('压缩请求失败，请检查网络连接');
    }
  }

  /// 解析摘要生成所需的 API 配置
  ///
  /// 公开方法：供 controller 在流式压缩前预检配置是否可用。
  Future<SummaryConfig?> resolveSummaryConfig(String sessionId) async {
    try {
      final session = await _chatRepository.getSession(sessionId);
      final config = await _settingsRepository.getResolvedConfig();
      final chatConfig = config.broadcastChat;

      // 1. 确定 presetId：会话级 > 默认供应商 > 第一个可用 preset
      var presetId = session.presetId ?? '';
      if (presetId.isEmpty) {
        final defaultPresetId = chatConfig.presetId;
        if (defaultPresetId.isNotEmpty) {
          presetId = defaultPresetId;
        } else {
          final presets = await _presetRepository.getAllPresets();
          if (presets.isNotEmpty) {
            presetId = presets.first.presetId;
          }
        }
      }

      if (presetId.isEmpty) return null;

      // 2. 获取 API key
      String? apiKey;
      try {
        apiKey = await _settingsRepository.getApiKey(presetId);
      } catch (_) {
        // ignore
      }

      // 当前 preset 没有 key，尝试查找第一个有 key 的 preset
      // 回落换 preset 时 modelId 必须跟随——此前把
      // 会话/全局的模型名（如 gpt-4o）发到别家供应商的 baseUrl，多数供应商
      // 对未知模型 400/404，压缩必然失败且症状间歇难排查。
      var presetSwitched = false;
      if (apiKey == null || apiKey.isEmpty) {
        final presets = await _presetRepository.getAllPresets();
        for (final preset in presets) {
          try {
            final key = await _settingsRepository.getApiKey(preset.presetId);
            if (key != null && key.isNotEmpty) {
              apiKey = key;
              presetId = preset.presetId;
              presetSwitched = true;
              break;
            }
          } catch (_) {
            continue;
          }
        }
      }

      if (apiKey == null || apiKey.isEmpty) return null;

      // 3. 获取 preset 的 baseUrl
      final preset = await _presetRepository.getPreset(presetId);

      // 4. 确定 modelId：会话级 > 配置文件默认
      var modelId = session.modelId ?? '';
      if (modelId.isEmpty) {
        modelId = chatConfig.modelId;
      }
      // 回落 preset 后原 modelId 属于旧供应商——优先用新 preset
      // 已缓存的模型列表首项；无缓存时保留原值（无法推断，与旧行为一致）
      if (presetSwitched && preset.cachedModels.isNotEmpty) {
        modelId = preset.cachedModels.first.modelId;
      }

      if (modelId.isEmpty) return null;

      return SummaryConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        // 协议随 preset 透传，压缩请求按供应商协议构造
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
        auxiliaryTemperature: config.common.auxiliary.temperature,
      );
    } catch (e) {
      _logger.error('Failed to resolve summary config', detail: '$e');
      return null;
    }
  }

  /// 获取压缩后的有效上下文消息列表
  ///
  /// 对标 ChatBox buildContextForSession：根据最新 CompactionPoint 过滤消息。
  /// 返回 `[最新summary, ...boundary之后的消息]`，过滤掉旧的 summary 消息。
  ///
  /// 调用时机：
  /// - 加载会话消息时（_loadMessages）
  /// - 压缩前获取当前上下文（传给 checkAndCompact）
  /// - 压缩后重新加载消息
  /// - 构建 API 请求消息（state.messages 已是过滤后的，_buildMessagesForApi 无需再过滤）
  Future<List<ChatMessage>> getCompressedMessages(String sessionId) async {
    final allMessages = await _chatRepository.getMessages(sessionId);
    final compactionPoints =
        await _chatRepository.getCompactionPoints(sessionId);

    if (compactionPoints.isEmpty) return allMessages;

    final latestCompaction = compactionPoints.last;
    final boundaryMessageId = latestCompaction['boundaryMessageId'] as String;

    final boundaryIndex = allMessages.indexWhere(
      (m) => m.messageId == boundaryMessageId,
    );

    if (boundaryIndex == -1) return allMessages;

    final summaryMessageId = latestCompaction['summaryMessageId'] as String;
    final summaryMessage = allMessages.firstWhere(
      (m) => m.messageId == summaryMessageId,
      orElse: () => ChatMessage(
        messageId: summaryMessageId,
        sessionId: sessionId,
        role: 'system',
        content: ChatMessage.summaryUnavailableContent,
        isSummary: true,
        createdAt: DateTime.now(),
      ),
    );

    // 对标 ChatBox buildContextForAI：取 boundary 之后的消息（不含 boundary 本身），
    // 过滤掉其中的旧 summary 消息。
    // boundary 是"压缩到此为止"的最后一条消息，已被纳入摘要，不应再出现在上下文。
    final messagesAfterBoundary = allMessages
        .sublist(boundaryIndex + 1)
        .where((m) => !m.isSummary)
        .toList();

    return [summaryMessage, ...messagesAfterBoundary];
  }

  /// 流式压缩（对标 ChatBox runCompactionWithStreaming）
  ///
  /// 编排流程：
  /// 1. 解析 [SummaryConfig]（失败调 [onError]）
  /// 2. 调 [CompactionStreamer.stream] 发起流式 LLM 请求
  /// 3. 增量回调 [onTextDelta]、完成回调 [onComplete]、失败回调 [onError]
  ///
  /// 本方法**不**创建摘要消息和 CompactionPoint，由调用方（controller）
  /// 在回调中完成落库，避免 service 与 controller 状态不同步。
  ///
  /// `boundaryMessageId` 输出参数：通过 [onComplete] 闭包不便于传递，
  /// 故由调用方在调本方法前自行从 messages 计算 boundary。
  /// 这里仅校验消息数量是否足够。
  Future<void> compactWithStream({
    required String sessionId,
    required List<ChatMessage> messages,
    required OnCompactionDelta onTextDelta,
    required OnCompactionComplete onComplete,
    required OnCompactionError onError,
    CancellationToken? cancelToken,
  }) async {
    final nonSummaryMessages = messages.where((m) => !m.isSummary).toList();
    if (nonSummaryMessages.length < 2) {
      await onError(const CompactionException('消息不足，无需压缩'));
      return;
    }

    final config = await resolveSummaryConfig(sessionId);
    if (config == null) {
      await onError(
        const CompactionException(
          '无法解析压缩所需的 API 配置，请检查模型和供应商设置',
        ),
      );
      return;
    }

    await _streamer.stream(
      config: config,
      messages: messages,
      onTextDelta: onTextDelta,
      onComplete: onComplete,
      onError: onError,
      cancelToken: cancelToken,
    );
  }
}
