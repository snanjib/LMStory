import 'dart:math' as math;

/// 流式跟随的底部缓冲（≈两行正文）：列表底部的**真实留白**。
///
/// 惰性跟随靠它吸收增长——缓冲区间内的文字增长不推动视口（已读文字保持
/// 静止），只有写入行越过缓冲才滑行一次、把缓冲重新建立起来。没有这块
/// 留白就没有缓冲：把最新行藏到屏幕外不算缓冲。
///
/// 定义在此（而非 smooth_follow_scroller.dart）以保持状态机单源引用时
/// 不引入 Flutter 依赖；scroller 文件 re-export 供既有消费面。
const double streamingFollowCushionPx = 48;

/// 贴底跟随状态机：宿主把滚动通知与布局变化翻译成输入，
/// 状态机只裁决「此刻是否应贴底跟随」。
///
/// 语义对齐 chatbox `smooth-follow-output.ts`（2026-09-10 移植）：
/// - 上划即停：任意上划（超过方向容差）首帧即冻结，不需要脱离
///   容差带——慢速上划看历史不被流式更新反复拉回底部；
/// - 内容收缩豁免：maxScrollExtent 下降导致的 pixels 下降不是用户上划；
/// - 回底自动恢复：滚回距底 ≤[resumeBandPx] 时自动恢复跟随；
/// - 发送新消息/点「回到最新」由宿主调 [forceFollowing] 强制恢复。
///
/// 纯逻辑、无 Flutter 依赖，与 ThrottledDeltaBuffer 同层共享。
class ScrollFollowStateMachine {
  ScrollFollowStateMachine({
    this.resumeAtBottomPx = 4, //  几乎贴底才恢复。
    this.directionTolerancePx = 0.5,
    double? resumeBandPx,
  }) : resumeBandPx = resumeBandPx ??
            math.max(resumeAtBottomPx, streamingFollowCushionPx);

  /// 恢复跟随的贴底线（对齐 chatbox AT_BOTTOM_TOLERANCE = 4：与
  /// Virtuoso 的 atBottom 信号在分数设备像素比下保持一致）。
  final double resumeAtBottomPx;

  /// 恢复跟随的判定带（：max(贴底线, 流式缓冲)）。
  ///
  /// 惰性跟随的底部缓冲（[streamingFollowCushionPx]）内允许写入行在
  /// 视口里往下走而不推动视口——用户把写入行拉回视口（进入缓冲区）
  /// 就是「我回来了」的信号，此时应恢复跟随；只认 4px 贴底会让用户
  /// 滚到缓冲区内仍保持冻结，感觉「回不到底」。显式注入供测试收窄。
  final double resumeBandPx;

  /// 方向判定容差（亚像素抖动不算滚动，对齐 chatbox
  /// SCROLL_DIRECTION_TOLERANCE = 0.5）。
  final double directionTolerancePx;

  bool _following = true;

  /// 是否应贴底跟随（宿主在内容增长后据此驱动滚动执行器）。
  bool get following => _following;

  /// 用户滚动输入。[pixelsDelta] 本次通知相对上次像素差（负=向上），
  /// [maxExtentDelta] 内容总滚动范围差（负=内容收缩），
  /// [distanceToBottom] 距底像素。
  void onUserScroll({
    required double pixelsDelta,
    required double maxExtentDelta,
    required double distanceToBottom,
  }) {
    final movedUp = pixelsDelta < -directionTolerancePx;
    // 内容收缩导致的 pixels 下降不是用户上划。
    final movedUpBecauseShrank =
        maxExtentDelta < -directionTolerancePx && pixelsDelta < 0;
    if (movedUp && !movedUpBecauseShrank) {
      _following = false; // 上划即停：不需要脱离容差带。
      return;
    }
    if (!_following &&
        pixelsDelta > directionTolerancePx &&
        distanceToBottom <= resumeBandPx) {
      _following = true; // 滚回底部自动恢复。
    }
  }

  /// 发送新消息/点「回到最新」强制回底恢复跟随。
  void forceFollowing() => _following = true;

  /// 进入会话/重置：回到初始跟随态。
  void reset() => _following = true;
}
