import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/network/http_client.dart'
    show CancellationToken, CancelledException;
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/chat/domain/entities/simple_error_context.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/continue_context.dart';
import 'package:lmstory/features/chat/domain/services/fork_manager.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/domain/services/message_manager.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/features/chat/domain/services/stream_handler.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

// 重新导出 ForkSwitchDirection，保持 UI 层导入兼容
export 'package:lmstory/features/chat/domain/services/fork_manager.dart'
    show ForkSwitchDirection;

/// 手动压缩结果
///
/// [ChatModeController.compressHistory] 的返回值，供 UI 层决定后续交互（如弹标题更新对话框）。
enum CompressResult {
  /// 压缩正在进行中（防抖锁触发，未执行新请求）
  busy,

  /// 消息不足，无需压缩
  insufficient,

  /// 压缩失败（失败摘要消息已插入对话流，用户可重试或关闭）
  failed,

  /// 压缩成功（摘要消息已落库，token 用量已刷新）
  success,

  /// 用户取消——流已静默中止，占位摘要已清理，
  /// 不触发失败冷却也不算成功。
  cancelled,
}

/// ChatMode 状态
class ChatModeState {
  ChatModeState({
    required this.session,
    this.messages = const [],
    this.forkAnchors = const [],
    this.isSending = false,
    this.isStreaming = false,
    this.isThinking = false,
    this.isCompressing = false,
    this.isGeneratingInBackground = false,
    this.currentCompactionSummaryId,
    this.error,
    this.currentAssistantMessageId,
    this.generatingAnchorUserMsgId,
    this.quoteText,
    this.currentModelName,
    this.currentProviderName,
    this.contextWindowTokens,
    this.compactionTriggerTokens,
    // 加载期标志，防止首次打开会话闪现空态
    this.isLoading = true,
  });

  final ChatSession session;
  final List<ChatMessage> messages;

  /// 当前会话的所有 Fork 锚点（仅 branchCount > 1 的）
  final List<ForkAnchor> forkAnchors;
  final bool isSending;
  final bool isStreaming;
  final bool isThinking;

  /// 是否正在压缩上下文（防抖锁，压缩中禁用菜单项）
  final bool isCompressing;

  /// 流式生成是否进入后台分支模式——流式中
  /// switchFork 切看旧分支后，生成在生成分支后台继续（isStreaming 保持
  /// true、currentAssistantMessageId 为 null）。此前页面无法区分
  /// 「等首 token」与「后台生成中」，会在被查看分支尾部渲染误导性的
  /// 「生成中」占位气泡。置位/清除点：switchFork 置位；切回生成分支、
  /// 流完成/出错/停止/恢复、新一轮流开启均清除。
  final bool isGeneratingInBackground;

  /// 当前正在流式生成内容的摘要消息 ID（仅压缩进行中非 null）
  ///
  /// UI 层据此判定该条摘要消息需要展示流式状态：
  /// - 折叠态：标签行显示"正在生成摘要..." + 加载动画，下方小窗预览实时显示流式内容
  /// - 展开态：正常显示流式内容 + 末尾闪烁光标
  ///
  /// 压缩开始时设置，结束（成功/失败/异常）时清除。
  final String? currentCompactionSummaryId;

  final String? error;
  final String? currentAssistantMessageId;

  /// 当前流式生成对应的 Fork 锚点用户消息 ID（仅 regenerate/editAndResend 时非 null）
  ///
  /// 用于占位气泡关联到 Fork 锚点，使分支导航在生成过程中就显示。
  /// 流式完成/出错/切换分支时清除。
  final String? generatingAnchorUserMsgId;

  /// 引用文本（对标 ChatBox uiStore.quote），输入框监听并追加
  final String? quoteText;

  /// 当前解析出的模型显示名（会话级 > 全局默认，供输入框工具栏芯片展示）
  final String? currentModelName;

  /// 当前解析出的供应商显示名（会话级 > 第一个可用 preset）
  final String? currentProviderName;

  /// 当前模型的上下文窗口大小（token），用于输入框 token 计数警告阈值
  final int? contextWindowTokens;

  /// chat 压缩触发线 token（圆环满刻度口径）。
  ///
  /// 与 [CompactionService.shouldCompact] 同公式同值
  /// （availableWindow × compactionThreshold），随模型窗口与会话/全局
  /// 压缩阈值变化在 _resolveModelDisplayInfo 里刷新；窗口未知为 null
  /// （圆环画空轨道）。
  final int? compactionTriggerTokens;

  /// 历史消息是否仍在加载
  final bool isLoading;

  /// Sentinel object to distinguish "not provided" from "explicitly null"
  /// in copyWith for nullable fields.
  static const _sentinel = Object();

  ChatModeState copyWith({
    ChatSession? session,
    List<ChatMessage>? messages,
    List<ForkAnchor>? forkAnchors,
    bool? isSending,
    bool? isStreaming,
    bool? isThinking,
    bool? isCompressing,
    bool? isGeneratingInBackground,
    Object? currentCompactionSummaryId = _sentinel,
    Object? error = _sentinel,
    Object? currentAssistantMessageId = _sentinel,
    Object? generatingAnchorUserMsgId = _sentinel,
    Object? quoteText = _sentinel,
    Object? currentModelName = _sentinel,
    Object? currentProviderName = _sentinel,
    Object? contextWindowTokens = _sentinel,
    Object? compactionTriggerTokens = _sentinel,
    bool? isLoading,
  }) {
    return ChatModeState(
      session: session ?? this.session,
      messages: messages ?? this.messages,
      forkAnchors: forkAnchors ?? this.forkAnchors,
      isSending: isSending ?? this.isSending,
      isStreaming: isStreaming ?? this.isStreaming,
      isThinking: isThinking ?? this.isThinking,
      isCompressing: isCompressing ?? this.isCompressing,
      isGeneratingInBackground:
          isGeneratingInBackground ?? this.isGeneratingInBackground,
      currentCompactionSummaryId:
          identical(currentCompactionSummaryId, _sentinel)
              ? this.currentCompactionSummaryId
              : currentCompactionSummaryId as String?,
      error: identical(error, _sentinel) ? this.error : error as String?,
      currentAssistantMessageId: identical(currentAssistantMessageId, _sentinel)
          ? this.currentAssistantMessageId
          : currentAssistantMessageId as String?,
      generatingAnchorUserMsgId: identical(generatingAnchorUserMsgId, _sentinel)
          ? this.generatingAnchorUserMsgId
          : generatingAnchorUserMsgId as String?,
      quoteText: identical(quoteText, _sentinel)
          ? this.quoteText
          : quoteText as String?,
      currentModelName: identical(currentModelName, _sentinel)
          ? this.currentModelName
          : currentModelName as String?,
      currentProviderName: identical(currentProviderName, _sentinel)
          ? this.currentProviderName
          : currentProviderName as String?,
      contextWindowTokens: identical(contextWindowTokens, _sentinel)
          ? this.contextWindowTokens
          : contextWindowTokens as int?,
      compactionTriggerTokens: identical(compactionTriggerTokens, _sentinel)
          ? this.compactionTriggerTokens
          : compactionTriggerTokens as int?,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// ChatMode 控制器
///
/// 处理 Simple 模式下的聊天逻辑，包括：
/// - 消息发送与接收
/// - SSE 流式响应处理
/// - 取消发送和重新生成
/// - 消息持久化
///
/// 重构后职责分离：
/// - [ConfigurationResolver]：配置解析（模型信息、会话设置、命名配置）
/// - [MessageManager]：消息管理（加载、持久化、删除、编辑）
/// - [StreamHandler]：流式响应处理（SSE 事件分发、消息构建）
/// - [ForkManager]：Fork 分支管理（重新生成、编辑重发、分支切换、回滚）
/// - [ChatModeController]：编排协调，管理 state
class ChatModeController extends StateNotifier<ChatModeState> {
  ChatModeController({
    required ChatRepository chatRepository,
    required ApiPresetRepository presetRepository,
    required SettingsRepository settingsRepository,
    required CompactionService compactionService,
    required LlmService llmService,
    required Logger logger,
    required FailureLogRepository failureLogRepository,
    required ChatSession session,
    Duration? streamDeltaCoalesceInterval,
  })  : _chatRepository = chatRepository,
        _presetRepository = presetRepository,
        _settingsRepository = settingsRepository,
        _compactionService = compactionService,
        _llmService = llmService,
        _logger = logger,
        _failureLogRepository = failureLogRepository,
        _classifier = const SimpleFailureClassifier(),
        _uuid = const Uuid(),
        super(ChatModeState(session: session)) {
    // 初始化服务类
    _configurationResolver = ConfigurationResolver(
      presetRepository: presetRepository,
      settingsRepository: settingsRepository,
      logger: logger,
    );
    _messageManager = MessageManager(
      chatRepository: chatRepository,
      logger: logger,
    );
    _forkManager = ForkManager(
      chatRepository: chatRepository,
      logger: logger,
    );
    _streamHandler = StreamHandler(
      uuid: _uuid,
      onStateUpdated: _onStreamStateUpdated,
      onBackgroundMessageUpdated: _onBackgroundMessageUpdated,
      onFinishStreaming: _onFinishStreaming,
      //  流式节流：生产默认 32ms 合帧；测试可注入 Duration.zero
      deltaCoalesceInterval: streamDeltaCoalesceInterval,
    );

    _loadMessages();
    _resolveModelDisplayInfo();
  }

  // ==================== 依赖 ====================

  final ChatRepository _chatRepository;
  final ApiPresetRepository _presetRepository;
  final SettingsRepository _settingsRepository;
  final CompactionService _compactionService;
  final LlmService _llmService;
  final Logger _logger;
  final Uuid _uuid;

  //  诊断包：失败日志仓储 + Simple 模式失败分类器
  final FailureLogRepository _failureLogRepository;
  final SimpleFailureClassifier _classifier;

  // ==================== 服务类 ====================
  late final ConfigurationResolver _configurationResolver;
  late final MessageManager _messageManager;
  late final ForkManager _forkManager;
  late final StreamHandler _streamHandler;

  // ==================== 流式请求状态 ====================

  CancellationToken? _currentCancelToken;
  StreamSubscription<LlmStreamEvent>? _currentSubscription;
  String? _cachedApiKey;

  /// 后台中断标志（App 切到后台时设置）
  ///
  /// `onBackgroundInterrupt` 时设为 true。`recoverIfStuck` 检查此标志：
  /// 即使 `_handleStreamError` 尚未完成（isStreaming 仍为 true），也能检测到
  /// 后台中断并恢复。发送新消息时重置为 false。
  bool _backgroundInterrupted = false;

  /// 强制命名在途标志（updateTitleFromSummary force
  /// 重入去抖——按钮连点只跑一次请求）。
  bool _titleNamingInFlight = false;

  /// 手动压缩的在途取消令牌（null=无压缩进行）
  CancellationToken? _compactionCancelToken;

  // ==================== 压缩失败冷却 ====================

  /// 最近一次自动压缩失败的时间（null 表示最近无失败或已成功恢复）。
  ///
  /// 用于避免 402（配额耗尽）/ 网络错误等场景下，自动压缩在每条消息发送时
  /// 重复触发导致的连续报错。冷却期内 [sendMessage] 的自动压缩被跳过，
  /// 用户仍可通过 [compressHistory] 手动重试。手动压缩不受冷却约束。
  DateTime? _lastCompactionFailureTime;

  /// 自动压缩失败后的冷却时长。
  ///
  /// 60 秒足以让用户感知到失败摘要卡片并决定下一步（修复 API Key / 手动重试 / 切换会话），
  /// 同时避免短时间内连续打 LLM API 浪费配额。
  static const _compactionFailureCooldown = Duration(seconds: 60);

  // ==================== StreamHandler 回调 ====================

  /// StreamHandler 状态更新回调
  ///
  /// 注意：`currentAssistantMessageId` 和 `generatingAnchorUserMsgId` 为 null 时
  /// 表示"不修改"，不会传递给 copyWith（避免 sentinel 语义冲突）。
  /// 需要设为 null 时由 Controller 直接处理。
  void _onStreamStateUpdated({
    List<ChatMessage>? messages,
    String? currentAssistantMessageId,
    bool? isThinking,
    bool? isViewingOtherBranch,
    String? generatingAnchorUserMsgId,
  }) {
    // 仅在非 null 时传递给 copyWith，避免将字段误设为 null
    if (currentAssistantMessageId != null) {
      state = state.copyWith(
        messages: messages,
        currentAssistantMessageId: currentAssistantMessageId,
        isThinking: isThinking,
      );
    } else {
      state = state.copyWith(
        messages: messages,
        isThinking: isThinking,
      );
    }
  }

  /// StreamHandler 后台消息更新回调
  void _onBackgroundMessageUpdated(ChatMessage? backgroundMessage) {
    // 后台消息存储在 StreamHandler 内部，无需更新 state
  }

  /// StreamHandler 流式完成回调
  Future<void> _onFinishStreaming({
    required bool isBackground,
    LlmUsage? usage,
    ChatMessage? finalMessage,
  }) async {
    // （接写合并）：续写完成——新内容追加进被续写消息
    // （单气泡 + 「已中断·续写」徽标），流式占位气泡不入库不入列表。
    // CH-5：后台分支完成的续写同样走接写合并——被续写的
    // 半截消息此刻随生成分支进了快照，在快照内按 messageId 合并，
    // 不再落独立新消息（两气泡形态回退）。
    final continuationTarget = _continuationTarget;
    if (continuationTarget != null) {
      _continuationTarget = null;
      final continuation = finalMessage?.content ?? '';
      if (continuation.isNotEmpty) {
        if (isBackground) {
          await _appendContinuationInBackgroundBranch(
            target: continuationTarget,
            continuation: continuation,
            finalMessage: finalMessage,
          );
          await _refreshForkAnchors();
        } else {
          // CH-7：续写 usage 随合并落库（null 时 SQL 端保留旧值），
          // 重进会话后上下文用量显示不回退
          await _chatRepository.appendContinuation(
            continuationTarget.messageId,
            continuation,
            tokensUsed: finalMessage?.tokensUsed,
          );
          final messages = state.messages
              .where((m) => m.messageId != finalMessage!.messageId)
              .toList();
          final index = messages.indexWhere(
            (m) => m.messageId == continuationTarget.messageId,
          );
          if (index != -1) {
            messages[index] = messages[index].copyWith(
              content: (messages[index].content ?? '') + continuation,
              isContinued: true,
              tokensUsed:
                  finalMessage!.tokensUsed ?? messages[index].tokensUsed,
            );
          }
          state = state.copyWith(messages: messages);
        }
      } else if (!isBackground && finalMessage != null) {
        // CH-6：空/纯思考续写不留幽灵气泡——占位消息从未入库，
        // 直接从列表移除（后台形态占位不在列表，无需处理）
        state = state.copyWith(
          messages: state.messages
              .where((m) => m.messageId != finalMessage.messageId)
              .toList(),
        );
      }
      // 占位消息从未入库：无消息数/锚点变更（后台形态快照已因合并变化，
      // 上方已刷新锚点）
      _forkManager.clearPendingRollback();
      await _currentSubscription?.cancel();
      _currentSubscription = null;
      _currentCancelToken = null;
      state = state.copyWith(
        isStreaming: false,
        isThinking: false,
        currentAssistantMessageId: null,
        generatingAnchorUserMsgId: null,
        isGeneratingInBackground: false,
      );
      unawaited(_autoNameSession());
      return;
    }

    if (isBackground) {
      // 后台模式：产物消息属于生成分支（此刻非活跃），走快照追加
      //（：此前直接 addMessage 落在当前查看分支的表尾，会被后续
      // 切分支/删除误并入当前分支快照，造成跨分支污染）
      if (finalMessage != null) {
        await _persistBackgroundBranchMessage(finalMessage);
      }
      await _refreshForkAnchors();
    } else {
      // 正常模式：持久化助手消息
      if (finalMessage != null) {
        await _messageManager.persistAssistantMessage(finalMessage);
        await _updateMessageCount();
      }
      await _refreshForkAnchors();
    }

    // 清除 Fork 回滚信息（流式成功完成，无需回滚）
    _forkManager.clearPendingRollback();

    await _currentSubscription?.cancel();
    _currentSubscription = null;
    _currentCancelToken = null;

    state = state.copyWith(
      isStreaming: false,
      isThinking: false,
      currentAssistantMessageId: null,
      generatingAnchorUserMsgId: null,
      // 后台/前台完成均收口清除（防陈旧 true 吞掉下一轮占位气泡）
      isGeneratingInBackground: false,
    );

    // 自动命名会话（异步执行，不阻塞 UI）
    unawaited(_autoNameSession());
  }

  /// CH-5：续写在后台分支完成的接写合并
  ///
  /// 被续写的半截消息随生成分支存在快照中（活跃表内无此行，普通
  /// appendContinuation 的 UPDATE 会 0 行命中）——本方法把续写段并入
  /// 快照内该消息（内容拼接 + is_continued 徽标 + tokensUsed）。
  /// 快照失配（嵌套锚点/锚点行缺失等边缘）时回退旧的独立消息落库
  /// （[_persistBackgroundBranchMessage] 口径，保数据不丢）。
  Future<void> _appendContinuationInBackgroundBranch({
    required ChatMessage target,
    required String continuation,
    required ChatMessage? finalMessage,
  }) async {
    final genAnchor = _streamHandler.state.generatingAnchorUserMsgId;
    final genBranch = _streamHandler.state.currentBranchIndex;
    var merged = false;
    try {
      if (genAnchor != null && genAnchor.isNotEmpty && genBranch >= 0) {
        merged = await _chatRepository.appendContinuationToBranchSnapshot(
          sessionId: state.session.sessionId,
          anchorUserMsgId: genAnchor,
          branchIndex: genBranch,
          messageId: target.messageId,
          continuation: continuation,
          tokensUsed: finalMessage?.tokensUsed,
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to append continuation to branch snapshot',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (!merged && finalMessage != null) {
      await _persistBackgroundBranchMessage(finalMessage);
    }
  }

  // ==================== 消息加载与初始化 ====================

  /// 加载会话消息
  ///
  /// 对标 ChatBox getAllMessageList：UI 显示全部消息（含已被 CompactionPoint
  /// 压缩的旧消息），摘要横幅按 createdAt 自然插入消息流。
  /// API 请求时的过滤在 _buildMessagesForApi 中通过 getCompressedMessages 完成。
  Future<void> _loadMessages() async {
    try {
      final result =
          await _messageManager.loadMessages(state.session.sessionId);
      state = state.copyWith(
        messages: result.messages,
        forkAnchors: result.anchors,
        isLoading: false,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load messages',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      final context = await _recordError(
        error: e,
        overrideCategory: SimpleFailureClassifier.persist,
      );
      state = state.copyWith(
        isLoading: false,
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
    }
    // chat 会话惰性物化——置于消息载入完成后（物化
    // await 链前置会翻转与 sendMessage 的竞态窗口（实测），三模式统一）
    await _materializeSnapshotColumnsIfNeeded();
  }

  /// 刷新 Fork 锚点（快照模型下消息无需过滤）
  Future<void> _refreshForkAnchors() async {
    final anchors =
        await _messageManager.refreshForkAnchors(state.session.sessionId);
    state = state.copyWith(forkAnchors: anchors);
  }

  /// 解析当前会话的模型显示信息（供应商名、模型名、上下文窗口）
  ///
  /// 同场解析压缩触发线（圆环满刻度）——与
  /// [CompactionService.shouldCompact] 同公式同值；压缩阈值走会话级 >
  /// broadcastChat 全局默认的既有解析链。
  Future<void> _resolveModelDisplayInfo() async {
    final displayInfo = await _configurationResolver.resolveModelDisplayInfo(
      state.session,
    );
    final settings = await _resolveSettings();
    state = state.copyWith(
      currentModelName: displayInfo.modelName,
      currentProviderName: displayInfo.providerName,
      contextWindowTokens: displayInfo.contextWindowTokens,
      compactionTriggerTokens: CompactionService.compactionTriggerTokens(
        contextWindow: displayInfo.contextWindowTokens,
        threshold: settings.compactionThreshold,
      ),
    );
  }

  // ==================== 会话管理 ====================

  /// 更新会话设置（对标 ChatBox updateSession）
  ///
  /// 由会话设置面板调用，持久化更新后的 [ChatSession] 并同步到 state。
  /// 下一轮发送时 [_resolveSettings] 会读取新的会话级设置。
  ///
  /// **草稿会话物化触发**（用户需求 2026-07-22）：
  /// "会话成立的标志是发第一条消息或会话配置变更"。
  /// 草稿期间首次修改配置时立即物化为真实会话，物化时快照所有字段
  /// （不只 modelId/presetId），实现"快照而非引用"语义。
  Future<void> updateSession(ChatSession updated) async {
    if (isDraftSession) {
      // 草稿会话期间首次修改配置 → 触发物化
      await _materializeDraftSessionWith(updated);
      return;
    }
    final saved = await _chatRepository.updateSession(updated);
    state = state.copyWith(session: saved);
    // 会话级模型/供应商可能变更，重新解析显示信息
    await _resolveModelDisplayInfo();
  }

  /// 侧边栏重命名后同步主区标题
  ///
  /// 新标题已由侧边栏持久化，此处只回填内存态展示字段：主区标题读
  /// state.session 值拷贝，而 ChatSession == 只看 sessionId，替换导航栈
  /// 值不会重建 provider，不同步则标题停留旧名。不重复写库。
  void applyExternalTitle(String title) {
    state = state.copyWith(session: state.session.copyWith(title: title));
  }

  /// 草稿会话的 sessionId 前缀。
  /// 草稿会话不存入数据库，仅在用户发送第一条消息或首次修改配置时才创建真实会话。
  static const draftSessionIdPrefix = '__draft_';

  /// 判断当前会话是否为草稿会话（未入库的临时会话）
  bool get isDraftSession =>
      state.session.sessionId.startsWith(draftSessionIdPrefix);

  /// 将草稿会话转为真实会话（入库）。
  ///
  /// 在用户发送第一条消息时调用（[sendMessage]）。
  /// 委托给 [_materializeDraftSessionWith]，使用当前 state.session 作为草稿。
  Future<void> _materializeDraftSession() async {
    await _materializeDraftSessionWith(state.session);
  }

  /// chat 存量会话配置列 NULL → 全局当前
  /// 快照（一次性惰性物化）。
  ///
  /// 快照化之前建立的会话配置列可能未物化（null=跟随态）。打开时复制
  /// 全局当前值写回；全列有值时零写入。例外（不进判定）：systemPrompt
  /// （全局源=内置常量非配置，null=内置默认）与 maxContextMessages
  /// （null=无限制）为具体态；reasoningEffort 为模型语义 carve-out。
  /// maxTokens 的全局未配置按  归一写 0（无上限哨兵）。
  /// 仅 chat 会话（故事/导演由各自路径处置）。失败静默（resolver 回退兜底）。
  Future<void> _materializeSnapshotColumnsIfNeeded() async {
    if (isDraftSession) return;
    if (state.session.mode != 'chat') return;
    final session = state.session;
    final needsMaterialize = session.presetId == null ||
        session.modelId == null ||
        session.temperature == null ||
        session.topP == null ||
        session.maxTokens == null ||
        session.presencePenalty == null ||
        session.frequencyPenalty == null ||
        session.streamEnabled == null ||
        session.autoCompaction == null ||
        session.compactionThreshold == null;
    if (!needsMaterialize) return;
    try {
      final snapshot = await _configurationResolver.snapshotSimpleDefaults();
      // await 期间用户可能已编辑会话列
      // （极速打开设置改模型）——重取最新会话为合并基线，物化只填充
      // 仍为 null 的列，防止用「开头捕获的旧 null 基线」覆盖用户刚写的值。
      final current = state.session;
      final updated = current.copyWith(
        presetId: current.presetId ?? snapshot.presetId,
        modelId: current.modelId ?? snapshot.modelId,
        temperature: current.temperature ?? snapshot.temperature,
        topP: current.topP ?? snapshot.topP,
        maxTokens: current.maxTokens ?? (snapshot.maxTokens ?? 0),
        presencePenalty: current.presencePenalty ?? snapshot.presencePenalty,
        frequencyPenalty: current.frequencyPenalty ?? snapshot.frequencyPenalty,
        streamEnabled: current.streamEnabled ?? snapshot.streamEnabled,
        autoCompaction: current.autoCompaction ?? snapshot.autoCompaction,
        compactionThreshold:
            current.compactionThreshold ?? snapshot.compactionThreshold,
      );
      final persisted = await _chatRepository.updateSession(updated);
      state = state.copyWith(session: persisted);
      _logger.info(
        'Legacy chat session snapshot materialized',
        detail: 'sessionId=${current.sessionId}',
      );
    } catch (e) {
      _logger.warn(
        'Legacy chat session snapshot materialization skipped',
        detail: '$e',
      );
    }
  }

  /// 将草稿会话转为真实会话（入库），并应用 [updated] 配置。
  ///
  /// 触发时机（用户需求 2026-07-22）：
  /// 1. 发送第一条消息时（[sendMessage] → [_materializeDraftSession]）
  /// 2. 草稿期间首次修改会话配置时（[updateSession]）
  ///
  /// 物化时快照所有字段（不只 modelId/presetId）：
  /// - 草稿值非 null → 使用草稿值（保留用户在生成阶段所做的修改）
  /// - 草稿值为 null → 使用全局默认快照值（"快照而非引用"语义：
  ///   后续全局配置变更不影响此会话）
  ///
  /// **快照语义说明**：用户需求"如果使用的是全局设置的值，使用这一刻的值，
  /// 而不是全局设置那一项的引用"。本方法在物化时刻调用
  /// [ConfigurationResolver.snapshotSimpleDefaults] 读取当前全局默认的具体值，
  /// 写入会话级字段。后续用户修改全局配置不会影响已物化的会话。
  Future<void> _materializeDraftSessionWith(ChatSession updated) async {
    final draft = updated;
    final realSession = await _chatRepository.createSession(
      title: draft.title,
      mode: draft.mode,
      modelId: draft.modelId,
      presetId: draft.presetId,
    );

    // 快照当前全局默认值（"快照而非引用"语义）
    final snapshot = await _configurationResolver.snapshotSimpleDefaults();

    // 合并：草稿值 > 全局快照值
    final sessionWithDefaults = realSession.copyWith(
      modelId: draft.modelId ?? snapshot.modelId,
      presetId: draft.presetId ?? snapshot.presetId,
      systemPromptOverride: draft.systemPromptOverride ?? snapshot.systemPrompt,
      temperature: draft.temperature ?? snapshot.temperature,
      topP: draft.topP ?? snapshot.topP,
      maxTokens: draft.maxTokens ?? snapshot.maxTokens,
      presencePenalty: draft.presencePenalty ?? snapshot.presencePenalty,
      frequencyPenalty: draft.frequencyPenalty ?? snapshot.frequencyPenalty,
      autoCompaction: draft.autoCompaction ?? snapshot.autoCompaction,
      compactionThreshold:
          draft.compactionThreshold ?? snapshot.compactionThreshold,
      streamEnabled: draft.streamEnabled ?? snapshot.streamEnabled,
      maxContextMessages:
          draft.maxContextMessages ?? snapshot.maxContextMessages,
      reasoningEffort: draft.reasoningEffort ?? snapshot.reasoningEffort,
    );

    final persisted = await _chatRepository.updateSession(sessionWithDefaults);
    state = state.copyWith(session: persisted);
    // 会话级模型/供应商可能变更，重新解析显示信息
    await _resolveModelDisplayInfo();
  }

  // ==================== 消息发送 ====================

  /// 草稿会话发送预检：的
  /// 「先验配置再物化」逻辑抽为公开方法——输入区在清空输入**之前**调用，
  /// 返回 false 时错误横幅已落、输入原地保留（此前先清空再拒绝，长文
  /// 输入与附件蒸发不可恢复）。非草稿会话恒通过。
  Future<bool> precheckDraftSend() async {
    if (!isDraftSession) return true;
    final preSettings = await _resolveSettings();
    final preApiKey = _cachedApiKey;
    if (preSettings.presetId.isEmpty ||
        preSettings.modelId.isEmpty ||
        preApiKey == null ||
        preApiKey.isEmpty) {
      final context = await _recordError(
        overrideCategory: SimpleFailureClassifier.config,
      );
      state = state.copyWith(
        isSending: false,
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
      return false;
    }
    return true;
  }

  /// 发送消息
  ///
  /// 流程（对标 ChatBox submitNewUserMessage）：
  /// 1. 草稿会话检查：若为草稿，先创建真实会话并替换 state.session
  /// 2. 自动压缩检查（阻塞式，在用户消息插入前触发）
  /// 3. 创建并插入用户消息
  /// 4. 调用 API 生成回复
  ///
  /// 压缩在用户消息前触发，确保摘要横幅显示在用户消息之前，
  /// 顺序为：摘要 → 用户消息 → AI回复。
  Future<void> sendMessage(
    String content, {
    List<MessageAttachment>? attachments,
  }) async {
    if (state.isSending) return;
    //  修复：自动压缩进行中不允许发送——压缩与生成并发
    // 会引发 _loadMessages 刷新与消息序抖动（此前只查 isSending）。
    if (state.isCompressing) return;

    state = state.copyWith(isSending: true, error: null);

    try {
      // 草稿场景先验配置再物化——无预设/模型/Key
      // 时不再创建真实会话并落库用户消息，否则新手反复尝试会累积一串
      // 空「新对话」。真实会话保持原行为（错误由 _sendToApi 全口径处理）。
      // （：逻辑抽为 precheckDraftSend，输入区发送前先行调用。）
      if (!await precheckDraftSend()) {
        return;
      }

      // 草稿会话检查：首次发送消息时创建真实会话
      if (isDraftSession) {
        await _materializeDraftSession();
      }

      // 自动压缩检查（对标 ChatBox：在用户消息插入前阻塞式压缩）
      // 复用流式压缩路径，UI 会展示摘要横幅的流式生成过程
      //
      // 刷新模型显示信息，确保 contextWindowTokens 反映最新的模型元数据
      // （修复用户在模型管理页修改 contextWindow 后当前会话不刷新的问题）
      await _resolveModelDisplayInfo();
      final settings = await _resolveSettings();
      if (settings.autoCompaction) {
        // 冷却检查：最近一次自动压缩失败后 60 秒内不再触发，避免 402 配额耗尽
        // 或网络异常场景下每条消息重复打 LLM API 造成连续报错。
        // 用户仍可通过手动压缩按钮（compressHistory）绕过冷却主动重试。
        final lastFailure = _lastCompactionFailureTime;
        final inCooldown = lastFailure != null &&
            DateTime.now().difference(lastFailure) < _compactionFailureCooldown;
        if (inCooldown) {
          _logger.warn(
            'Auto-compaction skipped: recent failure within cooldown',
            detail:
                'Last failure at $lastFailure, cooldown ${_compactionFailureCooldown.inSeconds}s',
          );
        } else {
          // 获取过滤后的当前上下文消息（对标 ChatBox buildContextForSession）
          final effectiveMessages =
              await _compactionService.getCompressedMessages(
            state.session.sessionId,
          );
          // 仅在非摘要消息 >= 2 条时考虑压缩（与 _compressHistoryCore 内部校验一致）
          if (effectiveMessages.where((m) => !m.isSummary).length >= 2) {
            final shouldCompact = await _compactionService.shouldCompact(
              messages: effectiveMessages,
              threshold: settings.compactionThreshold,
              contextWindow: state.contextWindowTokens,
            );
            if (shouldCompact) {
              // 复用流式压缩核心逻辑：占位摘要 → 流式生成 → 落库
              // 错误由 _compressHistoryCore 内部处理（通过 onError 回调更新占位摘要），
              // 不阻断消息发送，用户消息会正常插入并发送给 LLM
              await _compressHistoryCore();
            }
          }
        }
      }

      // 若存在引用文本，格式化为 markdown 引用块拼接到用户输入前
      final quote = state.quoteText;
      var actualContent = content;
      if (quote != null && quote.isNotEmpty) {
        final quotedBlock =
            quote.split('\n').map((line) => '> $line').join('\n');
        actualContent = '$quotedBlock\n\n$content';
      }

      final userMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: state.session.sessionId,
        role: 'user',
        content: actualContent,
        attachments: attachments,
        createdAt: DateTime.now(),
      );

      await _chatRepository.addMessage(userMessage);
      await _chatRepository.updateSessionLastActive(state.session.sessionId);

      final messages = List<ChatMessage>.from(state.messages)..add(userMessage);
      state = state.copyWith(
        messages: messages,
        isSending: false,
        isStreaming: true,
        // 新一轮流开启=前台形态（防上一轮残留的后台标志吞掉占位气泡）
        isGeneratingInBackground: false,
        quoteText: null, // 发送后清除引用
      );

      await _sendToApi(userMessage);
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to send message',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      final context = await _recordError(error: e);
      state = state.copyWith(
        isSending: false,
        isStreaming: false,
        isGeneratingInBackground: false,
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
    }
  }

  /// 发送到 API
  ///
  /// [branchIndex] 为本次生成的助手消息所属分支索引。
  Future<void> _sendToApi(
    ChatMessage userMessage, {
    int branchIndex = 0,
    ChatMessage? continueFrom,
  }) async {
    // 续写目标一次定值（普通发送/重生成/编辑重发不传 → null 清空）
    _continuationTarget = continueFrom;
    _currentCancelToken = CancellationToken();
    _backgroundInterrupted = false;
    _streamHandler.initStream(
      userMessage: userMessage,
      branchIndex: branchIndex,
      modelName: null, // 在下方解析后设置
    );

    try {
      final settings = await _resolveSettings();

      // 无预设时提前报错（S001 config）
      if (settings.presetId.isEmpty) {
        final context = await _recordError(
          overrideCategory: SimpleFailureClassifier.config,
        );
        final display = _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        );
        await _persistErrorToMessage(display);
        _finalizeStream();
        return;
      }

      // 无模型时提前报错（S001 config）
      if (settings.modelId.isEmpty) {
        final context = await _recordError(
          overrideCategory: SimpleFailureClassifier.config,
        );
        final display = _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        );
        await _persistErrorToMessage(display);
        _finalizeStream();
        return;
      }

      // 无 API Key 时提前报错（S001 config）
      if (_cachedApiKey == null || _cachedApiKey!.isEmpty) {
        final context = await _recordError(
          overrideCategory: SimpleFailureClassifier.config,
        );
        final display = _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        );
        await _persistErrorToMessage(display);
        _finalizeStream();
        return;
      }

      // 注意：自动压缩已在 sendMessage 开头执行（对标 ChatBox 阻塞式压缩），
      // 此处不再重复检查。

      final preset = await _presetRepository.getPreset(settings.presetId);

      // 解析模型显示名（用于写入消息的 modelName 字段）
      _streamHandler.state.currentModelName = _configurationResolver
          .resolveModelDisplayName(preset, settings.modelId);

      // 读取用户配置的超时时间（对标 ChatBox，用户可在通用设置中调整）
      final resolvedConfig = await _settingsRepository.getResolvedConfig();
      final connectTimeout = resolvedConfig.network.connectTimeout;
      final readTimeout = resolvedConfig.network.receiveTimeout;

      // 构造统一 LlmRequest 并通过 LlmService 发起流式请求
      //
      // 2026-07-28 重构：Simple 模式从手动拼 OpenAI Map + SseParser 直连，
      // 迁移到 LlmService → LlmAdapterFactory → LlmProtocolAdapter 统一链路。
      // 收益：
      // - 思考参数（reasoningEffort）由适配器层按 modelId 路由 6 套厂商原生格式
      // - 自动支持 Anthropic/Gemini/OpenAI Responses 协议（按 preset.protocol 分发）
      // - providerOptions 透传（高级用户手动配置协议特有参数）
      // - 与中级模式共用 LlmService，消除 Simple 模式的协议适配技术债
      // 详见 DOC-03 §7.3（LlmService 收口目标）。
      final request = LlmRequest(
        baseUrl: preset.baseUrl,
        apiKey: _cachedApiKey,
        modelId: settings.modelId,
        messages: await _buildMessagesForApi(
          settings.systemPrompt,
          maxContextMessages: settings.maxContextMessages,
          continueFrom: continueFrom,
        ),
        temperature: settings.temperature,
        topP: settings.topP,
        maxTokens: settings.maxTokens,
        stream: settings.streamEnabled,
        // 请求 usage 数据（对标 ChatBox），用于在消息下方显示 tokens 使用量
        includeUsage: settings.streamEnabled,
        // 无条件传递 reasoningEffort：许多 API 供应商（如 NVIDIA NIM）不返回
        // capabilities 字段，由适配器层按 modelId 路由原生格式（含 null/disabled
        // 返回空 Map），不在 Controller 层硬拦截
        reasoningEffort: settings.reasoningEffort,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        cancelToken: _currentCancelToken,
      );

      _currentSubscription = _llmService.streamChat(request).listen(
        (event) {
          _handleLlmStreamEvent(event, userMessage);
        },
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamError(error, stackTrace);
        },
        onDone: _finishStreaming,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'API request failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      // 持久化错误到助手消息（保留新分支显示错误，不回滚）
      final context = await _recordError(error: e);
      final display = _classifier.formatPersisted(
        context.errorCategory,
        context.errorCode,
      );
      await _persistErrorToMessage(display);
      _forkManager.clearPendingRollback();
      _finalizeStream();
    }
  }

  // ==================== LLM 流式事件处理（委托给 StreamHandler） ====================

  /// 处理 LlmStreamEvent
  Future<void> _handleLlmStreamEvent(
    LlmStreamEvent event,
    ChatMessage userMessage,
  ) async {
    if (event is LlmTextDelta) {
      _streamHandler.handleTextDelta(
        event.content,
        userMessage,
        currentMessages: state.messages,
        currentAssistantMessageId: state.currentAssistantMessageId,
      );
    } else if (event is LlmThinkingDelta) {
      _streamHandler.handleThinkingDelta(
        event.content,
        userMessage,
        currentMessages: state.messages,
        currentAssistantMessageId: state.currentAssistantMessageId,
      );
    } else if (event is LlmToolCallComplete) {
      _streamHandler.handleToolCallComplete(
        event,
        userMessage,
        currentMessages: state.messages,
        currentAssistantMessageId: state.currentAssistantMessageId,
      );
    } else if (event is LlmStreamDone) {
      await _finishStreaming(usage: event.usage);
    } else if (event is LlmStreamError) {
      // 错误路径先冲刷 32ms 合帧缓冲——否则落库的
      // 半截/错误卡比屏幕少最后 ≤32ms 增量，且迟到 timer 会在清态后继续
      // 改写内存消息列表（与 cancelSending/recoverIfStuck 同款收口）
      _streamHandler.flushPendingDeltas();
      _logger.warn(
        'LLM stream error',
        detail: '${event.code}: ${event.message}',
      );
      // 2026-07-29 修复：之前硬编码 overrideCategory: network，导致 400 参数
      // 验证错误等也被分类为 S002 network。改为构造异常对象传给 error 参数，
      // 让 classifyError 从错误信息中解析 HTTP 状态码并按语义分类：
      // - 400/4xx → config（S001，参数验证错误）
      // - 401/403 → auth（S003）
      // - 429 → rateLimit（S004）
      // - 5xx → server（S005）
      // - 无状态码 → network（S002，真正的网络连接问题）
      final streamError = Exception('${event.code}: ${event.message}');
      final context = await _recordError(
        error: streamError,
        overrideRawError: '${event.code}: ${event.message}',
      );
      final display = _classifier.formatPersisted(
        context.errorCategory,
        context.errorCode,
        rawError: context.rawError,
      );
      await _persistErrorToMessage(display);
      // currentUserMessage 置空标记本轮流已收口（错误事件后流还会
      // onDone，finishStreaming 据此静默返回，不再二次投递完成回调）
      _forkManager.clearPendingRollback();
      _finalizeStream();
    }
  }

  /// 流终点统一清态 helper。
  ///
  /// 收口 _sendToApi 三早退/catch 落库、LlmStreamError、_handleStreamError
  /// 两分支共七个「离开流式生命周期」的开口——此前各开口逐字段手写
  /// 清理，新增标志位时漏一即残留（CH10-N2 的 isThinking 即此类回归）。
  /// 统一清：流处理器影子态、busy/思考/当前助手锚点/后台生成标志。
  /// [clearError] 供取消路径显式清空既有 error（copyWith 为 sentinel
  /// 模式，显式传 null 才清空）。
  ///
  /// 不并入（各路径口径不同，留在调用点）：错误持久化；Fork 处理
  /// （取消=回滚、错误=清计划、早退=不动）；`_continuationTarget`
  /// （fire-and-forget 的 persist 尾巴仍会消费，早清会截断续写快照归属）；
  /// 订阅与令牌强清理（cancelSending/recoverIfStuck 的超集路径不经此）。
  void _finalizeStream({bool clearError = false}) {
    _streamHandler.state.isViewingOtherBranch = false;
    _streamHandler.state.backgroundAssistantMessage = null;
    _streamHandler.state.currentUserMessage = null;
    _streamHandler.state.generatingAnchorUserMsgId = null;
    state = state.copyWith(
      isStreaming: false,
      isThinking: false,
      currentAssistantMessageId: null,
      generatingAnchorUserMsgId: null,
      isGeneratingInBackground: false,
      error: clearError ? null : state.error,
    );
  }

  /// 完成流式响应
  Future<void> _finishStreaming({LlmUsage? usage}) async {
    await _streamHandler.finishStreaming(
      usage: usage,
      currentMessages: state.messages,
      currentAssistantMessageId: state.currentAssistantMessageId,
    );
  }

  /// 处理流错误
  Future<void> _handleStreamError(Object error, StackTrace stackTrace) async {
    // 错误路径先冲刷合帧缓冲（同 LlmStreamError 分支口径）
    _streamHandler.flushPendingDeltas();
    _logger.error(
      'Stream error',
      detail: '$error',
      error: error,
      stackTrace: stackTrace,
    );
    if (error is CancelledException) {
      // 用户主动取消（后台中断等令牌取消路径）：回滚 Fork 操作（恢复旧
      // 分支），不持久化错误。半截回复先落库（：与用户主动停止
      // 同口径，部分内容不再随刷新丢失）；Fork 回滚场景跳过（分支将被
      // 回滚，落库会孤儿）。
      final isForkRollback = _forkManager.pendingForkRollback != null;
      if (!isForkRollback) {
        _persistPartialAssistantMessage();
        // 后台分支形态的半截内容同样落库（此前随缓冲清空蒸发）
        _persistPartialBackgroundMessage();
      }
      // 续写目标兜底清空（无内容的续写停止已由 persist 消费或本就为空）
      _continuationTarget = null;
      await _rollbackForkIfNeeded();
      // 思考期流错误若不清 isThinking，假忙残留
      // 到下一轮首字——已由 _finalizeStream 统一收口。
      _finalizeStream(clearError: true);
    } else {
      // API 失败：持久化错误到助手消息，不回滚分支（保留新分支显示错误）
      // 续写失败回落旧的独立气泡形态（错误信息随占位消息落库）
      _continuationTarget = null;
      final context = await _recordError(error: error);
      final display = _classifier.formatPersisted(
        context.errorCategory,
        context.errorCode,
      );
      await _persistErrorToMessage(display);
      _forkManager.clearPendingRollback();
      _finalizeStream();
    }
  }

  // ==================== 错误处理（诊断包） ====================

  /// 构造 [SimpleErrorContext] 并写入 failure_logs 诊断表。
  ///
  /// 统一 Simple 模式的错误处理入口：
  /// - [error] 原始异常（可为 null，配置缺失等同步检查场景）。
  /// - [overrideCategory] 手动指定分类（如配置缺失强制 config、流错误强制 network）。
  /// - [overrideErrorCode] 手动指定错误码（一般由分类推导，无需手动传）。
  /// - [overrideRawError] 手动指定原始异常文本（无异常对象时携带上下文）。
  ///
  /// 日志写入失败由 [FailureLogRepository] 静默降级，不阻塞主流程。
  /// 返回的 [SimpleErrorContext] 供调用方生成用户可见提示（_classifier.formatDisplay）。
  Future<SimpleErrorContext> _recordError({
    Object? error,
    String? overrideCategory,
    String? overrideErrorCode,
    String? overrideRawError,
  }) async {
    String category;
    int? httpStatus;
    String? rawError;
    if (error != null) {
      final result = _classifier.classifyError(error);
      category = overrideCategory ?? result.category;
      httpStatus = result.httpStatus;
      rawError = overrideRawError ?? result.rawError;
    } else {
      category = overrideCategory ?? SimpleFailureClassifier.unknown;
      rawError = overrideRawError;
    }
    final errorCode =
        overrideErrorCode ?? _classifier.errorCodeFromCategory(category);
    final context = SimpleErrorContext(
      errorCode: errorCode,
      errorCategory: category,
      httpStatus: httpStatus,
      rawError: rawError,
    );

    // 持久化到 failure_logs（unawaited 不阻塞主流程；Repository 静默降级）
    unawaited(
      _failureLogRepository.insertLog(
        sessionId: state.session.sessionId,
        mode: ChatMode.chat,
        errorCategory: category,
        errorCode: errorCode,
        httpStatus: httpStatus,
        errorMessage: _classifier.resolveMessage(category),
        rawError: rawError,
      ),
    );

    return context;
  }

  // ==================== 消息持久化（委托给 MessageManager） ====================

  /// 持久化错误到助手消息（对标 ChatBox 错误持久化）
  ///
  /// 无论是否为 Fork 操作，都持久化错误到助手消息：
  /// - 已有助手消息（流式中途失败）：更新该消息的 error 字段
  /// - 无助手消息（首个 token 前失败）：创建带 error 的助手消息并入库
  ///
  /// 后台模式时：将错误持久化到后台缓冲区并入库。
  Future<void> _persistErrorToMessage(String errorText) async {
    // 后台模式：将错误持久化到后台缓冲区并入库
    if (_streamHandler.state.isViewingOtherBranch) {
      await _persistErrorToBackgroundMessage(errorText);
      return;
    }

    final result = await _messageManager.persistErrorToMessage(
      sessionId: state.session.sessionId,
      errorText: errorText,
      currentMessages: state.messages,
      currentAssistantMessageId: state.currentAssistantMessageId,
      parentUserMsgId: _streamHandler.state.currentUserMessage?.messageId,
      branchIndex: _streamHandler.state.currentBranchIndex,
      modelName: _streamHandler.state.currentModelName,
    );

    state = state.copyWith(messages: result.messages);
  }

  /// 持久化错误到后台缓冲区消息并入库
  Future<void> _persistErrorToBackgroundMessage(String errorText) async {
    final existing = _streamHandler.state.backgroundAssistantMessage;

    if (existing != null) {
      // 流式中途失败：更新后台消息的 error 字段
      _streamHandler.state.backgroundAssistantMessage =
          existing.copyWith(error: errorText);
      await _persistBackgroundBranchMessage(
        _streamHandler.state.backgroundAssistantMessage!,
      );
    } else {
      // 首个 token 前失败：创建带 error 的后台消息
      final errorMessage = ChatMessage(
        messageId: _uuid.v4(),
        sessionId: state.session.sessionId,
        role: 'assistant',
        error: errorText,
        parentUserMsgId: _streamHandler.state.currentUserMessage?.messageId,
        branchIndex: _streamHandler.state.currentBranchIndex,
        createdAt: DateTime.now(),
        modelName: _streamHandler.state.currentModelName,
      );
      _streamHandler.state.backgroundAssistantMessage = errorMessage;
      await _persistBackgroundBranchMessage(errorMessage);
    }

    // 刷新 Fork 锚点（生成分支快照已有错误消息）
    await _refreshForkAnchors();
  }

  /// 后台分支产物消息落库
  ///
  /// 后台模式（流式中切看其他分支）下产生的消息——完成稿/错误卡/停止时的
  /// 半截——属于生成分支，而该分支此刻以快照形式存在。优先写入该分支
  /// 快照尾部；无法定位（普通发送无锚点/嵌套锚点等边缘）时回退
  /// addMessage 保数据（与旧行为一致，至少不丢）。
  Future<void> _persistBackgroundBranchMessage(ChatMessage message) async {
    final genAnchor = _streamHandler.state.generatingAnchorUserMsgId;
    final genBranch = _streamHandler.state.currentBranchIndex;
    try {
      var stored = false;
      if (genAnchor != null && genAnchor.isNotEmpty && genBranch >= 0) {
        stored = await _chatRepository.appendMessageToBranchSnapshot(
          sessionId: state.session.sessionId,
          anchorUserMsgId: genAnchor,
          branchIndex: genBranch,
          message: message,
        );
        if (!stored) {
          _logger.warn(
            'Background branch snapshot not found, fallback to addMessage',
            detail: 'anchor=$genAnchor, branch=$genBranch',
          );
        }
      }
      if (!stored) {
        await _chatRepository.addMessage(message);
      }
      await _chatRepository.updateSessionLastActive(state.session.sessionId);
      await _updateMessageCount();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to persist background branch message',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 后台缓冲区的半截回复落库（停止/后台中断时调用）
  ///
  /// 后台模式下 `currentAssistantMessageId == null`，`_persistPartialAssistantMessage`
  /// 的早退使  的"停止不丢"承诺在该形态失效——半截内容随
  /// `state.reset()`/缓冲清空直接蒸发且无痕迹。本方法对后台缓冲区内容
  /// 补落库（走 [_persistBackgroundBranchMessage] 的快照归属语义）。
  ///
  /// 续写中的
  /// 后台停止与前台停止同构——半截内容原样并入被续写消息（分支快照
  /// 接写合并，见 [_appendContinuationInBackgroundBranch]），失配回退
  /// 独立落库。此前只独立落库，与前台停止的单气泡形态分裂（两气泡、
  /// 无「已中断·续写」徽标）。ChatBox 参照（G:/Projects/chatbox
  /// stores/session/generation.ts）：其续写本身即新消息、停止时半截
  /// 原样持久化——内核是「停止不丢内容」，与合并语义不冲突。
  void _persistPartialBackgroundMessage() {
    if (!_streamHandler.state.isViewingOtherBranch) return;
    final bg = _streamHandler.state.backgroundAssistantMessage;
    if (bg == null) return;
    final content = bg.content ?? '';
    final hasContent = content.isNotEmpty || bg.thinkingContent != null;
    if (!hasContent) return;
    final target = _continuationTarget;
    if (target != null && content.isNotEmpty) {
      _continuationTarget = null;
      unawaited(
        _appendContinuationInBackgroundBranch(
          target: target,
          continuation: content,
          finalMessage: bg,
        ),
      );
      return;
    }
    unawaited(_persistBackgroundBranchMessage(bg));
  }

  /// 更新消息计数
  Future<void> _updateMessageCount() async {
    final count =
        await _messageManager.updateMessageCount(state.session.sessionId);
    state = state.copyWith(
      session: state.session.copyWith(messageCount: count),
    );
  }

  // ==================== 取消发送 ====================

  /// 取消发送
  ///
  /// [persistPartial] 为 true 时（用户主动停止的正常发送流），已累积的
  /// 半截回复先落库再清状态——此前部分内容仅存内存，任何 _loadMessages
  /// （删消息/切分支/重开 App）即消失，且「继续生成」看不到半截内容，
  /// 实际退化为整篇重复生成。
  /// Fork 回滚场景（重新生成/编辑重发中停止）传 false：新分支将被回滚，
  /// 落库会造成孤儿消息。
  void cancelSending({bool persistPartial = true}) {
    //  流式节流：停止前先冲贴合帧缓冲——待合帧的尾段增量必须先落进
    // state.messages，半截回复落库才能取到完整内容
    _streamHandler.flushPendingDeltas();
    if (persistPartial) {
      _persistPartialAssistantMessage();
      // 后台模式下 currentAssistantMessageId==null，上面的方法
      // 早退——半截内容在 state.reset() 前补落库（快照归属语义）
      _persistPartialBackgroundMessage();
    }
    _currentCancelToken?.cancel();
    _currentSubscription?.cancel();
    _currentSubscription = null;
    _currentCancelToken = null;
    _streamHandler.state.reset();
    _cachedApiKey = null;

    state = state.copyWith(
      isStreaming: false,
      isSending: false,
      isThinking: false,
      currentAssistantMessageId: null,
      generatingAnchorUserMsgId: null,
      isGeneratingInBackground: false,
    );
  }

  /// 把流式中的半截回复落库（停止/中断时调用）
  ///
  /// 无累积内容（首 token 前）或消息不在列表中时静默跳过；
  /// 持久化失败仅记日志（与 persistAssistantMessage 同口径，不阻塞取消）。
  void _persistPartialAssistantMessage() {
    final id = state.currentAssistantMessageId;
    if (id == null) return;
    final index = state.messages.indexWhere((m) => m.messageId == id);
    if (index < 0) return;
    final partial = state.messages[index];
    final hasContent =
        (partial.content ?? '').isNotEmpty || partial.thinkingContent != null;
    if (!hasContent) return;

    // 续写中途停止——半截续写段同样并入被续写消息
    // （单气泡不破，内容不丢）；徽标随 appendContinuation 落库。
    final target = _continuationTarget;
    if (target != null && (partial.content ?? '').isNotEmpty) {
      _continuationTarget = null;
      final continuation = partial.content ?? '';
      unawaited(
        _chatRepository
            .appendContinuation(target.messageId, continuation)
            .then((_) {
          final messages =
              state.messages.where((m) => m.messageId != id).toList();
          final idx = messages.indexWhere(
            (m) => m.messageId == target.messageId,
          );
          if (idx != -1) {
            messages[idx] = messages[idx].copyWith(
              content: (messages[idx].content ?? '') + continuation,
              isContinued: true,
            );
          }
          state = state.copyWith(messages: messages);
        }).catchError((Object e) {
          _logger.error('Failed to append partial continuation', detail: '$e');
        }),
      );
      return;
    }

    unawaited(
      _messageManager
          .persistAssistantMessage(partial)
          .then((_) => _updateMessageCount())
          .catchError((Object e) {
        _logger.error('Failed to persist partial message', detail: '$e');
      }),
    );
  }

  /// App 切到后台时主动中断生成（由 `MainLayout._handleAppPaused` 调用）。
  ///
  /// 取消 SSE 令牌（同步），触发 `CancelledException` ->
  /// `_handleStreamError` 走 CancelledException 分支（不持久化错误、回滚 Fork）。
  ///
  /// 设置 `_backgroundInterrupted = true` 作为 `recoverIfStuck` 的安全网：
  /// 如果 resumed 时 `_handleStreamError` 尚未完成（async），isStreaming 仍为
  /// true，`recoverIfStuck` 通过此标志也能检测到并恢复。
  void onBackgroundInterrupt() {
    // 守卫：不在流式状态则无需中断，直接跳过
    if (!state.isStreaming) return;
    _backgroundInterrupted = true;
    _currentCancelToken?.cancel();
  }

  /// 检测并恢复卡死状态（App 从后台恢复时调用）。
  ///
  /// 场景：App 切后台时 OS 暂停网络 → readTimeout 误杀流 → 流死但
  /// isStreaming 仍为 true。切回前台时检测到 `_currentSubscription == null`
  /// 但 isStreaming=true → 清理到可发送状态。
  ///
  /// 返回 true 表示发生了恢复（调用方应提示用户"后台生成已中断"）。
  bool recoverIfStuck() {
    if (_backgroundInterrupted ||
        (state.isStreaming && _currentSubscription == null)) {
      _backgroundInterrupted = false;
      // 清理前先冲贴合帧缓冲（同 cancelSending）
      _streamHandler.flushPendingDeltas();
      // CH-2：前台半截回复与后台缓冲同口径补落库——
      // 移动端 paused→resume 时序下（事件循环冻结，CancelledException
      // 排队未投递），本方法先于 _handleStreamError 执行并 cancel 订阅
      // 压制了其落库路径，前台半截此前直接丢失。Fork 回滚挂起时跳过
      // （新分支将被回滚，落库会孤儿，与 _handleStreamError 同口径）。
      if (_forkManager.pendingForkRollback == null) {
        _persistPartialAssistantMessage();
        _persistPartialBackgroundMessage();
      }
      _continuationTarget = null;
      // CH-2：先取消订阅再清 controller 态——订阅 cancel 后未投递的
      // onError/onDone 不再触发 _handleStreamError 与下方清态竞态
      _currentCancelToken = null;
      _currentSubscription?.cancel();
      _currentSubscription = null;
      _cachedApiKey = null;
      // 与 cancelSending 同口径：重置流式状态（含后台模式标志，否则残留
      // 的 isViewingOtherBranch 会让下一轮 delta 误入后台缓冲）
      _streamHandler.state.reset();
      state = state.copyWith(
        isStreaming: false,
        isSending: false,
        isThinking: false,
        currentAssistantMessageId: null,
        generatingAnchorUserMsgId: null,
        isGeneratingInBackground: false,
      );
      return true;
    }
    return false;
  }

  /// 取消发送并回滚 Fork（用于用户主动终止重新生成/编辑重发的场景）
  ///
  /// 修复问题：用户在重新生成过程中点击终止时，旧回复已被物理删除（存为快照），
  /// 如果不回滚，分支记录会指向空的新分支，且分支导航按钮不刷新，
  /// 导致用户无法切换回旧回复。
  ///
  /// 此方法依次执行：
  /// 1. cancelSending() - 取消 HTTP 流和清理本地状态
  /// 2. _rollbackForkIfNeeded() - 回滚分支记录，从快照恢复旧分支消息
  /// 3. _refreshForkAnchors() - 刷新分支锚点，更新分支导航按钮
  Future<void> cancelSendingWithRollback() async {
    // 仅在真有 Fork 回滚挂起时（重新生成/
    // 编辑重发中停止）半截回复不落库——新分支将被撤销，落库会造成孤儿消息。
    // 正常发送/续写中停止必须落库（B' 承诺的"停止→半截气泡保留→继续生成
    // 接写"场景，此前被此处无条件 persistPartial:false 抵消，回归测试又只
    // 测了 cancelSending 直调路径而未覆盖 UI 接线）。
    final hasPendingRollback = _forkManager.pendingForkRollback != null;
    cancelSending(persistPartial: !hasPendingRollback);
    await _rollbackForkIfNeeded();
    await _refreshForkAnchors();
  }

  // ==================== Fork 操作（委托给 ForkManager） ====================

  /// 重新生成指定助手消息（在新分支中生成，旧分支保存为快照）
  ///
  /// 对标 ChatBox regenerateInNewFork：
  /// 1. 委托 ForkManager 创建新分支并保存旧分支快照
  /// 2. 截断消息列表到锚点用户消息
  /// 3. 发送 API 请求生成新回复
  Future<void> regenerateInNewFork(String assistantMessageId) async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;

    cancelSending();

    final result = await _forkManager.regenerateInNewFork(
      sessionId: state.session.sessionId,
      assistantMessageId: assistantMessageId,
      currentMessages: state.messages,
    );

    if (result == null) {
      state = state.copyWith(error: t.chat.failure.regenerateNoAnchor);
      return;
    }

    // 检查 Fork 是否在 await 期间被回滚（用户点了终止按钮）
    if (_forkManager.pendingForkRollback == null) return;

    // 立即刷新 Fork 锚点，让分支导航在生成过程中就显示（可切换到旧分支）
    await _refreshForkAnchors();

    // 再次检查：refreshForkAnchors 的 await 期间是否被回滚
    if (_forkManager.pendingForkRollback == null) return;

    state = state.copyWith(
      messages: result.truncatedMessages,
      isStreaming: true,
      // 新一轮流开启=前台形态
      isGeneratingInBackground: false,
      // 补锚点标识——占位气泡的分支导航（placeholderAnchor）依赖
      // 该字段，缺位使重生成过程中无法像编辑重发那样即时切看旧分支
      generatingAnchorUserMsgId: result.anchorUserMsgId,
      // 重开生成即清陈旧错误横幅（此前成功后仍驻留）
      error: null,
    );

    await _sendToApi(result.userMessage, branchIndex: result.newBranchIndex);
  }

  /// 续写接写合并：「继续生成」的目标半截消息。
  ///
  /// 非 null 时：API 上下文把半截+续写指令合并为单条（见
  /// [mergeContinueContext]）；流式完成后新内容追加进该消息（单气泡+
  /// 「已中断·续写」徽标），不再落独立气泡。生成中断/出错时回落旧的
  /// 独立气泡形态（半截内容照旧不丢）。
  ChatMessage? _continuationTarget;

  /// 继续生成（修复，2026-08-23； 接写合并）
  ///
  /// Wiki 承诺的「继续生成…接着写完」：不新增用户消息、不截断已有回复，
  /// 以最后一条用户消息为锚再发起一次生成。：挂到
  /// 锚点当前活跃分支（此前固定 branchIndex=0，有分支时续写流中切换分支
  /// 会被误判为"切回生成分支"，DB 活跃分支被错换、视图与库持续分歧）。
  /// 停止后的半截回复已落库（见 cancelSending），上下文从 DB 构建时自然
  /// 包含。
  ///
  /// 锚点后有半截 assistant 回复时走接写合并——API
  /// 上下文把半截+续写指令合并为单条，完成后新内容追加进被续写消息
  /// （单气泡+徽标）；无半截（如清空后）回落旧的两气泡形态。
  Future<void> continueGenerating() async {
    if (state.isSending || state.isCompressing || state.isStreaming) return;

    ChatMessage? anchor;
    var anchorIndex = -1;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].role == 'user') {
        anchor = state.messages[i];
        anchorIndex = i;
        break;
      }
    }
    if (anchor == null) return;

    // 锚点后最后一条非摘要、无错误的 assistant 消息即半截回复
    ChatMessage? half;
    for (var i = state.messages.length - 1; i > anchorIndex; i--) {
      final m = state.messages[i];
      if (m.role == 'assistant' &&
          !m.isSummary &&
          m.error == null &&
          (m.content ?? '').isNotEmpty) {
        half = m;
        break;
      }
    }

    final anchorEntry = state.forkAnchors
        .where((a) => a.parentUserMsgId == anchor!.messageId)
        .firstOrNull;
    final branchIndex = anchorEntry?.activeIndex ?? 0;

    // 新一轮流开启=前台形态（同 sendMessage）
    state = state.copyWith(
      isStreaming: true,
      isGeneratingInBackground: false,
      error: null,
    );
    await _sendToApi(anchor, branchIndex: branchIndex, continueFrom: half);
  }

  /// 编辑用户消息并重新发送（在新分支中生成）
  ///
  /// 对标 ChatBox 的 "Save & Resend"：
  /// 1. 委托 ForkManager 原地更新用户消息内容并创建新分支快照
  /// 2. 截断消息列表到编辑后的用户消息
  /// 3. 以编辑后的用户消息为上下文发送 API 请求
  Future<void> editAndResendInNewFork(
    String userMessageId,
    String newContent,
  ) async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;

    cancelSending();

    final result = await _forkManager.editAndResendInNewFork(
      sessionId: state.session.sessionId,
      userMessageId: userMessageId,
      newContent: newContent,
      currentMessages: state.messages,
    );

    if (result == null) {
      state = state.copyWith(error: t.chat.failure.editResendNotFound);
      return;
    }

    // 检查 Fork 是否在 await 期间被回滚（用户点了终止按钮）
    if (_forkManager.pendingForkRollback == null) return;

    // 立即刷新 Fork 锚点，让分支导航在生成过程中就显示（可切换到旧分支）
    await _refreshForkAnchors();

    // 再次检查：refreshForkAnchors 的 await 期间是否被回滚
    if (_forkManager.pendingForkRollback == null) return;

    state = state.copyWith(
      messages: result.truncatedMessages,
      isStreaming: true,
      // 新一轮流开启=前台形态（同 sendMessage）
      isGeneratingInBackground: false,
      generatingAnchorUserMsgId: userMessageId,
      // 重开生成即清陈旧错误横幅（此前成功后仍驻留）
      error: null,
    );

    await _sendToApi(result.userMessage, branchIndex: result.newBranchIndex);
  }

  /// 切换 Fork 分支（循环切换）
  ///
  /// 对标 ChatBox switchFork：在 prev/next 间循环切换。
  /// 快照模型：交换 DB 与快照中的消息。
  ///
  /// 流式生成期间切换分支：不取消生成，将占位消息移到后台缓冲区，
  /// 执行普通分支切换。后台生成继续在新分支上进行，完成后入库。
  /// 用户可随时切换回生成分支查看结果，生成完成时不强制切换。
  Future<void> switchFork(
    String anchorUserMsgId,
    ForkSwitchDirection direction,
  ) async {
    // 压缩窗口内禁止切换分支——快照交换会与
    // 正在流式落库的压缩 boundary/摘要交错，破坏  的压缩点一致性
    if (state.isCompressing) return;
    // 流式生成期间切换分支：进入后台模式
    if (state.isStreaming && !_streamHandler.state.isViewingOtherBranch) {
      _streamHandler.enterBackgroundMode(
        currentMessages: state.messages,
        currentAssistantMessageId: state.currentAssistantMessageId,
      );
      // 从 state.messages 移除占位消息
      final messages = state.messages
          .where((m) => m.messageId != state.currentAssistantMessageId)
          .toList();
      state = state.copyWith(
        messages: messages,
        currentAssistantMessageId: null,
        generatingAnchorUserMsgId: null,
        // 进入后台生成模式（占位气泡让位于轻量指示）
        isGeneratingInBackground: true,
      );
      // 继续执行普通分支切换逻辑（下方代码）
    }

    // 查找锚点并计算目标分支索引
    final anchor = state.forkAnchors.firstWhere(
      (a) => a.parentUserMsgId == anchorUserMsgId,
      orElse: () => const ForkAnchor(
        parentUserMsgId: '',
        activeIndex: 0,
        branchCount: 0,
      ),
    );
    if (anchor.parentUserMsgId.isEmpty) return;

    final total = anchor.branchCount;
    if (total == 0) return;
    final newIndex = direction == ForkSwitchDirection.next
        ? (anchor.activeIndex + 1) % total
        : (anchor.activeIndex - 1 + total) % total;

    // 后台模式：检查是否切换回生成分支
    if (_streamHandler.state.isViewingOtherBranch &&
        _streamHandler.state.generatingAnchorUserMsgId == anchorUserMsgId &&
        newIndex == _streamHandler.state.currentBranchIndex) {
      // 切换回生成分支：恢复后台缓冲区到 state.messages
      await _restoreBackgroundToState(anchorUserMsgId);
      return;
    }

    // 普通分支切换
    final newMessages = await _forkManager.switchFork(
      sessionId: state.session.sessionId,
      anchorUserMsgId: anchorUserMsgId,
      direction: direction,
      currentMessages: state.messages,
      forkAnchors: state.forkAnchors,
    );

    if (newMessages != null) {
      state = state.copyWith(messages: newMessages);
      await _refreshForkAnchors();
    }
  }

  /// 恢复后台缓冲区到 state.messages（用户切换回生成分支时调用）
  Future<void> _restoreBackgroundToState(String anchorUserMsgId) async {
    // 需要先切换 DB 到生成分支（交换快照）
    await _forkManager.switchToGeneratingBranch(
      sessionId: state.session.sessionId,
      anchorUserMsgId: anchorUserMsgId,
      branchIndex: _streamHandler.state.currentBranchIndex,
      currentMessages: state.messages,
    );

    // 恢复后台缓冲区到 state.messages
    final result = _streamHandler.restoreBackgroundToState(
      currentMessages: state.messages,
      anchorUserMsgId: anchorUserMsgId,
    );

    state = state.copyWith(
      messages: result.messages,
      currentAssistantMessageId: result.assistantMessageId,
      generatingAnchorUserMsgId: anchorUserMsgId,
      // 切回生成分支=恢复前台形态
      isGeneratingInBackground: false,
    );
    await _refreshForkAnchors();
  }

  /// 回滚 Fork 操作（API 失败时调用）
  Future<void> _rollbackForkIfNeeded() async {
    final success = await _forkManager.rollbackForkIfNeeded(
      state.session.sessionId,
    );
    if (success) {
      // 重新加载消息以恢复正确状态
      await _loadMessages();
    }
  }

  // ==================== 消息编辑与删除 ====================

  /// 删除消息（含分支记录维护）
  ///
  /// 快照模型下，删除助手消息会同时删除其尾部消息，
  /// 并通过 removeForkBranchWithSnapshot 维护分支记录。
  Future<void> deleteMessage(String messageId) async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;

    final result = await _messageManager.deleteMessage(
      sessionId: state.session.sessionId,
      messageId: messageId,
      currentMessages: state.messages,
      forkAnchors: state.forkAnchors,
    );

    if (result.needReload) {
      await _loadMessages();
      await _updateMessageCount();
    }
  }

  /// 删除摘要消息（对标 ChatBox removeMessage 删除 isSummary 消息）
  ///
  /// 删除摘要消息 + 关联的 CompactionPoint，使原始消息恢复到上下文中。
  /// 这是压缩操作的"反悔"机制：删除摘要后，被压缩的旧消息重新可见且参与上下文。
  Future<void> deleteSummary(String messageId) async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;

    final success = await _messageManager.deleteSummary(
      sessionId: state.session.sessionId,
      messageId: messageId,
    );

    if (success) {
      // 重新加载消息（原始消息恢复可见）
      await _loadMessages();
      await _updateMessageCount();
    } else {
      state = state.copyWith(error: t.chat.failure.deleteSummaryFailed);
    }
  }

  /// 编辑摘要内容（对标 ChatBox SummaryMessage handleEdit）
  ///
  /// 用户可手动修正摘要内容。仅更新消息文本，不影响 CompactionPoint。
  Future<void> editSummary(String messageId, String newContent) async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;

    final success = await _messageManager.editSummaryContent(
      messageId,
      newContent,
    );

    if (success) {
      await _loadMessages();
    } else {
      state = state.copyWith(error: t.chat.failure.editSummaryFailed);
    }
  }

  /// 引用消息（对标 ChatBox quote）
  ///
  /// 将被引用消息的原始内容存入 quoteText，输入框上方显示预览块。
  /// 发送时由 sendMessage 格式化为 markdown 引用块并拼接到用户输入前。
  void quoteMessage(String messageId) {
    final message = state.messages.firstWhere(
      (m) => m.messageId == messageId,
      orElse: () => ChatMessage(
        messageId: '',
        sessionId: '',
        role: 'user',
        createdAt: DateTime.now(),
      ),
    );
    if (message.messageId.isEmpty) return;

    final text = (message.content ?? '').trim();
    if (text.isEmpty) return;

    // 存储原始文本，预览块显示前 100 字符，发送时格式化为引用块
    state = state.copyWith(quoteText: text);
  }

  /// 清除引用文本（输入框消费后调用）
  void clearQuote() {
    state = state.copyWith(quoteText: null);
  }

  /// 手动清除错误横幅（横幅关闭按钮调用）
  ///
  /// 常规消失路径是下次 sendMessage 开头置 null；此方法供用户在不想
  /// 再发消息时主动关掉输入框上方的常驻报错横幅。
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 仅编辑消息内容（不重新发送，对标 ChatBox "Save"）
  ///
  /// 原地更新消息内容，不创建新分支。
  Future<void> editMessageContent(String messageId, String newContent) async {
    await _messageManager.editMessageContent(messageId, newContent);
    final messages = state.messages.map((m) {
      if (m.messageId == messageId) return m.copyWith(content: newContent);
      return m;
    }).toList();
    state = state.copyWith(messages: messages);
  }

  /// 重新生成最后一条助手消息（便捷方法，委托给 regenerateInNewFork）
  Future<void> regenerateLastResponse() async {
    if (state.messages.isEmpty) return;
    final lastAssistantIndex = state.messages.lastIndexWhere(
      (m) => m.role == 'assistant',
    );
    if (lastAssistantIndex == -1) return;
    await regenerateInNewFork(state.messages[lastAssistantIndex].messageId);
  }

  // ==================== 清空与压缩 ====================

  /// 清空当前会话的所有消息（对标 ChatBox Clear Messages）
  ///
  /// 完全重置所有内部状态，包括：
  /// - 取消正在进行的流式请求
  /// - 清除所有流式相关内部字段
  /// - 清空 state 中的消息、分支锚点、错误等
  Future<void> clearMessages() async {
    if (state.isSending || state.isStreaming || state.isCompressing) return;
    try {
      // 草稿会话未入库，跳过数据库操作
      if (!isDraftSession) {
        // DB 清空失败时 manager 吞掉
        // 异常只回 false——此前返回值被忽略，内存清空而库未动且零提示，
        // 重进会话消息「复活」。失败即中止内存重置并落持久化错误横幅。
        final cleared =
            await _messageManager.clearMessages(state.session.sessionId);
        if (!cleared) {
          final context = await _recordError(
            overrideCategory: SimpleFailureClassifier.persist,
          );
          state = state.copyWith(
            error: _classifier.formatPersisted(
              context.errorCategory,
              context.errorCode,
            ),
          );
          return;
        }
      }

      // 完全重置所有内部字段
      _currentCancelToken?.cancel();
      await _currentSubscription?.cancel();
      _currentSubscription = null;
      _currentCancelToken = null;
      _cachedApiKey = null;
      _streamHandler.state.reset();

      state = state.copyWith(
        messages: const [],
        forkAnchors: const [],
        error: null,
        isStreaming: false,
        isSending: false,
        isThinking: false,
        currentAssistantMessageId: null,
        generatingAnchorUserMsgId: null,
        isGeneratingInBackground: false,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to clear messages',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      final context = await _recordError(
        error: e,
        overrideCategory: SimpleFailureClassifier.persist,
      );
      state = state.copyWith(
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
    }
  }

  /// 手动压缩入口（对标 ChatBox 手动压缩按钮）。
  ///
  /// 仅做防抖锁检查和消息数量检查，实际压缩逻辑委托给 [_compressHistoryCore]，
  /// 与自动压缩复用同一条流式路径，确保 UI 展示一致的流式生成过程。
  ///
  /// 返回 [CompressResult]，UI 层据此决定是否弹标题更新对话框。
  Future<CompressResult> compressHistory() async {
    // 防抖锁：压缩中/发送中/流式中 直接返回
    if (state.isCompressing || state.isSending || state.isStreaming) {
      return CompressResult.busy;
    }
    if (state.messages.where((m) => !m.isSummary).length < 2) {
      return CompressResult.insufficient;
    }
    return _compressHistoryCore();
  }

  /// 流式压缩核心逻辑（无防抖锁，供手动压缩和自动压缩复用）。
  ///
  /// 自动压缩场景由 [sendMessage] 调用，此时 isSending=true 但无实际发送进行中，
  /// 故不检查防抖锁。手动压缩通过 [compressHistory] 进入，已检查防抖锁。
  ///
  /// 流程：
  /// 1. 创建占位摘要消息（content='', isSummary=true）→ UI 立即出现空摘要卡
  /// 2. 调 compactWithStream：
  ///    - onTextDelta: 累积 content → updateMessageContent → state 更新 → UI 流式打字
  ///    - onComplete: updateMessageTokensUsed + addCompactionPoint + _loadMessages
  ///    - onError: updateMessageError（保留已累积 content）+ _loadMessages → 失败卡片
  /// 3. 失败时不创建 CompactionPoint，故失败摘要不会被纳入下次上下文
  ///
  /// 副作用：维护 [_lastCompactionFailureTime] 冷却字段。
  /// - 失败（onError / 抛出异常）：记录失败时间，[sendMessage] 后续 60s 内跳过自动压缩
  /// - 成功：清空冷却字段，恢复正常自动压缩
  /// 手动压缩（[compressHistory] / [retryCompaction]）不受冷却约束，主动重试总是允许。
  Future<CompressResult> _compressHistoryCore() async {
    state = state.copyWith(
      isCompressing: true,
      error: null,
      currentCompactionSummaryId: null,
    );
    final sessionId = state.session.sessionId;
    // 本轮压缩的取消令牌（cancelCompaction 触发流中止）
    final cancelToken = CancellationToken();
    _compactionCancelToken = cancelToken;

    try {
      // 获取当前有效上下文（含旧摘要，对标 ChatBox）
      final effectiveMessages =
          await _compactionService.getCompressedMessages(sessionId);
      // boundary = 最后一条非摘要消息（对标 ChatBox lastNonSummaryMessage）
      final boundaryMessage = effectiveMessages.where((m) => !m.isSummary).last;

      // 创建占位摘要消息（content 空, isSummary true, error null）
      final placeholderId = _uuid.v4();
      final placeholder = ChatMessage(
        messageId: placeholderId,
        sessionId: sessionId,
        role: 'system',
        content: '',
        isSummary: true,
        createdAt: DateTime.now(),
      );
      await _chatRepository.addMessage(placeholder);
      // 设置 currentCompactionSummaryId，UI 据此展示流式生成状态
      state = state.copyWith(
        messages: [...state.messages, placeholder],
        currentCompactionSummaryId: placeholderId,
      );

      final buffer = StringBuffer();
      var failed = false;
      // 摘要已完整落库（压缩点已建）标志——onComplete 的多个 await 期间
      // 用户仍可按停止（isCompressing 未清），若仅凭 cancelToken 判取消
      // 会删掉已被压缩点引用的摘要，留下孤儿压缩点令 boundary 前历史
      // 全部从 API 上下文消失。收尾窗内迟到的取消按成功收口。
      var summaryPersisted = false;

      //  流式节流：压缩占位消息逐 delta UPDATE 合并为 ~100ms 节流写库。
      // state（打字效果）仍逐 delta 更新；DB 写回解耦合帧——流式摘要动辄
      // 数百 delta，此前每 delta 一次 UPDATE 既放大 IO 又延长事务占用。
      // onComplete/onError 前显式冲刷（flushNow），最终内容必落库。
      Timer? dbWriteTimer;
      Future<void> flushDbWrite() async {
        dbWriteTimer?.cancel();
        dbWriteTimer = null;
        await _chatRepository.updateMessageContent(
          placeholderId,
          buffer.toString(),
        );
      }

      await _compactionService.compactWithStream(
        sessionId: sessionId,
        messages: effectiveMessages,
        cancelToken: cancelToken,
        onTextDelta: (delta) async {
          buffer.write(delta);
          final acc = buffer.toString();
          // state：打字效果逐 delta（内存更新，廉价）
          state = state.copyWith(
            messages: state.messages
                .map(
                  (m) => m.messageId == placeholderId
                      ? m.copyWith(content: acc)
                      : m,
                )
                .toList(),
          );
          // DB：100ms 合帧写回（尾段由 onComplete/onError 前的 flushNow 兜底）
          dbWriteTimer ??= Timer(const Duration(milliseconds: 100), () {
            // lm-motion-exempt: DB 写盘去抖（持久化节流）
            unawaited(flushDbWrite());
          });
        },
        onComplete: (fullSummary, tokensUsed) async {
          await flushDbWrite();
          // 写入 tokensUsed 使 UI 顶部 token 用量立即刷新
          if (tokensUsed != null) {
            await _chatRepository.updateMessageTokensUsed(
              placeholderId,
              tokensUsed,
            );
          }
          await _chatRepository.addCompactionPoint(
            sessionId: sessionId,
            summaryMessageId: placeholderId,
            boundaryMessageId: boundaryMessage.messageId,
            createdAt: DateTime.now(),
          );
          summaryPersisted = true;
          await _loadMessages();
        },
        onError: (error) async {
          failed = true;
          await flushDbWrite();
          // 记录失败时间，触发 [sendMessage] 自动压缩冷却，避免 402 等错误连续触发
          _lastCompactionFailureTime = DateTime.now();
          final context = await _recordError(
            error: error is CompactionException ? null : error,
            overrideCategory: SimpleFailureClassifier.unknown,
            overrideRawError:
                error is CompactionException ? error.message : '$error',
          );
          final display = _classifier.formatPersisted(
            context.errorCategory,
            context.errorCode,
          );
          // 保留已累积的 content，仅标记 error（错误信息由失败卡片标题渲染）
          await _chatRepository.updateMessageError(placeholderId, display);
          await _loadMessages();
        },
      );

      // 流已收尾（onComplete/onError 已冲刷），撤销残留计时器
      dbWriteTimer?.cancel();
      dbWriteTimer = null;

      if (failed) {
        return CompressResult.failed;
      }
      // 用户取消——静默清理占位摘要（半截内容不入上下文也不留
      // 失败卡），不计失败冷却。摘要已完整落库的迟到取消不算取消
      // （删掉会被压缩点引用的摘要=孤儿点，见上方 summaryPersisted 注释）。
      if (cancelToken.isCancelled && !summaryPersisted) {
        await _chatRepository.deleteMessage(placeholderId);
        await _loadMessages();
        return CompressResult.cancelled;
      }
      // 成功：清空冷却字段，恢复正常自动压缩
      _lastCompactionFailureTime = null;
      return CompressResult.success;
    } on CompactionException catch (e) {
      _logger.warn('Compaction failed', detail: e.message);
      _lastCompactionFailureTime = DateTime.now();
      final context = await _recordError(
        overrideCategory: SimpleFailureClassifier.unknown,
        overrideRawError: e.message,
      );
      state = state.copyWith(
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
      return CompressResult.failed;
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to compress history',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      _lastCompactionFailureTime = DateTime.now();
      final context = await _recordError(
        error: e,
        overrideCategory: SimpleFailureClassifier.unknown,
      );
      state = state.copyWith(
        error: _classifier.formatPersisted(
          context.errorCategory,
          context.errorCode,
        ),
      );
      return CompressResult.failed;
    } finally {
      _compactionCancelToken = null;
      state = state.copyWith(
        isCompressing: false,
        currentCompactionSummaryId: null,
      );
    }
  }

  /// 停止压缩——取消在途摘要流；占位摘要的清理
  /// 由 [_compressHistoryCore] 的收尾分支完成（避免与流收尾并发写库）。
  void cancelCompaction() {
    _compactionCancelToken?.cancel();
  }

  /// 重试压缩（删除失败的摘要消息后重新触发压缩）
  ///
  /// 失败摘要消息无关联的 CompactionPoint，deleteSummary 内部的
  /// deleteCompactionPointBySummaryId 是 no-op，安全。
  Future<CompressResult> retryCompaction(String failedMessageId) async {
    // 入口先查忙再删失败卡——此前先
    // deleteFailedSummary（无守卫）再进 compressHistory 的防抖锁：
    // 生成中点重试会先删掉失败卡并把 state.messages 用 DB 快照整替
    // （内存中未落库的流式气泡被清出屏幕），最后才拿到 busy 且无提示。
    // 与 compressHistory 入口同口径拦截。
    if (state.isSending || state.isStreaming || state.isCompressing) {
      return CompressResult.busy;
    }
    // deleteFailedSummary 内部已 _loadMessages，
    // 去掉此前的显式重载（同操作双重全量读库+两帧列表重建）
    await deleteFailedSummary(failedMessageId);
    return compressHistory();
  }

  /// 删除失败的摘要消息（用户点失败卡片的关闭按钮）
  ///
  /// 失败摘要无 CompactionPoint，直接 deleteMessage 即可。
  Future<void> deleteFailedSummary(String messageId) async {
    await _chatRepository.deleteMessage(messageId);
    await _loadMessages();
  }

  /// 用新摘要更新会话标题
  ///
  /// 压缩成功后由 UI 层弹窗确认调用。force=true 绕过默认标题检查，
  /// 即使已有非默认标题也重新生成。
  /// 会话设置「更新标题」按钮入口。返回是否写入了
  /// 新标题（按钮据此弹反馈）；force 在途去抖——连点只跑一次。
  Future<bool> updateTitleFromSummary({bool force = false}) async {
    if (force && _titleNamingInFlight) return false;
    if (force) _titleNamingInFlight = true;
    try {
      return await _autoNameSession(force: force);
    } finally {
      if (force) _titleNamingInFlight = false;
    }
  }

  // ==================== API 请求构建 ====================

  /// 构建 API 请求消息列表
  ///
  /// 对标 ChatBox buildContextForAI：从 state.messages（全量，含旧消息）中
  /// 通过 getCompressedMessages 过滤出当前有效上下文 [摘要, ...boundary之后的消息]，
  /// 再转换为 OpenAI 消息格式。UI 显示的全部消息不会全部发给 API。
  ///
  /// [maxContextMessages] 为会话级最大上下文消息数限制（null = 无限制）。
  /// P0-A 修复：当设置该值时截断对话消息（不影响 system prompt）。
  /// 截断策略保留 CompactionPoint 摘要（首条 isSummary）+ 取最近 (N-1) 条，
  /// 避免摘要被丢弃导致历史上下文断层。详见下方实现注释。
  Future<List<Map<String, dynamic>>> _buildMessagesForApi(
    String systemPrompt, {
    int? maxContextMessages,
    ChatMessage? continueFrom,
  }) async {
    final messages = <Map<String, dynamic>>[];

    if (systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }

    // 对标 ChatBox buildContextForAI：过滤出当前有效上下文
    var contextMessages = await _compactionService.getCompressedMessages(
      state.session.sessionId,
    );

    // P0-A 修复：应用会话级 maxContextMessages 截断
    // 截断策略（改进版）：保留 CompactionPoint 摘要 + 取最近 (N-1) 条消息
    // - 若首条消息为 isSummary（压缩摘要），保留它并取剩余消息的最后 (N-1) 条，
    //   避免摘要被丢弃导致历史上下文断层。
    // - 若无摘要（未触发压缩），直接取最后 N 条。
    // - N <= 0 时不截断；N >= 已有消息数时不截断。
    if (maxContextMessages != null &&
        maxContextMessages > 0 &&
        contextMessages.length > maxContextMessages) {
      final hasSummary =
          contextMessages.isNotEmpty && contextMessages.first.isSummary;
      if (hasSummary && maxContextMessages > 1) {
        final summary = contextMessages.first;
        final rest = contextMessages.skip(1).toList();
        final keep = rest.length > maxContextMessages - 1
            ? rest.sublist(rest.length - (maxContextMessages - 1))
            : rest;
        contextMessages = [summary, ...keep];
      } else {
        contextMessages = contextMessages.sublist(
          contextMessages.length - maxContextMessages,
        );
      }
    }

    for (final message in contextMessages) {
      // 跳过无内容的消息（如纯思考消息）
      if (message.content == null &&
          message.toolCalls == null &&
          message.role != 'tool' &&
          (message.attachments == null || message.attachments!.isEmpty)) {
        continue;
      }

      if (message.role == 'tool') {
        // 工具响应消息
        messages.add({
          'role': 'tool',
          'content': message.content ?? '',
          'tool_call_id': message.toolCallId ?? '',
        });
      } else if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
        // 带 tool_calls 的助手消息
        final toolCallsList = message.parsedToolCalls
            .map(
              (tc) => {
                'id': tc.id,
                'type': 'function',
                'function': {
                  'name': tc.name,
                  'arguments': tc.arguments,
                },
              },
            )
            .toList();
        messages.add({
          'role': message.role,
          'content': message.content ?? '',
          'tool_calls': toolCallsList,
          // DeepSeek V4 thinking 模式：带 tool_calls 的 assistant 消息必须回传
          // reasoning_content，否则后续轮次返回 400。仅当 reasoningContent 非空时
          // 注入（reasoningContent 来自 SSE delta.reasoning_content，R1 的 <think>
          // 标签解析不会写入此字段，故 R1 不会误传）。对不支持 reasoning 的模型零影响。
          if (message.reasoningContent != null &&
              message.reasoningContent!.isNotEmpty)
            'reasoning_content': message.reasoningContent,
        });
      } else if (message.attachments != null &&
          message.attachments!.isNotEmpty) {
        // 多模态消息（带附件）
        final contentParts = <Map<String, dynamic>>[];

        // 添加文本内容前缀（文件附件的文本内容）
        final textPrefix = StringBuffer();
        for (final att in message.attachments!) {
          if (att.isFile && att.textContent != null) {
            textPrefix
              ..writeln('[File: ${att.name}]')
              ..writeln(att.textContent)
              ..writeln();
          }
        }

        final messageText = message.content ?? '';
        final fullText =
            textPrefix.isEmpty ? messageText : '$textPrefix$messageText';

        if (fullText.isNotEmpty) {
          contentParts.add({
            'type': 'text',
            'text': fullText,
          });
        }

        // 添加图片附件（OpenAI image_url 格式）
        for (final att in message.attachments!) {
          if (att.isImage && att.base64Data != null) {
            contentParts.add({
              'type': 'image_url',
              'image_url': {
                'url':
                    'data:${att.mimeType ?? 'image/png'};base64,${att.base64Data}',
              },
            });
          }
        }

        messages.add({
          'role': message.role,
          'content': contentParts,
        });
      } else if (message.content != null) {
        // 普通消息
        messages.add({
          'role': message.role,
          'content': message.content,
        });
      }
    }

    // 续写请求——半截 assistant 内容 + 续写指令合并为单条
    // user 消息替换末尾的半截条目（模型接写而非重新开场）
    if (continueFrom != null) {
      return mergeContinueContext(
        messages,
        halfContent: continueFrom.content ?? '',
      );
    }

    return messages;
  }

  /// 解析会话设置（会话级设置优先，否则使用全局默认）
  Future<ChatSessionSettings> _resolveSettings() async {
    final result = await _configurationResolver.resolveSettings(state.session);
    _cachedApiKey = result.apiKey;
    return result.settings;
  }

  // ==================== 自动命名会话 ====================

  /// 自动命名会话（对标 ChatBox autoGenerateTitle）
  ///
  /// 触发条件：
  /// 1. 会话标题是默认值"新建会话"或空
  /// 2. 消息数 >= 2（一问一答）
  ///
  /// 实现：
  /// - 取前 4 条非 system 消息，每条截取前 100 字符
  /// - 调用 LLM 生成简短标题（最多 10 个字）
  /// - 失败时回退到截取第一条用户消息前 20 字符
  Future<bool> _autoNameSession({bool force = false}) async {
    try {
      final title = state.session.title;
      // 仅对默认标题或空标题的会话自动命名（force=true 时绕过此检查）。
      //  修复：草稿路径的标题是 i18n 的「新对话」
      // （main_layout _startNewChat → t.chat.draft.title），旧守卫只认
      // 硬编码'新建会话'/'New Chat'，导致主流程会话永远不自动命名。
      // 改为同时识别草稿标题文案；i18n 切换语言后同样成立。
      final draftTitles = <String>{
        '新建会话',
        'New Chat',
        t.chat.draft.title,
      };
      // 前缀兜底名
      // 是「可升级」的待命名信号——标题请求紧随生成流发出，撞 RPM 一次
      // 瞬时失败即写入兜底名，此后守卫把它当终态秒退，一次失败永久关闭
      // 自动命名（9 例复现、60s+ 配额恢复也不自愈）。识别「当前标题 ==
      // 首条用户消息前缀兜底」时放行重试；写回 CAS 同步纳入该标题。
      final fallbackPrefix = _fallbackPrefixOfFirstUserMessage();
      final isFallbackName = fallbackPrefix != null && title == fallbackPrefix;
      if (!force &&
          title.isNotEmpty &&
          !draftTitles.contains(title) &&
          !isFallbackName) {
        return false;
      }
      // 写回侧 CAS——命名 LLM 在途期间用户手动
      // 重命名的会话（当前标题已非草稿标题）不再被自动命名覆盖。
      // force 时把入口快照标题也纳入允许集合：updateTitleFromSummary
      // 是用户主动触发，允许覆盖既有标题。
      final allowedCurrentTitles = <String>{...draftTitles, ''};
      if (force) allowedCurrentTitles.add(title);
      if (isFallbackName) allowedCurrentTitles.add(fallbackPrefix);

      // 至少需要 2 条消息（一问一答）
      if (state.messages.length < 2) return false;

      // 取前 4 条非 system 消息（供回退截断命名使用）
      final conversationMessages =
          state.messages.where((m) => m.role != 'system').take(4).toList();
      if (conversationMessages.isEmpty) return false;

      // 解析标题模型（2026-09-09 三级优先级：common.title_model > 本会话
      // 生成正文的模型 > 前缀截取兜底）
      final config = await _configurationResolver.resolveTitleNamingConfig() ??
          await _configurationResolver
              .resolveBroadcastGeneratingNamingConfig(state.session);
      if (config == null) {
        // 标题模型与生成模型均不可用，回退到截取方式（用户首条消息前 20 字符）。
        // force 失败不落截断名——保持原标题，
        // 按钮 SnackBar 提示失败即可（自动命名路径仍走兜底）。
        if (!force) {
          await _applyFallbackName(conversationMessages, allowedCurrentTitles);
        }
        return false;
      }

      // CF-D2：改走共享 SessionTitleGenerator（统一 LlmService
      // 调用层，带 protocol/providerOptions）。此前手拼 OpenAI 格式直发
      // http.post——anthropic/gemini 供应商的标题模型必 404 静默降级截断命名。
      final firstUser = conversationMessages.firstWhere(
        (m) => m.role == 'user',
        orElse: () => conversationMessages.first,
      );
      final firstAssistant = conversationMessages.firstWhere(
        (m) => m.role == 'assistant',
        orElse: () => conversationMessages.first,
      );
      final generator = SessionTitleGenerator(
        llmService: _llmService,
        logger: _logger,
      );
      // 超时透传 network.*（与主发送路径同源），失败进 generator
      // 内的 warn 日志
      final titleNetwork = await _settingsRepository.getResolvedConfig();
      final generatedTitle = await generator.generate(
        userMessage: firstUser.content ?? '',
        assistantReply: firstAssistant.content ?? '',
        namingConfig: config,
        connectTimeout: titleNetwork.network.connectTimeout,
        readTimeout: titleNetwork.network.receiveTimeout,
      );

      if (generatedTitle == null || generatedTitle.isEmpty) {
        if (!force) {
          await _applyFallbackName(conversationMessages, allowedCurrentTitles);
        }
        return false;
      }

      // 更新会话标题（：CAS 条件写——被用户抢先重命名则放弃写回）
      final written = await _chatRepository.updateSessionTitleIfCurrentTitleIn(
        state.session.sessionId,
        generatedTitle,
        allowedCurrentTitles,
      );
      if (!written) return false;

      // 更新 state
      state = state.copyWith(
        session: state.session.copyWith(title: generatedTitle),
      );
      return true;
    } catch (e, stackTrace) {
      _logger.error(
        'Auto-name session failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 回退命名：截取第一条用户消息前 20 字符
  ///
  /// [allowedCurrentTitles]： CAS 允许集合（与 LLM 命名路径同口径）。
  Future<void> _applyFallbackName(
    List<ChatMessage> messages,
    Set<String> allowedCurrentTitles,
  ) async {
    final firstUserMsg = messages.firstWhere(
      (m) => m.role == 'user',
      orElse: () => messages.first,
    );
    final content = firstUserMsg.content ?? '';
    final title = _fallbackPrefixOf(content) ?? t.chat.draft.title;

    final written = await _chatRepository.updateSessionTitleIfCurrentTitleIn(
      state.session.sessionId,
      title,
      allowedCurrentTitles,
    );
    if (!written) return;
    state = state.copyWith(
      session: state.session.copyWith(title: title),
    );
  }

  /// 首条用户消息的前缀兜底名（与 [_applyFallbackName] 同口径），
  /// 供入口守卫识别「兜底名是可升级的待命名信号」。
  static String? _fallbackPrefixOf(String? content) {
    if (content == null || content.isEmpty) return null;
    var title = content.length > 20 ? content.substring(0, 20) : content;
    title = title.replaceAll(RegExp(r'[\n\r]'), ' ').trim();
    // 空兜底走 t.chat.draft.title，由调用方处理；此处返回 null
    return title.isEmpty ? null : title;
  }

  String? _fallbackPrefixOfFirstUserMessage() {
    for (final m in state.messages) {
      if (m.role != 'user') continue;
      final prefix = _fallbackPrefixOf(m.content);
      if (prefix != null) return prefix;
    }
    return null;
  }

  @override
  void dispose() {
    cancelSending();
    super.dispose();
  }
}
