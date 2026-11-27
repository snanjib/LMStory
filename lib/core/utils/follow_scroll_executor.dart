import 'package:flutter/scheduler.dart' show TickerProvider;
import 'package:flutter/widgets.dart' show ScrollController, WidgetsBinding;
import 'package:lmstory/core/utils/scroll_follow_state_machine.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart';

/// 三模式共用的贴底跟随执行器：组合 [ScrollFollowStateMachine]
/// （是否跟随的裁决）与 [SmoothFollowScroller]（惰性跟随 + 速度受限滑行）。
///
/// 两平台行为一致：
/// 移动端此前是当帧瞬移，正是「每写满一行整屏跳一下」最明显的形态；现在
/// 与桌面共用同一套缓冲 + 滑行。
///
/// 显式回底（发送消息、点「回到最新」）仍即时到位——那是用户的明确意图，
/// 不走缓冲滑行。
///
/// R1 单源约束：chat/intermediate/advanced 三模式共用本执行器与同一组常量
/// （[streamingFollowCushionPx] / [streamingFollowCatchUpLag]），禁止模式
/// 私有调参。
class FollowScrollExecutor {
  FollowScrollExecutor({
    required ScrollController controller,
    required TickerProvider vsync,
  })  : state = ScrollFollowStateMachine(),
        _controller = controller {
    _scroller = SmoothFollowScroller(
      controller: controller,
      vsync: vsync,
      isFollowing: _isFollowing,
    );
  }

  /// 跟随裁决状态机（宿主读 [ScrollFollowStateMachine.following]）。
  final ScrollFollowStateMachine state;

  final ScrollController _controller;

  late final SmoothFollowScroller _scroller;

  /// 上一帧滚动位置（喂状态机算 pixelsDelta）。
  double _lastPixels = 0;

  /// 上一帧最大滚动范围（识别内容收缩导致的 pixels 钳位下降）。
  double _lastMaxExtent = 0;

  bool _isFollowing() => state.following;

  /// 滚动监听喂入：宿主 `_onScroll` 把 pixels/maxScrollExtent 交给本方法
  /// （替代各模式自己的 `_lastPixels/_lastMaxExtent` 簿记）；未跟随时
  /// 顺手停掉 ticker（上划当帧生效，无残余位移）。
  void handleScrollMetrics(double pixels, double maxExtent) {
    state.onUserScroll(
      pixelsDelta: pixels - _lastPixels,
      maxExtentDelta: maxExtent - _lastMaxExtent,
      distanceToBottom: maxExtent - pixels,
    );
    _lastPixels = pixels;
    _lastMaxExtent = maxExtent;
    if (!state.following) {
      _scroller.stop();
    }
  }

  /// 内容增长后的跟随 gate（流式路径入口）：跟随态才启动追踪。
  ///
  /// 实际位移由 [SmoothFollowScroller] 决定：缓冲区内不动、越过缓冲才滑行
  /// ——因此「写满一行整屏上移」的跳动被缓冲吸收，只在不定期的一小段滑行
  /// 里出现，且滑行是连续限速的（滑行途中新内容到达不会重启或变速突跳）。
  void followGrowth() {
    if (!state.following) return;
    _scroller.nudge();
  }

  /// 发送/胶囊/轮完成等强制回底：恢复跟随 + 停 ticker + postFrame 即时
  /// jumpTo 贴底（用户明确要求看最新，不走缓冲滑行）。宿主需要 settle
  /// 校准的自行再调其 `_settleAtBottom(1)`（发送回底的单次校准语义）。
  void forceToBottom() {
    state.forceFollowing();
    _scroller.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!state.following || !_controller.hasClients) return;
      final position = _controller.position;
      if (!position.hasContentDimensions) return;
      _controller.jumpTo(position.maxScrollExtent);
    });
  }

  /// 停止平滑跟随（宿主自驱滚动——导航/胶囊 animateTo 前调用，避免与
  /// ticker 抢帧）。
  void stop() => _scroller.stop();

  /// A newly anchored viewport has a different origin. Its initial offset
  /// is a baseline, not a user gesture or a change in following intent.
  void rebase() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    _scroller.stop();
    _lastPixels = position.pixels;
    _lastMaxExtent = position.maxScrollExtent;
  }

  /// 会话切换：回初始跟随态、停 ticker、清零滚动游标。
  void reset() {
    state.reset();
    _scroller.stop();
    _lastPixels = 0;
    _lastMaxExtent = 0;
  }

  /// 页面 dispose：释放 ticker。
  void dispose() {
    _scroller.dispose();
  }
}
