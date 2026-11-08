import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_input_lock.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';

/// 向导选择进度快照（向导页经 ref.listen 实时上报到桥；页面销毁即
/// 停报，语义与页面级 autoDispose 状态一致）。流程据此按「选择结果」
/// 推进向导步骤，而非目标注册即推进。
class WizardProgress {
  const WizardProgress({
    required this.modelReady,
    this.embeddingDone = false,
    this.rulesConfirmed = false,
    this.currentStep = 0,
  });

  /// 模型步：GM preset+model 均已选择（isModelReady）
  final bool modelReady;

  /// 嵌入步：已显式选择（配上选中模型或「暂时跳过」）
  final bool embeddingDone;

  /// 规则步：模板/问卷产物已确认（confirmedRules 非空）
  final bool rulesConfirmed;

  /// 向导当前步索引（0=模型, 1=嵌入, 2=规则）
  final int currentStep;
}

/// Demo 作用域运行态（桥内广播；根/Demo 两作用域共用同一实例）
class DemoRunState {
  const DemoRunState({this.step, this.overlayVisible = false});

  /// 当前步骤（DemoStepId.name；桥层持字符串保持零业务语义）
  final String? step;

  /// Spotlight 遮罩是否应显示
  final bool overlayVisible;
}

/// 两作用域间唯一通信桥。
///
/// 根作用域（DemoRuntime）创建并持有；经 `overrideWithValue` 注入
/// Demo 容器（demoBridgeProvider）。除本桥对象外，独立无父的 Demo
/// 容器与根作用域零共享——隔离不依赖使用方自觉。
class DemoBridge {
  final SpotlightRegistry spotlights = SpotlightRegistry();
  final DirectorInputLockController inputLock = DirectorInputLockController();
  final DemoNetworkGuard guard = DemoNetworkGuard();
  final ValueNotifier<DemoRunState> run =
      ValueNotifier<DemoRunState>(const DemoRunState());

  /// 教程控制器（遮罩经 tutorialControllerProvider 消费同一实例）
  final TutorialController tutorial = TutorialController();

  /// 回放服务句柄（装配后设置；桥在重发回合/新 run 时重置游标）
  DemoReplayLlmService? replay;

  /// 回放嵌入服务句柄（多仿真候选换绑时与 [replay] 一致换包）
  DemoReplayEmbeddingService? replayEmbedding;

  /// 多仿真候选选择/绑定协调点（运行时装配后设置；向导模型步经此绑定）
  DemoSelectionController? selection;

  /// 固定首轮提示词（装配时来自数据包；输入锁文本源）
  String? fixedPrompt;

  /// 本 run 数据包语言
  String? localeTag;

  /// 本 run 数据包回放画像
  DemoReplayProfile? replayProfile;

  /// 本 run 完整数据包引用
  DemoPack? pack;

  /// 恢复检查点（装配前由运行时设置；null=从头开始）
  String? initialStepId;

  /// 恢复导航目标：非空且未消费时，Demo 容器内的宿主 UI 把用户带回
  /// 该会话页（推导先于挂载，见 DemoRuntime._deriveResume）
  String? resumeSessionId;

  /// 向导选择进度（见 [WizardProgress]）
  final ValueNotifier<WizardProgress?> wizardProgress =
      ValueNotifier<WizardProgress?>(null);

  /// 根作用域注入的回调（检查点持久化经根侧完成）
  ({
    Future<void> Function()? onComplete,
    Future<void> Function()? onExitRequested,
    Future<void> Function(String stepId)? onStepCheckpoint,
    Future<void> Function(String sessionId)? onSessionRecorded,
  }) hooks = (
    onComplete: null,
    onExitRequested: null,
    onStepCheckpoint: null,
    onSessionRecorded: null,
  );

  /// 用户重新发送同一回合/新 run 时由流程侧调用
  void resetReplayTurn() => replay?.resetTurn();

  /// 宿主完成恢复导航后调用（防重复导航）
  void consumeResumeNavigation() {
    resumeSessionId = null;
  }

  void dispose() {
    spotlights.dispose();
    inputLock.dispose();
    run.dispose();
    wizardProgress.dispose();
    tutorial.dispose();
  }
}

/// Demo 容器内取桥的唯一入口；根作用域缺省 null——宿主 UI 据此判定
/// 当前作用域（null=正式作用域，非空=演示作用域）。
final demoBridgeProvider = Provider<DemoBridge?>((ref) => null);
