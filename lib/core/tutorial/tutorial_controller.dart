import 'package:flutter/foundation.dart';

/// 教程步骤值对象（文本由驱动方提供——本层不关心业务语义与 i18n）
class TutorialStep {
  const TutorialStep({
    required this.id,
    required this.title,
    required this.message,
    this.targetId,
    this.candidateTargetIds = const [],
    this.extraHighlightTargetIds = const [],
    this.targetResolver,
    this.passThroughTargetId,
    this.allowUntargetedTaps = false,
    this.targetWaitTimeout = const Duration(seconds: 15),
    this.skippable = false,
    this.confirmLabel,
  });

  /// 步骤 id（驱动方定位/恢复检查点用）
  final String id;

  /// Spotlight 语义目标 id；null=无目标居中说明卡
  final String? targetId;

  /// 候选语义目标 id 列表（按优先级依次尝试已挂载目标；为空时回退 [targetId]）
  final List<String> candidateTargetIds;

  /// 额外并列高亮目标 id 列表（与主目标一同挖孔高亮，用于多区域协同指示如顶部导航+内容）
  final List<String> extraHighlightTargetIds;

  /// 动态目标解析器（用于多子视图流转步如向导规则步）
  final String? Function()? targetResolver;

  /// 局部交互放行目标 id（该区域内放行浏览与折叠交互，遮罩仍渲染，遮罩外按钮吸收阻断）
  final String? passThroughTargetId;

  final String title;
  final String message;

  /// 介绍性步骤允许遮罩外自由操作（不阻误触）
  final bool allowUntargetedTaps;

  /// 目标缺失等待超时（等待态提示 + 超时处理由宿主决定）
  final Duration targetWaitTimeout;

  /// 非必需步骤允许跳过（介绍类）；必需步骤（业务操作）不可跳过
  final bool skippable;

  /// 确认按钮文案；null=无确认按钮（仅退出入口）
  final String? confirmLabel;

  /// 解析当前应指向的目标 id：优先执行 [targetResolver]，次查 [candidateTargetIds]，
  /// 最后回退 [targetId]。
  String? resolveTargetId(bool Function(String id) isRegistered) {
    if (targetResolver != null) {
      final resolved = targetResolver!();
      if (resolved != null) return resolved;
    }
    if (candidateTargetIds.isNotEmpty) {
      for (final id in candidateTargetIds) {
        if (isRegistered(id)) return id;
      }
    }
    return targetId;
  }
}

/// 教程步骤状态机（纯逻辑，可测；UI 由 SpotlightOverlayHost 消费）
///
/// 只负责步骤推进/等待/跳过——不发送消息、不点选目标、不写实体。
class TutorialController extends ChangeNotifier {
  // 回调可运行时重绑（驱动器装配晚于构造；字段非 final，init form 亦可变）
  TutorialController({
    this.onFinished,
    this.onAborted,
    this.onExitRequested,
  });

  /// 全部步骤完成（可运行时重绑——驱动器装配晚于构造）
  VoidCallback? onFinished;

  /// 用户主动退出（可运行时重绑）
  VoidCallback? onAborted;

  /// 用户请求退出（**不结束教程**）——宿主弹确认框后：
  /// 继续体验→[cancelExit]；确认退出/放弃→[end]/宿主销毁。
  VoidCallback? onExitRequested;

  List<TutorialStep> _steps = const [];
  int _index = -1;
  bool _waitingForTarget = false;
  bool _exitRequestOpen = false;

  List<TutorialStep> get steps => _steps;
  TutorialStep? get current =>
      (_index >= 0 && _index < _steps.length) ? _steps[_index] : null;
  bool get active => _index >= 0;
  bool get waitingForTarget => _waitingForTarget;

  /// 退出确认框是否打开（打开期间教程原样保持：步骤/进度/目标全不动）
  bool get exitRequestOpen => _exitRequestOpen;

  void begin(List<TutorialStep> steps) {
    _steps = List.unmodifiable(steps);
    _index = _steps.isEmpty ? -1 : 0;
    _waitingForTarget = false;
    if (_steps.isEmpty) {
      onFinished?.call();
    }
    notifyListeners();
  }

  void end({bool aborted = false}) {
    if (!active) return;
    _index = -1;
    _waitingForTarget = false;
    _exitRequestOpen = false;
    notifyListeners();
    if (aborted) {
      onAborted?.call();
    } else {
      onFinished?.call();
    }
  }

  /// 用户主动退出（遮罩常驻退出入口）。语义保留：直接结束。
  /// UI 入口应改用 [requestExit]（先确认后结束）。
  void abort() => end(aborted: true);

  /// 请求退出：**不结束教程**——置请求态并通知宿主（宿主弹确认框）。
  /// 原步骤、进度、目标与回放进度全部保留；宿主在用户选择后调
  /// [cancelExit]（继续体验）或 [end]/自行销毁（确认退出/放弃）。
  void requestExit() {
    if (!active || _exitRequestOpen) return;
    _exitRequestOpen = true;
    notifyListeners();
    onExitRequested?.call();
  }

  /// 取消退出请求：清除请求态，教程原地继续（不重启、不重复生成）。
  void cancelExit() {
    if (!_exitRequestOpen) return;
    _exitRequestOpen = false;
    notifyListeners();
  }

  /// 推进到下一步；末步则收尾
  void next() {
    if (!active) return;
    if (_index >= _steps.length - 1) {
      end();
      return;
    }
    _index++;
    _waitingForTarget = false;
    notifyListeners();
  }

  /// 跳过当前步（仅 skippable）；不可跳过步为 no-op
  void skipCurrent() {
    if (!active) return;
    if (!current!.skippable) return;
    next();
  }

  /// 目标缺失等待态（宿主在目标注册表无该 id 时置位/解除）
  void setWaitingForTarget({required bool waiting}) {
    if (_waitingForTarget == waiting) return;
    _waitingForTarget = waiting;
    notifyListeners();
  }

  /// 刷新当前目标解析（外部业务状态更新时主动通知重算）
  void refreshTarget() {
    if (active) notifyListeners();
  }

  /// 按步骤 id 推进到指定步（恢复检查点用）；不存在则 no-op
  void jumpTo(String stepId) {
    final i = _steps.indexWhere((s) => s.id == stepId);
    if (i < 0) return;
    _index = i;
    _waitingForTarget = false;
    notifyListeners();
  }
}
