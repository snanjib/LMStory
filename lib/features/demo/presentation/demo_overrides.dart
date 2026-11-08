import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/tutorial/spotlight_overlay.dart'
    show tutorialControllerProvider;
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_input_lock.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_flow.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/onboarding/presentation/controllers/onboarding_controller.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';

/// 演示作用域 onboarding stub：读侧恒报「已完成」、写侧 no-op——
/// Demo 期间 MainLayout 显示主界面而非 OnboardingPage；真实标记
/// （SharedPreferences onboarding_completed）完全不受影响，退出
/// Demo 后既有首次拦截照常生效。
///
/// OnboardingNotifier 构造即 _load()（异步读 getBool）——桩 prefs
/// 对完成键恒返回 true，天然消除时序竞态，无需覆写私有 _load。
class _DemoOnboardingNotifier extends OnboardingNotifier {
  _DemoOnboardingNotifier() : super(_AlwaysCompletedPrefs());

  @override
  Future<void> markCompleted() async {}
}

class _AlwaysCompletedPrefs extends Preferences {
  _AlwaysCompletedPrefs() : super();

  @override
  Future<bool?> getBool(String key) async =>
      key == OnboardingNotifier.kCompletedKey ? true : null;
}

/// 演示作用域惰性 AutoBackup：runIfNeeded 永不执行——不检查、
/// 不写真实目录 backups/（依赖从演示容器解析，天然隔离）。
class _InertAutoBackupManager extends AutoBackupManager {
  _InertAutoBackupManager({
    required super.dataManagementService,
    required super.settingsRepository,
    required super.chatRepository,
  });

  @override
  Future<File?> runIfNeeded({bool force = false}) async => null;
}

/// 演示作用域惰性文件接收器：不注册平台 channel handler、流永不发射
/// （防止覆写根作用域 receiver 的 MethodChannel handler——Demo 退出后
/// 正式「打开方式/分享」导入将失效）。
class _InertIncomingFileReceiver extends IncomingFileReceiver {
  _InertIncomingFileReceiver() : super();

  @override
  Future<void> init() async {}
}

/// 构建演示容器的 override 集（契约 §5.1 唯一实现点）。
///
/// 基座替换 + 行为桩之外的一切 provider 在独立无父容器内全新构建，
/// 自动落到隔离基座（无父容器共享，不存在父作用域缓存泄漏）。
List<Override> buildDemoOverrides({
  required DemoBridge bridge,
  required AppDatabase demoDb,
  required DemoPreferences prefs,
  required DemoSecureStorage secure,
  required DemoPack pack,
  DemoSelectionController? selection,
}) {
  final profile =
      pack.manifest.replayProfile ?? DemoReplayProfile.conservativeRelay;
  final capabilities = profile.resolveCapabilities();
  // 首轮开始即锁定候选绑定：回放服务的首次叙事步调用回调 selection.lock，
  // 不依赖后续 agent_events 轮询。
  final replay = DemoReplayLlmService(
    pack: pack,
    guard: bridge.guard,
    onRoundStarted: selection?.lock,
  );
  final replayEmbedding =
      DemoReplayEmbeddingService(pack: pack, guard: bridge.guard);
  bridge
    ..replay = replay
    ..replayEmbedding = replayEmbedding
    ..fixedPrompt = pack.prompt
    ..localeTag = pack.manifest.locale
    ..replayProfile = profile
    ..pack = pack;
  return [
    // —— 网关能力画像覆盖（仅 Demo 容器生效，生产保持默认 resolve）——
    // 多仿真候选：经选择协调点实时取当前绑定包的完整画像。绑定只发生
    // 在真实 Controller 构造/首轮发送之前（向导模型步），消费方（网关、
    // 会话页）的首次读取都晚于绑定，首读即最新；绑定入口在首轮后锁定。
    agentCapabilitiesOverrideProvider.overrideWith(
      (ref) => selection?.capabilities ?? capabilities,
    ),
    // —— 选择协调点（多仿真候选绑定入口；无候选目录时缺省）——
    if (selection != null) demoSelectionProvider.overrideWithValue(selection),
    // —— 持久化/凭据基座 ——
    preferencesProvider.overrideWithValue(prefs),
    secureStorageProvider.overrideWithValue(secure),
    appDatabaseProvider.overrideWithValue(demoDb),
    // —— 网络出口（全部守卫化，零真实出口）——
    dioClientProvider.overrideWithValue(GuardedDioClient(bridge.guard)),
    httpClientProvider.overrideWithValue(GuardedHttpClient(bridge.guard)),
    llmServiceProvider.overrideWithValue(replay),
    embeddingServiceProvider.overrideWithValue(replayEmbedding),
    // —— 行为桩 ——
    onboardingProvider.overrideWith((ref) => _DemoOnboardingNotifier()),
    autoBackupManagerProvider.overrideWith(
      (ref) => _InertAutoBackupManager(
        dataManagementService: ref.read(dataManagementServiceProvider),
        settingsRepository: ref.read(settingsRepositoryProvider),
        chatRepository: ref.read(chatRepositoryProvider),
      ),
    ),
    incomingFileReceiverProvider.overrideWithValue(
      _InertIncomingFileReceiver(),
    ),
    // —— 桥注入（与根作用域共享的唯一通道）——
    spotlightRegistryProvider.overrideWithValue(bridge.spotlights),
    directorInputLockProvider.overrideWithValue(bridge.inputLock),
    tutorialControllerProvider.overrideWithValue(bridge.tutorial),
    demoBridgeProvider.overrideWithValue(bridge),
    demoDbProviderForFlow.overrideWithValue(demoDb),
    // 职责边界：Demo 容器内的宿主 UI 读到禁用门即跳过启动检查——
    // 不会构造第二个运行时、不会重复弹邀请/恢复框
    demoStartupGateProvider.overrideWithValue(_disabledInDemoGate),
  ];
}

/// Demo 作用域内禁用启动检查（见 [buildDemoOverrides] 内注释）
Future<void> _disabledInDemoGate() async {}
