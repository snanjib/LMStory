import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';

/// 承接链存活推导：摘要的承接只在「其 checkpoint 仍存活」时有效。
/// 连续压缩遗漏（第二次摘要不承接）必须撤销继承资格——不得对全部历史
/// summary 做永久并集；undo 撤销第二次压缩后先前承接恢复生效。
///
/// 用生产纯函数 [deriveCarriedEvidenceKeys] 计算 carried（不复制
/// runner 旧口径）：连续遗漏后 missing 非空。
void main() {
  AgentDurableEvent declarationEvent() => AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        seq: 1,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'turn': 1,
          'toolCalls': [
            {'id': 'c1', 'name': 'query_facts', 'args': <String, dynamic>{}},
          ],
        },
      );

  AgentDurableEvent evidenceEvent() => AgentDurableEvent(
        type: AgentEventTypes.toolResult,
        seq: 2,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'turn': 1,
          'callId': 'c1',
          ...retrievalEvidencePayload(
            status: 'success',
            queryScope: const {},
            entities: [
              const EvidenceEntityRef(
                id: 'e1',
                primaryName: '甲甲',
                updatedAtMs: 1,
                contentDigest: 'digest',
              ),
            ],
          ),
        },
      );

  // A checkpoint 压掉原声明+回执，其摘要承接 1:c1
  final summaryA = AgentDurableEvent(
    type: AgentEventTypes.compactionSummary,
    seq: 3,
    data: {
      'opId': 'A',
      'evidenceCarried': [
        {'turn': 1, 'callId': 'c1'},
      ],
    },
  );
  final checkpointA = AgentDurableEvent(
    type: AgentEventTypes.userMessage,
    seq: 4,
    surfaceOp: AgentSurfaceOpKind.replace,
    replaceStart: 0,
    replaceEnd: 2,
    sourceEventSeqs: [1, 2],
    data: {
      'source': 'compaction_checkpoint',
      'opId': 'A',
      'content': 'A核对甲甲，引用c1',
    },
  );

  // B 再压掉 A 的表面（传递展开含 A checkpoint），摘要不承接 c1
  final summaryB = AgentDurableEvent(
    type: AgentEventTypes.compactionSummary,
    seq: 5,
    data: {
      'opId': 'B',
      'evidenceCarried': <Map<String, dynamic>>[],
    },
  );
  final checkpointB = AgentDurableEvent(
    type: AgentEventTypes.userMessage,
    seq: 6,
    surfaceOp: AgentSurfaceOpKind.replace,
    replaceStart: 0,
    replaceEnd: 1,
    sourceEventSeqs: [1, 2, 4],
    data: {
      'source': 'compaction_checkpoint',
      'opId': 'B',
      'content': 'B仅保留未决计划',
    },
  );

  final keyEntities = {
    'e1': (
      primaryName: '甲甲',
      updatedAtMs: 1,
      contentDigest: 'digest',
    ),
  };

  test(
      'a later summary that omits evidence must revoke inherited qualification',
      () {
    final events = [
      declarationEvent(),
      evidenceEvent(),
      summaryA,
      checkpointA,
      summaryB,
      checkpointB,
    ];
    final projected = deriveAgentSurface(events).messages;
    expect(projected, hasLength(1));
    expect(projected.single.content, 'B仅保留未决计划');

    // 修复后口径：承接键来自存活推导，不是历史 summary 永久并集
    final carried = deriveCarriedEvidenceKeys(events);
    expect(carried, isNot(contains('1:c1')), reason: 'A 被传递遮蔽，B 未承接');

    final check = checkEntityCoverage(
      keyEntities: keyEntities,
      windowEvents: events,
      eligibility: EvidenceEligibilityInput(
        windowEvents: events,
        carriedEvidenceKeys: carried,
      ),
    );
    expect(check.missingEntities, contains('甲甲'));
    expect(check.missingDueToRevision, isEmpty);
  });

  test('只有 A 存活（单次压缩承接）时 carried 资格仍然生效（正向保留）', () {
    final events = [
      declarationEvent(),
      evidenceEvent(),
      summaryA,
      checkpointA,
    ];
    final carried = deriveCarriedEvidenceKeys(events);
    expect(carried, contains('1:c1'));

    final check = checkEntityCoverage(
      keyEntities: keyEntities,
      windowEvents: events,
      eligibility: EvidenceEligibilityInput(
        windowEvents: events,
        carriedEvidenceKeys: carried,
      ),
    );
    expect(check.missingEntities, isEmpty);
    expect(check.missingDueToRevision, isEmpty);
  });

  test('undo 撤销第二次压缩：A 的承接资格恢复', () {
    final events = [
      declarationEvent(),
      evidenceEvent(),
      summaryA,
      checkpointA,
      summaryB,
      checkpointB,
      // 服务 undo 事件形态：targetOpId 指向被撤销的压缩操作
      AgentDurableEvent(
        type: AgentEventTypes.compactionUndo,
        data: {'targetOpId': 'B', 'targetStartSeq': 5},
      ),
    ];
    final carried = deriveCarriedEvidenceKeys(events);
    expect(carried, contains('1:c1'), reason: 'B 撤销后其遮蔽贡献回收，A 恢复存活');

    final check = checkEntityCoverage(
      keyEntities: keyEntities,
      windowEvents: events,
      eligibility: EvidenceEligibilityInput(
        windowEvents: events,
        carriedEvidenceKeys: carried,
      ),
    );
    expect(check.missingEntities, isEmpty);
    expect(check.missingDueToRevision, isEmpty);
  });
}
