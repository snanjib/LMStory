import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show BuildContext, GlobalKey, NavigatorState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_seeder.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_exit_dialog.dart';
import 'package:lmstory/features/demo/presentation/demo_invite_dialog.dart';
import 'package:lmstory/features/demo/presentation/demo_overrides.dart';
import 'package:lmstory/features/demo/presentation/demo_resume_dialog.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

/// 演示运行时（根作用域）：生命周期状态机 + Demo 容器管理 + 交接执行。
///
/// MyApp 据此在运行期把 MaterialApp 包进独立无父的 Demo 容器
/// （UncontrolledProviderScope）——除桥外两作用域零共享。
///
/// 职责边界（主控复核修正）：本类只活在前台根作用域；Demo 容器内的
/// 宿主 UI 经 [demoStartupGateProvider]（演示装配覆写为禁用）隔离，
/// 不会构造第二个运行时实例、不会重复弹邀请/恢复框。
class DemoRuntime extends ChangeNotifier {
  DemoRuntime({
    required AppDatabase realDatabase,
    required Preferences preferences,
    required SecureStorage secureStorage,
    DemoStateStore? stateStore,
    DemoPackLoader? packLoader,
    Future<AppDatabase> Function()? databaseOpener,
    DemoSessionHandover Function()? handoverFactory,
  })  : _realDb = realDatabase,
        _prefs = preferences,
        _secure = secureStorage,
        _store = stateStore ?? DemoStateStore(),
        _loader = packLoader ?? const DemoPackLoader(),
        _openDatabase = databaseOpener ?? openDemoDatabase,
        _handoverFactory = handoverFactory ?? DemoSessionHandover.new;

  final AppDatabase _realDb;
  final Preferences _prefs;
  final SecureStorage _secure;
  final DemoStateStore _store;
  final DemoPackLoader _loader;
  final Future<AppDatabase> Function() _openDatabase;
  final DemoSessionHandover Function() _handoverFactory;
  final _uuid = const Uuid();

  /// MaterialApp 的导航键（切换作用域时刷新实例，避免跨 ProviderScope 重挂载 Navigator 触发 Element 断言）
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;

  DemoState _state = const DemoState();
  DemoState get state => _state;

  ProviderContainer? _container;
  AppDatabase? _demoDb;
  DemoBridge? _bridge;

  /// Demo 作用域是否挂载（MyApp 据此切换树形态）
  bool get scopeActive => _container != null;
  ProviderContainer? get container => _container;

  /// 启动加载完成（含邀请门控预判）
  bool loaded = false;

  /// 当前 locale 是否有可用演示包
  bool packAvailable = false;

  /// 正式环境是否已有带 Key 供应商（有则不弹首问）
  bool hasKeyedPreset = false;

  /// 邀请门控：首问是否应弹（onboarding 未完成由宿主另判）
  bool get inviteEligible =>
      loaded &&
      state.inviteStatus == DemoInviteStatus.pending &&
      packAvailable &&
      !hasKeyedPreset;

  /// 启动加载状态文件 + 核验并补跑中断的交接（幂等）
  Future<void> load() async {
    if (loaded) return;
    _state = await _store.load();
    final localeTag = LocaleSettings.currentLocale.languageTag;
    packAvailable = await _loader.isAvailable(localeTag);
    hasKeyedPreset = await _realHasKeyedPreset();
    loaded = true;
    if (!_disposed) notifyListeners();
    // handoverPending：打开源库核验/补跑（不依赖 start 挂载的库句柄）
    if (_state.phase == DemoPhase.handoverPending) {
      await _resolvePendingHandoverOnStartup();
    }
  }

  Future<bool> _realHasKeyedPreset() async {
    try {
      final rows =
          await _realDb.customSelect('SELECT preset_id FROM api_presets').get();
      if (rows.isEmpty) return false;
      // Key 存在性检查走真实钥匙串——正式上下文读自身 Key 属正常应用
      // 行为；Demo 作用域内永不触碰（那是被隔离替换的独立容器）。
      for (final row in rows) {
        final id = row.read<String>('preset_id');
        final v = await _secure.read('api_key_$id');
        if (v != null && v.isNotEmpty) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 邀请拒绝：标记后不再自动弹（手动入口仍可用）
  Future<void> declineInvite() async {
    _state = _state.copyWith(inviteStatus: DemoInviteStatus.declined);
    await _store.save(_state);
    if (!_disposed) notifyListeners();
  }

  /// 进入 Demo 作用域。
  ///
  /// - [fresh]=true（首问接受 / 手动重看 / 恢复弹窗「重新开始」）：
  ///   全新 run——清库播种，永不覆写已交接会话；
  /// - false 且状态含 runId：**继续体验**——不清库（保留会话、正文、
  ///   实体、事件与回合状态），仅重注入内存密钥与确定性配置覆写；
  ///   恢复步骤与导航目标先推导、后挂载。
  ///
  /// 多仿真模型：按当前 locale 解析可用候选目录，恢复路径先按持久
  /// 身份定位同一候选（未知身份/缺包拒绝恢复，不静默换模型）。
  Future<void> start({bool fresh = false}) async {
    if (scopeActive) return;
    final localeTag = LocaleSettings.currentLocale.languageTag;
    final candidates = await _loader.availableCandidates(localeTag);
    if (candidates.isEmpty) {
      throw const DemoPackUnavailableException(
        'no demo pack available for this locale',
      );
    }
    final (initialCandidate, initialPack) = await _resolveCandidateForStart(
      fresh: fresh,
      candidates: candidates,
    );

    final AppDatabase demoDb;
    try {
      demoDb = await _openDatabase();
    } catch (_) {
      return; // 打不开演示库：保持状态，不挂载
    }
    try {
      await _mount(
        pack: initialPack,
        candidate: initialCandidate,
        candidates: candidates,
        demoDb: demoDb,
        localeTag: localeTag,
        fresh: fresh,
      );
    } catch (_) {
      await demoDb.close();
      rethrow; // 挂载失败（如模板哈希不符）：状态保持可恢复
    }
  }

  /// 恢复/全新 run 的初始候选解析（候选包加载与身份对账一体完成）。
  ///
  /// - 全新 run → 默认候选；
  /// - 恢复 + 状态带 candidateId → 同 id 候选（目录缺失/不可用 → 拒绝恢复）；
  /// - 恢复 + 旧单包状态（无 candidateId）→ 映射默认候选，随后挂载期
  ///   逐字段身份对账（contentVersion/画像/指纹）把关——旧身份与当前
  ///   默认候选对不上即拒绝恢复，等价于「可证明为原默认包身份才映射」，
  ///   绝不静默换另一模型。
  Future<(DemoCandidate, DemoPack)> _resolveCandidateForStart({
    required bool fresh,
    required List<DemoCandidate> candidates,
  }) async {
    if (!fresh && _state.candidateId != null) {
      for (final c in candidates) {
        if (c.id == _state.candidateId) {
          return (c, await _loader.loadCandidate(c));
        }
      }
      throw DemoPackUnavailableException(
        'saved demo candidate unavailable: ${_state.candidateId}',
      );
    }
    final defaultCandidate = candidates.firstWhere(
      (c) => c.isDefault,
      orElse: () => candidates.first,
    );
    return (defaultCandidate, await _loader.loadCandidate(defaultCandidate));
  }

  Future<void> _mount({
    required DemoPack pack,
    required DemoCandidate candidate,
    required List<DemoCandidate> candidates,
    required AppDatabase demoDb,
    required String localeTag,
    required bool fresh,
  }) async {
    final prefs = DemoPreferences(fallback: _prefs);
    final secure = DemoSecureStorage();

    final resuming = !fresh && _state.runId != null;
    String presetId;
    if (resuming) {
      // 恢复身份对账（契约 §4.2 / Pillar C）：
      // 核验保存的候选身份（candidateId、虚拟模型id、包字节指纹）与包身份
      // （contentVersion、formatVersion、locale、replayProfile及指纹）
      // 是否与当前待回放数据严格一致。若候选已漂移、包已升级、画像已变
      // 或语言不符，安全拒绝恢复，抛出 DemoPackUnavailableException，
      // 不清库、不伪造交接。
      final savedCandidateId = _state.candidateId;
      if (savedCandidateId != null && savedCandidateId != candidate.id) {
        throw DemoPackUnavailableException(
          'runtime candidateId mismatch: '
          'saved=$savedCandidateId resolved=${candidate.id}',
        );
      }
      final savedModelId = _state.virtualModelId;
      if (savedModelId != null && savedModelId != candidate.virtualModelId) {
        throw DemoPackUnavailableException(
          'runtime virtualModelId mismatch: '
          'saved=$savedModelId pack=${candidate.virtualModelId}',
        );
      }
      final savedSha = _state.packSha256;
      if (savedSha != null && savedSha != candidate.packSha256) {
        throw DemoPackUnavailableException(
          'runtime packSha256 mismatch: '
          'saved=$savedSha catalog=${candidate.packSha256}',
        );
      }
      final savedVersion = _state.packContentVersion;
      if (savedVersion != null &&
          savedVersion != pack.manifest.contentVersion) {
        throw DemoPackUnavailableException(
          'runtime pack contentVersion mismatch: '
          'saved=$savedVersion pack=${pack.manifest.contentVersion}',
        );
      }
      final savedFormat = _state.formatVersion;
      if (savedFormat != null && savedFormat != pack.manifest.formatVersion) {
        throw DemoPackUnavailableException(
          'runtime pack formatVersion mismatch: '
          'saved=$savedFormat pack=${pack.manifest.formatVersion}',
        );
      }
      if (_state.localeTag.isNotEmpty && _state.localeTag != localeTag) {
        throw DemoPackUnavailableException(
          'runtime pack locale mismatch: '
          'saved=${_state.localeTag} pack=$localeTag',
        );
      }
      final currentProfileId = pack.manifest.replayProfile?.id ??
          DemoReplayProfile.conservativeRelayId;
      final savedProfileId = _state.replayProfileId;
      if (savedProfileId != null && savedProfileId != currentProfileId) {
        throw DemoPackUnavailableException(
          'runtime pack replayProfileId mismatch: '
          'saved=$savedProfileId pack=$currentProfileId',
        );
      }
      final currentCapHash = pack.manifest.replayProfile?.capabilitiesHash ??
          DemoReplayProfile.conservativeRelay.capabilitiesHash;
      final savedCapHash = _state.capabilitiesHash;
      if (savedCapHash != null && savedCapHash != currentCapHash) {
        throw DemoPackUnavailableException(
          'runtime capabilitiesHash mismatch: '
          'saved=$savedCapHash pack=$currentCapHash',
        );
      }

      // 恢复：不清库，仅重注入内存密钥 + 确定性配置覆写
      await attachDemoEnvironment(
        demoDb,
        secure,
        prefs,
        localeTag: localeTag,
        presetId: _state.seedPresetId,
      );
      presetId = _state.seedPresetId ??
          await findDemoPresetId(demoDb) ??
          (throw const DemoPackUnavailableException(
            'demo seed preset missing',
          ));
    } else {
      final seed = await seedDemoEnvironment(
        demoDb,
        secure,
        prefs,
        localeTag: localeTag,
        candidates: candidates,
      );
      presetId = seed.presetId;
    }

    // 运行时模板哈希复核（契约 §7.2 第三重，生产路径强制）：
    // 库内实际模板行 content 与包 manifest 对账——模板已变而包未更新
    // 时本地拒绝，已有可恢复数据保留。
    final template = await TemplateRepositoryImpl(
      demoDb,
    ).getTemplate(pack.manifest.templateId);
    final actualHash = demoContentHash(template.content);
    if (actualHash != pack.manifest.templateHash) {
      throw DemoPackUnavailableException(
        'runtime template hash mismatch: '
        'pack=${pack.manifest.templateHash} actual=$actualHash',
      );
    }

    // 恢复推导先于挂载：步骤与导航目标由库内实际状态决定
    var initialStepId = fresh ? null : _state.stepId;
    String? resumeSessionId;
    var roundStarted = false;
    if (resuming) {
      final derived = await _deriveResume(demoDb);
      initialStepId = derived.$1;
      resumeSessionId = derived.$2;
      roundStarted = await _roundStarted(demoDb, resumeSessionId);
      // 数据库核验后的会话 id 同步回填状态文件——状态缺 id 不能等同
      // 「没有成果」（源库可能已有完成回合），否则完成链会跳过导入。
      if (resumeSessionId != null && resumeSessionId != _state.sessionId) {
        _state = _state.copyWith(sessionId: resumeSessionId);
        await _store.save(_state);
      }
    }

    final bridge = DemoBridge()
      ..fixedPrompt = pack.prompt
      ..initialStepId = initialStepId
      ..resumeSessionId = resumeSessionId
      ..hooks = (
        onComplete: _completeDemo,
        onExitRequested: _handleExitRequested,
        onStepCheckpoint: updateStep,
        onSessionRecorded: recordSessionId,
      );

    final selection = DemoSelectionController(
      bridge: bridge,
      loader: _loader,
      candidates: candidates,
      initialCandidate: candidate,
      initialPack: pack,
      onIdentityPersist: _persistCandidateIdentity,
    );
    if (roundStarted) selection.lock();
    bridge.selection = selection;

    _container = ProviderContainer(
      overrides: buildDemoOverrides(
        bridge: bridge,
        demoDb: demoDb,
        prefs: prefs,
        secure: secure,
        pack: pack,
        selection: selection,
      ),
    );
    _demoDb = demoDb;
    _bridge = bridge;

    if (!resuming) {
      _state = _state.copyWith(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        runId: _uuid.v4(),
        clearSessionId: true,
        seedPresetId: presetId,
        localeTag: localeTag,
        packContentVersion: pack.manifest.contentVersion,
        formatVersion: pack.manifest.formatVersion,
        replayProfileId: pack.manifest.replayProfile?.id ??
            DemoReplayProfile.conservativeRelayId,
        capabilitiesHash: pack.manifest.replayProfile?.capabilitiesHash ??
            DemoReplayProfile.conservativeRelay.capabilitiesHash,
        candidateId: candidate.id,
        virtualModelId: candidate.virtualModelId,
        packSha256: candidate.packSha256,
      );
    } else {
      _state = _state.copyWith(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        stepId: initialStepId,
        seedPresetId: presetId,
        localeTag: localeTag,
        // 候选身份回填：旧单包状态（无 candidateId）经映射+对账成功后
        // 补记，后续恢复不再依赖映射推断
        candidateId: candidate.id,
        virtualModelId: candidate.virtualModelId,
        packSha256: candidate.packSha256,
      );
    }
    // 若当前有子路由在栈（如从设置/Wiki页手动启动），先退回根路由，
    // 待路由退出动画完成后再挂载演示作用域并激活遮罩，确保用户回到主界面后再出现引导蒙版。
    if (_navigatorKey.currentState?.canPop() ?? false) {
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      // lm-motion-exempt: 路由退出动画完成等待窗口（非过渡动效，挂载遮罩前的时序缓冲）
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _navigatorKey = GlobalKey<NavigatorState>();
    await _store.save(_state);
    notifyListeners();
  }

  /// 候选身份持久化（选择绑定完成后、向导确认前调用——可等待）。
  /// 全新 run 挂载时已写入初始身份，此处覆盖为最新绑定。
  ///
  /// 失败补偿：保存抛错时把内存身份回滚到保存前快照——
  /// 协调点据此保持上一个完整选择，不出现「内存已换、磁盘没写」或
  /// 「磁盘已写、内存没换」的半提交。
  Future<void> _persistCandidateIdentity(
    DemoCandidate candidate,
    DemoPack pack,
  ) async {
    final previous = _state;
    _state = _state.copyWith(
      candidateId: candidate.id,
      virtualModelId: candidate.virtualModelId,
      packSha256: candidate.packSha256,
      packContentVersion: pack.manifest.contentVersion,
      formatVersion: pack.manifest.formatVersion,
      replayProfileId: pack.manifest.replayProfile?.id ??
          DemoReplayProfile.conservativeRelayId,
      capabilitiesHash: pack.manifest.replayProfile?.capabilitiesHash ??
          DemoReplayProfile.conservativeRelay.capabilitiesHash,
    );
    try {
      await _store.save(_state);
    } catch (_) {
      _state = previous;
      rethrow;
    }
  }

  /// 该会话是否已开始回合（任一 agent 事件落库）——据此在恢复路径
  /// 锁定候选绑定（首轮发送后禁止热换模型）。
  Future<bool> _roundStarted(AppDatabase demoDb, String? sessionId) async {
    if (sessionId == null) return false;
    try {
      final rows = await demoDb.customSelect(
        'SELECT COUNT(*) AS n FROM agent_events WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).get();
      return rows.first.read<int>('n') > 0;
    } catch (_) {
      return false;
    }
  }

  /// 恢复矩阵（契约 §4.2）：返回（步骤, 会话导航目标）。
  /// 无物化会话 → 向导起点；回合未提交 → 重发步骤；已提交 → 设置步。
  Future<(String, String?)> _deriveResume(AppDatabase demoDb) async {
    try {
      final rows = await demoDb
          .customSelect(
            'SELECT session_id, next_turn FROM chat_sessions '
            "WHERE mode = 'advanced' ORDER BY last_active_at DESC LIMIT 1",
          )
          .get();
      if (rows.isEmpty) return ('homeWizardEntry', null);
      final sid = rows.first.read<String>('session_id');
      final nextTurn = rows.first.data['next_turn'] as int?;
      if (nextTurn != null && nextTurn >= 2) {
        if (_state.stepId == 'backToSession') {
          return ('backToSession', sid);
        }
        return ('settingsIntro', sid);
      }
      return ('sessionInput', sid);
    } catch (_) {
      return ('homeWizardEntry', null);
    }
  }

  /// 教程完成 → 交接（先落 handoverPending 再执行——崩溃窗口靠幂等）
  Future<void> _completeDemo() async {
    if (_state.sessionId == null) {
      await _teardownScope();
      await _finishHandover();
      return;
    }
    _state = _state.copyWith(phase: DemoPhase.handoverPending);
    await _store.save(_state);
    if (!_disposed) notifyListeners();
    await _runHandover();
  }

  /// 运行中交接（Demo 容器存活着，库句柄在途）
  Future<void> _runHandover() async {
    final sid = _state.sessionId;
    if (sid == null || _demoDb == null) {
      // 句柄缺失不应冒充完成：走启动期核验路径
      await _resolvePendingHandoverOnStartup();
      return;
    }
    try {
      final result = await _handoverFactory().run(
        demoDb: _demoDb!,
        realDb: _realDb,
        sourceSessionId: sid,
      );
      if (result == DemoHandoverResult.sourceMissing) {
        // 源缺失且正式未导入：不得标记完成——保持 pending 可重试/放弃
        debugPrint('demo handover: source missing, stays pending');
        notifyListeners();
        return;
      }
    } catch (e) {
      // 交接失败：保持 handoverPending，源数据完好，可重试
      debugPrint('demo handover failed: $e');
      notifyListeners();
      return;
    }
    await _teardownScope();
    await _finishHandover();
  }

  /// 启动期 handoverPending 核验：**重新打开正确源库**，按实际导入
  /// 状态收敛——只有「本次导入成功」或「此前确已成功」才标记完成；
  /// 源缺失/打开失败/导入异常一律保持 pending（可重试、可放弃）。
  Future<void> _resolvePendingHandoverOnStartup() async {
    final sid = _state.sessionId;
    if (sid == null) {
      // 无源可核验：保持 pending，交由显式放弃/全新 run 收敛
      return;
    }
    final AppDatabase demoDb;
    try {
      demoDb = await _openDatabase();
    } catch (_) {
      return; // 打不开源库：保留 pending，下次启动重试
    }
    try {
      final result = await _handoverFactory().run(
        demoDb: demoDb,
        realDb: _realDb,
        sourceSessionId: sid,
      );
      if (result == DemoHandoverResult.sourceMissing) {
        debugPrint('demo handover: source missing on startup, stays pending');
        return;
      }
      await _finishHandover();
    } catch (e) {
      debugPrint('demo handover retry failed: $e');
    } finally {
      await demoDb.close();
    }
  }

  Future<void> _finishHandover() async {
    _state = _state.copyWith(
      phase: DemoPhase.handoverDone,
      clearSessionId: true,
    );
    await _store.save(_state);
    if (!_disposed) notifyListeners();
  }

  /// 交接失败后的手动重试（或 handoverPending 态重进）
  Future<void> retryHandover() => _runHandover();

  /// 测试入口：教程收尾（完成）触发的交接链。生产入口为教程
  /// onFinished 回调（经桥 onComplete），两者共用同一实现。
  @visibleForTesting
  Future<void> completeForTest() => _completeDemo();

  /// 遮罩退出/退出体验入口：确认后按选择处置。
  /// 弹窗上下文经导航键实时取用（每次 await 前重取，不跨 gap 持有）。
  Future<void> _handleExitRequested() async {
    final entryContext = navigatorKey.currentContext;
    if (entryContext == null) {
      await exitKeepData();
      return;
    }
    final choice = await showDemoExitDialog(entryContext);
    switch (choice) {
      case DemoExitChoice.keep:
        await exitKeepData();
      case DemoExitChoice.abandon:
        final abandonContext = navigatorKey.currentContext;
        if (abandonContext == null) break;
        final confirmed = await _confirmAbandon();
        if (confirmed) {
          await abandon();
        } else {
          // 二次确认取消：教程原地恢复
          _bridge?.tutorial.cancelExit();
        }
      case DemoExitChoice.stay:
        // 继续体验：清除请求态，教程原步骤/进度/回放全部保留
        _bridge?.tutorial.cancelExit();
    }
  }

  /// 放弃演示数据的二次确认（导航键实时取上下文）
  Future<bool> _confirmAbandon() async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return confirmDemoAbandon(context);
  }

  /// 退出保存（保持 running 检查点，可 resume）
  Future<void> exitKeepData() async {
    await _teardownScope();
  }

  /// 放弃演示数据（已交接的正式会话不受影响）
  Future<void> abandon() async {
    const newState = DemoState(
      inviteStatus: DemoInviteStatus.accepted,
    );
    _state = newState;
    await _store.delete();
    await _store.save(_state);
    try {
      await deleteDemoDatabaseFiles();
    } catch (_) {}
    await _teardownScope();
  }

  /// 步骤检查点更新（流程侧调用）
  Future<void> updateStep(String? stepId) async {
    if (_state.stepId == stepId) return;
    _state = _state.copyWith(stepId: stepId);
    await _store.save(_state);
  }

  /// 演示会话 id 回填（物化后由流程侧调用）
  Future<void> recordSessionId(String sessionId) async {
    if (_state.sessionId == sessionId) return;
    _state = _state.copyWith(sessionId: sessionId);
    await _store.save(_state);
  }

  Future<void> _teardownScope() async {
    // 先解绑回调（bridge.dispose 同步触发 tutorial/registry 的
    // listener→hooks→updateStep→notifyListeners 再入链），再销毁。
    _bridge?.hooks = (
      onComplete: null,
      onExitRequested: null,
      onStepCheckpoint: null,
      onSessionRecorded: null,
    );
    final deadContainer = _container;
    final deadDb = _demoDb;
    final deadBridge = _bridge;
    _container = null;
    _demoDb = null;
    _bridge = null;
    _navigatorKey = GlobalKey<NavigatorState>();

    // 关键生命周期纪律：先通知 UI 卸载 DemoScope（MaterialApp 切回根作用域），
    // 待旧树完成卸载后再销毁旧 ProviderContainer 与桥。
    if (!_disposed) notifyListeners();

    // 推进微任务，让 Flutter 完成旧树卸载与 Element 依赖解绑
    await Future.microtask(() {});

    deadContainer?.dispose();
    await deadDb?.close();
    deadBridge?.dispose();
  }

  bool _disposed = false;

  @override
  void dispose() {
    // 幂等：addTearDown 与 provider 自动 dispose 可能双调
    if (_disposed) return;
    _disposed = true;
    _teardownScope();
    super.dispose();
  }
}

/// 根作用域注册（真实库/真实 prefs/真实钥匙串——仅邀请门控读取）
final demoRuntimeProvider = ChangeNotifierProvider<DemoRuntime>((ref) {
  return DemoRuntime(
    realDatabase: ref.read(appDatabaseProvider),
    preferences: ref.read(preferencesProvider),
    secureStorage: ref.read(secureStorageProvider),
  );
});

/// 启动检查门（职责边界）：邀请/恢复弹窗只发生在**前台根作用域**。
/// 根缺省=真实门（委托根运行时，含一次性防重入）；演示装配覆写为
/// 禁用门（no-op 函数）——Demo 容器内的宿主 UI（MainLayout）调用
/// 禁用门即跳过，不会构造第二个运行时、不会重复弹邀请/恢复框。
typedef DemoStartupGate = Future<void> Function();

final demoStartupGateProvider = Provider<DemoStartupGate>((ref) {
  final runtime = ref.read(demoRuntimeProvider);
  var done = false;
  var inFlight = false;
  Future<void> gate() async {
    if (done || inFlight) return;
    inFlight = true;
    try {
      await _runChecks(runtime);
    } finally {
      done = true;
      inFlight = false;
    }
  }

  return gate;
});

Future<void> _runChecks(DemoRuntime runtime) async {
  await runtime.load();
  final eligible = runtime.inviteEligible;
  final resumable = runtime.state.phase == DemoPhase.running;
  if (!eligible && !resumable) return;

  final context = runtime.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;

  if (eligible) {
    final accepted = await showDemoInviteDialog(context);
    if (accepted) {
      await runtime.start();
    } else {
      await runtime.declineInvite();
    }
    return;
  }

  await handleDemoResumeFlow(runtime, context);
}

/// 处理演示恢复与不兼容决策流程
Future<void> handleDemoResumeFlow(
  DemoRuntime runtime,
  BuildContext context,
) async {
  final choice = await showDemoResumeDialog(context);
  if (!context.mounted) return;
  switch (choice) {
    case DemoResumeChoice.cont:
      try {
        await runtime.start();
      } catch (e) {
        // 画像/版本不符等身份拒绝：保持库与状态完整，不清库、不伪造交接
        debugPrint('demo resume refused: $e');
        if (!context.mounted) return;
        final postChoice = await showDemoIncompatibleDialog(
          context,
          error: e,
        );
        if (!context.mounted) return;
        switch (postChoice) {
          case DemoIncompatibleChoice.restart:
            await runtime.start(fresh: true);
          case DemoIncompatibleChoice.abandon:
            await runtime.abandon();
          case DemoIncompatibleChoice.cancel:
          case null:
            // 稍后处理 / 取消：原演示成果与正式会话不变，不清库、不伪造交接
            break;
        }
      }
    case DemoResumeChoice.restart:
      await runtime.start(fresh: true);
    case DemoResumeChoice.abandon:
      await runtime.abandon();
    case null:
      break;
  }
}
