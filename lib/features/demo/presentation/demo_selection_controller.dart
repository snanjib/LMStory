import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';

/// 首轮发送/会话入口后候选已锁定，禁止再换包
class DemoCandidateLockedException implements Exception {
  const DemoCandidateLockedException();

  @override
  String toString() =>
      'DemoCandidateLockedException: candidate locked after first send';
}

/// 虚拟模型 id 未命中当前 locale 可用候选目录
class DemoCandidateUnknownException implements Exception {
  const DemoCandidateUnknownException(this.virtualModelId);

  final String virtualModelId;

  @override
  String toString() =>
      'DemoCandidateUnknownException: $virtualModelId not in available candidates';
}

/// 未提交的选择请求被取消（选择器关闭/页面离开时统一取消）。
/// 被取消的请求不换包、不写身份；调用方（向导页/选择器）静默处理。
class DemoCandidateCancelledException implements Exception {
  const DemoCandidateCancelledException();

  @override
  String toString() =>
      'DemoCandidateCancelledException: pending selection cancelled';
}

/// 候选身份持久化回调（运行时注入：一致更新状态文件候选字段后才放行向导确认）
typedef DemoCandidateIdentityPersist = Future<void> Function(
  DemoCandidate candidate,
  DemoPack pack,
);

/// Demo 内部的选择/会话绑定协调点（多仿真模型体验的单一事实源）。
///
/// 职责：把「用户在真实向导模型步点了某个仿真模型」翻译成一次**一致绑定**——
/// 校验候选包 → 原子换装回放 LLM / 回放嵌入 / Bridge 的包引用与固定首问 /
/// 能力画像 → 持久化候选身份 → 返回。向导选择回调 await 本方法成功后才
/// 确认向导选择并推进引导；失败保持上一个完整选择（不联网兜底）。
///
/// **并发纪律**：所有绑定请求在单一协调点**串行化**——前一请求彻底结束
/// （提交或失败）后才执行下一请求，杜绝「先点的慢请求迟到覆盖后点的快
/// 请求」。每个请求的提交顺序为：加载（可 await）→ 加载后复检锁定/取消 →
/// 持久化身份（失败=零变更）→ 持久化后复检锁定/取消（补偿回滚持久身份）→
/// 同步原子换装（最后一步，无 await 窗口）。任何失败都保持上一个完整版本：
/// 身份存储、运行时内存、LLM 与嵌入回放、Bridge/画像要么全部指向新包，
/// 要么全部保持原包。
///
/// **生命周期**：绑定只发生在真实 Controller 构造/首轮发送之前（向导
/// 模型步）。选择器关闭时 [cancelPendingSelections] 取消全部未提交请求
/// （已提交的选择不受影响）——迟到请求不得在向导推进/页面离开后换包；
/// 首轮开始（首次回放 agent_step 调用）即 [lock]；会话创建入口先经
/// [settleForSessionEntry] 收敛队列并锁定，Controller/网关消费配置与
/// 画像前固定同一份已提交候选。不重建页面容器、不重写业务轮次——
/// 服务实例稳定，仅换数据源。
class DemoSelectionController {
  DemoSelectionController({
    required DemoBridge bridge,
    required DemoPackLoader loader,
    required List<DemoCandidate> candidates,
    required DemoCandidate initialCandidate,
    required DemoPack initialPack,
    required DemoCandidateIdentityPersist onIdentityPersist,
  })  : _bridge = bridge,
        _loader = loader,
        _candidates = List.unmodifiable(candidates),
        _current = initialCandidate,
        _pack = initialPack,
        _onIdentityPersist = onIdentityPersist;

  final DemoBridge _bridge;
  final DemoPackLoader _loader;
  final List<DemoCandidate> _candidates;
  final DemoCandidateIdentityPersist _onIdentityPersist;

  DemoCandidate _current;
  DemoPack _pack;
  bool _locked = false;

  /// 串行队列尾：下一个绑定请求等它彻底结束后才执行。
  /// 仅保留最近一个未来引用，已完成的链节随覆盖被回收。
  Future<void>? _bindQueueTail;

  /// 取消代次：递增即取消全部在途未提交请求（含已入队尚未开始执行的
  /// 请求——代次在入队时捕获）；各请求在开始执行与提交检查点比对代次，
  /// 代次已变即放弃提交。
  int _cancelEpoch = 0;

  /// 当前 locale 经加载校验的可用候选（向导模型步选项的唯一来源）
  List<DemoCandidate> get candidates => _candidates;

  /// 当前绑定候选
  DemoCandidate get current => _current;

  /// 当前绑定数据包
  DemoPack get pack => _pack;

  /// 当前候选的完整能力画像（注入 agentCapabilitiesOverrideProvider）
  ProviderToolCapabilities get capabilities =>
      _pack.manifest.replayProfile?.resolveCapabilities() ??
      DemoReplayProfile.conservativeRelay.resolveCapabilities();

  /// 当前候选虚拟模型 id
  String get virtualModelId => _current.virtualModelId;

  /// 首轮发送/会话入口后锁定（流程侧、运行时恢复路径与会话入口屏障调用）
  bool get locked => _locked;

  void lock() {
    _locked = true;
  }

  /// 取消当前所有未完成绑定请求（选择器关闭/页面离开时调用）。
  /// 已提交的选择不受影响；被取消的请求在其提交检查点抛
  /// [DemoCandidateCancelledException]（调用方静默处理），不换包、
  /// 不写身份——迟到回调就此失效。
  void cancelPendingSelections() => _cancelEpoch++;

  /// 会话创建入口屏障：等待未完成绑定请求收敛（完整提交或被取消），
  /// 锁定候选并返回**已提交候选**的虚拟模型 id。向导完成在真实
  /// Controller/网关消费配置与画像之前调用——此后任何迟到请求一律
  /// 被锁拒绝，保证会话配置、Bridge、两回放服务、画像与持久身份
  /// 指向同一份已提交候选。
  Future<String> settleForSessionEntry() async {
    // 排空串行队列（在途请求完整提交或被取消；已被取消但仍在加载的
    // 请求也等到底——其提交检查点会放弃提交）。捕获-等待-比对循环
    // 覆盖等待期间新入队请求的极端情况。
    for (var guard = 0; guard < 16; guard++) {
      final tail = _bindQueueTail;
      if (tail == null) break;
      try {
        await tail;
      } catch (_) {
        // 失败/取消只属于各自调用方；入口屏障只要求队列排空
      }
      if (identical(_bindQueueTail, tail)) break;
    }
    lock();
    return _current.virtualModelId;
  }

  /// 选择并绑定候选（可等待）。成功返回即「换装 + 持久身份」全部完成；
  /// 抛错则一切保持上一个完整选择。
  ///
  /// - [virtualModelId]：演示命名空间虚拟模型 id（`demo-narrator-*`）。
  /// - 并发请求串行执行（按到达顺序逐一完整提交，最后执行的即最终绑定）；
  ///   各请求的成败只上抛给各自调用方，前一请求失败不阻塞后一请求。
  /// - 同候选重复选择：不换包不重置游标，仅补记身份（全新 run 默认项
  ///   也经此补记，保证持久身份完整）。
  Future<void> bindByVirtualModelId(String virtualModelId) {
    final prior = _bindQueueTail;
    // 取消代次在入队时捕获：排队期间发生的取消同样作用于本请求，
    // 不能等开始执行时重新领取新代次（否则已取消的排队请求照常提交）。
    final cancelEpochAtEntry = _cancelEpoch;
    final execution =
        _runBindSerialized(prior, virtualModelId, cancelEpochAtEntry);
    _bindQueueTail = execution;
    return execution;
  }

  /// 串行执行壳：前一请求彻底结束后才运行本请求（提交或失败皆算结束）。
  Future<void> _runBindSerialized(
    Future<void>? prior,
    String virtualModelId,
    int cancelEpochAtEntry,
  ) async {
    try {
      await prior;
    } catch (_) {
      // 前一请求的失败只属于它自己的调用方；不阻塞本请求
    }
    await _runBind(virtualModelId, cancelEpochAtEntry);
  }

  /// 请求发起时的取消代次；此后任一检查点代次变化即放弃提交
  void _ensureNotCancelled(int epochAtEntry) {
    if (_cancelEpoch != epochAtEntry) {
      throw const DemoCandidateCancelledException();
    }
  }

  Future<void> _runBind(String virtualModelId, int cancelEpochAtEntry) async {
    if (_locked) {
      throw const DemoCandidateLockedException();
    }
    // 排队期间已被取消：开始执行即受控取消——不加载、不写身份、不换包
    //（同候选快速通道同样不可绕过本检查）。
    _ensureNotCancelled(cancelEpochAtEntry);
    DemoCandidate? candidate;
    for (final c in _candidates) {
      if (c.virtualModelId == virtualModelId) {
        candidate = c;
        break;
      }
    }
    if (candidate == null) {
      throw DemoCandidateUnknownException(virtualModelId);
    }

    final previousCandidate = _current;
    final previousPack = _pack;
    final sameCandidate = candidate.id == _current.id;
    var nextPack = _pack;
    if (!sameCandidate) {
      nextPack = await _loader.loadCandidate(candidate);
      // 加载窗口复检：锁定/取消发生 → 拒绝本次绑定，保持原选择
      if (_locked) {
        throw const DemoCandidateLockedException();
      }
      _ensureNotCancelled(cancelEpochAtEntry);
    }

    // 提交第一步——身份持久化。失败在此上抛：服务/Bridge/协调点内存
    // 尚未做任何变更，上一个完整选择原样保持（换装必须排在可失败的
    // 异步步骤之后）。
    await _onIdentityPersist(candidate, nextPack);

    // 持久化窗口复检：锁定/取消发生在保存期间 → 补偿回滚持久身份后再
    // 拒绝（磁盘/运行时内存/协调点回到同一完整版本，不留下「身份已写、
    // 服务未换」的半提交状态）。同候选重绑写入值恒等，无需回滚。
    final superseded = _locked || _cancelEpoch != cancelEpochAtEntry;
    if (superseded && !sameCandidate) {
      await _onIdentityPersist(previousCandidate, previousPack);
    }
    if (_locked) {
      throw const DemoCandidateLockedException();
    }
    _ensureNotCancelled(cancelEpochAtEntry);
    if (!sameCandidate) {
      _attachPack(candidate, nextPack);
    }
  }

  /// 原子换装：回放服务 + 桥引用一次换齐（任一失败不会留下半换状态——
  /// 全部是内存赋值，无异步窗口）
  void _attachPack(DemoCandidate candidate, DemoPack pack) {
    _current = candidate;
    _pack = pack;
    _bridge.replay?.attachPack(pack);
    _bridge.replayEmbedding?.pack = pack;
    _bridge
      ..pack = pack
      ..fixedPrompt = pack.prompt
      ..localeTag = pack.manifest.locale
      ..replayProfile =
          pack.manifest.replayProfile ?? DemoReplayProfile.conservativeRelay;
  }
}

/// Demo 容器内取选择协调点的入口（buildDemoOverrides 覆写注入；
/// 根作用域缺省抛错——仅演示作用域内有多候选绑定语义）
final demoSelectionProvider = Provider<DemoSelectionController>(
  (ref) => throw StateError(
    'demoSelectionProvider must be overridden by buildDemoOverrides',
  ),
);
