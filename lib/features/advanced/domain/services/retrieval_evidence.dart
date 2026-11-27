import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 检索证据记录（tool/result 事件 data.retrievalEvidence）与资格判定。
///
/// 证据底座：status 按结果真实状态写入（error/empty 不因调用过而记成功）；
/// calledTools 不再作为放行依据。证据资格四类（active / 压缩遮蔽条件
/// 继承 / 分支废弃不继承 / 旧纪元无资格）+ 修订未变（a 档出厂）。

/// 证据负载键（tool/result 事件 data 内）
const String kRetrievalEvidenceKey = 'retrievalEvidence';

/// 实体修订摘要（证据采集与闸门比对统一口径）：updatedAt 毫秒（null 按 0）+ 属性
/// 「key=value」规范化排序（key→value 字典序，消除采集路径顺序差）拼接
/// 的 FNV 摘要。证据采集（工具执行处读取时点快照）与闸门比对（闸门时点
/// 当前修订）**共用同一函数/排序/时间身份**——两侧独立实现会把未修订
/// 实体误判为「修订变化」。
String entityRevisionDigest({
  required int? updatedAtMs,
  required List<(String, String)> attributes,
}) {
  final sorted = [...attributes]..sort((a, b) {
      final byKey = a.$1.compareTo(b.$1);
      return byKey != 0 ? byKey : a.$2.compareTo(b.$2);
    });
  final attrText = sorted.map((a) => '${a.$1}=${a.$2}').join('|');
  final input = '${updatedAtMs ?? 0};$attrText';
  var hash = 0xcbf29ce4;
  for (final cu in input.codeUnits) {
    hash ^= cu;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash.toRadixString(16);
}

/// 事件暴露量输入采集：本轮正文**实际命中**的关键实体名与
/// 历史正文**已见**实体名集合。按实体身份去重——主名或任一别名命中都
/// 归并到该实体的主名（同一实体不会因别名重复计数）。短于 2 字的候选
/// 名不参与命中（与证据闸门同一抽取口径）。
({List<String> hitNames, Set<String> priorSeenNames}) collectExposureInputs({
  required String prose,
  required Iterable<String> priorProseMessages,
  required List<({String primaryName, List<String> aliases})> keyEntities,
  Set<String> coveredByMemoryNames = const {},
}) {
  final priorJoined = priorProseMessages.join('\n');
  final hitNames = <String>[];
  final priorSeenNames = <String>{};
  for (final entity in keyEntities) {
    final candidates = [entity.primaryName, ...entity.aliases]
        .map((c) => c.trim())
        .where((c) => c.length >= 2);
    final hit = candidates.any(prose.contains);
    if (hit) hitNames.add(entity.primaryName);
    // 已见=此前轮正文出现过 ∨ 已被既有事件记忆覆盖（后者的排除与
    // 压缩无关——记忆在库即不构成新暴露）
    if (candidates.any(priorJoined.contains) ||
        coveredByMemoryNames.contains(entity.primaryName)) {
      priorSeenNames.add(entity.primaryName);
    }
  }
  return (hitNames: hitNames, priorSeenNames: priorSeenNames);
}

/// 证据实体条目 {id, primaryName, updatedAtMs, contentDigest}
class EvidenceEntityRef {
  const EvidenceEntityRef({
    required this.id,
    required this.primaryName,
    required this.updatedAtMs,
    required this.contentDigest,
  });

  final String id;
  final String primaryName;
  final int? updatedAtMs;
  final String contentDigest;
}

/// 单条证据（从 tool/result 事件解析）
class RetrievalEvidenceRecord {
  const RetrievalEvidenceRecord({
    required this.status,
    required this.toolName,
    required this.entities,
    required this.attemptId,
    required this.event,
  });

  /// success / empty / error
  final String status;
  final String toolName;
  final List<EvidenceEntityRef> entities;

  /// 产生该证据的生成尝试身份（事件盖戳）
  final String? attemptId;
  final AgentDurableEvent event;

  bool get isSuccess => status == 'success';
}

/// 从事件解析证据（无负载 → null）
RetrievalEvidenceRecord? retrievalEvidenceOf(AgentDurableEvent event) {
  if (event.type != AgentEventTypes.toolResult) return null;
  final raw = event.data[kRetrievalEvidenceKey];
  if (raw is! Map) return null;
  final status = raw['status'];
  if (status is! String) return null;
  final entities = <EvidenceEntityRef>[];
  final rawEntities = raw['entities'];
  if (rawEntities is List) {
    for (final e in rawEntities) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String || id.isEmpty) continue;
      entities.add(
        EvidenceEntityRef(
          id: id,
          primaryName: (e['primaryName'] as String?) ?? '',
          updatedAtMs: (e['updatedAtMs'] as num?)?.toInt(),
          contentDigest: (e['contentDigest'] as String?) ?? '',
        ),
      );
    }
  }
  return RetrievalEvidenceRecord(
    status: status,
    toolName: (event.data['toolName'] as String?) ?? '',
    entities: entities,
    attemptId: event.data['attemptId'] as String?,
    event: event,
  );
}

/// 构造证据负载（工具执行处挂到 AgentToolResult.metadata）
Map<String, dynamic> retrievalEvidencePayload({
  required String status,
  required Map<String, dynamic> queryScope,
  List<EvidenceEntityRef> entities = const [],
}) {
  return {
    kRetrievalEvidenceKey: {
      'status': status,
      'queryScope': queryScope,
      'entities': [
        for (final e in entities)
          {
            'id': e.id,
            'primaryName': e.primaryName,
            if (e.updatedAtMs != null) 'updatedAtMs': e.updatedAtMs,
            if (e.contentDigest.isNotEmpty) 'contentDigest': e.contentDigest,
          },
      ],
    },
  };
}

/// 资格判定输入：当前纪元窗事件 + 变体遮蔽轮集合 + 压缩承接清单
class EvidenceEligibilityInput {
  const EvidenceEligibilityInput({
    required this.windowEvents,
    this.maskedTurns = const {},
    this.carriedEvidenceKeys = const {},
  });

  final List<AgentDurableEvent> windowEvents;

  /// 被变体切换遮蔽（retain=false）的轮集合——其证据归「分支废弃」
  final Set<int> maskedTurns;

  /// 压缩摘要承接的证据键集合（「turn:callId」——由压缩 summary 事件 evidenceCarried 提供）；
  /// 不在其中的 shadowed 证据按未核对处理
  final Set<String> carriedEvidenceKeys;
}

/// 单条证据的资格（active / carried / masked / notCarried）
enum EvidenceQualification { active, carried, branchDiscarded, notCarried }

/// 判定单条证据资格（纪元内事件的前提下）
EvidenceQualification qualifyEvidence(
  RetrievalEvidenceRecord evidence,
  EvidenceEligibilityInput input,
) {
  final turn = (evidence.event.data['turn'] as num?)?.toInt();
  if (turn != null && input.maskedTurns.contains(turn)) {
    return EvidenceQualification.branchDiscarded;
  }
  // 投影可见（窗内未被遮蔽）→ active。被压缩遮蔽的判定：其 seq 出现在
  // 现存 checkpoint（未被 undo）的 sourceEventSeqs 内。
  final seq = evidence.event.seq;
  if (seq != null) {
    var shadowed = false;
    // 存活 checkpoint（未被 undo）的遮蔽区间
    final undoneOps = <String>{};
    final opShadow = <String, List<int>>{};
    for (final e in input.windowEvents) {
      if (e.type == AgentEventTypes.compactionUndo) {
        // 与 deriveCarriedEvidenceKeys 同键口径（targetOpId 主、opId 兜底）
        final t = e.data['targetOpId'] ?? e.data['opId'];
        if (t is String) undoneOps.add(t);
      }
      if (e.surfaceOp == AgentSurfaceOpKind.replace &&
          e.data['source'] == 'compaction_checkpoint') {
        final op = e.data['opId'];
        if (op is String) {
          opShadow[op] = [...e.sourceEventSeqs];
        }
      }
    }
    for (final entry in opShadow.entries) {
      if (undoneOps.contains(entry.key)) continue;
      if (entry.value.contains(seq)) {
        shadowed = true;
        break;
      }
    }
    if (shadowed) {
      final key = '${turn ?? 0}:${evidence.event.data['callId'] ?? ''}';
      return input.carriedEvidenceKeys.contains(key)
          ? EvidenceQualification.carried
          : EvidenceQualification.notCarried;
    }
  }
  return EvidenceQualification.active;
}

/// 按当前存活压缩产物推导承接键集合（「turn:callId」）。
///
/// 摘要的承接只在**其 checkpoint 仍存活**时有效：checkpoint=同 opId 的
/// compaction_checkpoint replace 事件。存活判定：操作未被 undo，且自身
/// seq 不在其余未撤销 checkpoint 的 sourceEventSeqs 并集内（后续 checkpoint
/// 的传递展开把先前 checkpoint 遮蔽——二次压缩遗漏后旧承接不再永久有效；
/// undo 撤销后其遮蔽贡献回收，先前摘要的承接恢复生效）。对照 runner 消费：
/// [checkEntityCoverage] 的 carriedEvidenceKeys 必须来自本函数，不得对全部
/// 历史 summary 做永久并集。
Set<String> deriveCarriedEvidenceKeys(List<AgentDurableEvent> events) {
  final undoneOps = <String>{};
  final summariesByOp = <String, Set<String>>{};
  final checkpoints = <({String opId, int? seq, List<int> sources})>[];
  for (final e in events) {
    if (e.type == AgentEventTypes.compactionUndo) {
      final t = e.data['targetOpId'] ?? e.data['opId'];
      if (t is String) undoneOps.add(t);
      continue;
    }
    if (e.type == AgentEventTypes.compactionSummary) {
      final op = e.data['opId'];
      if (op is! String) continue;
      final keys = summariesByOp.putIfAbsent(op, () => <String>{});
      final list = e.data['evidenceCarried'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            keys.add('${item['turn'] ?? 0}:${item['callId'] ?? ''}');
          }
        }
      }
      continue;
    }
    if (e.surfaceOp == AgentSurfaceOpKind.replace &&
        e.data['source'] == 'compaction_checkpoint') {
      final op = e.data['opId'];
      if (op is String) {
        checkpoints.add(
          (
            opId: op,
            seq: e.seq,
            sources: [...e.sourceEventSeqs],
          ),
        );
      }
    }
  }
  // 遮蔽集合=全部未撤销 checkpoint 的 sourceEventSeqs 并集（含传递展开）
  final shadowed = <int>{};
  for (final c in checkpoints) {
    if (undoneOps.contains(c.opId)) continue;
    shadowed.addAll(c.sources);
  }
  // 存活 checkpoint：op 未撤销 ∧ 自身 seq 不被其余 checkpoint 遮蔽
  final aliveOps = <String>{};
  for (final c in checkpoints) {
    if (undoneOps.contains(c.opId)) continue;
    final seq = c.seq;
    if (seq != null && shadowed.contains(seq)) continue;
    aliveOps.add(c.opId);
  }
  return {
    for (final op in aliveOps) ...summariesByOp[op] ?? const <String>{},
  };
}

/// 实体充分性核对结果
class EntityCoverageCheck {
  const EntityCoverageCheck({
    required this.missingEntities,
    required this.missingDueToRevision,
  });

  /// 缺少当前有效核对证据的实体名（未检索/失败空结果/资格不符）
  final List<String> missingEntities;

  /// 因事实修订变化而失效的实体名（a 档：修订未变才充分）
  final List<String> missingDueToRevision;
}

/// 判据（修订档）：每个实体需存在「成功 ∧ 命中 ∧ 修订未变 ∧ 资格（active 或
/// carried）」的证据。当前修订（updatedAtMs/contentDigest）由调用方注入
/// （工具执行处快照 vs 闸门时点比对）。
EntityCoverageCheck checkEntityCoverage({
  required Map<String,
          ({String primaryName, int? updatedAtMs, String contentDigest})>
      keyEntities,
  required List<AgentDurableEvent> windowEvents,
  required EvidenceEligibilityInput eligibility,
}) {
  final missing = <String>[];
  final revisionStale = <String>[];
  final evidenceByEntity = <String, List<RetrievalEvidenceRecord>>{};
  for (final event in windowEvents) {
    final ev = retrievalEvidenceOf(event);
    if (ev == null) continue;
    final qual = qualifyEvidence(ev, eligibility);
    if (qual != EvidenceQualification.active &&
        qual != EvidenceQualification.carried) {
      continue;
    }
    for (final entity in ev.entities) {
      evidenceByEntity.putIfAbsent(entity.id, () => []).add(ev);
    }
  }
  // 实体检索证据按名命中（无 id 的文本类检索不构成实体级证据）
  keyEntities.forEach((id, entity) {
    final records = evidenceByEntity[id];
    if (records == null || records.isEmpty) {
      missing.add(entity.primaryName.isEmpty ? id : entity.primaryName);
      return;
    }
    final hasSuccess = records.any((r) => r.isSuccess);
    if (!hasSuccess) {
      missing.add(entity.primaryName.isEmpty ? id : entity.primaryName);
      return;
    }
    // 修订未变：任一成功证据的修订快照 == 当前修订
    final latest = records.where((r) => r.isSuccess).last;
    final entityRef = latest.entities.firstWhere(
      (e) => e.id == id,
      orElse: () => const EvidenceEntityRef(
        id: '',
        primaryName: '',
        updatedAtMs: null,
        contentDigest: '',
      ),
    );
    final timeChanged = entityRef.updatedAtMs != null &&
        entity.updatedAtMs != null &&
        entityRef.updatedAtMs != entity.updatedAtMs;
    final digestChanged = entityRef.contentDigest.isNotEmpty &&
        entity.contentDigest.isNotEmpty &&
        entityRef.contentDigest != entity.contentDigest;
    final revisionChanged = timeChanged || digestChanged;
    if (revisionChanged) {
      revisionStale.add(entity.primaryName.isEmpty ? id : entity.primaryName);
    }
  });
  return EntityCoverageCheck(
    missingEntities: missing,
    missingDueToRevision: revisionStale,
  );
}

/// 事件暴露量闸门（新关键实体数 + 0.5×update_facts 条数，含长期未记事件兜底）：
/// exposure = 新关键实体数 + 0.5 × update_facts delta 条数；
/// 满足「表面超比 ∧ 本轮未记事件 ∧ (exposure≥3 ∨ eventGap≥eventGapFallback)」时触发。
class EventExposureCheck {
  const EventExposureCheck({
    required this.shouldGate,
    required this.newEntities,
  });

  final bool shouldGate;
  final List<String> newEntities;
}

EventExposureCheck checkEventExposure({
  required List<String> keyEntityNamesHitInProse,
  required Set<String> entityNamesInPriorProse,
  required int updateFactsDeltaCount,
  required bool recordedEventMemory,
  required double surfaceEstimateRatio,
  double surfaceRatioThreshold = 0.6,
  int exposureMin = 3,
  int eventGap = 0,
  int eventGapFallback = 7,
}) {
  final newEntities = keyEntityNamesHitInProse
      .where((name) => !entityNamesInPriorProse.contains(name))
      .toList();
  final exposure = newEntities.length + 0.5 * updateFactsDeltaCount;
  final gapTriggered = eventGapFallback > 0 && eventGap >= eventGapFallback;
  final shouldGate = !recordedEventMemory &&
      surfaceEstimateRatio > surfaceRatioThreshold &&
      (exposure >= exposureMin || gapTriggered);
  return EventExposureCheck(
    shouldGate: shouldGate,
    newEntities: newEntities.take(5).toList(),
  );
}
