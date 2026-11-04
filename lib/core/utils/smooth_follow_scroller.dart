import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/utils/scroll_follow_state_machine.dart'
    show streamingFollowCushionPx;

// 缓冲常量单源在状态机文件（纯逻辑层），此处 re-export 维持既有消费面。
export 'package:lmstory/core/utils/scroll_follow_state_machine.dart'
    show streamingFollowCushionPx;

// lm-motion-exempt: 跟随滚动追赶滞后（性能红线区引擎调参，文件内已具名单源）
/// 滑行的排空窗口：超出缓冲的量在这个时间内滑完（速度上限）。
/// 与揭示配速同规则——积压越多滑得越快，连续无断点。
const Duration streamingFollowCatchUpLag = Duration(milliseconds: 200);

/// 贴底跟随执行器：惰性跟随 + 速度受限滑行。
///
/// 为什么不是「永远钉在 maxScrollExtent」：段落高度是文本长度的阶梯函数
/// （字符填满最后一行时高度不变，换行时正好跳一行），钉住底部的意思是每
/// 跳一次就把已读文字整体推上一行——观感就是「整屏跳一下」（chatbox 同样，
/// 移动端 WebView 的瞬移滚动更明显）。
///
/// 本实现允许视口在 [streamingFollowCushionPx] 的缓冲内**原地不动**：写入行
/// 自己在缓冲里往下走；一旦越过缓冲，按 [streamingFollowCatchUpLag] 限速
/// 滑行到新的贴底位（整像素、只前进），再进入静止期。
///
/// 滑行**不是**「每段触发一个动画」：每帧朝当前目标挪一小步、步长与超出量
/// 成正比——新内容在滑行途中到达时目标自然前移、滑行继续，没有重启也没有
/// 断点，因此不会出现动画重叠或速度突跳（低速→静止+短滑行；高速→滑行
/// 自然连成匀速运动）。
///
/// 上划即停由 [isFollowing] 回调实现：ticker 每帧先查状态机，冻结当帧
/// 停止（滑行立即中断，无残余位移）。
class SmoothFollowScroller {
  SmoothFollowScroller({
// lm-motion-exempt: 跟随滚动轻推保持（性能红线区引擎调参，文件内已具名单源）
    required ScrollController controller,
    required TickerProvider vsync,
    required this.isFollowing,
    this.cushionPx = streamingFollowCushionPx,
    this.catchUpLag = streamingFollowCatchUpLag,
    this.holdAfterNudge = const Duration(milliseconds: 500),
  }) : _controller = controller {
    _ticker = vsync.createTicker(_onTick);
  }

  final ScrollController _controller;

  late final Ticker _ticker;

  /// ticker 回调先查状态机：上划冻结当帧停（无残余下滑）。
  final bool Function() isFollowing;

  /// 底部缓冲（逻辑像素）：视口可落后底部的最大距离。
  final double cushionPx;

  /// 滑行排空窗口（超出缓冲的量在该时长内滑完 = 速度上限）。
  final Duration catchUpLag;

  /// 停止前的持续追踪窗口：显示层的平滑揭示会在两次 state 更新之间继续
  /// 放字（见 streaming_reveal_pacer.dart），贴底瞬间就停会让最终揭示出来
  /// 的一两行停在视口下方。期间有新的 [nudge] 就顺延。
  final Duration holdAfterNudge;

  /// 上次 tick 时间戳；null = ticker 刚启动（首帧 dt=0，无位移）。
  Duration? _lastElapsed;

  /// 缓冲区内已持续的时长（[nudge] 时清零；达到 [holdAfterNudge] 才停）。
  Duration _idleFor = Duration.zero;

  /// 是否处于滑行中。滑行一旦开始就走完当前这段距离（到贴底位），
  /// 途中若有新增长则按新距离重排窗口——位置连续，不会停在缓冲刚被吃光的
  /// 位置（那既没缓冲观感、又几乎每次都触发滑行）。
  bool _gliding = false;

  /// 当前滑行窗口：起点时刻 / 起点位置 / 目标位置。滑行起点/目标仅在
  /// [_gliding] 守卫内读写（use_late_for_private_fields lint 收口）。
  late Duration _glideStart;
  late double _glideFrom;
  late double _glideTo;

  /// 内容增长后由跟随 gate 调用；已在跑则顺延持续追踪窗口。
  void nudge() {
    _idleFor = Duration.zero;
    if (_controller.hasClients &&
        _controller.position.hasContentDimensions &&
        !_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
  }

  /// 停止跟随：上划冻结（状态机裁决侧调用）、宿主自驱滚动、会话切换。
  void stop() {
    if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  /// 释放 ticker（页面 dispose 时由宿主调用）。
  void dispose() {
    _ticker.dispose();
  }

  void _onTick(Duration elapsed) {
    final last = _lastElapsed;
    _lastElapsed = elapsed;
    if (!isFollowing()) {
      stop();
      return;
    }
    if (!_controller.hasClients) {
      stop();
      return;
    }
    final position = _controller.position;
    if (!position.hasContentDimensions) {
      stop();
      return;
    }
    final dt = last == null ? Duration.zero : elapsed - last;

    // 不变量：**最新一行始终留在视口内**。缓冲的作用是让写入行在视口里
    // 向下走一段（此时视口原地不动、已读文字静止）；一旦它会越过屏幕下沿
    // （max - pixels > cushionPx），就限速滑行回贴底位、把缓冲重新建立起来。
    final max = position.maxScrollExtent;
    final gap = max - position.pixels;
    if (!_gliding && gap <= cushionPx) {
      // 仍在缓冲内：视口原地不动（已读文字静止），只维持追踪窗口。
      _idleFor += dt;
      if (_idleFor >= holdAfterNudge) {
        stop();
      }
      return;
    }
    _idleFor = Duration.zero;
    if (last == null) {
      return; // 首帧 dt=0：无位移，下一帧起滑行。
    }
    // 滑行 = 定时窗口内的缓动。用「剩余距离成正比」的步长会在末端无限慢
    //（每帧 1px 爬行），定时窗口保证在 catchUpLag 内走完；途中目标前移
    //（新内容到达）就按新距离重排窗口——位置连续，速度平滑变化不突跳。
    if (!_gliding || _glideTo != max) {
      _gliding = true;
      _glideStart = elapsed;
      _glideFrom = position.pixels;
      _glideTo = max;
    }
    final span = catchUpLag.inMicroseconds;
    final t = span <= 0
        ? 1.0
        : ((elapsed - _glideStart).inMicroseconds / span).clamp(0.0, 1.0);
    final planned = _glideFrom +
        (_glideTo - _glideFrom) * LmMotion.easeStandard.transform(t);
    // 整逻辑像素量化（逐帧写分数偏移会让整屏文字亚像素相位持续变化），
    // 且只前进——取整回退会被跟随状态机判成「用户上划」而误冻结。
    final rounded = planned.roundToDouble();
    final next = rounded <= position.pixels ? position.pixels + 1 : rounded;
    _controller.jumpTo(next < max ? next : max);
    // +1px 地板让位置可能在 t<1 时已提前到顶，
    // 此时继续滑行只是每帧重复 jumpTo(max)——到位即结束本段滑行。
    if (t >= 1 || position.pixels >= max) {
      _gliding = false; // 本段走完；缓冲重新建立后进入静止期。
    }
  }
}
