import 'dart:convert';

import 'package:lmstory/core/utils/throttled_delta_buffer.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:uuid/uuid.dart';

/// 流式响应状态
///
/// 封装流式响应过程中的所有可变状态，由 [StreamHandler] 维护。
class StreamState {
  StreamState();

  /// 思考开始时间（用于计算思考耗时）
  DateTime? thinkingStartTime;

  /// 流式请求开始时间（用于计算首字延迟，对标 ChatBox）
  DateTime? streamStartTime;

  /// 首字延迟（毫秒）— 首次收到文本 token 时计算，流结束时写入消息
  int? firstTokenLatency;

  /// 当前流式响应对应的模型显示名（用于写入消息的 modelName 字段）
  String? currentModelName;

  /// 当前正在累积的 tool calls
  final List<ToolCallData> accumulatedToolCalls = [];

  /// 当前流式响应对应的分支索引（由 sendMessage/regenerate 设置）
  int currentBranchIndex = 0;

  /// 当前流式响应对应的用户消息（用于错误持久化时创建助手错误消息）
  ChatMessage? currentUserMessage;

  /// 防止 finishStreaming 重入（StreamEnd + onDone 可能都触发）
  bool isFinishing = false;

  /// 后台流式生成模式：用户切换到其他分支查看时，流式生成继续在后台进行
  bool isViewingOtherBranch = false;

  /// 后台流式生成的助手消息（用户查看其他分支时使用）
  ChatMessage? backgroundAssistantMessage;

  /// 生成分支的锚点用户消息 ID（用于判断用户是否切换回生成分支）
  String? generatingAnchorUserMsgId;

  ///  思考标签增量维护：累计 raw 内容是否出现过 '<'。
  ///
  /// false 时 parseThinkingTags(raw) 恒为 (null, raw)——跳过全量重扫，
  /// 直接把 delta 追加进正文即可（每 delta O(len(delta)) 而非 O(全长)）。
  /// 一旦出现 '<'（可能是 <think> 起始）置 true，此后维持全量解析语义。
  bool sawThinkBracket = false;

  /// 重置所有流式状态
  void reset() {
    thinkingStartTime = null;
    streamStartTime = null;
    firstTokenLatency = null;
    currentModelName = null;
    accumulatedToolCalls.clear();
    currentBranchIndex = 0;
    currentUserMessage = null;
    isFinishing = false;
    isViewingOtherBranch = false;
    backgroundAssistantMessage = null;
    generatingAnchorUserMsgId = null;
    sawThinkBracket = false;
  }
}

/// 流式响应处理器
///
/// 从 ChatModeController 中抽离的流式响应处理职责，包括：
/// - SSE 事件分发（TextDelta、ThinkingDelta、ToolCallComplete、StreamEnd、StreamError）
/// - 文本增量处理（含思考标签解析）
/// - 思考增量处理
/// - 工具调用完成处理
/// - 后台模式消息缓冲
///
/// 通过回调接口通知 Controller 状态变化，保持 Controller 对 state 的控制权。
class StreamHandler {
  StreamHandler({
    required Uuid uuid,
    required this.onStateUpdated,
    required this.onBackgroundMessageUpdated,
    required this.onFinishStreaming,
    Duration? deltaCoalesceInterval,
  })  : _uuid = uuid,
        _deltaCoalesceInterval =
            // lm-motion-exempt: 流式增量合并间隔（吞吐调参，非过渡动效）
            deltaCoalesceInterval ?? const Duration(milliseconds: 32);

  final Uuid _uuid;

  ///  合帧间隔：生产 32ms（≈30fps）；测试注入 Duration.zero 可让每个
  /// delta 即时落地（旧语义），避免零延迟轮询等不到真实定时器。
  final Duration _deltaCoalesceInterval;

  /// 流式状态
  final StreamState state = StreamState();

  // ──  流式节流（32ms 合帧）───────────────────────────────────────────
  //
  // SSE 逐 delta 触发 onStateUpdated → 整个消息列表重建 + Markdown 重解析，
  // 高频小 delta 下一个显示帧内重建多次。文本/思考增量经
  // ThrottledDeltaBuffer 合帧后再应用（网络解析与首字延迟统计不受影响）。
  ThrottledDeltaBuffer? _textBuffer;
  ThrottledDeltaBuffer? _thinkingBuffer;

  /// 合帧 flush 时复用的最近一次调用参数（消息列表/当前助手消息 id
  /// 随 delta 到达而演进，flush 取最新即可）。
  List<ChatMessage>? _latestMessages;
  String? _latestAssistantId;
  ChatMessage? _latestUserMessage;

  /// 状态更新回调
  ///
  /// 参数：
  /// - `messages`：更新后的消息列表（正常模式下）
  /// - `currentAssistantMessageId`：当前助手消息 ID
  /// - `isThinking`：是否正在思考
  final void Function({
    List<ChatMessage>? messages,
    String? currentAssistantMessageId,
    bool? isThinking,
    bool? isViewingOtherBranch,
    String? generatingAnchorUserMsgId,
  }) onStateUpdated;

  /// 后台消息更新回调
  final void Function(ChatMessage? backgroundMessage)
      onBackgroundMessageUpdated;

  /// 流式完成回调
  ///
  /// 参数：
  /// - `usage`：LLM usage 数据
  /// - `isBackground`：是否为后台模式完成
  /// - `finalMessage`：完成后的最终消息（正常模式下来自 messages，后台模式下来自 backgroundAssistantMessage）
  final Future<void> Function({
    required bool isBackground,
    LlmUsage? usage,
    ChatMessage? finalMessage,
  }) onFinishStreaming;

  /// 初始化流式请求
  void initStream({
    required ChatMessage userMessage,
    required int branchIndex,
    required String? modelName,
  }) {
    state.thinkingStartTime = null;
    state.accumulatedToolCalls.clear();
    state.currentBranchIndex = branchIndex;
    state.currentUserMessage = userMessage;
    state.generatingAnchorUserMsgId = userMessage.messageId;
    state.streamStartTime = DateTime.now();
    state.firstTokenLatency = null;
    state.currentModelName = modelName;
    state.isFinishing = false;
    state.sawThinkBracket = false;
    // 换轮重建合帧缓冲（旧缓冲若有尾段先冲刷丢弃——本轮是新流）
    _textBuffer?.flushAndDispose();
    _thinkingBuffer?.flushAndDispose();
    _textBuffer = null;
    _thinkingBuffer = null;
    _latestMessages = null;
    _latestAssistantId = null;
    _latestUserMessage = null;
  }

  /// 冲刷全部合帧缓冲（流终点/进后台/用户停止前调用，尾段不丢）。
  ///
  /// 公开给控制器：停止生成（cancelSending）与卡死恢复（recoverIfStuck）
  /// 在落库半截回复 / 清理状态前必须先冲刷，否则待合帧的增量滞留缓冲。
  void flushPendingDeltas() {
    _textBuffer?.flushAndDispose();
    _thinkingBuffer?.flushAndDispose();
  }

  /// 处理文本增量
  void handleTextDelta(
    String delta,
    ChatMessage userMessage, {
    List<ChatMessage>? currentMessages,
    String? currentAssistantMessageId,
  }) {
    // 首字延迟记录（对标 ChatBox）：首次收到文本时计算从请求开始的耗时
    if (state.firstTokenLatency == null && state.streamStartTime != null) {
      state.firstTokenLatency =
          DateTime.now().difference(state.streamStartTime!).inMilliseconds;
    }

    // 后台模式：更新后台缓冲区，不更新 state.messages（低频特殊态，不合帧）
    if (state.isViewingOtherBranch) {
      _updateBackgroundMessage(delta, userMessage);
      return;
    }

    // 32ms 合帧后应用（首字延迟已在上方即时记录）
    _latestUserMessage = userMessage;
    _latestMessages = currentMessages;
    _latestAssistantId = currentAssistantMessageId;
    _textBuffer ??= ThrottledDeltaBuffer(
      _applyTextDelta,
      interval: _deltaCoalesceInterval,
    );
    _textBuffer!.add(delta);
  }

  /// 应用合帧后的文本增量（原 handleTextDelta 主体）
  void _applyTextDelta(String delta) {
    final userMessage = _latestUserMessage;
    if (userMessage == null) return;
    final messages = List<ChatMessage>.from(_latestMessages ?? const []);
    ChatMessage? assistantMessage;

    if (_latestAssistantId != null) {
      final index = messages.indexWhere(
        (m) => m.messageId == _latestAssistantId,
      );
      if (index != -1) {
        assistantMessage = messages[index];
      }
    }

    // 写回最新列表/消息 id：finishStreaming 等后续步骤须基于冲刷后的状态
    _latestMessages = messages;

    if (assistantMessage != null) {
      // 追加增量到现有消息
      final existing = assistantMessage;
      final rawContent = (existing.content ?? '') + delta;

      //  思考标签增量维护：累计内容从未出现 '<' 时 parseThinkingTags
      // 恒为 (null, raw)，跳过全量重扫直接走快速路径
      final (thinking, display) = _splitThinking(rawContent, delta);

      // 如果检测到思考内容，更新 isThinking 状态
      final nowThinking = thinking != null && display.isEmpty;

      // 计算思考耗时
      int? thinkingDuration;
      if (thinking != null && !nowThinking && state.thinkingStartTime != null) {
        thinkingDuration =
            DateTime.now().difference(state.thinkingStartTime!).inSeconds;
      }
      if (thinking != null && state.thinkingStartTime == null) {
        state.thinkingStartTime = DateTime.now();
      }

      // 只有检测到 <think> 标签时才更新 thinkingContent，
      // 避免覆盖 handleThinkingDelta 通过 reasoning_content 累积的思考内容。
      // （DeepSeek-R1 等模型使用 reasoning_content 字段发送思考内容，
      // 后续 content delta 不含 <think> 标签，thinking 为 null，
      // 若传 null 会覆盖已累积的 thinkingContent，导致流式结束后思考过程消失）
      final updatedMessage = thinking != null
          ? existing.copyWith(
              content: display.isEmpty ? null : display,
              thinkingContent: thinking,
              thinkingDuration: thinkingDuration,
            )
          : existing.copyWith(
              content: display,
            );
      final idx = messages.indexWhere(
        (m) => m.messageId == existing.messageId,
      );
      if (idx != -1) messages[idx] = updatedMessage;

      onStateUpdated(
        messages: messages,
        isThinking: nowThinking,
      );
    } else {
      // 创建新的助手消息
      final (thinking, display) = _splitThinking(delta, delta);

      final nowThinking = thinking != null && display.isEmpty;
      if (thinking != null) state.thinkingStartTime = DateTime.now();

      assistantMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: userMessage.sessionId,
        role: 'assistant',
        content: display.isEmpty && thinking != null ? null : display,
        thinkingContent: thinking,
        parentUserMsgId: userMessage.messageId,
        branchIndex: state.currentBranchIndex,
        createdAt: DateTime.now(),
        modelName: state.currentModelName,
      );
      messages.add(assistantMessage);
      _latestMessages = messages;
      _latestAssistantId = assistantMessage.messageId;
      onStateUpdated(
        messages: messages,
        currentAssistantMessageId: assistantMessage.messageId,
        isThinking: nowThinking,
      );
    }
  }

  /// 思考标签拆分的增量维护
  ///
  /// [delta] 是本次新到达的增量（用于探测 '<'）。累计 raw 从未出现 '<'
  /// 时直接返回 (null, raw)——与全量 parseThinkingTags 结果恒等，
  /// 但把每 delta 的 O(全长) 重扫降为 O(增量)。
  (String?, String) _splitThinking(String raw, String delta) {
    if (!state.sawThinkBracket && !delta.contains('<')) {
      return (null, raw);
    }
    state.sawThinkBracket = true;
    return ChatMessageUtils.parseThinkingTags(raw);
  }

  /// 更新后台缓冲区的助手消息（用户查看其他分支时使用）
  void _updateBackgroundMessage(String delta, ChatMessage userMessage) {
    final existing = state.backgroundAssistantMessage;

    if (existing != null) {
      // 追加增量到现有后台消息
      final rawContent = (existing.content ?? '') + delta;
      final (thinking, display) =
          ChatMessageUtils.parseThinkingTags(rawContent);
      final nowThinking = thinking != null && display.isEmpty;

      int? thinkingDuration;
      if (thinking != null && !nowThinking && state.thinkingStartTime != null) {
        thinkingDuration =
            DateTime.now().difference(state.thinkingStartTime!).inSeconds;
      }
      if (thinking != null && state.thinkingStartTime == null) {
        state.thinkingStartTime = DateTime.now();
      }

      // 只有检测到 <think> 标签时才更新 thinkingContent（同 handleTextDelta 修复）
      if (thinking != null) {
        state.backgroundAssistantMessage = existing.copyWith(
          content: display.isEmpty ? null : display,
          thinkingContent: thinking,
          thinkingDuration: thinkingDuration,
        );
      } else {
        state.backgroundAssistantMessage = existing.copyWith(
          content: display,
        );
      }
      onBackgroundMessageUpdated(state.backgroundAssistantMessage);
    } else {
      // 创建新的后台消息
      final (thinking, display) = ChatMessageUtils.parseThinkingTags(delta);
      if (thinking != null) state.thinkingStartTime = DateTime.now();

      state.backgroundAssistantMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: userMessage.sessionId,
        role: 'assistant',
        content: display.isEmpty && thinking != null ? null : display,
        thinkingContent: thinking,
        parentUserMsgId: userMessage.messageId,
        branchIndex: state.currentBranchIndex,
        createdAt: DateTime.now(),
        modelName: state.currentModelName,
      );
      onBackgroundMessageUpdated(state.backgroundAssistantMessage);
    }
  }

  /// 处理思考/推理内容增量（DeepSeek V4 的 reasoning_content、o-series 的 reasoning）
  ///
  /// 同步写入两个字段：
  /// - [ChatMessage.thinkingContent]：用于 UI 展示思考过程
  /// - [ChatMessage.reasoningContent]：原始 reasoning_content/reasoning 文本，
  ///   用于 tool call 场景跨轮回传给 API（DOC-12 §5.4.2）
  ///
  /// 注意：`<think>` 标签解析（DeepSeek-R1）走 [handleTextDelta]，不会写入
  /// reasoningContent，因此 R1 不会误传 reasoning_content 字段。
  void handleThinkingDelta(
    String delta,
    ChatMessage userMessage, {
    List<ChatMessage>? currentMessages,
    String? currentAssistantMessageId,
  }) {
    // 后台模式：更新后台缓冲区的思考内容（低频特殊态，不合帧）
    if (state.isViewingOtherBranch) {
      _updateBackgroundThinking(delta, userMessage);
      return;
    }

    // 32ms 合帧后应用
    _latestUserMessage = userMessage;
    _latestMessages = currentMessages;
    _latestAssistantId = currentAssistantMessageId;
    _thinkingBuffer ??= ThrottledDeltaBuffer(
      _applyThinkingDelta,
      interval: _deltaCoalesceInterval,
    );
    _thinkingBuffer!.add(delta);
  }

  /// 应用合帧后的思考增量（原 handleThinkingDelta 正常模式主体）
  void _applyThinkingDelta(String delta) {
    final userMessage = _latestUserMessage;
    if (userMessage == null) return;
    final messages = List<ChatMessage>.from(_latestMessages ?? const []);
    ChatMessage? assistantMessage;

    if (_latestAssistantId != null) {
      final index = messages.indexWhere(
        (m) => m.messageId == _latestAssistantId,
      );
      if (index != -1) {
        assistantMessage = messages[index];
      }
    }

    // 写回最新列表（同 _applyTextDelta）
    _latestMessages = messages;

    if (assistantMessage != null) {
      // 追加思考增量
      final existing = assistantMessage;
      final existingThinking = existing.thinkingContent ?? '';
      final existingReasoning = existing.reasoningContent ?? '';
      final updatedMessage = existing.copyWith(
        thinkingContent: existingThinking + delta,
        reasoningContent: existingReasoning + delta,
      );
      final idx = messages.indexWhere(
        (m) => m.messageId == existing.messageId,
      );
      if (idx != -1) messages[idx] = updatedMessage;
      onStateUpdated(messages: messages, isThinking: true);
    } else {
      // 收到思考内容但还没有助手消息 — 先创建
      state.thinkingStartTime = DateTime.now();
      assistantMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: userMessage.sessionId,
        role: 'assistant',
        thinkingContent: delta,
        reasoningContent: delta,
        parentUserMsgId: userMessage.messageId,
        branchIndex: state.currentBranchIndex,
        createdAt: DateTime.now(),
        modelName: state.currentModelName,
      );
      messages.add(assistantMessage);
      _latestAssistantId = assistantMessage.messageId;
      onStateUpdated(
        messages: messages,
        currentAssistantMessageId: assistantMessage.messageId,
        isThinking: true,
      );
    }
  }

  /// 后台模式的思考增量（原 handleThinkingDelta 后台分支，不合帧直通）
  void _updateBackgroundThinking(String delta, ChatMessage userMessage) {
    final existing = state.backgroundAssistantMessage;
    if (existing != null) {
      final existingThinking = existing.thinkingContent ?? '';
      final existingReasoning = existing.reasoningContent ?? '';
      state.backgroundAssistantMessage = existing.copyWith(
        thinkingContent: existingThinking + delta,
        reasoningContent: existingReasoning + delta,
      );
      onBackgroundMessageUpdated(state.backgroundAssistantMessage);
    } else {
      // 收到思考内容但还没有后台消息 — 先创建
      state.thinkingStartTime = DateTime.now();
      state.backgroundAssistantMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: userMessage.sessionId,
        role: 'assistant',
        thinkingContent: delta,
        reasoningContent: delta,
        parentUserMsgId: userMessage.messageId,
        branchIndex: state.currentBranchIndex,
        createdAt: DateTime.now(),
        modelName: state.currentModelName,
      );
      onBackgroundMessageUpdated(state.backgroundAssistantMessage);
    }
  }

  /// 处理 ToolCallComplete 事件
  void handleToolCallComplete(
    LlmToolCallComplete event,
    ChatMessage userMessage, {
    List<ChatMessage>? currentMessages,
    String? currentAssistantMessageId,
  }) {
    // 累积 tool call 数据
    // 注意：LlmToolCallComplete.arguments 是 Map<String, dynamic>，
    // ToolCallData.arguments 是 JSON 字符串，需要 jsonEncode 转换
    state.accumulatedToolCalls.add(
      ToolCallData(
        id: event.toolCallId,
        name: event.name,
        arguments: jsonEncode(event.arguments),
      ),
    );

    // 后台模式：更新后台缓冲区的 toolCalls 字段
    if (state.isViewingOtherBranch) {
      final existing = state.backgroundAssistantMessage;
      if (existing != null) {
        final toolCallsJson =
            ChatMessageUtils.encodeToolCalls(state.accumulatedToolCalls);
        state.backgroundAssistantMessage =
            existing.copyWith(toolCalls: toolCallsJson);
        onBackgroundMessageUpdated(state.backgroundAssistantMessage);
      }
      return;
    }

    // 更新当前助手消息的 toolCalls 字段
    final messages = List<ChatMessage>.from(currentMessages ?? const []);
    if (currentAssistantMessageId != null) {
      final index = messages.indexWhere(
        (m) => m.messageId == currentAssistantMessageId,
      );
      if (index != -1) {
        final toolCallsJson =
            ChatMessageUtils.encodeToolCalls(state.accumulatedToolCalls);
        messages[index] = messages[index].copyWith(toolCalls: toolCallsJson);
        // 与文本/思考增量同源写回（finishStreaming 取最新列表）
        _latestMessages = messages;
        onStateUpdated(messages: messages);
      }
    }
  }

  /// 完成流式响应
  ///
  /// 后台模式时：将 backgroundAssistantMessage 传递给回调入库
  /// 正常模式时：更新 messages 中的助手消息元数据并传递给回调入库
  ///
  /// CH-1：零 delta 的「干净空响应」（模型只发 done / 流
  /// onDone 无事件）同样必须回调 [onFinishStreaming]（finalMessage 为
  /// null 表示无产物，Controller 据此只清 busy 态）——此前两处早退不
  /// 回调，会话永久卡 isStreaming=true，UI 假死只能手动停止自愈。
  Future<void> finishStreaming({
    LlmUsage? usage,
    List<ChatMessage>? currentMessages,
    String? currentAssistantMessageId,
  }) async {
    // 守卫：防止重复调用（StreamEnd + onDone 可能都触发）
    if (state.isFinishing) return;
    // 本轮流已收口（onDone 在完成/错误处理之后又触发了一次）或无进行中
    // 的流：静默返回。currentUserMessage 由 initStream 置位、在流收口
    // （完成回调后 / 错误处理）时清空，是「流仍打开」的判据。
    if (state.currentUserMessage == null) return;
    state.isFinishing = true;

    try {
      // 先冲贴合帧缓冲——尾段增量必须落进 messages 再做元数据收尾/入库。
      // 冲刷是同步的且可能创建占位消息（首个 delta 与流终点同窗到达的
      // 边界），因此下方的判空与定位都以冲刷后的有效 id 为准，入参
      // currentAssistantMessageId 可能仍是冲刷前的旧值（null）。
      flushPendingDeltas();
      final effectiveId = currentAssistantMessageId ?? _latestAssistantId;

      if (state.isViewingOtherBranch) {
        // 后台模式：将后台缓冲区入库
        final msg = state.backgroundAssistantMessage;
        if (msg == null) {
          // CH-1：后台零 delta 形态——回调收口（此前静默早退，卡 busy 态）
          state.isViewingOtherBranch = false;
          await onFinishStreaming(
            usage: usage,
            isBackground: true,
            finalMessage: null,
          );
          state.currentUserMessage = null;
          state.generatingAnchorUserMsgId = null;
          return;
        }

        // 计算最终思考耗时
        var thinkingDuration = msg.thinkingDuration;
        if (msg.thinkingContent != null && thinkingDuration == null) {
          thinkingDuration = state.thinkingStartTime != null
              ? DateTime.now().difference(state.thinkingStartTime!).inSeconds
              : null;
        }

        final firstTokenLatency = state.firstTokenLatency;
        final tokensUsed = usage?.totalTokens;

        // 更新后台消息的元数据
        final updatedMsg = (thinkingDuration != msg.thinkingDuration ||
                firstTokenLatency != null ||
                tokensUsed != null)
            ? msg.copyWith(
                thinkingDuration: thinkingDuration,
                firstTokenLatency: firstTokenLatency,
                tokensUsed: tokensUsed,
              )
            : msg;

        await onFinishStreaming(
          usage: usage,
          isBackground: true,
          finalMessage: updatedMsg,
        );

        // 清除后台模式状态
        state.backgroundAssistantMessage = null;
        state.isViewingOtherBranch = false;
      } else if (effectiveId == null) {
        // CH-1：零 delta 的干净空响应——回调收口清 busy 态
        await onFinishStreaming(
          usage: usage,
          isBackground: false,
          finalMessage: null,
        );
        state.currentUserMessage = null;
        state.generatingAnchorUserMsgId = null;
        return;
      } else {
        // 正常模式：更新 state.messages 中的助手消息并入库
        // 优先用冲刷后的最新列表（调用方传入的 currentMessages 在
        // flush 之前取的，可能缺尾段增量）
        final messages =
            List<ChatMessage>.from(_latestMessages ?? currentMessages ?? []);
        final index = messages.indexWhere((m) => m.messageId == effectiveId);
        if (index != -1) {
          final msg = messages[index];

          // 计算最终思考耗时（如仍在思考中）
          var thinkingDuration = msg.thinkingDuration;
          if (msg.thinkingContent != null && thinkingDuration == null) {
            thinkingDuration = state.thinkingStartTime != null
                ? DateTime.now().difference(state.thinkingStartTime!).inSeconds
                : null;
          }

          // 使用已记录的首字延迟
          final firstTokenLatency = state.firstTokenLatency;

          // 提取 tokens 使用量
          final tokensUsed = usage?.totalTokens;

          // 仅在有新数据时更新消息
          if (thinkingDuration != msg.thinkingDuration ||
              firstTokenLatency != null ||
              tokensUsed != null) {
            messages[index] = msg.copyWith(
              thinkingDuration: thinkingDuration,
              firstTokenLatency: firstTokenLatency,
              tokensUsed: tokensUsed,
            );
            onStateUpdated(messages: messages);
          }

          await onFinishStreaming(
            usage: usage,
            isBackground: false,
            finalMessage: messages[index],
          );
        } else {
          // CH-1：占位消息已不在列表（如流式中被删除）：无产物可入库，
          // 仍须回调收口，否则 busy 态无人清理
          await onFinishStreaming(
            usage: usage,
            isBackground: false,
            finalMessage: null,
          );
        }
      }

      // 清理状态
      state.currentUserMessage = null;
      state.generatingAnchorUserMsgId = null;
    } finally {
      state.isFinishing = false;
    }
  }

  /// 进入后台模式（用户切换到其他分支查看时调用）
  ///
  /// 将当前占位消息移到后台缓冲区，后续 SSE 事件更新后台缓冲区。
  void enterBackgroundMode({
    required List<ChatMessage> currentMessages,
    required String? currentAssistantMessageId,
  }) {
    if (state.isViewingOtherBranch) return;

    // 进后台前冲贴合帧缓冲——占位消息必须带上全部已到达增量
    flushPendingDeltas();

    // 将占位消息移到后台缓冲区
    if (currentAssistantMessageId != null) {
      final index = currentMessages.indexWhere(
        (m) => m.messageId == currentAssistantMessageId,
      );
      if (index != -1) {
        state.backgroundAssistantMessage = currentMessages[index];
      }
    }

    state.isViewingOtherBranch = true;
    onBackgroundMessageUpdated(state.backgroundAssistantMessage);
    // 注意：state 更新（currentAssistantMessageId=null 等）由 Controller 直接处理，
    // 避免回调中 null 值与 copyWith sentinel 的语义冲突。
  }

  /// 恢复后台缓冲区到 state.messages（用户切换回生成分支时调用）
  ///
  /// 返回恢复后的消息列表和助手消息 ID。
  ({List<ChatMessage> messages, String? assistantMessageId})
      restoreBackgroundToState({
    required List<ChatMessage> currentMessages,
    required String anchorUserMsgId,
  }) {
    final bgMessage = state.backgroundAssistantMessage;

    // 截断到锚点 + 恢复后台缓冲区消息
    final anchorIndex = currentMessages.indexWhere(
      (m) => m.messageId == anchorUserMsgId,
    );
    final truncated = anchorIndex >= 0
        ? currentMessages.sublist(0, anchorIndex + 1)
        : currentMessages;
    final updated = bgMessage != null ? [...truncated, bgMessage] : truncated;

    // 清除后台模式状态
    state.backgroundAssistantMessage = null;
    state.isViewingOtherBranch = false;

    return (messages: updated, assistantMessageId: bgMessage?.messageId);
  }
}
