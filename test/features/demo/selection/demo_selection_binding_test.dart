import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';

/// 多仿真候选选择绑定回归：真实资产包（rootBundle 加载经完整校验）+
/// 换包一致性（回放 LLM/嵌入/画像/桥引用一次换齐）+ 失败回滚 + 锁定 +
/// 并发串行化（可控加载/保存延迟与错误）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loader = DemoPackLoader();
  late List<DemoCandidate> candidates;
  late Map<String, DemoPack> packsById;

  setUpAll(() async {
    candidates = await loader.availableCandidates('zh-CN');
    packsById = {
      for (final c in candidates) c.id: await loader.loadCandidate(c),
    };
  });

  ({
    DemoSelectionController controller,
    DemoBridge bridge,
    DemoReplayLlmService replay,
    DemoReplayEmbeddingService embedding,
    List<(DemoCandidate, DemoPack)> persisted,
  }) buildController({
    DemoCandidate? initial,
    bool persistFails = false,
    DemoPackLoader? loaderOverride,
    Completer<void>? persistGate,
  }) {
    final bridge = DemoBridge();
    final initialCandidate = initial ?? candidates.first;
    final initialPack = packsById[initialCandidate.id]!;
    final replay = DemoReplayLlmService(
      pack: initialPack,
      guard: bridge.guard,
      timing: DemoReplayTiming.immediate,
    );
    final embedding =
        DemoReplayEmbeddingService(pack: initialPack, guard: bridge.guard);
    bridge
      ..replay = replay
      ..replayEmbedding = embedding
      // 挂载期装配语义（buildDemoOverrides 同源）：桥引用随初始包就位
      ..pack = initialPack
      ..replayProfile = initialPack.manifest.replayProfile;
    final persisted = <(DemoCandidate, DemoPack)>[];
    final controller = DemoSelectionController(
      bridge: bridge,
      loader: loaderOverride ?? loader,
      candidates: candidates,
      initialCandidate: initialCandidate,
      initialPack: initialPack,
      onIdentityPersist: (candidate, pack) async {
        if (persistGate != null) await persistGate.future;
        if (persistFails) throw StateError('synthetic identity write failure');
        persisted.add((candidate, pack));
      },
    );
    return (
      controller: controller,
      bridge: bridge,
      replay: replay,
      embedding: embedding,
      persisted: persisted,
    );
  }

  DemoCandidate byId(String id) => candidates.firstWhere((c) => c.id == id);

  test('绑定换包：回放服务/嵌入服务/桥引用/画像一次换齐', () async {
    final c = buildController();
    final target = byId('deepseek-v4.1-flash');

    await c.controller.bindByVirtualModelId(target.virtualModelId);

    expect(c.controller.current.id, 'deepseek-v4.1-flash');
    final bound = packsById['deepseek-v4.1-flash']!;
    // bind 为按需真实加载（新实例），按包身份值断言
    expect(
      c.replay.pack.manifest.contentVersion,
      bound.manifest.contentVersion,
    );
    expect(
      c.embedding.pack.manifest.contentVersion,
      bound.manifest.contentVersion,
    );
    expect(
      c.bridge.pack!.manifest.contentVersion,
      bound.manifest.contentVersion,
    );
    expect(
      c.controller.pack.manifest.source?['textModel'],
      'deepseek-v4.1-flash',
    );
    expect(
      c.bridge.replayProfile?.id,
      packsById['deepseek-v4.1-flash']!.manifest.replayProfile?.id,
    );
    expect(c.controller.capabilities, ProviderToolCapabilities.deepseek);
    // 身份持久化在绑定完成前发生（可等待，向导确认在其后）
    expect(c.persisted, hasLength(1));
    expect(c.persisted.single.$1.id, 'deepseek-v4.1-flash');
  });

  test('不同候选画像真实不同（zhipu/deepseek/conservativeRelay 三态）', () async {
    final c = buildController();
    expect(c.controller.capabilities, ProviderToolCapabilities.zhipu);

    await c.controller
        .bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId);
    expect(
      c.controller.capabilities,
      ProviderToolCapabilities.conservativeRelay,
    );
    expect(c.controller.capabilities.streamingToolCallsReliable, isFalse);

    await c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    expect(c.controller.capabilities, ProviderToolCapabilities.deepseek);
    expect(c.controller.capabilities.streamingToolCallsReliable, isTrue);
  });

  test('A→B→A 快速连续绑定：终态一致且每次身份都持久化', () async {
    final c = buildController();
    final a = candidates.first; // glm-5.3
    final b = byId('glm-5.3-flash');

    await c.controller.bindByVirtualModelId(b.virtualModelId);
    await c.controller.bindByVirtualModelId(a.virtualModelId);
    await c.controller.bindByVirtualModelId(b.virtualModelId);

    expect(c.controller.current.id, 'glm-5.3-flash');
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById['glm-5.3-flash']!.manifest.contentVersion,
    );
    expect(
      c.persisted.map((p) => p.$1.id).toList(),
      ['glm-5.3-flash', 'glm-5.3', 'glm-5.3-flash'],
    );
  });

  test('同候选重复绑定：不换包不重置游标，仅补记身份', () async {
    final c = buildController();
    final a = candidates.first;
    await c.controller.bindByVirtualModelId(a.virtualModelId);
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById[a.id]!.manifest.contentVersion,
    );
    expect(c.persisted, hasLength(1));
    expect(c.persisted.single.$1.id, a.id);
  });

  test('未知虚拟模型 id：本地失败，保持上一个完整选择', () async {
    final c = buildController();
    expect(
      () => c.controller.bindByVirtualModelId('demo-narrator-not-exist'),
      throwsA(isA<DemoCandidateUnknownException>()),
    );
    // 给异常路径一点完成时间（await 抛出即返回）
    await Future<void>.delayed(Duration.zero);
    expect(c.controller.current.id, candidates.first.id);
    expect(c.persisted, isEmpty);
  });

  test('候选加载失败：保持上一个完整选择，不联网兜底', () async {
    final c = buildController();
    // 用坏候选（指向缺失资产）构造失败路径
    const broken = DemoCandidate(
      id: 'broken-candidate',
      sourceModelId: 'x',
      virtualModelId: 'demo-narrator-broken',
      locale: 'zh-CN',
      assetPath: 'assets/demo/first_launch/zh-CN/missing.json',
      isDefault: false,
      displayNameZh: '坏',
      displayNameEn: 'Broken',
    );
    final withBroken = DemoSelectionController(
      bridge: c.bridge,
      loader: loader,
      candidates: [...candidates, broken],
      initialCandidate: candidates.first,
      initialPack: packsById[candidates.first.id]!,
      onIdentityPersist: (_, __) async {},
    );
    await expectLater(
      withBroken.bindByVirtualModelId('demo-narrator-broken'),
      throwsA(isA<DemoPackUnavailableException>()),
    );
    expect(withBroken.current.id, candidates.first.id);
    expect(
      withBroken.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
      reason: '失败后回放数据包必须保持上一个完整选择',
    );
  });

  test('锁定后绑定一律拒绝（首轮发送/物化开始后禁热换）', () async {
    final c = buildController();
    c.controller.lock();
    expect(
      () => c.controller
          .bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId),
      throwsA(isA<DemoCandidateLockedException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.controller.current.id, candidates.first.id);
    expect(c.persisted, isEmpty);
  });

  test('换包后回放内容真实切换（串包防线：流式通道画像）', () async {
    final c = buildController();
    final target = byId('deepseek-v4.1-flash'); // 流式工具通道画像
    await c.controller.bindByVirtualModelId(target.virtualModelId);

    const request = LlmRequest(
      baseUrl: 'https://demo.invalid/v1',
      modelId: 'demo-narrator-deepseek-v4.1-flash',
      messages: <Map<String, dynamic>>[],
      purpose: LlmPurposes.agentStep,
    );
    // 回放全部 agent_step 步（思考/工具步后才是正文步）
    final buffer = StringBuffer();
    for (var i = 0; i < 3; i++) {
      final events = await c.replay.streamChat(request).toList();
      buffer
        ..write(
          events.whereType<LlmTextDelta>().map((e) => e.content).join(),
        )
        ..write(
          events
              .whereType<LlmToolCallComplete>()
              .map((e) => e.arguments.toString())
              .join(),
        );
    }
    final text = buffer.toString();
    final pack = packsById['deepseek-v4.1-flash']!;
    expect(text, isNotEmpty, reason: '换包后回放应产出正文');
    for (final needle in pack.expectations.proseContains) {
      expect(text, contains(needle), reason: '正文必须来自新绑定包');
    }
    // 旧包（默认 glm-5.3）的正文不得串入
    final oldPack = packsById[candidates.first.id]!;
    for (final needle in oldPack.expectations.proseContains) {
      expect(text, isNot(contains(needle)), reason: '不得串到旧包正文');
    }
  });

  test('换包后非流式通道回放真实切换（保守档画像走 chat）', () async {
    final c = buildController();
    final target = byId('mimo-v2.6-flash'); // conservativeRelay：非流式工具
    await c.controller.bindByVirtualModelId(target.virtualModelId);

    const request = LlmRequest(
      baseUrl: 'https://demo.invalid/v1',
      modelId: 'demo-narrator-mimo-v2.6-flash',
      messages: <Map<String, dynamic>>[],
      purpose: LlmPurposes.agentStep,
    );
    // 回放全部 agent_step 条目；正文经工具调用参数（叙事工具）交付
    final buffer = StringBuffer();
    for (var i = 0; i < 6; i++) {
      final resp = await c.replay.chat(request);
      buffer.write(resp.content);
      for (final tc in resp.toolCalls ?? const <ToolCall>[]) {
        buffer.write(tc.arguments.toString());
      }
    }
    final text = buffer.toString();
    final pack = packsById['mimo-v2.6-flash']!;
    expect(text, isNotEmpty, reason: '换包后回放应产出正文');
    for (final needle in pack.expectations.proseContains) {
      expect(text, contains(needle), reason: '正文必须来自新绑定包');
    }
    final oldPack = packsById[candidates.first.id]!;
    for (final needle in oldPack.expectations.proseContains) {
      expect(text, isNot(contains(needle)), reason: '不得串到旧包正文');
    }
  });

  test('零嵌入候选（mimo）与有嵌入候选（glm-5.3）的嵌入服务真实换包', () async {
    final c = buildController();
    expect(
      packsById['glm-5.3']!.embeddings,
      isNotEmpty,
    );
    expect(
      packsById['mimo-v2.6-flash']!.embeddings,
      isEmpty,
      reason: 'mimo 候选未触发嵌入，零 embed 行合法',
    );
    await c.controller
        .bindByVirtualModelId(byId('mimo-v2.6-flash').virtualModelId);
    expect(c.embedding.pack.embeddings, isEmpty);
    await c.controller.bindByVirtualModelId(candidates.first.virtualModelId);
    expect(c.embedding.pack.embeddings, isNotEmpty);
  });

  // —— 并发串行化与全提交面一致（可控延迟/错误回归）——

  test('身份保存失败：绑定失败且全部提交面保持上一完整选择', () async {
    final c = buildController(persistFails: true);
    final target = byId('deepseek-v4.1-flash');
    await expectLater(
      c.controller.bindByVirtualModelId(target.virtualModelId),
      throwsStateError,
      reason: '身份持久化失败必须让绑定整体失败',
    );
    // 全提交面（协调点内存/回放 LLM/嵌入/Bridge/画像）全部保持原包
    expect(c.controller.current.id, candidates.first.id);
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
    );
    expect(
      c.embedding.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
    );
    expect(
      c.bridge.pack!.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
    );
    expect(c.bridge.replayProfile?.id, DemoReplayProfile.zhipuId);
    expect(c.controller.capabilities, ProviderToolCapabilities.zhipu);
    expect(c.persisted, isEmpty, reason: '失败的绑定不留下身份记录');
  });

  test('并发绑定串行提交：先点的慢请求不能覆盖后点的快请求', () async {
    final gate = Completer<void>();
    final gated = _GatedLoader(
      packsById,
      gates: {'deepseek-v4.1-flash': gate},
    );
    final c = buildController(loaderOverride: gated);
    final deepseek = byId('deepseek-v4.1-flash');
    final kimi = byId('kimi-k3.1-pro');

    final a = c.controller.bindByVirtualModelId(deepseek.virtualModelId);
    await Future<void>.delayed(Duration.zero); // A 进入慢加载
    final b = c.controller.bindByVirtualModelId(kimi.virtualModelId);
    await Future<void>.delayed(Duration.zero); // B 进入排队
    gate.complete();
    // 两个请求都必须正常完成（串行逐一提交），最终状态=最后选择的 B
    await Future.wait([a, b]);

    expect(c.controller.current.id, 'kimi-k3.1-pro');
    expect(
      c.controller.capabilities,
      ProviderToolCapabilities.conservativeRelay,
    );
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById['kimi-k3.1-pro']!.manifest.contentVersion,
    );
    expect(
      c.embedding.pack.manifest.contentVersion,
      packsById['kimi-k3.1-pro']!.manifest.contentVersion,
    );
    expect(
      c.bridge.pack!.manifest.contentVersion,
      packsById['kimi-k3.1-pro']!.manifest.contentVersion,
    );
    // 身份按提交顺序逐一落账：慢的 A 先提交，快的 B 最后提交定稿
    expect(
      c.persisted.map((p) => p.$1.id).toList(),
      ['deepseek-v4.1-flash', 'kimi-k3.1-pro'],
    );
  });

  test('加载窗口内首轮锁定：迟到加载拒绝换包并保持原选择', () async {
    final gate = Completer<void>();
    final gated = _GatedLoader(
      packsById,
      gates: {'deepseek-v4.1-flash': gate},
    );
    final c = buildController(loaderOverride: gated);

    final pending = c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    await Future<void>.delayed(Duration.zero); // 进入加载窗口
    c.controller.lock(); // 首轮开始
    final assertion = expectLater(
      pending,
      throwsA(isA<DemoCandidateLockedException>()),
    );
    gate.complete();
    await assertion;

    expect(c.controller.current.id, candidates.first.id);
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
    );
    expect(c.persisted, isEmpty, reason: '被拒绝的迟到绑定不落身份');
  });

  test('持久化窗口内首轮锁定：补偿回滚持久身份，保持原选择', () async {
    final gate = Completer<void>();
    final c = buildController(persistGate: gate);

    final pending = c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    await Future<void>.delayed(Duration.zero); // 进入身份保存窗口
    c.controller.lock(); // 保存期间首轮开始
    final assertion = expectLater(
      pending,
      throwsA(isA<DemoCandidateLockedException>()),
    );
    gate.complete();
    await assertion;

    expect(c.controller.current.id, candidates.first.id);
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
      reason: '锁定后的迟到绑定不换装回放',
    );
    // 持久化账：先写新身份（提交第一步），锁定后补偿写回原身份
    expect(
      c.persisted.map((p) => p.$1.id).toList(),
      ['deepseek-v4.1-flash', 'glm-5.3'],
      reason: '补偿回滚必须真实写回上一身份，不留半提交',
    );
  });

  test('首轮回放调用即锁定（真实接线：onRoundStarted→lock），辅助通道不触发', () async {
    final bridge = DemoBridge();
    final initialPack = packsById[candidates.first.id]!;
    final persisted = <DemoCandidate>[];
    final controller = DemoSelectionController(
      bridge: bridge,
      loader: loader,
      candidates: candidates,
      initialCandidate: candidates.first,
      initialPack: initialPack,
      onIdentityPersist: (c, _) async => persisted.add(c),
    );
    // 与 buildDemoOverrides 相同的接线：回放服务首调 → selection.lock
    final replay = DemoReplayLlmService(
      pack: initialPack,
      guard: bridge.guard,
      timing: DemoReplayTiming.immediate,
      onRoundStarted: controller.lock,
    );
    bridge.replay = replay;

    // 辅助通道（会话标题）不是回合开始证据：不锁定。
    // glm-5.3 包无 chat 条目，未匹配本地失败即预期形态——关键断言是
    // 这次真实调用没有触发锁定。
    await expectLater(
      replay.chat(
        const LlmRequest(
          baseUrl: 'https://demo.invalid/v1',
          modelId: 'demo-narrator-glm',
          messages: <Map<String, dynamic>>[],
          purpose: LlmPurposes.sessionTitle,
        ),
      ),
      throwsA(isA<DemoReplayUnmatchedException>()),
    );
    expect(controller.locked, isFalse, reason: '辅助通道不触发首轮锁定');

    // 首次叙事步调用（流式）即锁定
    const request = LlmRequest(
      baseUrl: 'https://demo.invalid/v1',
      modelId: 'demo-narrator-glm',
      messages: <Map<String, dynamic>>[],
      purpose: LlmPurposes.agentStep,
    );
    await replay.streamChat(request).drain<void>();
    expect(controller.locked, isTrue, reason: '首轮开始即锁定，不等事件轮询');

    // 锁定后绑定一律拒绝，原选择保持
    await expectLater(
      controller.bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId),
      throwsA(isA<DemoCandidateLockedException>()),
    );
    expect(controller.current.id, candidates.first.id);
    expect(persisted, isEmpty);
  });

  test('关闭取消同时覆盖执行中与排队中的请求：排队请求开始执行即取消', () async {
    final gate = Completer<void>();
    final gated = _GatedLoader(
      packsById,
      gates: {'deepseek-v4.1-flash': gate},
    );
    final c = buildController(loaderOverride: gated);

    final a = c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    await Future<void>.delayed(Duration.zero); // A 进入慢加载
    final b =
        c.controller.bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId);
    await Future<void>.delayed(Duration.zero); // B 排队（尚未开始执行）
    c.controller.cancelPendingSelections(); // 选择器关闭：取消全部未提交请求
    final assertions = Future.wait([
      expectLater(a, throwsA(isA<DemoCandidateCancelledException>())),
      expectLater(b, throwsA(isA<DemoCandidateCancelledException>())),
    ]);
    gate.complete();
    await assertions;

    expect(
      c.controller.current.id,
      candidates.first.id,
      reason: '执行中与排队中的未提交请求都取消：原完整选择保持',
    );
    expect(
      c.persisted,
      isEmpty,
      reason: '取消的请求不写持久身份（排队请求开始执行即取消，不加载不保存）',
    );
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById[candidates.first.id]!.manifest.contentVersion,
      reason: '回放/桥引用保持原包',
    );
    // 完成入口屏障采用原已提交候选并锁定
    final committed = await c.controller.settleForSessionEntry();
    expect(committed, candidates.first.virtualModelId);
    expect(c.controller.locked, isTrue);
  });

  test('取消后新发起的选择可正常提交（未被入口锁定时）', () async {
    final gate = Completer<void>();
    final gated = _GatedLoader(
      packsById,
      gates: {'deepseek-v4.1-flash': gate},
    );
    final c = buildController(loaderOverride: gated);

    final pending = c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    await Future<void>.delayed(Duration.zero); // 进入加载窗口
    c.controller.cancelPendingSelections();
    final assertion = expectLater(
      pending,
      throwsA(isA<DemoCandidateCancelledException>()),
    );
    gate.complete();
    await assertion;
    expect(c.controller.current.id, candidates.first.id);

    // 取消之后用户新发起的选择：领取新代次，正常提交
    await c.controller
        .bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId);
    expect(c.controller.current.id, 'kimi-k3.1-pro');
    expect(c.persisted.map((p) => p.$1.id).toList(), ['kimi-k3.1-pro']);
  });

  test('取消不影响已提交的选择：原提交面保持原包', () async {
    final gate = Completer<void>();
    final gated = _GatedLoader(
      packsById,
      gates: {'kimi-k3.1-pro': gate},
    );
    final c = buildController(loaderOverride: gated);

    await c.controller
        .bindByVirtualModelId(byId('deepseek-v4.1-flash').virtualModelId);
    final pending =
        c.controller.bindByVirtualModelId(byId('kimi-k3.1-pro').virtualModelId);
    await Future<void>.delayed(Duration.zero); // K 进入加载窗口
    c.controller.cancelPendingSelections();
    final assertion = expectLater(
      pending,
      throwsA(isA<DemoCandidateCancelledException>()),
    );
    gate.complete();
    await assertion;

    expect(
      c.controller.current.id,
      'deepseek-v4.1-flash',
      reason: '已提交的选择不受取消影响',
    );
    expect(
      c.persisted.map((p) => p.$1.id).toList(),
      ['deepseek-v4.1-flash'],
      reason: '被取消的请求不落身份',
    );
    expect(
      c.replay.pack.manifest.contentVersion,
      packsById['deepseek-v4.1-flash']!.manifest.contentVersion,
    );
  });
}

/// 可控延迟/失败加载器：按候选 id 挂 Completer 门（复现「先点 A 再点 B」
/// 与「加载中锁定」的真实时序）与强制失败集。
class _GatedLoader extends DemoPackLoader {
  _GatedLoader(this._packs, {this.gates = const {}}) : failures = const {};

  final Map<String, DemoPack> _packs;
  final Map<String, Completer<void>> gates;
  final Set<String> failures;

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async {
    final gate = gates[candidate.id];
    if (gate != null) await gate.future;
    if (failures.contains(candidate.id)) {
      throw DemoPackUnavailableException('gated failure: ${candidate.id}');
    }
    return _packs[candidate.id]!;
  }
}
