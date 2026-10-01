import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/domain/services/incremental_json_parser.dart';
import 'package:lmstory/features/intermediate/domain/services/stream_marker_parser.dart';
import 'package:lmstory/features/story_runtime/domain/entities/stream_failure.dart';

// StreamErrorException 下沉至 story_runtime/domain/entities/
// stream_failure.dart（携带语义码与 Retry-After），此处 re-export 保持
// 既有 import 兼容。
export 'package:lmstory/features/story_runtime/domain/entities/stream_failure.dart'
    show StreamErrorException;

/// 流式请求结果（展示正文 + JSON 载荷 + 思考内容）
class StreamResult {
  const StreamResult(
    this.displayText,
    this.jsonPayload, {
    this.thinkingContent,
    this.usage,
  });

  final String displayText;
  final String? jsonPayload;

  /// LLM 思考/推理内容（来自 `reasoning_content` / `reasoning` 字段）
  ///
  /// 仅当模型支持 reasoning 且发送了 `reasoning_effort` 参数时有值。
  /// 供调用方写入消息的 `thinkingContent` 字段，在 UI 中可折叠展示。
  final String? thinkingContent;

  /// 本次请求 token 用量（上下文用量指示：runPlainText 捕获
  /// LlmStreamDone.usage；端点不回 usage 或流异常截断时为 null）
  final LlmUsage? usage;
}

/// 工具调用流式请求结果（Phase 6 Step 6.1 新增）
///
/// 表示一次携带 `tools` 参数的流式请求的结果：
/// - [arguments] 非空：LLM 发起了工具调用，参数已解析为 Map
/// - [arguments] 为 null：LLM 未发起工具调用（可能不支持 tools 参数），
///   调用方应降级到 JSON 模式（用 [fallbackText] 作为 JSON 载荷解析）
///
/// 降级链判定由调用方（extract/summarize handler）负责，本类只承载数据。
///
/// **多工具并行调用支持**（DOC-11 §4.4，2026-07-20 新增）：
/// summarizing 阶段同时注入 `extract_event_summary` + `extract_facts` 两个工具，
/// LLM 可能在一次响应中并发调用两者。新字段 `argumentsByToolName` 按 toolName
/// 索引所有工具调用结果，调用方通过 [argumentsFor] 按工具名取参数。
/// 旧字段 [arguments] 保留向后兼容（取首个工具的参数），extracting 阶段不受影响。
class ToolCallResult {
  const ToolCallResult({
    this.arguments,
    this.fallbackText,
    this.reasoningContent,
    Map<String, Map<String, dynamic>>? argumentsByToolName,
  }) : _argumentsByToolName = argumentsByToolName;

  /// 工具调用参数（null = 未收到工具调用，需降级）
  ///
  /// **多工具场景下**：取首个工具的参数（向后兼容 extracting 阶段单工具逻辑）。
  /// 多工具调用方应使用 [argumentsFor] 按工具名取参数。
  final Map<String, dynamic>? arguments;

  /// LLM 输出的文本兜底（无工具调用时可能有文本输出，用于 JSON 模式降级）
  final String? fallbackText;

  /// LLM 思考/推理内容（来自 `reasoning_content` 字段）
  ///
  /// DeepSeek V4 thinking 模式下，工具调用响应会携带 reasoning_content。
  /// 多轮工具调用场景下，调用方需将此字段回传给 API（注入到 assistant 消息的
  /// `reasoning_content` 字段），否则 DeepSeek 会返回 400 错误。
  /// 仅当模型支持 reasoning 时有值，其他模型为 null（不影响兼容性）。
  final String? reasoningContent;

  /// 按 toolName 索引的工具调用参数表（多工具并行调用场景，DOC-11 §4.4）
  ///
  /// Key 为工具名（如 `extract_event_summary` / `extract_facts`），
  /// Value 为该工具的已解析参数 Map。
  /// 单工具场景下此表只含一个条目；多工具场景含多个。
  /// 完全无工具调用时为 null。
  final Map<String, Map<String, dynamic>>? _argumentsByToolName;

  /// 是否成功收到工具调用
  bool get hasToolCall => arguments != null;

  /// 所有被调用的工具名列表（多工具并行场景）
  ///
  /// 单工具场景下含一个条目；完全无工具调用时为空列表。
  List<String> get toolNames => _argumentsByToolName?.keys.toList() ?? const [];

  /// 按工具名获取参数（多工具并行调用场景）
  ///
  /// 返回该工具的已解析参数 Map，未找到时返回 null。
  /// 单工具场景下传入工具名也可获取（兼容写法）。
  Map<String, dynamic>? argumentsFor(String toolName) {
    return _argumentsByToolName?[toolName];
  }

  /// 是否包含指定工具名的调用
  bool hasTool(String toolName) {
    return _argumentsByToolName?.containsKey(toolName) ?? false;
  }
}

/// LLM 流式执行 + 取消管理封装（Phase 5 Step 5.2 提取）
///
/// 从 `IntermediateChatController` 提取，负责：
/// - 发起 [LlmService.streamChat] 流式请求
/// - 监听 [LlmStreamEvent]：文本增量切分 / JSON 缓冲、完成、错误
/// - 取消管理：[CancellationToken] + [StreamSubscription] 双保险
///
/// **职责边界**：
/// - 本类只管流式执行与取消，不感知降级标志 / 重试 / 状态机
/// - 降级链判定（response_format 构建 / 400 降级）留在控制器
///   （访问降级标志 + logger，跨方法散落）
///
/// 详见 DOC-09A-2 §6（失败处理）、DOC-09B §8.6（JSON 兜底）。
class StreamRunner {
  StreamRunner({required LlmService llmService}) : _llmService = llmService;

  final LlmService _llmService;

  /// 当前流式订阅（取消用）
  StreamSubscription<LlmStreamEvent>? _currentSubscription;

  /// 当前请求取消令牌
  CancellationToken? _currentCancelToken;

  /// 取消标志（R1：防止 cancel 与流式 onDone 竞态）
  bool _isCancelled = false;

  /// 是否已取消（控制器在各阶段边界检查，提前 return）
  bool get isCancelled => _isCancelled;

  /// 是否正在流式订阅中（recoverIfStuck 据此判断是否卡死）
  bool get isStreaming => _currentSubscription != null;

  /// 运行一次 LLM 流式请求，返回展示正文与 JSON 载荷
  ///
  /// 通过 [LlmService.streamChat] 发起请求，监听 [LlmStreamEvent] 流：
  /// - [LlmTextDelta] → 透传给 [StreamMarkerParser] 切分（或缓冲到 JSON 兜底）
  /// - [LlmStreamDone] → 完成 completer
  /// - [LlmStreamError] → 抛 [StreamErrorException] 进 catch 块
  ///
  /// [jsonFallback] = true 时启用 JSON 兜底模式（DOC-09B §8.6）：
  /// - 不使用 [StreamMarkerParser] 切分标记
  /// - 流式增量全部缓冲到 StringBuffer
  /// - 流结束后将完整缓冲文本作为 `jsonPayload` 返回（`displayText` 为空）
  /// - ** 新增**：若 [jsonStreamField] 非空，流式过程中用
  ///   [IncrementalJsonParser] 实时提取该字段当前值，计算增量后调用 [onDelta]，
  ///   让用户在 JSON 模式下也能看到 draft/reply 的实时生成（而非等到完整 JSON 接收后）。
  /// 调用方拿到完整 JSON 后用 [parseDraftJsonResult] / [parseReviseJsonResult] 解析。
  ///
  /// 取消语义：内部创建 [CancellationToken] 并赋值给 [_currentCancelToken]，
  /// 通过 `request.copyWith` 注入到 effectiveRequest；订阅存入
  /// [_currentSubscription]，[cancel] / [cleanup] 时双保险取消。
  Future<StreamResult> run({
    required LlmRequest request,
    required String marker,
    required void Function(String display) onDelta,
    bool jsonFallback = false,
    String? jsonStreamField,
    String phaseLabel = 'unknown',
  }) async {
    final parser = StreamMarkerParser(marker: marker);
    final jsonBuffer = StringBuffer(); // jsonFallback 模式专用
    // 流式字段值跟踪（用于增量计算）
    var lastStreamedField = '';
    final cancelToken = CancellationToken();
    _currentCancelToken = cancelToken;

    // 2026-08-04：统一阶段标签日志
    final logger = Logger('Intermediate.$phaseLabel');
    final stopwatch = Stopwatch()..start();

    final effectiveRequest = request.copyWith(cancelToken: cancelToken);
    final completer = Completer<StreamResult>();

    _currentSubscription = _llmService.streamChat(effectiveRequest).listen(
      (event) {
        if (_isCancelled) return;
        if (event is LlmTextDelta) {
          if (jsonFallback) {
            jsonBuffer.write(event.content);
            // JSON 模式下流式显示指定字段（如 draft/reply）
            if (jsonStreamField != null) {
              final current = IncrementalJsonParser.extractStringField(
                jsonBuffer.toString(),
                jsonStreamField,
              );
              if (current != null &&
                  current.length > lastStreamedField.length) {
                // 计算增量：当前值比上次多出的部分
                final delta = current.substring(lastStreamedField.length);
                lastStreamedField = current;
                if (delta.isNotEmpty) onDelta(delta);
              }
            }
          } else {
            final display = parser.feed(event.content);
            if (display.isNotEmpty) onDelta(display);
          }
        } else if (event is LlmStreamDone) {
          if (!completer.isCompleted) {
            if (jsonFallback) {
              completer.complete(
                StreamResult('', jsonBuffer.toString().trim()),
              );
            } else {
              completer.complete(
                StreamResult(parser.displayText, parser.jsonPayload),
              );
            }
          }
        } else if (event is LlmStreamError) {
          if (!completer.isCompleted) {
            completer.completeError(
              StreamErrorException(
                event.message,
                code: event.code,
                retryAfter: event.retryAfter,
              ),
            );
          }
        }
      },
      onError: (Object e, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(e, stackTrace);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          if (jsonFallback) {
            completer.complete(
              StreamResult('', jsonBuffer.toString().trim()),
            );
          } else {
            completer.complete(
              StreamResult(parser.displayText, parser.jsonPayload),
            );
          }
        }
      },
    );

    try {
      final result = await completer.future;
      // 2026-08-04：流结束后记录汇总日志（无碎片，单条汇总）
      stopwatch.stop();
      final displayLen = result.displayText.length;
      final thinkingLen = result.thinkingContent?.length ?? 0;
      logger.info(
        '[$phaseLabel] LLM stream completed',
        detail: 'displayLen=$displayLen, thinkingLen=$thinkingLen, '
            'elapsed=${stopwatch.elapsedMilliseconds}ms, '
            'model=${request.modelId}',
      );
      if (Logger.debugOptions.logPayloads) {
        final displayPreview = displayLen > 2000
            ? '${result.displayText.substring(0, 2000)}...[truncated ${displayLen - 2000} chars]'
            : result.displayText;
        logger.info(
          '[$phaseLabel] response display text',
          detail: 'len=$displayLen\n$displayPreview',
        );
        if (result.thinkingContent != null &&
            result.thinkingContent!.isNotEmpty) {
          final thinkingPreview = thinkingLen > 2000
              ? '${result.thinkingContent!.substring(0, 2000)}...[truncated $thinkingLen chars]'
              : result.thinkingContent!;
          logger.info(
            '[$phaseLabel] response thinking content',
            detail: 'len=$thinkingLen\n$thinkingPreview',
          );
        }
      }
      return result;
    } finally {
      await _currentSubscription?.cancel();
      _currentSubscription = null;
      _currentCancelToken = null;
    }
  }

  // ==================== V2 纯文本模式（Phase 6 Step 6.4 新增）====================

  /// 运行一次纯文本流式请求（V2 四步流程，generating/reviewing 步骤）
  ///
  /// 与 [run] 的差异：
  /// - **不使用 [StreamMarkerParser]**：V2 提示词不再要求分隔标记，LLM 直接输出纯文本
  /// - **不启用 JSON 兜底**：V2 generating/reviewing 只产出纯文本生成内容/回复，
  ///   关键词与事件摘要交由 extracting/summarizing 步骤的工具调用获取
  /// - 所有 [LlmTextDelta] 直接累积为 [StreamResult.displayText]，
  ///   并透传增量给 [onDelta]（流式显示）
  /// - [LlmThinkingDelta] 累积到 [StreamResult.thinkingContent]，
  ///   供调用方写入消息的 thinkingContent 字段
  ///
  /// 取消语义与 [run] / [runWithToolCall] 一致：[CancellationToken] +
  /// [StreamSubscription] 双保险。
  ///
  /// 返回的 [StreamResult.jsonPayload] 始终为 null（V2 纯文本模式无 JSON 载荷）。
  Future<StreamResult> runPlainText({
    required LlmRequest request,
    required void Function(String display) onDelta,
    void Function(String thinking)? onThinkingDelta,
    String phaseLabel = 'unknown',
  }) async {
    final buffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    // LlmStreamDone 携带的 usage（onDone 兜底完成时也可用）
    LlmUsage? doneUsage;
    final cancelToken = CancellationToken();
    _currentCancelToken = cancelToken;

    // 2026-08-04：统一阶段标签日志（替代 per-delta 碎片日志）
    final logger = Logger('Intermediate.$phaseLabel');
    final stopwatch = Stopwatch()..start();
    if (Logger.debugOptions.logPayloads) {
      logger.info(
        '[$phaseLabel] LLM request started',
        detail: 'model=${request.modelId}, '
            'messageCount=${request.messages.length}, '
            'temperature=${request.temperature}, '
            'maxTokens=${request.maxTokens}',
      );
      for (var i = 0; i < request.messages.length; i++) {
        final msg = request.messages[i];
        final content = msg['content']?.toString() ?? '';
        final preview = content.length > 2000
            ? '${content.substring(0, 2000)}...[truncated ${content.length - 2000} chars]'
            : content;
        logger.info(
          '[$phaseLabel] request message[$i]',
          detail: 'role=${msg['role']}, len=${content.length}\n$preview',
        );
      }
    }

    final effectiveRequest = request.copyWith(cancelToken: cancelToken);
    final completer = Completer<StreamResult>();

    _currentSubscription = _llmService.streamChat(effectiveRequest).listen(
      (event) {
        if (_isCancelled) return;
        if (event is LlmTextDelta) {
          buffer.write(event.content);
          if (event.content.isNotEmpty) onDelta(event.content);
        } else if (event is LlmThinkingDelta) {
          thinkingBuffer.write(event.content);
          // 2026-08-04：移除 per-delta 调试日志（碎片化严重，流结束后汇总记录见下方）
          if (onThinkingDelta != null && event.content.isNotEmpty) {
            onThinkingDelta(event.content);
          }
        } else if (event is LlmStreamDone) {
          doneUsage = event.usage;
          if (!completer.isCompleted) {
            completer.complete(
              StreamResult(
                buffer.toString().trim(),
                null,
                thinkingContent: thinkingBuffer.isEmpty
                    ? null
                    : thinkingBuffer.toString().trim(),
                usage: doneUsage,
              ),
            );
          }
        } else if (event is LlmStreamError) {
          if (!completer.isCompleted) {
            completer.completeError(
              StreamErrorException(
                event.message,
                code: event.code,
                retryAfter: event.retryAfter,
              ),
            );
          }
        }
      },
      onError: (Object e, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(e, stackTrace);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            StreamResult(
              buffer.toString().trim(),
              null,
              thinkingContent: thinkingBuffer.isEmpty
                  ? null
                  : thinkingBuffer.toString().trim(),
              usage: doneUsage,
            ),
          );
        }
      },
    );

    try {
      final result = await completer.future;
      // 2026-08-04：流结束后记录汇总日志（无碎片，单条汇总）
      stopwatch.stop();
      final displayLen = result.displayText.length;
      final thinkingLen = result.thinkingContent?.length ?? 0;
      logger.info(
        '[$phaseLabel] LLM stream completed',
        detail: 'displayLen=$displayLen, thinkingLen=$thinkingLen, '
            'elapsed=${stopwatch.elapsedMilliseconds}ms, '
            'model=${request.modelId}',
      );
      if (Logger.debugOptions.logPayloads) {
        final displayPreview = displayLen > 2000
            ? '${result.displayText.substring(0, 2000)}...[truncated ${displayLen - 2000} chars]'
            : result.displayText;
        logger.info(
          '[$phaseLabel] response display text',
          detail: 'len=$displayLen\n$displayPreview',
        );
        if (result.thinkingContent != null &&
            result.thinkingContent!.isNotEmpty) {
          final thinkingPreview = thinkingLen > 2000
              ? '${result.thinkingContent!.substring(0, 2000)}...[truncated $thinkingLen chars]'
              : result.thinkingContent!;
          logger.info(
            '[$phaseLabel] response thinking content',
            detail: 'len=$thinkingLen\n$thinkingPreview',
          );
        }
      }
      return result;
    } finally {
      await _currentSubscription?.cancel();
      _currentSubscription = null;
      _currentCancelToken = null;
    }
  }

  /// 取消当前流式请求（停止 SSE 订阅 + 取消令牌）
  ///
  /// 置 [isCancelled] = true 防止后续 onDone 回调误触发；
  /// 双保险取消订阅与令牌。控制器 `IntermediateChatController.cancel`
  /// 调用本方法后还需重置自身的 _round / 降级标志 / state。
  ///
  /// **竞态安全**：`await _currentSubscription?.cancel` 期间，
  /// 调用方可能已启动新轮次并设置了新的 subscription/token。
  /// 使用 `identical` 检查确保只清空"本轮"的引用，不误清新轮次的。
  Future<void> cancel() async {
    _isCancelled = true;
    final sub = _currentSubscription;
    final token = _currentCancelToken;
    token?.cancel();
    await sub?.cancel();
    // 仅在引用未变时清空（防止新轮次已设置的 subscription 被误清）
    if (identical(_currentSubscription, sub)) {
      _currentSubscription = null;
    }
    if (identical(_currentCancelToken, token)) {
      _currentCancelToken = null;
    }
  }

  /// 重置取消标志（每轮开始时调用，`IntermediateChatController._prepareAndRunRound`）
  void resetCancelled() {
    _isCancelled = false;
  }

  /// 清理流式资源（dispose / 异常兜底）
  ///
  /// 与 [cancel] 的差异：不置 [isCancelled]（保留已取消语义供边界检查），
  /// 仅取消底层订阅与令牌。供 dispose / clearRound / deletePendingUserMessage 调用。
  void cleanup() {
    _currentCancelToken?.cancel();
    _currentSubscription?.cancel();
    _currentSubscription = null;
    _currentCancelToken = null;
  }

  // ==================== 工具调用模式（Phase 6 Step 6.1 新增）====================

  /// 运行一次携带 `tools` 参数的 LLM 流式请求（工具调用模式）
  ///
  /// 监听 [LlmStreamEvent] 流，累积工具调用参数分片：
  /// - [LlmToolCallStart] → 记录 toolCallId + name（用于多工具并发区分）
  /// - [LlmToolCallArgs] → 累积 `argsDelta` 分片到对应 toolCallId 的缓冲
  /// - [LlmToolCallComplete] → 直接采用已解析的 `arguments`（最权威）
  /// - [LlmTextDelta] → 累积到 `fallbackText`（无工具调用时的文本兜底）
  /// - [LlmStreamDone] / `onDone` → 完成 Completer
  /// - [LlmStreamError] → 抛 [StreamErrorException] 进 catch 块
  ///
  /// **结果判定**（[ToolCallResult]）：
  /// - 收到 [LlmToolCallComplete] → `arguments = complete.arguments`（已解析）
  /// - 无 Complete 但有累积 argsDelta → 解析累积的 JSON 字符串为 Map
  ///   （容错：解析失败返回空 Map，调用方按降级链处理）
  /// - 完全无工具调用事件 → `arguments = null`，`fallbackText = 累积文本`
  ///   调用方应降级到 JSON 模式（用 fallbackText 作为 JSON 载荷解析）
  ///
  /// [onTextDelta] 可选回调：工具调用模式下 LLM 通常只输出工具调用，
  /// 但部分供应商在不支持 tools 时会输出文本（JSON 格式）。
  /// 调用方可通过此回调实时展示文本（如 JSON 模式降级时的流式显示）。
  ///
  /// 取消语义与 [run] 一致：[CancellationToken] + [StreamSubscription] 双保险。
  Future<ToolCallResult> runWithToolCall({
    required LlmRequest request,
    void Function(String textDelta)? onTextDelta,
    String phaseLabel = 'unknown',
  }) async {
    // 按工具调用 ID 累积参数分片（支持多工具并发，DOC-11 §4.4 双工具并行）
    final argsBuffers = <String, StringBuffer>{};
    // Complete 事件最权威，直接采用其 arguments（按 toolCallId 索引）
    final completeArgumentsById = <String, Map<String, dynamic>>{};
    // toolCallId → toolName 映射（从 LlmToolCallStart / LlmToolCallComplete 获取）
    final toolNamesById = <String, String>{};
    // 无工具调用时的文本兜底
    final fallbackBuffer = StringBuffer();
    // LLM 思考内容累积（DeepSeek V4 thinking 模式 + 工具调用场景，回传用）
    final thinkingBuffer = StringBuffer();
    // 记录首个 toolCallId（单工具场景下用作结果 ID，向后兼容 arguments 字段）
    var firstToolCallId = '';

    // 2026-08-04：统一阶段标签日志
    final logger = Logger('Intermediate.$phaseLabel');
    final stopwatch = Stopwatch()..start();
    if (Logger.debugOptions.logPayloads) {
      logger.info(
        '[$phaseLabel] LLM tool-call request started',
        detail: 'model=${request.modelId}, '
            'messageCount=${request.messages.length}, '
            'toolCount=${request.tools?.length ?? 0}',
      );
      for (var i = 0; i < request.messages.length; i++) {
        final msg = request.messages[i];
        final content = msg['content']?.toString() ?? '';
        final preview = content.length > 2000
            ? '${content.substring(0, 2000)}...[truncated ${content.length - 2000} chars]'
            : content;
        logger.info(
          '[$phaseLabel] request message[$i]',
          detail: 'role=${msg['role']}, len=${content.length}\n$preview',
        );
      }
    }

    final cancelToken = CancellationToken();
    _currentCancelToken = cancelToken;

    final effectiveRequest = request.copyWith(cancelToken: cancelToken);
    final completer = Completer<ToolCallResult>();

    _currentSubscription = _llmService.streamChat(effectiveRequest).listen(
      (event) {
        if (_isCancelled) return;
        if (event is LlmToolCallStart) {
          // 保留首个 toolCallId（单工具场景下即唯一 ID；多工具异常场景取首个）
          if (firstToolCallId.isEmpty) {
            firstToolCallId = event.toolCallId;
          }
          argsBuffers.putIfAbsent(event.toolCallId, StringBuffer.new);
          // 记录 toolName（用于多工具并行调用按 name 索引参数）
          toolNamesById[event.toolCallId] = event.name;
        } else if (event is LlmToolCallArgs) {
          argsBuffers
              .putIfAbsent(event.toolCallId, StringBuffer.new)
              .write(event.argsDelta);
        } else if (event is LlmToolCallComplete) {
          // Complete 事件优先级最高（已解析），按 toolCallId 索引存储
          completeArgumentsById[event.toolCallId] = event.arguments;
          toolNamesById[event.toolCallId] = event.name;
        } else if (event is LlmTextDelta) {
          fallbackBuffer.write(event.content);
          if (onTextDelta != null) onTextDelta(event.content);
        } else if (event is LlmThinkingDelta) {
          thinkingBuffer.write(event.content);
        } else if (event is LlmStreamDone) {
          if (!completer.isCompleted) {
            completer.complete(
              _buildToolCallResult(
                completeArgumentsById: completeArgumentsById,
                argsBuffers: argsBuffers,
                toolNamesById: toolNamesById,
                firstToolCallId: firstToolCallId,
                fallbackBuffer: fallbackBuffer,
                thinkingBuffer: thinkingBuffer,
              ),
            );
          }
        } else if (event is LlmStreamError) {
          if (!completer.isCompleted) {
            completer.completeError(
              StreamErrorException(
                event.message,
                code: event.code,
                retryAfter: event.retryAfter,
              ),
            );
          }
        }
      },
      onError: (Object e, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(e, stackTrace);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            _buildToolCallResult(
              completeArgumentsById: completeArgumentsById,
              argsBuffers: argsBuffers,
              toolNamesById: toolNamesById,
              firstToolCallId: firstToolCallId,
              fallbackBuffer: fallbackBuffer,
              thinkingBuffer: thinkingBuffer,
            ),
          );
        }
      },
    );

    try {
      final result = await completer.future;
      // 2026-08-04：流结束后记录汇总日志
      stopwatch.stop();
      final fallbackLen = result.fallbackText?.length ?? 0;
      logger.info(
        '[$phaseLabel] LLM tool-call stream completed',
        detail: 'hasToolCall=${result.hasToolCall}, '
            'hasFallback=${fallbackLen > 0}, '
            'fallbackLen=$fallbackLen, '
            'elapsed=${stopwatch.elapsedMilliseconds}ms, '
            'model=${request.modelId}',
      );
      if (Logger.debugOptions.logPayloads) {
        if (result.hasToolCall) {
          for (final toolName in result.toolNames) {
            final args = result.argumentsFor(toolName);
            final argsJson = args != null ? jsonEncode(args) : 'null';
            final preview = argsJson.length > 2000
                ? '${argsJson.substring(0, 2000)}...[truncated ${argsJson.length - 2000} chars]'
                : argsJson;
            logger.info(
              '[$phaseLabel] tool call result: $toolName',
              detail: 'argsLen=${argsJson.length}\n$preview',
            );
          }
        } else if (fallbackLen > 0) {
          final fallbackPreview = fallbackLen > 2000
              ? '${result.fallbackText!.substring(0, 2000)}...[truncated ${fallbackLen - 2000} chars]'
              : result.fallbackText;
          logger.info(
            '[$phaseLabel] fallback text (no tool call)',
            detail: 'len=$fallbackLen\n$fallbackPreview',
          );
        }
      }
      return result;
    } finally {
      await _currentSubscription?.cancel();
      _currentSubscription = null;
      _currentCancelToken = null;
    }
  }

  /// 构建工具调用结果（优先 Complete 事件，其次解析累积 argsDelta，最后文本兜底）
  ///
  /// **多工具并行调用支持**（DOC-11 §4.4）：
  /// 遍历所有 toolCallId，分别按 Complete 事件 / 累积 argsDelta 解析参数，
  /// 然后用 toolNamesById 映射为 `argumentsByToolName`。
  /// [firstToolCallId] 的解析结果作为向后兼容的 `arguments` 字段返回。
  ToolCallResult _buildToolCallResult({
    required Map<String, Map<String, dynamic>> completeArgumentsById,
    required Map<String, StringBuffer> argsBuffers,
    required Map<String, String> toolNamesById,
    required String firstToolCallId,
    required StringBuffer fallbackBuffer,
    required StringBuffer thinkingBuffer,
  }) {
    // 按 toolName 索引所有工具调用参数
    final argumentsByToolName = <String, Map<String, dynamic>>{};
    // 思考内容（为空则 null，不注入到 ToolCallResult，对不支持 reasoning 的模型无影响）
    final reasoningContent =
        thinkingBuffer.isEmpty ? null : thinkingBuffer.toString().trim();

    for (final entry in argsBuffers.entries) {
      final toolCallId = entry.key;
      final buffer = entry.value;
      final toolName = toolNamesById[toolCallId];

      // 1. Complete 事件优先
      final complete = completeArgumentsById[toolCallId];
      if (complete != null) {
        if (toolName != null) {
          argumentsByToolName[toolName] = complete;
        }
        continue;
      }

      // 2. 解析累积 argsDelta
      if (buffer.isNotEmpty) {
        final parsed = _parseToolCallArgs(buffer.toString());
        if (parsed != null && toolName != null) {
          argumentsByToolName[toolName] = parsed;
        }
      }
    }

    // 处理 Complete 事件中存在但 argsBuffers 中没有的 toolCallId
    // （某些供应商只发 Complete 不发 Start）
    for (final entry in completeArgumentsById.entries) {
      final toolCallId = entry.key;
      final toolName = toolNamesById[toolCallId];
      if (toolName != null && !argumentsByToolName.containsKey(toolName)) {
        argumentsByToolName[toolName] = entry.value;
      }
    }

    // 向后兼容：取首个工具的参数作为 arguments 字段
    Map<String, dynamic>? firstArguments;
    String? firstFallback;

    if (firstToolCallId.isNotEmpty) {
      // 1. Complete 事件
      firstArguments = completeArgumentsById[firstToolCallId];
      // 2. 累积 argsDelta 解析
      if (firstArguments == null) {
        final buffer = argsBuffers[firstToolCallId];
        if (buffer != null && buffer.isNotEmpty) {
          final raw = buffer.toString();
          final parsed = _parseToolCallArgs(raw);
          if (parsed != null) {
            firstArguments = parsed;
          } else {
            // 解析失败：将原始文本作为 fallbackText 返回，让调用方尝试 JSON 解析降级。
            // 之前返回空 Map 会被调用方误判为"LLM 有意输出空"（hasToolCall=true），
            // 导致静默跳过降级链。改为 fallbackText 后调用方可尝试 parseKeywords 等解析。
            firstFallback = raw;
          }
        }
      }
    }

    if (firstArguments != null) {
      return ToolCallResult(
        arguments: firstArguments,
        argumentsByToolName: argumentsByToolName,
        reasoningContent: reasoningContent,
      );
    }
    if (firstFallback != null) {
      return ToolCallResult(
        fallbackText: firstFallback,
        argumentsByToolName:
            argumentsByToolName.isEmpty ? null : argumentsByToolName,
        reasoningContent: reasoningContent,
      );
    }

    // 3. 无工具调用事件 → 文本兜底（调用方降级到 JSON 模式）
    final fallback = fallbackBuffer.toString().trim();
    return ToolCallResult(
      fallbackText: fallback.isEmpty ? null : fallback,
      argumentsByToolName:
          argumentsByToolName.isEmpty ? null : argumentsByToolName,
      reasoningContent: reasoningContent,
    );
  }

  /// 解析工具调用参数 JSON 字符串为 Map（容错：解析失败返回 null）
  ///
  /// LLM 累积的 argsDelta 拼接后应为合法 JSON 字符串（如
  /// `{"entities":["古碑"],"events":["苏明远查看古碑"]}`）。
  /// 解析失败时返回 null，由 [_buildToolCallResult] 决定降级策略。
  Map<String, dynamic>? _parseToolCallArgs(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 容错：参数 JSON 非法（如分片乱序/截断），返回 null 触发降级
    }
    return null;
  }
}
