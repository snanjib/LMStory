import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_compaction_summary_card.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_navigation.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/follow_scroll_executor.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
// 阅读位置记忆——复用 chat 侧滚动位置 LRU 缓存
import 'package:lmstory/features/chat/presentation/utils/scroll_position_cache.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_round_panels_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
// 变体切换器（story_runtime 共享组件）
import 'package:lmstory/features/story_runtime/presentation/widgets/message_variant_switcher.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式聊天主体（消息列表 + 生成/检索小窗 + 空状态）。
///
/// 状态驱动渲染：
/// - 消息列表：state.messages + 流式 streamingReply
/// - generating/extracting/retrieving/reviewing/summarizing 阶段：
///   依次显示 GeneratePanel + ExtractingHint + RetrievalPanel + 流式回复 +
///   SummarizingHint（DOC-09B §7.4.1 V2 四步）
/// - 空状态（无消息 + idle）：衬线引导文案
///
/// 透传 [generatingFoldDelayMs]/[retrievalFoldDelayMs] 给小窗组件，
/// 从 `StreamConfig` 读取，让自动折叠时序可配置。
///
/// 透传 Fork 相关参数给每条消息气泡：
/// - [windowRounds]：Fork 窗口轮数（canOperate=false 时菜单项禁用 + SnackBar 提示）
/// - [canOperate]：按消息判断是否在窗口内（委托 controller.canOperateMessage）
/// - [onCopy]/[onRegenerate]/[onEdit]/[onDeleteRound]：4 个动作回调
/// - 全局动作开关：state.phase != idle 时隐藏所有 actions（避免生成中误操作）
class IntermediateChatBody extends ConsumerStatefulWidget {
  const IntermediateChatBody({
    required this.state,
    required this.onRetryRetrieval,
    required this.windowRounds,
    required this.canOperate,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
    this.generatingFoldDelayMs = 2000,
    this.retrievalFoldDelayMs = 1000,
    this.embeddingConfigured = true,
    this.fontScale = 1.0,
    this.onUseExample,
    this.onUndoCompaction,
    // 稿件变体切换回调（null = 切换器不渲染）
    this.onSwitchVariant,
    this.onDeleteVariant,
    this.onVariantFlashConsumed,
    this.initialFocusMessageId,
    super.key,
  });

  final IntermediateChatState state;
  final VoidCallback onRetryRetrieval;

  /// 撤销压缩回调（U2，2026-09-04）：null = 摘要卡不显示撤销入口。
  /// 可用性由本组件按 phase/压缩中状态计算后传给摘要卡。
  final Future<void> Function()? onUndoCompaction;

  /// Fork 窗口轮数（从 ForkConfig.regenerateWindowRounds 传入）
  final int windowRounds;

  /// 判断指定消息是否在 Fork 窗口内（委托 controller.canOperateMessage）
  final bool Function(ChatMessage) canOperate;

  /// 复制回调（始终可用，不受 canOperate 限制）
  final void Function(ChatMessage) onCopy;

  /// 重新生成回调（仅助手消息 + canOperate）
  final void Function(ChatMessage) onRegenerate;

  /// 编辑重发回调（仅用户消息 + canOperate）
  final void Function(ChatMessage) onEdit;

  /// 删除整轮回调（canOperate）
  final void Function(ChatMessage) onDeleteRound;

  /// 生成面板自动折叠延迟（毫秒），从 `StreamConfig.generatingFoldDelayMs` 传入
  final int generatingFoldDelayMs;

  /// 检索小窗自动折叠延迟（毫秒），从 `StreamConfig.retrievalFoldDelayMs` 传入
  final int retrievalFoldDelayMs;

  /// 嵌入模型是否已配置（2026-07-21 新增）
  ///
  /// 用于检索小窗显示「语义/关键词」模式标签。
  /// true（默认）= 已配置 embedding 模型，使用语义检索；
  /// false = 未配置，使用 FTS5 关键词检索。
  final bool embeddingConfigured;

  /// 字体缩放比例（来自通用设置"字体大小"，与 ChatModePage 共享计算公式）。
  ///
  /// fontScale = fontSize.clamp(12, 22) / 15。默认 1.0（fontSize=15）。
  /// 应用到消息正文与思考区块的字号，保留故事模式双字体策略
  /// （助手衬线 16px / 用户无衬线 15px），仅在基准上按 fontScale 缩放。
  /// UI 标签（caption/label）不受影响，保持视觉层次稳定。
  final double fontScale;

  /// 空态示例开场点击回填输入框（null = 不显示示例卡）
  final void Function(String example)? onUseExample;

  /// 稿件变体操作回调（null = 切换器不渲染）。
  /// 切换=设为当前版本；删除=删非当前变体；flash 消费=2s 高亮结束清信号。
  final void Function(ChatMessage message, int variantIndex)? onSwitchVariant;
  final void Function(ChatMessage message, int variantIndex)? onDeleteVariant;
  final VoidCallback? onVariantFlashConsumed;

  /// 全局搜索命中进入时携带：首载后滚动定位并
  /// 短暂高亮该消息。普通进入为 null。
  final String? initialFocusMessageId;

  @override
  ConsumerState<IntermediateChatBody> createState() =>
      IntermediateChatBodyState();
}

/// State 公开化——页面持 GlobalKey 调
/// [revealAndFlash]（会话内搜索命中定位），与 SimpleChatInputState
/// 同款句柄范式。
class IntermediateChatBodyState extends ConsumerState<IntermediateChatBody>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();

  /// 滚动导航：用户正在滑动时为 true，停止 2 秒后自动 false
  bool _isScrollActive = false;

  /// 滚动导航：是否位于底部附近（在底部时隐藏导航）
  bool _atBottom = true;

  /// 滚动空闲计时器（2 秒后标记滑动停止）
  Timer? _scrollIdleTimer;

  /// 贴底跟随裁决与执行（2026-09-10 chatbox smooth-follow-output 语义
  /// 移植，与 chat/导演同款 [FollowScrollExecutor]， 单源）：状态机
  /// 裁决「是否跟随」——任一上划（非内容收缩钳位）首帧即冻结，不需
  /// 脱离底部容差带，慢速上划看历史不被流式更新反复拉回；滚回距底
  /// ≤4px 自动恢复；发送/点胶囊强制回底。执行按平台分派——桌面 ticker
  /// 逐帧指数趋近平滑贴底、移动 postFrame jumpTo 直贴（行为不回归）。
  late final FollowScrollExecutor _followExecutor;

  /// 每条消息的 GlobalKey，用于可见性计算和滚动定位
  final Map<String, GlobalKey> _messageKeys = {};

  /// 搜索定位闪示：非空时该消息行短暂着色，
  /// [_flashTimer] 到时清除。
  String? _flashMessageId;
  Timer? _flashTimer;
  bool _focusHandled = false;

  /// 动态目标滚动消息 ID（仅此消息与高亮/焦点项动态持有 GlobalKey）
  String? _targetScrollMessageId;

  /// 轮完成提示胶囊——上滑阅读中轮完成时置 true，
  /// [_roundDoneHintTimer] 5s 后清除；点按跳底。
  bool _roundDoneHintVisible = false;
  Timer? _roundDoneHintTimer;

  @override
  void initState() {
    super.initState();
    _followExecutor = FollowScrollExecutor(
      controller: _scrollController,
      vsync: this,
    );
    _scrollController.addListener(_onScroll);
    // fresh-mount 半边——控制器缓存（非 autoDispose）
    // 下页面首建即可能非空，首帧后应用进入定位（深链 > 恢复缓存 > 贴底）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyEntryScrollPosition();
    });
  }

  /// 进入会话的定位——深链焦点 > 恢复缓存阅读位置；
  /// 两者皆无时保持既有进入行为（默认贴底属  同族独立事项，不在
  /// 本批范围）。消息未就绪时等 didUpdateWidget 的真实「空→非空」跃迁再试。
  void _applyEntryScrollPosition() {
    if (!mounted) return;
    if (widget.state.messages.isEmpty) return;
    if (widget.initialFocusMessageId != null) {
      _focusInitialMessage(widget.state.messages);
      return;
    }
    // 缓存键用 state.session.sessionId（物化后的真实 id，draft id 天然
    // miss——与 chat 侧 2026-07-22 修复同口径）
    final cached = ref
        .read(scrollPositionCacheProvider)
        .restore(widget.state.session.sessionId);
    if (cached != null) {
      _jumpToOffsetImmediate(cached);
    }
  }

  /// 立即跳到指定偏移（postFrame 一拍，等 ListView 完成首建；
  /// clamp 防懒加载 maxScrollExtent 尚未收敛时越界）。跳变负 delta 会被
  /// 跟随状态机冻结跟随——这正是恢复阅读位的期望语义（保持原位不被
  /// 后续内容拉底）。
  void _jumpToOffsetImmediate(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(offset.clamp(0, maxExtent));
      }
    });
  }

  /// 滚动定位 + 短暂高亮搜索命中消息。
  void _focusInitialMessage(List<ChatMessage> messages) {
    final id = widget.initialFocusMessageId;
    if (id == null || _focusHandled) return;
    // 目标已被压缩归档（不在可见消息区，全局搜索
    // 仍会索引库内全部消息）时回退跳底，避免「点搜索结果毫无反应」的
    // 静默缺失；置 _focusHandled 防止消息装载后再次触发。
    //
    // 这里必须走「回底 + settle 校准」而不是裸 forceToBottom：进入会话时
    // 列表刚从 offset 0 首建，惰性列表的 maxScrollExtent 仍是早估，
    // 单次 postFrame jumpTo 会落在真实底部之上（阅读列限宽后气泡变高，
    // 偏差被放大到 200px 量级，用户看到最新一轮被截掉）。与发送回底
    // 同语义——都是「一次到位贴底」，故共用同一入口（见
    // FollowScrollExecutor.forceToBottom 的 settle 契约）。
    if (!messages.any((m) => m.messageId == id)) {
      _focusHandled = true;
      _forceToBottomWithSettle();
      return;
    }
    _focusHandled = true;
    _scrollToMessage(id);
    _startFlash(id);
  }

  /// 命中行短暂着色（闪示基建； 抽提共用）。
  void _startFlash(String messageId, {int durationMs = 1800}) {
    if (!mounted) return;
    setState(() => _flashMessageId = messageId);
    _flashTimer?.cancel();
    _flashTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => _flashMessageId = null);
    });
  }

  /// 会话内搜索命中定位（页面经 GlobalKey 调用）——
  /// 三段式 reveal（懒加载远端命中无 RenderObject，先按索引比例估算再
  /// 逐视口校准），闪示顺延到气泡真实构建后。
  void revealAndFlash(String messageId) {
    _flashTimer?.cancel();
    if (_targetScrollMessageId != messageId) {
      setState(() {
        _targetScrollMessageId = messageId;
        _messageKeys.putIfAbsent(messageId, GlobalKey.new);
      });
    }
    _revealMessage(
      messageId,
      useEstimate: true,
      attemptsRemaining: 4,
      onSettled: () {
        _startFlash(messageId);
        if (mounted && _targetScrollMessageId == messageId) {
          setState(() {
            _targetScrollMessageId = null;
          });
        }
      },
    );
  }

  /// 阅读位置测试探针（滚动位置记忆三路径断言用）。
  @visibleForTesting
  double scrollOffsetForTest() =>
      _scrollController.hasClients ? _scrollController.offset : 0;

  @visibleForTesting
  double maxScrollExtentForTest() => _scrollController.hasClients
      ? _scrollController.position.maxScrollExtent
      : 0;

  @visibleForTesting
  void jumpToOffsetForTest(double offset) {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  @override
  void didUpdateWidget(IntermediateChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 故事→故事切会话时重置滚动阅读态——旧会话的
    // 上滑冻结态与游标位置会漏进新会话；重置后回到贴底跟随新会话最新轮
    if (widget.state.session.sessionId != oldWidget.state.session.sessionId) {
      // 离开前保存旧会话阅读位置（键=旧 state
      // session.sessionId，物化后即真实 id）
      if (_scrollController.hasClients) {
        ref
            .read(scrollPositionCacheProvider)
            .save(oldWidget.state.session.sessionId, _scrollController.offset);
      }
      _followExecutor
        ..reset()
        ..forceToBottom();
      // 页面级标记随会话切换清扫——旧会话的轮完成
      // 胶囊（残留会把新会话拽底）与搜索闪示不得泄漏进新会话。
      _roundDoneHintTimer?.cancel();
      if (_roundDoneHintVisible) {
        setState(() => _roundDoneHintVisible = false);
      }
      _flashTimer?.cancel();
      if (_flashMessageId != null) {
        setState(() => _flashMessageId = null);
      }
      return;
    }
    //  + ：首载完成（0 → N 条）应用进入定位——深链
    // 焦点或缓存阅读位置存在时接管（覆盖默认行为）；两者皆无时落到下方
    // 既有的跟随贴底逻辑（followGrowth），保持原有进入行为。
    if (oldWidget.state.messages.isEmpty &&
        widget.state.messages.isNotEmpty &&
        (widget.initialFocusMessageId != null ||
            ref
                    .read(scrollPositionCacheProvider)
                    .restore(widget.state.session.sessionId) !=
                null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyEntryScrollPosition();
      });
      return;
    }
    // 消息数变化或流式内容（生成内容/回复）更新时，滚动到底部
    // 新增 streamingGenerated 触发——小窗移到消息列表后，生成流式增长需跟随滚动
    final oldMessages = oldWidget.state.messages.length;
    final newMessages = widget.state.messages.length;
    final oldReply = oldWidget.state.streamingReply ?? '';
    final newReply = widget.state.streamingReply ?? '';
    final oldGenerated = oldWidget.state.streamingGenerated ?? '';
    final newGenerated = widget.state.streamingGenerated ?? '';
    final hasNewContent = newMessages > oldMessages ||
        newReply.length > oldReply.length ||
        newGenerated.length > oldGenerated.length;
    //  修复：pendingUserMessage 从 null 变为非 null = 用户刚发消息
    // 此时必须立即滚动到底部。原因：pendingUserMessage 出现后 ListView 内容变长，
    // maxScrollExtent 增大，但 pixels 没变 → 距底被拉远，
    // 后续 streamingGenerated 增长时若跟随已冻结则不滚动。
    // 用户发消息意图明确是看底部：forceFollowing 强制恢复跟随。
    final pendingUserMessageAppeared =
        oldWidget.state.pendingUserMessage == null &&
            widget.state.pendingUserMessage != null;
    // 贴底跟随 gate 全权交给执行器（上划即停/滚回距底 ≤4px 自动恢复）：
    // pendingUserMessage 出现时强制回底（用户发消息意图明确，发送语义
    // 单次校准）；其他情况仅跟随态才滚动（桌面平滑趋近/移动直贴）。
    if (pendingUserMessageAppeared) {
      _forceToBottomWithSettle();
    } else if (hasNewContent && _followExecutor.state.following) {
      _followExecutor.followGrowth();
    }

    // +  门控改造：轮完成反馈——
    // persist 成功（phase→idle 且消息数增长）时，summarize/facts 面板
    // 已追加在流式气泡之下，折线下积压使距底拉远；跟随时正常贴底
    // （面板追加造成的远离底部不是用户的阅读意图），上划阅读位则不
    // 拽回、以顶部轻胶囊非打断提示（与 「误判卡死
    // 4 分钟实为已完成」同根）。
    final roundCompleted = oldWidget.state.phase != IntermediatePhase.idle &&
        widget.state.phase == IntermediatePhase.idle &&
        newMessages > oldMessages;
    if (roundCompleted) {
      if (_followExecutor.state.following) {
        // 跟随态：轮完成贴底=即时（两平台一致，near-bottom 门控已由
        // 状态机取代，无需绕过）。
        _followExecutor.forceToBottom();
      } else {
        _showRoundDoneHint();
      }
    }
  }

  /// 上滑阅读中的非打断式完成提示——顶部轻胶囊，5s 自动消失，
  /// 点按跳底查看本轮产出。
  void _showRoundDoneHint() {
    setState(() => _roundDoneHintVisible = true);
    _roundDoneHintTimer?.cancel();
    _roundDoneHintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _roundDoneHintVisible = false);
    });
  }

  /// 强制回底（发送/点胶囊/归档搜索命中回退）：执行器恢复跟随并即时贴底
  /// （两平台一致，桌面也不走平滑），settle 校准挂 postFrame 下一帧——
  /// 这三条路径都有「一次到位」预期，懒加载列表 maxScrollExtent 修正后做
  /// 单次校准（稳态下距离 ≤1 直接 no-op；流式跟随路径零 settle）。
  void _forceToBottomWithSettle() {
    _followExecutor.forceToBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _settleAtBottom(1);
      }
    });
  }

  /// Lazy lists refine their max scroll extent while previously unseen children
  /// are built. Settle once more after the animation so opening a long story
  /// still lands on the actual latest round rather than an early estimate.
  void _settleAtBottom([int attemptsRemaining = 3]) {
    if (!mounted ||
        attemptsRemaining <= 0 ||
        !_followExecutor.state.following) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          !_followExecutor.state.following) {
        return;
      }
      final position = _scrollController.position;
      final distance = position.maxScrollExtent - position.pixels;
      if (distance.abs() <= 1) return;
      _scrollController.jumpTo(position.maxScrollExtent);
      _settleAtBottom(attemptsRemaining - 1);
    });
  }

  /// 滚动监听：跟随状态机输入 + 导航可见性状态。
  ///
  /// 滑动时立即标记 `_isScrollActive = true`，重置 2 秒空闲计时器。
  /// 同步更新 `_atBottom`（底部 50px 容差，仅服务导航显隐），在底部时
  /// 隐藏导航。
  ///
  /// 跟随裁决交给 [FollowScrollExecutor]（chatbox 语义）：
  /// - 上划即停：pixels 下降（且非内容收缩钳位）首帧即冻结贴底跟随
  /// - 滚回距底 ≤4px 自动恢复；发送/点胶囊由执行器强制回底
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final pixels = position.pixels;
    final atBottom = position.maxScrollExtent - pixels < 50;

    _followExecutor.handleScrollMetrics(pixels, position.maxScrollExtent);

    if (!_isScrollActive) {
      setState(() => _isScrollActive = true);
    }
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isScrollActive = false);
    });

    if (_atBottom != atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  /// 跳到顶部（最旧消息）。
  void _jumpToTop() {
    if (!_scrollController.hasClients) return;
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController.animateTo(
      0,
      duration: LmMotion.emphasis,
      curve: LmMotion.easeStandard,
    );
  }

  /// 跳到底部（最新消息）。
  ///
  /// 用户主动点击"跳到底部" = 强制恢复贴底跟随。
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _followExecutor.state.forceFollowing();
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: LmMotion.emphasis,
      curve: LmMotion.easeStandard,
    );
  }

  /// 跳到上一条用户消息（向前查找 role='user'）。
  void _jumpToPrevUserMessage() {
    final messages = widget.state.messages;
    if (messages.isEmpty || !_scrollController.hasClients) return;

    final visibleIndex = _findFirstVisibleIndex();
    if (visibleIndex == null) {
      _jumpToTop();
      return;
    }

    // 从当前可见消息向前查找用户消息
    for (var i = visibleIndex - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        _scrollToMessage(messages[i].messageId);
        return;
      }
    }
    // 找不到更早的用户消息，跳到顶部
    _jumpToTop();
  }

  /// 跳到下一条用户消息（向后查找 role='user'）。
  void _jumpToNextUserMessage() {
    final messages = widget.state.messages;
    if (messages.isEmpty || !_scrollController.hasClients) return;

    final visibleIndex = _findFirstVisibleIndex();
    if (visibleIndex == null) {
      _jumpToBottom();
      return;
    }

    // 从当前可见消息向后查找用户消息
    for (var i = visibleIndex + 1; i < messages.length; i++) {
      if (messages[i].role == 'user') {
        _scrollToMessage(messages[i].messageId);
        return;
      }
    }
    // 找不到更晚的用户消息，跳到底部
    _jumpToBottom();
  }

  /// 查找当前视口中第一条可见消息的索引。
  int? _findFirstVisibleIndex() {
    final messages = widget.state.messages;
    if (messages.isEmpty) return null;
    if (!_scrollController.hasClients) return 0;

    // 优先检查当前已分配且已挂载的活跃 Key（目标/高亮消息）
    for (final entry in _messageKeys.entries) {
      final context = entry.value.currentContext;
      if (context == null) continue;
      final renderBox = context.findRenderObject();
      if (renderBox is! RenderBox) continue;
      final offset = renderBox.localToGlobal(Offset.zero);
      // y > 100 表示在视口顶部下方可见
      if (offset.dy > 100) {
        final idx = messages.indexWhere((m) => m.messageId == entry.key);
        if (idx != -1) return idx;
      }
    }

    // 无法通过少数活跃 Key 判定时，按滚动比例常数时间预估，避免全量遍历
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 0) return 0;
    final ratio = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    return (ratio * (messages.length - 1)).round();
  }

  /// 滚动到指定消息（通过 GlobalKey 定位）。
  void _scrollToMessage(String messageId) {
    if (_targetScrollMessageId != messageId) {
      setState(() {
        _targetScrollMessageId = messageId;
        _messageKeys.putIfAbsent(messageId, GlobalKey.new);
      });
    }
    _revealMessage(
      messageId,
      useEstimate: true,
      attemptsRemaining: 4,
      onSettled: () {
        if (mounted && _targetScrollMessageId == messageId) {
          setState(() {
            _targetScrollMessageId = null;
          });
        }
      },
    );
  }

  void _revealMessage(
    String messageId, {
    required bool useEstimate,
    required int attemptsRemaining,
    void Function()? onSettled,
  }) {
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    final key = _messageKeys[messageId];
    final targetContext = key?.currentContext;
    if (targetContext != null) {
      final renderObject = targetContext.findRenderObject();
      if (renderObject == null) {
        onSettled?.call();
        return;
      }
      final scrollable = Scrollable.of(targetContext);
      final viewport = RenderAbstractViewport.of(renderObject);
      final offsetToReveal = viewport.getOffsetToReveal(renderObject, 0).offset;
      scrollable.position.animateTo(
        offsetToReveal,
        duration: LmMotion.emphasis,
        curve: LmMotion.easeStandard,
      );
      onSettled?.call();
      return;
    }

    // 懒加载列表中的远端消息尚未创建 RenderObject。先按索引比例跳转到
    // 目标附近，再逐个视口校准；挂载后仍使用精确的 reveal 偏移。
    if (!_scrollController.hasClients || attemptsRemaining <= 0) {
      onSettled?.call();
      return;
    }
    final messages = widget.state.messages;
    final targetIndex = messages.indexWhere((m) => m.messageId == messageId);
    if (targetIndex < 0) {
      onSettled?.call();
      return;
    }

    final position = _scrollController.position;
    double nextOffset;
    if (useEstimate && messages.length > 1) {
      nextOffset =
          position.maxScrollExtent * targetIndex / (messages.length - 1);
    } else {
      final visibleIndex = _findFirstVisibleIndex();
      final direction =
          visibleIndex == null || targetIndex > visibleIndex ? 1.0 : -1.0;
      nextOffset = position.pixels + position.viewportDimension * direction;
    }
    _scrollController.jumpTo(
      nextOffset.clamp(0.0, position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _revealMessage(
        messageId,
        useEstimate: false,
        attemptsRemaining: attemptsRemaining - 1,
        onSettled: onSettled,
      );
    });
  }

  @override
  void dispose() {
    // 保存当前滚动位置，再次进入该会话时恢复。
    // 键=widget.state.session.sessionId（物化后的真实 id；draft 未物化
    // 以 draft id 保存，下次新 draft id 天然 miss 回退贴底）。
    if (_scrollController.hasClients) {
      ref
          .read(scrollPositionCacheProvider)
          .save(widget.state.session.sessionId, _scrollController.offset);
    }
    _flashTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _roundDoneHintTimer?.cancel();
    _followExecutor.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final state = widget.state;

    // 空状态：无消息 + 无 pendingUserMessage + idle
    // Stage 3：pendingUserMessage 非空时不进空状态（显示临时用户气泡）
    if (state.messages.isEmpty &&
        state.pendingUserMessage == null &&
        state.phase == IntermediatePhase.idle) {
      return _buildEmptyState(colors);
    }

    // 预计算最后一条助手消息 ID（用于 isLastAssistantMessage 标记）
    // 反向查找避免遍历整个列表；无助手消息时为 null
    String? lastAssistantMessageId;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].role == 'assistant') {
        lastAssistantMessageId = state.messages[i].messageId;
        break;
      }
    }
    // 全局动作开关——非 idle 阶段隐藏所有 actions（避免生成中误操作）
    // 手动压缩全程 phase 恒为 idle，消息菜单须一并
    // 锁定，与控制器四消息操作的 isManualCompacting 守卫同口径——否则
    // 菜单可点而控制器静默 no-op，用户零反馈。
    final actionsEnabled =
        state.phase == IntermediatePhase.idle && !state.isManualCompacting;

    // 会话切换或删除下游消息后移除无效 key，且清理非当前目标的冗余 key。
    final activeMessageIds = state.messages.map((m) => m.messageId).toSet();
    if (state.pendingUserMessage != null) {
      activeMessageIds.add(state.pendingUserMessage!.messageId);
    }
    _messageKeys.removeWhere(
      (id, _) =>
          !activeMessageIds.contains(id) ||
          (id != _targetScrollMessageId &&
              id != _flashMessageId &&
              id != widget.initialFocusMessageId),
    );

    final hasPendingMessage = state.pendingUserMessage != null;
    final hasCurrentRound = shouldRenderCurrentRoundPanels(state);
    final tailItemCount =
        (hasPendingMessage ? 1 : 0) + (hasCurrentRound ? 1 : 0);

    return Stack(
      children: [
        // Builder-based construction is critical for long stories: only
        // visible rounds pay the Markdown, panel and layout cost. Previously
        // the spread below eagerly instantiated every message and every
        // historical panel before the first frame.
        //
        // 阅读限宽（大屏口径）：故事正文此前**完全没有**行长约束——
        // 气泡自身只按「视口宽 92%」封顶，2560 窗口下正文行长达 ~2355px，
        // 眼动回扫距离失控。对话模式（chat_mode_page_message_list）与导演
        // 模式（director_chat_body）早已钳制到同一 token，三模式来回切换时
        // 行长三套口径，本处补齐即以同一版心对齐。
        //
        // 只包列表自身：Stack 内的完成提示胶囊 / 滚动导航 / 准备中遮罩等
        // 兄弟节点仍按整窗定位，浮层位置不受影响。
        Center(
          child: RepaintBoundary(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: LmLayout.readingMeasure,
              ),
              child: ListView.builder(
                controller: _scrollController,
                scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                // 2026-09-10：底部缓冲留白（惰性跟随用）——写入行在缓冲内下走时
                // 视口不动，已读文字保持静止。
                padding: const EdgeInsets.only(
                  top: IntermediateSpacing.sMd,
                  bottom: IntermediateSpacing.sMd + streamingFollowCushionPx,
                ),
                itemCount: state.messages.length + tailItemCount,
                itemBuilder: (context, index) {
                  if (index < state.messages.length) {
                    return _buildPersistedMessageGroup(
                      colors: colors,
                      state: state,
                      index: index,
                      lastAssistantMessageId: lastAssistantMessageId,
                      actionsEnabled: actionsEnabled,
                    );
                  }

                  var tailIndex = index - state.messages.length;
                  if (hasPendingMessage) {
                    if (tailIndex == 0) {
                      return _buildMessage(
                        colors,
                        state.pendingUserMessage!,
                        lastAssistantMessageId: null,
                        actionsEnabled:
                            (state.phase == IntermediatePhase.idle ||
                                    state.phase == IntermediatePhase.failed) &&
                                !state.isManualCompacting,
                        canOperateOverride: true,
                        animateEntrance: true,
                      );
                    }
                    tailIndex--;
                  }

                  if (hasCurrentRound && tailIndex == 0) {
                    // 当前轮 idle 态的切换器由顶层函数渲染，
                    // 此处构建好组件传入（回调在 widget 上，顶层函数拿不到）
                    final lastTurn = completedTurnCount(
                      compactedTurnBase: state.compactedTurnBase,
                      messages: state.messages,
                    );
                    final currentRoundSwitcher =
                        _buildCurrentRoundVariantSwitcher(
                      state: state,
                      lastTurn: lastTurn,
                    );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: buildCurrentRoundPanels(
                        context: context,
                        state: state,
                        generatingFoldDelayMs: widget.generatingFoldDelayMs,
                        retrievalFoldDelayMs: widget.retrievalFoldDelayMs,
                        onRetryRetrieval: widget.onRetryRetrieval,
                        messageActions: _buildCurrentRoundMessageActions(
                          state: state,
                          lastAssistantMessageId: lastAssistantMessageId,
                          actionsEnabled: actionsEnabled,
                        ),
                        embeddingConfigured: widget.embeddingConfigured,
                        fontScale: widget.fontScale,
                        variantSwitcher: currentRoundSwitcher,
                      ),
                    );
                  }

                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
        // 上滑阅读中轮完成的非打断式提示胶囊
        //（5s 自动消失，点按跳底）——完成时点显性化，消除「正文完即回
        // ▥、无任何完成信号」的误判死机观感。
        if (_roundDoneHintVisible)
          Positioned(
            top: IntermediateSpacing.sXs,
            left: 0,
            right: 0,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sLg,
                ),
                child: ActionChip(
                  avatar: Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: colors.primary,
                  ),
                  label: Text(t.intermediate.chat.roundDoneHint),
                  onPressed: () {
                    setState(() => _roundDoneHintVisible = false);
                    _forceToBottomWithSettle();
                  },
                ),
              ),
            ),
          ),
        // 滚动导航浮层（滑动时出现，停止 2 秒后自动消失；在底部时不显示）
        if (state.messages.isNotEmpty)
          Positioned(
            right: IntermediateSpacing.sSm,
            bottom: IntermediateSpacing.sMd,
            child: IntermediateMessageNavigation(
              visible: _isScrollActive && !_atBottom,
              onJumpToTop: _jumpToTop,
              onJumpToBottom: _jumpToBottom,
              onPrevUserMessage: _jumpToPrevUserMessage,
              onNextUserMessage: _jumpToNextUserMessage,
            ),
          ),
        // 重新生成/编辑重发"准备中"遮罩（DOC-09A-1 §2.4/§2.5）
        // DB 删除 await 期间覆盖聊天区，避免下游消息残留显示。
        // 半透明夜航底色 + 居中转圈 + ink 色文案；AbsorbPointer 拦截消息列表交互。
        if (state.isPreparingRegenerate)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: colors.bg.withValues(alpha: 0.5),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(height: IntermediateSpacing.sSm),
                      Text(
                        Translations.of(context)
                            .intermediate
                            .chat
                            .preparingRegenerate,
                        style: IntermediateTextStyles.label.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPersistedMessageGroup({
    required LmPalette colors,
    required IntermediateChatState state,
    required int index,
    required String? lastAssistantMessageId,
    required bool actionsEnabled,
  }) {
    final message = state.messages[index];
    if (message.role != 'assistant') {
      return _buildMessage(
        colors,
        message,
        lastAssistantMessageId: lastAssistantMessageId,
        actionsEnabled: actionsEnabled,
      );
    }

    //  修复：artifacts 键为真实轮次号，需叠加压缩基数
    // （压缩后可见列表骤减，本地配对序号不再等于存储轮次号）
    // 旧 index 奇偶公式改走共享工具的 role 感知配对推导
    final turnNumber = turnNumberForMessage(
          message: message,
          messages: state.messages,
          compactedTurnBase: state.compactedTurnBase,
        ) ??
        0;
    final artifacts = state.artifactsByTurnNumber?[turnNumber];
    final isLastAssistant = message.messageId == lastAssistantMessageId;
    final renderedByCurrentRound = isLastAssistant &&
        state.phase == IntermediatePhase.idle &&
        artifacts != null;
    if (renderedByCurrentRound) return const SizedBox.shrink();

    final variantSwitcher = _buildVariantSwitcher(
      message: message,
      turnNumber: turnNumber,
      artifacts: artifacts,
    );
    return KeyedSubtree(
      key: ValueKey('message-group-${message.messageId}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (artifacts != null) ...buildHistoryPanelsBeforeReply(artifacts),
          _buildMessage(
            colors,
            message,
            lastAssistantMessageId: lastAssistantMessageId,
            actionsEnabled: actionsEnabled,
          ),
          if (artifacts != null) buildHistorySummaryPanel(artifacts),
          if (artifacts != null) buildHistoryFactsChangePanel(artifacts),
          if (variantSwitcher != null) variantSwitcher,
        ],
      ),
    );
  }

  /// 历史轮稿件变体切换器——渲染条件与导演同款
  ///（>1 版本 + 指针非 null + 回调已接线）；当前轮 idle 版本由
  /// buildCurrentRoundPanels 经 variantSwitcher 参数渲染。
  Widget? _buildVariantSwitcher({
    required ChatMessage message,
    required int turnNumber,
    required StoryRoundArtifacts? artifacts,
  }) {
    final variants = widget.state.variantsByTurn?[turnNumber];
    final currentIndex = artifacts?.currentVariantIndex;
    final showSwitcher = variants != null &&
        variants.length > 1 &&
        currentIndex != null &&
        widget.onSwitchVariant != null;
    if (!showSwitcher) return null;
    return MessageVariantSwitcher(
      assistantMessage: message,
      variants: variants,
      currentIndex: currentIndex,
      flash: widget.state.variantFlashTurn == turnNumber,
      flashStartedAtMs: widget.state.variantFlashStartedAtMs,
      onSwitch: (index) => widget.onSwitchVariant!(message, index),
      onDelete: widget.onDeleteVariant == null
          ? null
          : (index) => widget.onDeleteVariant!(message, index),
      onFlashConsumed: widget.onVariantFlashConsumed,
    );
  }

  /// 当前轮（idle 末轮）的切换器——目标消息=最后一条 assistant。
  Widget? _buildCurrentRoundVariantSwitcher({
    required IntermediateChatState state,
    required int lastTurn,
  }) {
    ChatMessage? lastAssistant;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].role == 'assistant') {
        lastAssistant = state.messages[i];
        break;
      }
    }
    if (lastAssistant == null) return null;
    return _buildVariantSwitcher(
      message: lastAssistant,
      turnNumber: lastTurn,
      artifacts: state.artifactsByTurnNumber?[lastTurn],
    );
  }

  Widget _buildMessage(
    LmPalette colors,
    ChatMessage message, {
    required String? lastAssistantMessageId,
    required bool actionsEnabled,
    bool? canOperateOverride,
    bool animateEntrance = false,
  }) {
    // 仅针对目标滚动项或高亮项分配 GlobalKey；普通消息使用轻量 ValueKey，
    // 避免成百上千个永久 GlobalKey 阻塞主 Isolate 追踪和排版。
    final isTarget = _targetScrollMessageId == message.messageId ||
        _flashMessageId == message.messageId ||
        widget.initialFocusMessageId == message.messageId;
    final messageKey = isTarget
        ? _messageKeys.putIfAbsent(message.messageId, GlobalKey.new)
        : ValueKey<String>(message.messageId);
    // 压缩摘要消息（isSummary=true, role=system）：用专门的隔断卡片渲染，
    // 不走普通气泡分支。卡片整宽显示 + 区分底色 + 上下留白，视觉上作为
    // 上下文隔断（DOC-06B §6.5）。
    // 位置：由 filterByCompactionPoint 置于列表最前，boundary 之后的消息
    // （含新用户消息）排在摘要后边（用户需求 2026-08-04）。
    if (message.isSummary) {
      return KeyedSubtree(
        key: messageKey,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sSm,
          ),
          child: IntermediateCompactionSummaryCard(
            content: message.content ?? '',
            fontScale: widget.fontScale,
            //  触底警示：压缩后可见列表仅此一张摘要卡，
            // 触底标志即对本卡生效
            showFloorWarning: widget.state.compactionFloorWarningTurn != null,
            // 已归档轮次范围标注
            archivedTurnRange: widget.state.archivedTurnRange,
            // U2（2026-09-04 撤销压缩）：仅 idle 且非压缩中可撤销
            onUndo: widget.onUndoCompaction,
            undoEnabled: widget.state.phase == IntermediatePhase.idle &&
                !widget.state.isManualCompacting,
          ),
        ),
      );
    }

    final isUser = message.role == 'user';
    // 搜索命中的消息短暂着色闪示。
    final isFlashTarget = _flashMessageId == message.messageId;
    return KeyedSubtree(
      key: messageKey,
      child: AnimatedContainer(
        duration: LmMotion.enter,
        margin: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sSm,
        ),
        decoration: BoxDecoration(
          color: isFlashTarget ? colors.primaryDim : Colors.transparent,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        padding: const EdgeInsets.symmetric(
          vertical: IntermediateSpacing.s2xs,
        ),
        child: IntermediateMessageBubble(
          content: message.content ?? '',
          isUser: isUser,
          thinkingContent: message.thinkingContent,
          isLastAssistantMessage: message.messageId == lastAssistantMessageId,
          // canOperateOverride 非 null 时直接用（pendingUserMessage 场景），
          // 否则委托 controller.canOperateMessage 判断窗口范围。
          canOperate: canOperateOverride ?? widget.canOperate(message),
          windowRounds: widget.windowRounds,
          actionsEnabled: actionsEnabled,
          animateEntrance: animateEntrance,
          onCopy: () => widget.onCopy(message),
          onRegenerate: () => widget.onRegenerate(message),
          onEdit: () => widget.onEdit(message),
          onDeleteRound: () => widget.onDeleteRound(message),
          // 字体缩放比例透传，应用到消息正文与思考区块字号
          fontScale: widget.fontScale,
        ),
      ),
    );
  }

  /// 为当前轮 assistant 气泡构造动作回调集合（2026-07-18 修复重新生成 bug）。
  ///
  /// idle 时最后一轮 assistant 消息由 `buildCurrentRoundPanels` 统一渲染，
  /// 但 `buildCurrentRoundPanels` 是顶层函数无法直接访问 widget 回调，
  /// 因此在此处查找消息后构造 `CurrentRoundMessageActions` 传入。
  ///
  /// 找不到消息时（理论不应发生，但防御性处理）返回全 false + 空回调，
  /// 让气泡正常渲染但 actions 不响应——避免构建失败影响消息显示。
  CurrentRoundMessageActions _buildCurrentRoundMessageActions({
    required IntermediateChatState state,
    required String? lastAssistantMessageId,
    required bool actionsEnabled,
  }) {
    // 反向查找最后一条 assistant 消息对象（与上方 lastAssistantMessageId 同源）
    ChatMessage? lastAssistant;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].role == 'assistant') {
        lastAssistant = state.messages[i];
        break;
      }
    }
    if (lastAssistant == null) {
      // 防御：无 assistant 消息时 actions 不响应（不应发生，因 idle 时
      // shouldRenderCurrentRoundPanels 要求 artifacts 非空 → 必有 assistant）
      return CurrentRoundMessageActions(
        canOperate: false,
        windowRounds: widget.windowRounds,
        actionsEnabled: false,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );
    }
    // local non-nullable 变量：闭包捕获后 Dart flow analysis 仍能识别为非空
    final message = lastAssistant;
    return CurrentRoundMessageActions(
      canOperate: widget.canOperate(message),
      windowRounds: widget.windowRounds,
      actionsEnabled: actionsEnabled,
      onCopy: () => widget.onCopy(message),
      onRegenerate: () => widget.onRegenerate(message),
      // assistant 气泡不显示编辑重发按钮（组件内部按 isUser 判断），
      // 但仍需传入占位回调以满足必填参数
      onEdit: () => widget.onEdit(message),
      onDeleteRound: () => widget.onDeleteRound(message),
    );
  }

  /// 空状态：衬线引导文案
  ///
  /// v0.2.2 修复：原实现用 `Center + Column(mainAxisAlignment.center)`，
  /// 键盘弹出时可视区域被压缩，Column 内 children 总高度 > 可用高度时溢出底部
  /// （黄黑斑马纹）。即使每个 Text 都设了 maxLines+ellipsis，Column 本身仍会溢出。
  ///
  /// 修复模式：`LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight)`
  /// - LayoutBuilder 获取键盘挤压后的实际可用高度
  /// - ConstrainedBox(minHeight) 让 Column 能撑满可用高度居中显示
  /// - SingleChildScrollView 在 children 总高度 > 可用高度时允许滚动
  /// - Column mainAxisSize.min + mainAxisAlignment.center 居中布局
  /// 这样既保留了"屏幕中央居中"的视觉效果，又避免了键盘挤压导致的溢出。
  Widget _buildEmptyState(LmPalette colors) {
    final t = Translations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.all(IntermediateSpacing.s2xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_stories,
                    size: 48,
                    color: colors.faint,
                  ),
                  const SizedBox(height: IntermediateSpacing.sLg),
                  Text(
                    t.intermediate.chat.emptyTitle,
                    style: IntermediateTextStyles.narrativeDisplay.copyWith(
                      color: colors.ink,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: IntermediateSpacing.sXs),
                  Text(
                    t.intermediate.chat.emptyDesc,
                    style: IntermediateTextStyles.bodyUi.copyWith(
                      color: colors.muted,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 示例开场卡（点击一键填入输入框，对齐导演）
                  if (widget.onUseExample != null) ...[
                    const SizedBox(height: IntermediateSpacing.sLg),
                    Material(
                      color: colors.surfaceVariant,
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.md),
                      ),
                      child: InkWell(
                        onTap: () => widget
                            .onUseExample!(t.intermediate.chat.emptyExample),
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.md),
                        ),
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: 44,
                            maxWidth: 300,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: IntermediateSpacing.sLg,
                            vertical: IntermediateSpacing.sSm,
                          ),
                          child: Column(
                            children: [
                              Text(
                                t.intermediate.chat.emptyExample,
                                style: IntermediateTextStyles.bodyUi.copyWith(
                                  color: colors.ink,
                                  fontStyle: FontStyle.italic,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: IntermediateSpacing.s2xs),
                              Text(
                                t.intermediate.chat.emptyExampleAction,
                                style: IntermediateTextStyles.caption.copyWith(
                                  color: colors.faint,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
