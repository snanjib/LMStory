import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_compaction_summary_card.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_navigation.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/follow_scroll_executor.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
// TODO(decouple): 临时依赖，P1/P2 迁往 advanced/story_runtime 后消除
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_timeline_assembler.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_process_row.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_recap_card.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
// 变体切换器自本文件提取为 story_runtime 共享组件
import 'package:lmstory/features/story_runtime/presentation/widgets/message_variant_switcher.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式消息区（体验重构 §4 + 对话流计划 §5.2：L0 正文 / 折叠组 / L2 审计分层）
///
/// 一轮 = 用户气泡 + 幕后折叠组（[DirectorWorkGroup]，思考/播报/动作按
/// 真实顺序交错，默认收起、error 动作卡常显）+ 叙事正文（稿件卡，永远
/// 可见的唯一主角，在折叠组之外）。等宽字体与原始参数只存在于 L2 审计
/// 展开层。
///
/// 直播与收工同构（§2.3）：直播态由 AgentTimelineAssembler 现算装配同一条
/// 交错时间线原样直播（组默认展开，收工自动收起）；升格正文的末个文本段
/// 流式进稿件卡。历史轮优先按 artifacts.agentTimeline 渲染，旧会话（缺列）
/// 回退 agentSteps-only 的 [DirectorProcessRow]。发送后首增量前由
/// [_PendingNarrative] 呼吸标签占位。
///
/// 滚动（2026-08-31 二次修复：普通方向列表）：曾用 reverse ListView 免费获得
/// "初始贴底"，但阅读态下直播增长（尾部 child 变高）会把视口内容逐帧顶走，
/// 事后补偿必然慢一帧、流式高频更新下两种画面交替闪屏。普通方向列表的尾部
/// 增长发生在视口外，历史内容坐标天然稳定，无需补偿；贴底初值改由首帧
/// 对齐 + 收敛校准实现，跟随语义与故事模式一致（跟随状态机：上划即停）。
/// 右下角浮层：生成中为「回到最新」胶囊，收工后为与故事模式同款的四键
/// 导航条（回顶 / 上、下一条用户消息 / 回底）。
///
/// 外壳（AppBar/输入/设置/记忆）仍复用故事模式；只有本消息区是专属重写。
class DirectorChatBody extends StatefulWidget {
  const DirectorChatBody({
    required this.state,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
    this.onUseExample,
    this.windowRounds = 5,
    this.onUndoCompaction,
    this.onSwitchVariant,
    this.onDeleteVariant,
    this.onVariantFlashConsumed,
    this.onEditAnchor,
    this.pureReading = false,
    this.initialFocusMessageId,
    this.fontScale = 1.0,
    super.key,
  });

  final AdvancedChatState state;
  final void Function(ChatMessage) onCopy;
  final void Function(ChatMessage) onRegenerate;
  final void Function(ChatMessage) onEdit;
  final void Function(ChatMessage) onDeleteRound;

  /// 空态示例开场语的一键填入（接输入框 setText）
  final void Function(String example)? onUseExample;

  /// 字体缩放比例（= fontSize.clamp(12,22)/15，与 chat/故事页同源）。
  /// 应用到稿件卡正文与用户气泡基准字号；UI 标签不受影响。
  final double fontScale;

  /// 可操作窗口轮数（体验重构 ：与故事模式同源于 fork.regenerateWindowRounds）
  final int windowRounds;

  /// 撤销压缩回调（U2，2026-09-04）：null = 摘要卡不显示撤销入口。
  /// 与故事模式同构（IntermediateChatBody.onUndoCompaction）。
  final Future<void> Function()? onUndoCompaction;

  /// 切换该轮稿件变体（null = 变体功能不可用，不渲染切换器）
  final Future<void> Function(ChatMessage assistant, int variantIndex)?
      onSwitchVariant;

  /// 删除非当前变体
  final Future<void> Function(ChatMessage assistant, int variantIndex)?
      onDeleteVariant;

  /// 切换器 2s 高亮消费完毕（清除 state.variantFlashTurn）
  final VoidCallback? onVariantFlashConsumed;

  /// 编辑当前剧情锚（null = 功能不可用）。仅最新已完成幕的 Recap 卡
  /// 提供入口——历史轮快照保持只读，编辑写入会话当前锚（与 AI 同一数据源）。
  final ValueChanged<StoryAnchor>? onEditAnchor;

  /// 全局搜索命中进入时携带：定位到命中消息所在轮
  /// 的用户气泡行（导演行的渲染变体多，v1 只定位不闪示）。普通进入为 null。
  final String? initialFocusMessageId;

  /// 纯净阅读模式——隐藏全部幕后（折叠组/
  /// 过程行/用户气泡/直播组），只留稿件流+Recap+压缩摘要；偏好由页面层
  /// 按会话持久，重生成窗口等操作入口随之隐藏（切回正常模式操作）。
  final bool pureReading;

  @override
  State<DirectorChatBody> createState() => _DirectorChatBodyState();
}

class _DirectorChatBodyState extends State<DirectorChatBody>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();

  // ── ：时间线装配签名缓存 ──────────────────────
  //
  // build 期每次都跑 AgentTimelineAssembler.assemble（O(blocks+steps)），
  // 但装配输入只在 live 增量/步事件变化时才变。输入（实体均不可变，
  // final 字段）按元素 identical 比较 + 升格下标构成签名：命中则复用
  // 上次装配的 List（无关重建——压缩流式/上下文用量回流/相位标量——
  // 不再重跑装配）；元素实例被替换（文本追加、步状态翻转）即失效。
  List<AgentTimelineBlock>? _timelineCache;
  var _timelineInputBlocks = const <AgentLiveBlock>[];
  var _timelineInputSteps = const <AgentWorkStep>[];
  int? _timelineInputPromoted;

  /// 底部容差（普通方向列表：maxExtent - offset 为距底距离）：80px 内视为贴底。
  static const double _bottomTolerance = 80;

  /// 滚动导航：用户滑动中为 true，停止 2 秒后自动 false。
  bool _isScrollActive = false;

  /// 滚动导航：是否脱离底部（脱离时才显示导航条/回到最新胶囊）。
  bool _awayFromBottom = false;

  /// 滚动空闲计时器（2 秒后标记滑动停止）。
  Timer? _scrollIdleTimer;

  /// 贴底跟随裁决与执行（2026-09-10 chatbox smooth-follow-output 语义
  /// 移植，与 chat/故事模式同款 [FollowScrollExecutor]， 单源）：
  ///
  /// 普通方向列表下直播内容增长发生在列表尾部（视口下方），不移动视口内
  /// 的历史内容——阅读态天然静止，只需上划即停（首帧冻结，不需脱离任何
  /// 容差带，慢速上划看历史不被流式更新拉回）；滚回距底 ≤4px 自动恢复；
  /// 发送/点「回到最新」强制回底。执行为统一的「缓冲 + 限速滑行」（两
  /// 平台一致，，取代早期「桌面平滑 / 移动直贴」分派）。
  late final FollowScrollExecutor _followExecutor;

  /// 首帧对齐：普通方向列表初始停在顶部（最旧），首次有内容后跳到最新
  /// 并等待懒加载收敛（reverse 列表曾免费获得贴底初值）。
  bool _initialAligned = false;

  /// 搜索定位已处理标记。
  bool _focusHandled = false;

  /// 用户气泡 row 的定位 key：消息 id → GlobalKey（缓存复用避免重建 reparent）。
  final Map<String, GlobalKey> _rowKeys = {};

  /// 时间序用户气泡 row id（含 pending），供上/下一条用户消息跳转。
  /// build 期 O(n) 扫描 messages 收集（不依赖行构建，行已懒化）。
  List<String> _userRowIds = const [];

  @override
  void initState() {
    super.initState();
    _followExecutor = FollowScrollExecutor(
      controller: _scrollController,
      vsync: this,
    );
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _alignToLatestOnce());
  }

  @override
  void didUpdateWidget(DirectorChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 导演→导演切会话时重置滚动阅读态——页面无 key
    // 复用 State，旧会话的上滑冻结态与游标位置会漏进新会话（夹断位置
    // 落地、跟随冻结且四键条隐藏）；_initialAligned 复位让首帧对齐重跑。
    if (widget.state.session.sessionId != oldWidget.state.session.sessionId) {
      _followExecutor.reset();
      _initialAligned = false;
    }
    // 同会话再次被搜索命中时重新定位——页面壳无 key
    // 复用 State，定位逻辑挂在 _initialAligned 单次门控的 _alignToLatestOnce
    // 上，二次命中静默失效。initialFocusMessageId 变化是唯一的重定位信号；
    // 命中消息未入 state（缓存控制器异步首载）时逐帧重试。
    if (widget.initialFocusMessageId != null &&
        widget.initialFocusMessageId != oldWidget.initialFocusMessageId) {
      _focusHandled = false; // 新深链允许再次定位
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusSearchHit();
      });
    }
    _alignToLatestOnce();

    final hasNewContent =
        widget.state.messages.length > oldWidget.state.messages.length ||
            _liveContentGrew(oldWidget.state, widget.state) ||
            widget.state.agentSteps.length > oldWidget.state.agentSteps.length;
    // 发送瞬间（pending 气泡出现）：用户意图明确看最新，强制回底并恢复
    // 跟随（对齐故事模式 ：绕过一切阅读态判定，发送语义单次校准）。
    final pendingAppeared = oldWidget.state.pendingUserMessage == null &&
        widget.state.pendingUserMessage != null;
    if (pendingAppeared) {
      _forceToBottomWithSettle();
    } else if (hasNewContent && _followExecutor.state.following) {
      // 贴底跟随（gate 全权交给执行器：上划即停/回底 ≤4px 自动恢复；
      // 桌面平滑趋近/移动直贴）
      _followExecutor.followGrowth();
    }
    // 帧末对账：内容收缩（收工折叠、稿件并档）可能让布局把滚动位置
    // clamp 到新的 maxScrollExtent 且不经滚动监听——物理贴底且未跟随
    // 说明是收缩钳位而非用户阅读位，恢复跟随并同步浮层可见性。
    // 判据必须是状态机同源的贴底线，不得用
    // 80px 容差带——「上划即停」会冻结带内上划，宽判据随后的帧末对账
    // 把阅读位强行恢复成跟随、下一个 delta 就拉回底部。收缩钳位落地时
    // gap 必然归零（或收缩把 gap 拉进贴底线），本判据完整覆盖对账块
    // 的本来目的；带内阅读位（gap 4-80px）不再被推翻。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      final gap = position.maxScrollExtent - position.pixels;
      if (gap <= _followExecutor.state.resumeAtBottomPx &&
          !_followExecutor.state.following) {
        _followExecutor.state.forceFollowing();
      }
      _syncAwayFromBottom();
    });
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _followExecutor.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  bool get _isWorking =>
      widget.state.phase != IntermediatePhase.idle &&
      widget.state.phase != IntermediatePhase.failed;

  bool get _hasAnyContent =>
      widget.state.messages.isNotEmpty ||
      widget.state.pendingUserMessage != null ||
      widget.state.liveBlocks.isNotEmpty ||
      widget.state.agentSteps.isNotEmpty;

  ///  批3：直播内容是否增长——O(1) 判定，替代此前每 delta 的全块
  /// 遍历累加文本长度（O(总文本量)，长稿件时每帧都白算）。
  /// 语义等价：总长增长 ⟺ 块数增长，或（块数不变时）末块变长。
  static bool _liveContentGrew(
    AdvancedChatState oldState,
    AdvancedChatState newState,
  ) {
    final oldBlocks = oldState.liveBlocks;
    final newBlocks = newState.liveBlocks;
    if (newBlocks.length != oldBlocks.length) {
      return newBlocks.length > oldBlocks.length;
    }
    if (newBlocks.isEmpty) return false;
    return newBlocks.last.text.length > oldBlocks.last.text.length;
  }

  /// 首次有内容时对齐到底部（只执行一次）。
  void _alignToLatestOnce() {
    if (_initialAligned || !_hasAnyContent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _initialAligned ||
          !_scrollController.hasClients ||
          !_hasAnyContent) {
        return;
      }
      _initialAligned = true;
      // 搜索命中进入优先定位命中轮（覆盖跳底对齐）。
      final focusRowId = _resolveFocusRowId();
      if (focusRowId != null) {
        _revealUserRow(focusRowId);
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      _settleAtBottom(8);
    });
  }

  /// 命中消息 → 所在轮的用户气泡 row id
  ///（向前含自身找最近 user；找不到/已处理过返回 null）。
  String? _resolveFocusRowId() {
    final id = widget.initialFocusMessageId;
    if (id == null || _focusHandled) return null;
    final messages = widget.state.messages;
    final targetIndex = messages.indexWhere((m) => m.messageId == id);
    if (targetIndex < 0) return null;
    String? rowId;
    for (var i = targetIndex; i >= 0; i--) {
      if (messages[i].role == 'user') {
        rowId = messages[i].messageId;
        break;
      }
    }
    if (rowId == null || !_userRowIds.contains(rowId)) return null;
    _focusHandled = true;
    return rowId;
  }

  /// 解析并定位当前深链命中轮。命中消息尚未进入
  /// state（缓存控制器的异步首载）时隔帧重试，上限 8 帧后放弃。
  void _focusSearchHit({int attemptsRemaining = 8}) {
    if (!mounted || attemptsRemaining <= 0) return;
    final rowId = _resolveFocusRowId();
    if (rowId != null) {
      _revealUserRow(rowId);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusSearchHit(attemptsRemaining: attemptsRemaining - 1);
    });
  }

  /// 用户是否位于底部附近（贴底跟随决策，故事模式同款）。
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < _bottomTolerance;
  }

  /// 强制回底（发送路径）：执行器恢复跟随并即时贴底（两平台一致，
  /// 桌面也不走平滑），settle 校准挂 postFrame 下一帧——发送有「一次
  /// 到位」预期，懒加载列表 maxScrollExtent 修正后做单次校准（稳态下
  /// 距离 ≤1 直接 no-op；沿用  改造前发送路径的单次 settle 语义，
  /// 流式跟随路径零 settle）。上滚冻结/「回到最新」胶囊/首帧对齐
  /// 语义不变。
  void _forceToBottomWithSettle() {
    _followExecutor.forceToBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _settleAtBottom(1);
      }
    });
  }

  /// 懒加载列表的 maxScrollExtent 在远端内容布局后修正；到位后再逐帧
  /// 校准，保证精确贴底（同故事模式 _settleAtBottom 思路）。
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

  /// 滚动监听：跟随状态机输入 + 导航可见性。
  ///
  /// 跟随裁决交给 [FollowScrollExecutor]（chatbox 语义）：
  /// - 上划即停：pixels 下降（且非内容收缩钳位）首帧即冻结贴底跟随
  /// - 滚回距底 ≤4px 自动恢复；发送/点胶囊由执行器强制回底
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    _followExecutor.handleScrollMetrics(
      position.pixels,
      position.maxScrollExtent,
    );

    if (!_isScrollActive) {
      setState(() => _isScrollActive = true);
    }
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isScrollActive = false);
    });

    _syncAwayFromBottom();
  }

  void _syncAwayFromBottom() {
    if (!_scrollController.hasClients) return;
    final away = !_isNearBottom();
    if (_awayFromBottom != away) {
      setState(() => _awayFromBottom = away);
    }
  }

  /// row 的 reveal 偏移（child 与视口对齐所需的滚动位置，与当前
  /// pixels 正交）。行未挂载（远端懒加载）或已失联时返回 null。
  double? _revealOf(String rowId, {required double target}) {
    final key = _rowKeys[rowId];
    final context = key?.currentContext;
    if (context == null) return null;
    final renderObject = context.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    final viewport = RenderAbstractViewport.of(renderObject);
    return viewport.getOffsetToReveal(renderObject, target).offset;
  }

  /// row 当前在滚动坐标中的可视区间 [top, bottom]；未挂载返回 null。
  ///
  /// 普通方向视口：target=0 = child 顶端对齐视口顶端（即 child 的
  /// scrollOffset）；target=1 = child 底端对齐视口底端（= 底端 − 视口
  /// 高度），需补回。
  (double, double)? _rowExtent(String rowId) {
    if (!_scrollController.hasClients) return null;
    final top = _revealOf(rowId, target: 0);
    final bottomRaw = _revealOf(rowId, target: 1);
    if (top == null || bottomRaw == null) return null;
    return (top, bottomRaw + _scrollController.position.viewportDimension);
  }

  // ---------------------------------------------------------------------------
  // 跳转
  // ---------------------------------------------------------------------------

  /// 跳到顶部（最旧内容，offset 0 恒精确，无需收敛校准）。
  void _jumpToTop() {
    if (!_scrollController.hasClients) return;
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController.animateTo(
      0,
      duration: LmMotion.emphasis,
      curve: LmMotion.easeStandard,
    );
  }

  /// 跳到底部（最新内容）。用户主动回底 = 强制恢复贴底跟随（故事模式同语义）。
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _followExecutor.state.forceFollowing();
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController
        .animateTo(
      _scrollController.position.maxScrollExtent,
      duration: LmMotion.slow,
      curve: LmMotion.easeEmphasis,
    )
        .whenComplete(() {
      if (mounted) _settleAtBottom();
    });
  }

  void _jumpToPrevUserMessage() => _jumpToUserMessage(forward: false);

  void _jumpToNextUserMessage() => _jumpToUserMessage(forward: true);

  /// 跳到上/下一条用户消息（对标故事模式：以视口内第一条可见用户气泡为
  /// 基准向前/向后找；无可见基准时回退到最旧/最新一条）。
  void _jumpToUserMessage({required bool forward}) {
    final ids = _userRowIds;
    if (ids.isEmpty || !_scrollController.hasClients) return;

    final position = _scrollController.position;
    final vpTop = position.pixels;
    final vpBottom = vpTop + position.viewportDimension;
    var visibleRank = -1;
    for (var i = 0; i < ids.length; i++) {
      final extent = _rowExtent(ids[i]);
      if (extent == null) continue;
      final (top, bottom) = extent;
      if (top < vpBottom && bottom > vpTop) {
        visibleRank = i;
        break;
      }
    }

    var targetRank = forward ? visibleRank + 1 : visibleRank - 1;
    if (visibleRank < 0) {
      targetRank = forward ? ids.length - 1 : 0;
    } else if (targetRank < 0 || targetRank >= ids.length) {
      return;
    }
    _revealUserRow(ids[targetRank]);
  }

  /// 滚动到指定用户气泡（顶对齐）。远端行未布局时按用户消息序比例估计
  /// offset 逼近，逐帧校准到精确 reveal 偏移（同故事模式）。
  void _revealUserRow(String rowId, {int attemptsRemaining = 8}) {
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    final target = _revealOf(rowId, target: 0);
    if (target != null) {
      _scrollController.animateTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: LmMotion.emphasis,
        curve: LmMotion.easeStandard,
      );
      return;
    }
    if (!_scrollController.hasClients ||
        attemptsRemaining <= 0 ||
        _userRowIds.length < 2) {
      return;
    }
    final position = _scrollController.position;
    final rank = _userRowIds.indexOf(rowId);
    if (rank < 0) return;
    // 普通方向列表：越旧（rank 小）offset 越小
    final ratio = rank / (_userRowIds.length - 1);
    _scrollController.jumpTo(
      (position.maxScrollExtent * ratio).clamp(0.0, position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _revealUserRow(rowId, attemptsRemaining: attemptsRemaining - 1);
    });
  }

  GlobalKey _rowKeyFor(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  /// 逐元素 identical（实体不可变：实例相同 ⟺ 内容相同）；长度或任一
  /// 元素被替换即视为输入变化。
  static bool _sameByElement<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    if (state.messages.isEmpty &&
        state.pendingUserMessage == null &&
        state.liveBlocks.isEmpty &&
        state.agentSteps.isEmpty) {
      // 历史加载中渲染骨架而非空态引导——重会话打开瞬间不再
      // 闪「发送第一句话开始」
      if (state.loadingHistory) return const _HistoryLoadingSkeleton();
      return _DirectorEmptyState(onUseExample: widget.onUseExample);
    }

    // 失联行（会话切换/压缩重建）清理 key，避免长时间使用持续累积。
    final activeIds = {
      for (final message in state.messages) message.messageId,
      if (state.pendingUserMessage != null) state.pendingUserMessage!.messageId,
    };
    _rowKeys.removeWhere((id, _) => !activeIds.contains(id));

    // （=）：用户气泡 row id 改为 O(n) 消息扫描收集
    //（顺序与旧 _buildRows 内联收集一致：时间序 user 消息 + 末尾 pending），
    // 不再依赖行构建——行懒构建后 build 期只剩这一遍轻量扫描。
    _userRowIds = [
      for (final message in state.messages)
        if (message.role == 'user') message.messageId,
      if (state.pendingUserMessage != null) state.pendingUserMessage!.messageId,
    ];

    // 尾部进行中轮（pending 气泡 / live 折叠组 / 稿件卡或呼吸占位）在
    // build 期预判槽位与数据（装配一次，itemBuilder 复用）。
    final blocks = state.liveBlocks;
    var manuscriptIndex = -1;
    for (var i = blocks.length - 1; i >= 0; i--) {
      if (blocks[i].kind == AgentLiveBlockKind.text && !blocks[i].isEmpty) {
        manuscriptIndex = i;
        break;
      }
    }
    // 直播与收工同构（对话流 §2.3 + 正文交付契约 §5.2）：live 态由装配器
    // 现算同一条交错时间线，升格块与稿件卡同源——末个非空文本段不进组、
    // 流式进稿件卡。
    final promotedIndex = manuscriptIndex >= 0 ? manuscriptIndex : null;
    // 输入签名命中 → 复用上次装配结果（见 _timelineCache 注释）
    final timelineUnchanged = _timelineCache != null &&
        _sameByElement(blocks, _timelineInputBlocks) &&
        _sameByElement(state.agentSteps, _timelineInputSteps) &&
        promotedIndex == _timelineInputPromoted;
    final liveTimeline = timelineUnchanged
        ? _timelineCache!
        : blocks.isEmpty && state.agentSteps.isEmpty
            ? const <AgentTimelineBlock>[]
            : AgentTimelineAssembler.assemble(
                liveBlocks: blocks,
                agentSteps: state.agentSteps,
                promotedIndex: promotedIndex,
              );
    if (!timelineUnchanged) {
      _timelineCache = liveTimeline;
      _timelineInputBlocks = blocks;
      _timelineInputSteps = state.agentSteps;
      _timelineInputPromoted = promotedIndex;
    }
    final manuscriptBlock =
        manuscriptIndex >= 0 ? blocks[manuscriptIndex] : null;
    // 纯净阅读隐藏尾槽的 pending 气泡与直播折叠组（重试提示与稿件
    // 卡保留——前者是系统裁决通知，后者正是阅读对象）
    final hasPending = state.pendingUserMessage != null && !widget.pureReading;
    final hasLiveGroup = liveTimeline.isNotEmpty && !widget.pureReading;
    // 请求重试等待状态条（工作态才渲染；位于 pending 气泡与折叠组之间）
    final hasRetryRow = _isWorking && state.agentRetryWait != null;
    // 稿件卡与呼吸占位互斥占用同一尾槽（旧实现的 else-if 语义）
    final hasTailBody = manuscriptBlock != null ||
        (_isWorking && blocks.isEmpty && state.agentSteps.isEmpty);
    final tailItemCount = (hasPending ? 1 : 0) +
        (hasRetryRow ? 1 : 0) +
        (hasLiveGroup ? 1 : 0) +
        (hasTailBody ? 1 : 0);

    final showPill = _awayFromBottom && _isWorking;
    final showNav = _awayFromBottom && !_isWorking;
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Stack(
      children: [
        // 行按 index 现算懒构建（对齐故事侧 intermediate_chat_body
        // 的 builder 范式）——此前 _buildRows 每 build 全量实例化所有行
        // widget、itemBuilder 只取数组下标，直播期间每个 delta 都为全部
        // 历史轮付出行装配成本；现在只有可见轮付 Markdown/面板/布局成本。
        RepaintBoundary(
          child: ListView.builder(
            controller: _scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(600),
            // 2026-09-10：底部缓冲留白（惰性跟随用）——写入行在缓冲内下走时
            // 视口不动，已读文字保持静止。
            padding: const EdgeInsets.fromLTRB(
              IntermediateSpacing.sMd,
              IntermediateSpacing.sMd,
              IntermediateSpacing.sMd,
              IntermediateSpacing.sMd + streamingFollowCushionPx,
            ),
            itemCount: state.messages.length + tailItemCount,
            // 键 → index 回查——builder 型 sliver 默认不做跨索引 key
            // 移位（SliverChildBuilderDelegate.findIndexByKey 无回调时恒
            // null），删除中间轮后轮聚合项的展开态要跟随轮迁移必须显式回查
            //（回调收到的键已经过 delegate 解盐，即 itemBuilder 产出的原键）。
            findChildIndexCallback: _findRoundChildIndex,
            itemBuilder: (context, index) {
              if (index < state.messages.length) {
                return _buildPersistedItem(state, index);
              }
              var tailIndex = index - state.messages.length;
              if (hasPending) {
                if (tailIndex == 0) return _pendingUserRow(state);
                tailIndex--;
              }
              // 重试等待状态条（折叠组上方单行）
              if (hasRetryRow) {
                if (tailIndex == 0) {
                  return AgentRetryWaitRow(
                    key: const ValueKey('agent-retry-wait-row'),
                    wait: state.agentRetryWait!,
                  );
                }
                tailIndex--;
              }
              if (hasLiveGroup) {
                if (tailIndex == 0) {
                  // live 跟随工作态——取消/失败后残留的
                  // 过程行不再以「正在 X…」的 shimmer 形态挂在 idle 界面
                  //（历史态渲染为已收起的 idle 汇总行）
                  return DirectorWorkGroup(
                    timeline: liveTimeline,
                    live: _isWorking,
                    // 正文流式接管焦点后，末段思考行自动收起（同旧直播行为）
                    textStreaming: _isWorking &&
                        blocks.isNotEmpty &&
                        blocks.last.kind == AgentLiveBlockKind.text,
                    // 预算进度快照（live 标题「第 N/M 步 · 已用 X:XX」）
                    progress: state.agentRoundProgress,
                  );
                }
                tailIndex--;
              }
              if (hasTailBody) {
                // 稿件卡：升格正文块（直播流式 / 失败轮半截中性收尾）
                if (manuscriptBlock != null) {
                  return Center(
                    // 阅读行宽钳制（与历史稿件行同款）
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: IntermediateSpacing.readingWidth,
                      ),
                      child: _ManuscriptCard(
                        key: const ValueKey('live-manuscript'),
                        text: manuscriptBlock.text,
                        streaming: _isWorking,
                        fontScale: widget.fontScale,
                        // 失败轮的半截稿件未定稿也不会入库，不得挂
                        //「落幕线」定稿视觉（重试即蒸发），留中性收尾
                        failed: state.phase == IntermediatePhase.failed,
                      ),
                    ),
                  );
                }
                // 刚发送、尚无任何增量时的呼吸标签（有步骤/时间线时由折叠组报告）
                return const _PendingNarrative(showLabel: true);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
        // 生成中：醒目的「回到最新」胶囊；收工后：与故事模式同款的
        // 四键导航条（回顶 / 上、下一条用户消息 / 回底）。二者互斥。
        if (showPill)
          Positioned(
            right: IntermediateSpacing.sLg,
            bottom: IntermediateSpacing.sMd,
            child: _JumpToLatestPill(onTap: _jumpToBottom),
          ),
        if (showNav)
          Positioned(
            right: IntermediateSpacing.sSm,
            bottom: IntermediateSpacing.sMd,
            child: IntermediateMessageNavigation(
              visible: _isScrollActive,
              onJumpToTop: _jumpToTop,
              onJumpToBottom: _jumpToBottom,
              onPrevUserMessage: _jumpToPrevUserMessage,
              onNextUserMessage: _jumpToNextUserMessage,
            ),
          ),
        // 重生成/编辑重发「准备中」遮罩（照抄故事侧
        // DOC-09A-1 样板）——DB 删除 await 期间覆盖聊天区，半透明底 +
        // 居中转圈 + AbsorbPointer 拦截列表交互。
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
                        t.advanced.chat.preparingRegenerate,
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

  /// `director-round-<assistant 消息 id>` 聚合键 → 消息 index。
  ///
  /// 只回查轮聚合项（附带缺陷的主角：用户手动展开的幕后组/Recap 展开
  /// 态）；user 行的 GlobalKey（服务滚动 reveal，不服务状态保持）与
  /// live 尾项（每 delta 重建、finalize 即消散）返回 null，沿用按位匹配
  /// ——与旧急构建的删除行为同口径，不扩大本批语义。
  int? _findRoundChildIndex(Key key) {
    if (key is! ValueKey<String>) return null;
    final value = key.value;
    if (!value.startsWith('director-round-')) return null;
    final id = value.substring('director-round-'.length);
    final messages = widget.state.messages;
    // 从 1 起：聚合项只可能落在紧跟 user 的 assistant 上（与分派一致）
    for (var i = 1; i < messages.length; i++) {
      final message = messages[i];
      if (message.messageId == id &&
          message.role == 'assistant' &&
          messages[i - 1].role == 'user') {
        return i;
      }
    }
    return null;
  }

  /// 按消息 index 分派历史行（对齐故事侧 _buildPersistedMessageGroup
  /// 范式）。与旧 _buildRows while 循环逐分支等价、行序零变化：
  ///
  /// - user 消息 → 用户气泡行（旧实现里 user 之后同轮的组/正文/Recap
  ///   移入紧随其后的 assistant 消息自己的聚合项，视觉顺序不变）
  /// - 紧跟 user 的 assistant → 单轮聚合项 [_persistedRoundGroup]
  ///   （折叠组或旧数据过程行 + 正文行 + Recap 卡）
  /// - isSummary 摘要卡 / 孤儿消息兜底正文行 → 各自成独立项
  Widget _buildPersistedItem(AdvancedChatState state, int index) {
    final messages = state.messages;
    final message = messages[index];
    // 纯净阅读隐藏用户气泡（只留稿件流+Recap+摘要卡）
    if (message.role == 'user' && widget.pureReading) {
      return const SizedBox.shrink();
    }
    if (message.role == 'user') {
      return _userRow(message);
    }
    if (message.isSummary) {
      // DP-1：压缩摘要行不是正文——对齐故事模式的隔断卡
      //（IntermediateCompactionSummaryCard），不挂任何消息操作：
      // 编辑会改写 DB 宏摘要污染后续每轮请求，删除会从摘要行起清空
      // 全部可见历史。
      return _summaryRow(message);
    }
    if (message.role == 'assistant' &&
        index > 0 &&
        messages[index - 1].role == 'user') {
      return _persistedRoundGroup(state, message);
    }
    // 孤儿 assistant / system 消息：按叙事正文兜底渲染（旧 while 循环的
    // else 分支，无 artifacts 配套）
    return _assistantRow(message);
  }

  /// 单轮聚合项：幕后折叠组（或旧数据过程行）+ 叙事正文 + 幕间 Recap 卡。
  ///
  /// 键取 assistant 消息 id（附带缺陷修复）：删除中间轮后轮号整体
  /// 前移，turn 号键会让错位的 Element 承接展开态；消息 id 在兄弟轮删除
  /// 后保持稳定。重生成换 id 时聚合组状态随之重置（新内容理应如此）。
  Widget _persistedRoundGroup(AdvancedChatState state, ChatMessage assistant) {
    //  修复：artifacts 键为真实轮次号，需叠加压缩基数
    // 改走共享工具的 role 感知配对推导（公式侧唯一实现；
    //  批3 性能：经 _turnNumberOf memo，见其注释）
    final turn = _turnNumberOf(assistant) ?? 0;
    final artifacts = state.artifactsByTurnNumber?[turn];
    final timeline = artifacts?.agentTimeline ?? const <AgentTimelineBlock>[];
    final steps = artifacts?.agentSteps ?? const <AgentWorkStep>[];
    final anchor = artifacts?.storyAnchor;
    return Column(
      key: ValueKey('director-round-${assistant.messageId}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 纯净阅读隐藏幕后折叠组/过程行（稿件与 Recap 保留）
        if (!widget.pureReading) ...[
          if (timeline.isNotEmpty)
            // 新数据：轮时间线 → 单一折叠组（思考/播报/动作交错）
            DirectorWorkGroup(
              timeline: timeline,
              summary: artifacts?.agentWorkSummary,
            )
          else if (steps.isNotEmpty)
            // 旧数据回退：agentSteps-only 的 L1 过程行（零迁移可用）
            DirectorProcessRow(
              steps: steps,
              summary: artifacts?.agentWorkSummary,
            ),
        ],
        // 思考已随时间线进折叠组；旧数据仍由消息行 thinkingContent 渲染
        _assistantRow(
          assistant,
          hideThinking: timeline.isNotEmpty || widget.pureReading,
          variants: state.variantsByTurn?[turn],
          currentVariantIndex: artifacts?.currentVariantIndex,
          flashNewVariant: state.variantFlashTurn == turn,
          flashStartedAtMs: state.variantFlashStartedAtMs,
        ),
        if (anchor != null && !anchor.isEmpty)
          DirectorRecapCard(
            act: turn,
            anchor: anchor,
            // （'）：设定集变更 chip（点击直达记忆库）
            factsChangeCount: artifacts?.factsChanges.length ?? 0,
            onOpenMemory: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MemoryBrowserPage(
                  session: state.session,
                ),
              ),
            ),
            // 编辑入口只给最新已完成幕（编辑目标是会话当前锚，
            // 历史轮快照保持只读）
            onEditAnchor: turn == _latestCompletedTurn(state) &&
                    widget.onEditAnchor != null
                ? widget.onEditAnchor
                : null,
          ),
      ],
    );
  }

  /// 尾槽 1：pending 用户气泡。
  ///
  /// 失败/中断轮的临时气泡可操作（对齐故事模式的 actionsEnabled 判定）：
  /// 重新生成=重发本轮输入，编辑/删除由页面层走 pending 专属入口；
  /// 生成中保持不可操作，避免轮次进行中误触
  ///  同族：手动压缩全程 phase=idle，须一并锁定
  Widget _pendingUserRow(AdvancedChatState state) {
    return _userRow(
      state.pendingUserMessage!,
      interactive: (state.phase == IntermediatePhase.idle ||
              state.phase == IntermediatePhase.failed) &&
          !state.isManualCompacting,
      // DP-2：pending 气泡不在 messages 里（轮次推导为 null），
      // 失败/中断轮的编辑重发是设计入口，显式放行（同故事模式
      // canOperateOverride 的 pending 场景）
      canOperateOverride: true,
    );
  }

  Widget _userRow(
    ChatMessage message, {
    bool interactive = true,
    bool? canOperateOverride,
  }) {
    //  同族：手动压缩全程 phase=idle，用户菜单与
    // 助手行内动作一并锁定——控制器 regenerate/edit/delete 遇
    // isManualCompacting 静默 no-op，UI 必须同口径，否则可点而无反馈。
    final actionsEnabled = !widget.state.isManualCompacting;
    return Padding(
      key: _rowKeyFor(message.messageId),
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: IntermediateMessageBubble(
        content: message.content ?? '',
        isUser: true,
        fontScale: widget.fontScale,
        actionsEnabled: actionsEnabled,
        // DP-2：历史轮按 Fork 窗口门控；pending 气泡（不在 messages 里，
        // 轮次推导为 null）由调用方显式放行
        canOperate: canOperateOverride ?? _canOperateMessage(message),
        onCopy: interactive ? () => widget.onCopy(message) : () {},
        onRegenerate: interactive ? () => widget.onRegenerate(message) : () {},
        onEdit: interactive ? () => widget.onEdit(message) : () {},
        onDeleteRound:
            interactive ? () => widget.onDeleteRound(message) : () {},
      ),
    );
  }

  /// DP-1：压缩摘要隔断卡（与故事模式同款组件）。
  ///
  /// 导演态无 compactionFloorWarningTurn / archivedTurnRange 数据源
  ///（AdvancedChatState 未携带，属 domain 实体），两可选项维持组件默认
  /// 关闭；纯展示、零消息操作。
  Widget _summaryRow(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: IntermediateSpacing.sSm),
      child: IntermediateCompactionSummaryCard(
        content: message.content ?? '',
        // U2（2026-09-04 撤销压缩）：与故事模式同构，仅 idle 且非压缩中可撤销
        onUndo: widget.onUndoCompaction,
        undoEnabled: widget.state.phase == IntermediatePhase.idle &&
            !widget.state.isManualCompacting,
      ),
    );
  }

  ///  批3：轮号推导 memo（messages 引用 + 压缩基数为键）。
  ///
  /// [turnNumberForMessage] 是 O(index) 的向前扫描（配对推导），
  /// 历史轮装配一次 + `_canOperateMessage` 每行一次，长会话每 build
  /// 合计 O(n²)——流式期间每 delta 全量重算。messages 列表只在 persist
  /// 时换引用，直播 delta 不动它；按引用缓存后每 build 只为新增轮付费。
  ///  懒构建后仅可见轮触发推导，memo 继续兜底滚回历史时的复算。
  List<ChatMessage>? _turnCacheMessages;
  int? _turnCacheCompactedBase;
  final Map<String, int?> _turnByMessageId = {};

  int? _turnNumberOf(ChatMessage assistant) {
    final state = widget.state;
    if (!identical(_turnCacheMessages, state.messages) ||
        _turnCacheCompactedBase != state.compactedTurnBase) {
      _turnCacheMessages = state.messages;
      _turnCacheCompactedBase = state.compactedTurnBase;
      _turnByMessageId.clear();
    }
    return _turnByMessageId.putIfAbsent(
      assistant.messageId,
      () => turnNumberForMessage(
        message: assistant,
        messages: state.messages,
        compactedTurnBase: state.compactedTurnBase,
      ),
    );
  }

  /// 最新已完成幕的轮次号（completedTurnCount 共享公式——
  /// 压缩基数 + 可见对话轮数）；Recap 编辑入口只挂在这一幕。
  int _latestCompletedTurn(AdvancedChatState state) {
    return completedTurnCount(
      compactedTurnBase: state.compactedTurnBase,
      messages: state.messages,
    );
  }

  /// DP-2：Fork 可操作窗口门控（DOC-09A-1），与故事模式同构。
  ///
  /// 窗口公式与故事模式 intermediate.canOperateMessage 同构（本组件不持
  /// controller 引用，页面层只回传操作回调；controller 侧旧同名方法已随
  ///  删除）；轮次推导复用
  /// 同一共享工具 [turnNumberForMessage]——controller 侧 `_computeTurnNumber`
  /// 委托的同一实现，两侧窗口语义保持一致：
  /// `canOperate = targetTurn >= totalRounds - windowRounds + 1`。
  bool _canOperateMessage(ChatMessage message) {
    final targetTurn = _turnNumberOf(message);
    if (targetTurn == null) return false;
    final totalRounds = widget.state.session.messageCount ~/ 2;
    return targetTurn >= totalRounds - widget.windowRounds + 1;
  }

  Widget _assistantRow(
    ChatMessage message, {
    bool hideThinking = false,
    List<MessageVariantRecord>? variants,
    int? currentVariantIndex,
    bool flashNewVariant = false,
    int? flashStartedAtMs,
  }) {
    final showSwitcher = variants != null &&
        variants.length > 1 &&
        currentVariantIndex != null &&
        widget.onSwitchVariant != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      // 阅读行宽钳制——稿件卡与动作行作为整体居中收窄，宽屏下
      // 不再拉满（移动端视口窄于上限，不受影响）
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: IntermediateSpacing.readingWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 旧数据兜底：无 agentTimeline 的历史轮，思考合并串仍由消息行渲染
              //（新数据的思考已随时间线进折叠组，不重复展示）
              if (!hideThinking &&
                  (message.thinkingContent?.isNotEmpty ?? false))
                _ThinkingToggle(content: message.thinkingContent!),
              _ManuscriptCard(
                text: message.content ?? '',
                streaming: false,
                fontScale: widget.fontScale,
              ),
              //  同族：压缩中隐藏行内动作行（重生成/编辑/
              // 删轮控制器静默 no-op；复制随行隐藏，压缩结束后即恢复）。
              // 纯净阅读同门——类文档承诺
              // 「重生成窗口等操作入口随之隐藏（切回正常模式操作）」，此前
              // 操作行与切换器不受 pureReading 门控照常渲染。
              if (!widget.state.isManualCompacting && !widget.pureReading)
                IntermediateMessageActions(
                  isUser: false,
                  // DP-2：按 Fork 窗口门控（此前恒 true，窗口外重生成/删除
                  // 畅通无阻，windowRounds 沦为纯装饰）
                  canOperate: _canOperateMessage(message),
                  windowRounds: widget.windowRounds,
                  onCopy: () => widget.onCopy(message),
                  onRegenerate: () => widget.onRegenerate(message),
                  onEdit: () => widget.onEdit(message),
                  onDeleteRound: () => widget.onDeleteRound(message),
                ),
              // 变体切换器（>1 版本才出现；重生成收稿后高亮 2s；
              // 纯净阅读下同操作行一并隐藏）
              if (showSwitcher && !widget.pureReading)
                MessageVariantSwitcher(
                  assistantMessage: message,
                  variants: variants,
                  currentIndex: currentVariantIndex,
                  flash: flashNewVariant,
                  flashStartedAtMs: flashStartedAtMs,
                  onSwitch: (index) => widget.onSwitchVariant!(message, index),
                  onDelete: widget.onDeleteVariant == null
                      ? null
                      : (index) => widget.onDeleteVariant!(message, index),
                  onFlashConsumed: widget.onVariantFlashConsumed,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 稿件卡（L0 正文唯一容器，直播与定稿同形态）
///
/// surfaceElevated 底 + 细边框圆角容器，正文排版与故事模式一致；直播中
/// 末尾呼吸光标，定稿后琥珀落幕线收尾。作品是主角，卡只是舞台——无
/// 侧边色条、无渐变等装饰（impeccable product 语域）。
class _ManuscriptCard extends StatelessWidget {
  const _ManuscriptCard({
    required this.text,
    required this.streaming,
    this.failed = false,
    this.fontScale = 1.0,
    super.key,
  });

  final String text;
  final bool streaming;

  /// 字体缩放比例（与 DirectorChatBody.fontScale 同源透传）
  final double fontScale;

  /// 失败轮的半截稿件：未定稿、不入库，不渲染定稿落幕线
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(IntermediateSpacing.sLg),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          border: Border.all(color: colors.divider, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            //  批3：直播稿件卡正文接冻结前缀分块渲染——
            // 直播态每 delta 的全文重解析是导演流式卡顿主源之一；定稿后
            // 回整文渲染（一次终解析）。
            // 纯文本单块尾段走 Text 快速路径（样式与
            // IntermediateMarkdownBody 的 styleSheet.p 同源）——叙事散文
            // 无空行流式时免全文重解析。稿件卡恒 isUser:false、中级配色
            // 恒夜航；fontScale 变化时冻结缓存经 cacheKey 整体失效。
            if (streaming)
              StreamingMarkdownBody(
                data: text,
                blockGap: IntermediateSpacing.s2xs,
                // 平滑揭示配速（消除批量上屏的蹦字感）。
                revealPacing: true,
                cacheKey: fontScale,
                plainTextStyle: IntermediateMarkdownBody.paragraphStyle(
                  colors: colors,
                  isUser: false,
                  fontScale: fontScale,
                ),
                blockBuilder: (segment) => IntermediateMarkdownBody(
                  data: segment,
                  isUser: false,
                  fontScale: fontScale,
                ),
              )
            else
              IntermediateMarkdownBody(
                data: text,
                isUser: false,
                fontScale: fontScale,
              ),
            if (streaming)
              const _StreamingCursor()
            else if (!failed)
              const _CurtainLine()
            else
              // 失败轮半截稿件挂「未定稿」
              // 徽标（中性收尾的补充说明——未入库、重试即替换）
              const _DraftBadge(),
          ],
        ),
      ),
    );
  }
}

/// 未定稿徽标——失败轮的半截稿件不入库，重试将替换此段
class _DraftBadge extends StatelessWidget {
  const _DraftBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sSm),
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: t.advanced.draftBadge.hint,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sSm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.accentDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note, size: 12, color: colors.accent),
                const SizedBox(width: 3),
                Text(
                  t.advanced.draftBadge.label,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 思考过程折叠（opencode 式灰字；旧数据消息行兜底渲染用）
///
/// 收起态显示「思考 · N 字」。直播思考已由 DirectorWorkGroup 组内的
/// 思考块接替，本组件仅服务无 agentTimeline 的历史轮（恒收起态）。
class _ThinkingToggle extends StatefulWidget {
  const _ThinkingToggle({required this.content});

  final String content;

  @override
  State<_ThinkingToggle> createState() => _ThinkingToggleState();
}

class _ThinkingToggleState extends State<_ThinkingToggle> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: colors.faint,
                ),
                const SizedBox(width: IntermediateSpacing.s2xs),
                Text(
                  _expanded
                      ? t.advanced.live.thinkingCollapse
                      : t.advanced.live.thinkingCount(
                          count: widget.content.length,
                        ),
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.faint,
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sLg,
                top: IntermediateSpacing.s2xs,
              ),
              child: Text(
                widget.content,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 流式正文末尾的呼吸光标。
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.pulse,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    //  reduced-motion：减弱动态下**不启动**循环脉冲（不是启动后再停）。
    if (LmMotion.shouldAnimate(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    if (!LmMotion.shouldAnimate(context)) {
      return Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
        ),
      );
    }
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _controller,
        child: Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 落幕线：正文定稿后底部 1px 琥珀细线 240ms 淡入（本轮定稿的视觉句号）。
class _CurtainLine extends StatefulWidget {
  const _CurtainLine();

  @override
  State<_CurtainLine> createState() => _CurtainLineState();
}

class _CurtainLineState extends State<_CurtainLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.sweep,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // reduced-motion：静态细线，不做淡入
    if (LmMotion.reducedMotion(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value != 1) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return FadeTransition(
      opacity:
          CurvedAnimation(parent: _controller, curve: LmMotion.easeStandard),
      child: Container(
        height: 0.5,
        margin: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
        color: colors.primary.withValues(alpha: 0.45),
      ),
    );
  }
}

/// 首增量前的呼吸占位（体验重构 §4.3.2 v2，2026-08-23 重构）
///
/// 段落骨架已移除：任何增量到达即有真实内容可渲染，不再需要版式占位。
/// 无步骤时显示「导演正在构思…」标签；已有步骤时 L1 过程行在上方报告
/// 当前动作，此处不再追加任何内容。
class _PendingNarrative extends StatelessWidget {
  const _PendingNarrative({required this.showLabel});

  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    if (!showLabel) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      child: _BreathingLabel(
        text: t.advanced.heartbeat.composing,
        color: colors.muted,
      ),
    );
  }
}

/// 心跳文字（800ms 呼吸，与流式光标同节拍；reduced-motion 静态）
class _BreathingLabel extends StatefulWidget {
  const _BreathingLabel({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  State<_BreathingLabel> createState() => _BreathingLabelState();
}

class _BreathingLabelState extends State<_BreathingLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.pulse,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LmMotion.reducedMotion(context)) {
      _controller.value = 0.6;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true, min: 0.35, max: 1);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _controller,
        child: Text(
          widget.text,
          style: IntermediateTextStyles.caption.copyWith(color: widget.color),
        ),
      ),
    );
  }
}

/// 回到最新浮标（生成中上滚脱离底部时浮现的右下角胶囊）。
class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Material(
      color: colors.surfaceElevated,
      shape: StadiumBorder(
        side: BorderSide(color: colors.divider, width: 0.5),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 13, color: colors.muted),
              const SizedBox(width: IntermediateSpacing.s2xs),
              Text(
                t.advanced.scrollToLatest,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态引导（体验重构 §4.3.5）：开场语示例（一键填入）+ 项目规则提示。
class _DirectorEmptyState extends StatelessWidget {
  const _DirectorEmptyState({this.onUseExample});

  final void Function(String example)? onUseExample;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(IntermediateSpacing.sXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 28,
              color: colors.faint,
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                t.advanced.emptyHint,
                style: IntermediateTextStyles.bodyUi.copyWith(
                  color: colors.muted,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sLg),
            // 开场语示例：点击一键填入输入框
            Material(
              color: colors.surfaceVariant,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              child: InkWell(
                onTap: onUseExample != null
                    ? () => onUseExample!(t.advanced.emptyState.example)
                    : null,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sLg,
                    vertical: IntermediateSpacing.sSm,
                  ),
                  child: Column(
                    children: [
                      Text(
                        t.advanced.emptyState.example,
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          color: colors.ink,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: IntermediateSpacing.s2xs),
                      Text(
                        t.advanced.emptyState.exampleAction,
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.faint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            Text(
              t.advanced.emptyState.rulesHint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话历史加载骨架（最近 3 条占位卡）
///
/// 静态占位（无动画，reduced-motion 免适配）；loadHistory 期间替代空态
/// 引导，消除重会话打开瞬间「发送第一句话开始」的误导闪现。
class _HistoryLoadingSkeleton extends StatelessWidget {
  const _HistoryLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    Widget card(double height) => Padding(
          padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: IntermediateSpacing.readingWidth,
              ),
              child: Container(
                width: double.infinity,
                height: height,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
              ),
            ),
          ),
        );
    return ListView(
      key: const ValueKey('history-loading-skeleton'),
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      children: [
        card(88),
        card(120),
        card(72),
      ],
    );
  }
}
