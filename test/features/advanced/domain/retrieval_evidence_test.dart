import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';

/// 证据闸门验收（资格矩阵 + 失败证据反例）：
/// 成功/空/错误三态、修订变更失效、错误不从 calledTools 旁路放行、
/// 四类资格（压缩承接 vs 变体遮蔽不继承 vs 未承接按未核对）、
/// 事件暴露量三条件。
void main() {
  AgentDurableEvent toolResultEvent(
    int seq,
    int turn, {
    required String status,
    List<Map<String, dynamic>> entities = const [],
    String attemptId = 'a1',
    String callId = 'c1',
  }) =>
      AgentDurableEvent(
        seq: seq,
        type: AgentEventTypes.toolResult,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'callId': callId,
          'toolName': 'query_facts',
          'output': 'ok',
          'turn': turn,
          'attemptId': attemptId,
          kRetrievalEvidenceKey: {
            'status': status,
            'queryScope': {'query': 'q'},
            'entities': entities,
          },
        },
      );

  const entity = {
    'id': 'ent1',
    'primaryName': '林涣',
    'updatedAtMs': 100,
    'contentDigest': 'abc',
  };

  Map<String, ({String primaryName, int? updatedAtMs, String contentDigest})>
      revisions({int? updatedAtMs, String digest = 'abc'}) => {
            'ent1': (
              primaryName: '林涣',
              updatedAtMs: updatedAtMs,
              contentDigest: digest,
            ),
          };

  test('成功∧命中∧修订未变 → 覆盖通过（放行）', () {
    final window = [
      toolResultEvent(2, 1, status: 'success', entities: [entity]),
    ];
    final check = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 100),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(check.missingEntities, isEmpty);
    expect(check.missingDueToRevision, isEmpty);
  });

  test('error/empty 证据不构成核对（一次失败查询不绕过闸门）', () {
    final window = [
      toolResultEvent(2, 1, status: 'error'),
      toolResultEvent(3, 1, status: 'empty', callId: 'c2'),
    ];
    final check = checkEntityCoverage(
      keyEntities: revisions(),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(check.missingEntities, ['林涣']);
  });

  test('修订变化（updatedAt/digest）→ 失效并列入修订缺口', () {
    final window = [
      toolResultEvent(2, 1, status: 'success', entities: [entity]),
    ];
    final check = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 999, digest: 'changed'),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(check.missingEntities, isEmpty);
    expect(check.missingDueToRevision, ['林涣']);
  });

  test('压缩遮蔽：evidenceCarried 承接 → 继承；未承接 → 按未核对', () {
    final evidence =
        toolResultEvent(2, 1, status: 'success', entities: [entity]);
    final checkpoint = AgentDurableEvent(
      seq: 3,
      type: AgentEventTypes.userMessage,
      surfaceOp: AgentSurfaceOpKind.replace,
      replaceStart: 0,
      replaceEnd: 2,
      sourceEventSeqs: [2],
      data: {
        'content': 'checkpoint',
        'source': 'compaction_checkpoint',
        'opId': 'op1',
        'turn': 0,
      },
    );
    final window = [evidence, checkpoint];

    final carried = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 100),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(
        windowEvents: window,
        carriedEvidenceKeys: {'1:c1'},
      ),
    );
    expect(carried.missingEntities, isEmpty);

    final notCarried = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 100),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(notCarried.missingEntities, ['林涣']);
  });

  test('变体切换遮蔽轮的证据不继承（重新核对即放行）', () {
    final window = [
      toolResultEvent(2, 1, status: 'success', entities: [entity]),
    ];
    final check = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 100),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(
        windowEvents: window,
        maskedTurns: {1},
      ),
    );
    expect(check.missingEntities, ['林涣']);
  });

  test('旧纪元/捕获史料无证据负载 → 按未核对（不回溯合成）', () {
    final plain = AgentDurableEvent(
      seq: 1,
      type: AgentEventTypes.toolResult,
      surfaceOp: AgentSurfaceOpKind.append,
      data: {
        'callId': 'c9',
        'toolName': 'query_facts',
        'output': '命中',
        'turn': 1,
      },
    );
    expect(retrievalEvidenceOf(plain), isNull);
  });

  group('事件暴露量（三条件）', () {
    test('三条件同时 → 触发（附新实体清单）', () {
      final check = checkEventExposure(
        keyEntityNamesHitInProse: ['林涣', '沈青禾', '新角色甲'],
        entityNamesInPriorProse: {'林涣'},
        updateFactsDeltaCount: 2,
        recordedEventMemory: false,
        surfaceEstimateRatio: 0.7,
      );
      expect(check.shouldGate, isTrue);
      expect(check.newEntities, ['沈青禾', '新角色甲']);
    });

    test('任一条件不满足 → 放行（过渡轮/已记录/表面未超/暴露不足）', () {
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: ['a', 'b', 'c'],
          entityNamesInPriorProse: {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: true,
          surfaceEstimateRatio: 0.9,
        ).shouldGate,
        isFalse,
      );
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: ['a', 'b', 'c'],
          entityNamesInPriorProse: {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: false,
          surfaceEstimateRatio: 0.5,
        ).shouldGate,
        isFalse,
      );
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: ['a'],
          entityNamesInPriorProse: {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: false,
          surfaceEstimateRatio: 0.9,
        ).shouldGate,
        isFalse,
      );
    });

    test('长期未记事件兜底：exposure==0 但 eventGap 达阈值且表面超比时触发', () {
      final triggered = checkEventExposure(
        keyEntityNamesHitInProse: const [],
        entityNamesInPriorProse: const {},
        updateFactsDeltaCount: 0,
        recordedEventMemory: false,
        surfaceEstimateRatio: 0.7,
        eventGap: 7,
      );
      expect(triggered.shouldGate, isTrue);
      expect(triggered.newEntities, isEmpty);

      // 缺口未达阈值 → 仍放行
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: const [],
          entityNamesInPriorProse: const {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: false,
          surfaceEstimateRatio: 0.7,
          eventGap: 6,
        ).shouldGate,
        isFalse,
      );

      // 表面未超阈值 → 不触发
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: const [],
          entityNamesInPriorProse: const {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: false,
          surfaceEstimateRatio: 0.5,
          eventGap: 10,
        ).shouldGate,
        isFalse,
      );

      // 本轮已记录事件 → 不触发
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: const [],
          entityNamesInPriorProse: const {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: true,
          surfaceEstimateRatio: 0.8,
          eventGap: 10,
        ).shouldGate,
        isFalse,
      );

      // eventGapFallback <= 0 禁用兜底
      expect(
        checkEventExposure(
          keyEntityNamesHitInProse: const [],
          entityNamesInPriorProse: const {},
          updateFactsDeltaCount: 0,
          recordedEventMemory: false,
          surfaceEstimateRatio: 0.8,
          eventGap: 10,
          eventGapFallback: 0,
        ).shouldGate,
        isFalse,
      );
    });
  });

  test('统一修订摘要：采集与比对同函数/同排序/同时间身份（未修订不误判）', () {
    const attrs = [('状态', '熄灭'), ('位置', '塔顶')];
    final evidenceDigest = entityRevisionDigest(
      updatedAtMs: 100,
      attributes: attrs,
    );
    // 闸门侧采集顺序不同（属性池路径差）——规范化排序后摘要等值
    final gateDigest = entityRevisionDigest(
      updatedAtMs: 100,
      attributes: const [('位置', '塔顶'), ('状态', '熄灭')],
    );
    expect(gateDigest, evidenceDigest);

    final window = [
      toolResultEvent(
        2,
        1,
        status: 'success',
        entities: [
          {
            'id': 'ent1',
            'primaryName': '林涣',
            'updatedAtMs': 100,
            'contentDigest': evidenceDigest,
          },
        ],
      ),
    ];
    final check = checkEntityCoverage(
      keyEntities: revisions(updatedAtMs: 100, digest: gateDigest),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(check.missingEntities, isEmpty, reason: '同一实体未修订不得判修订变化');
    expect(check.missingDueToRevision, isEmpty);

    // 同内容但 updatedAt 变化 → 时间身份变化 → 修订失效（a 档）
    final stale = checkEntityCoverage(
      keyEntities: revisions(
        updatedAtMs: 200,
        digest: entityRevisionDigest(updatedAtMs: 200, attributes: attrs),
      ),
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(stale.missingDueToRevision, ['林涣']);
  });

  test('暴露量输入采集：本轮真实命中/别名归并主名/历史已见剔除', () {
    final inputs = collectExposureInputs(
      prose: '青梧推门而入。',
      priorProseMessages: ['此前正文提到灯台。'],
      keyEntities: [
        (primaryName: '沈青梧', aliases: ['青梧']),
        (primaryName: '灯台', aliases: []),
        (primaryName: '荒庙', aliases: []),
        (primaryName: '河', aliases: []),
      ],
    );
    // 本轮命中：别名「青梧」归并到主名沈青梧；灯台/荒庙不在本轮正文
    expect(inputs.hitNames, ['沈青梧']);
    // 历史已见：灯台在此前正文出现过；短名（<2 字）不参与
    expect(inputs.priorSeenNames, {'灯台'});
    // 纯函数衔接：新实体 = 命中 − 已见
    final check = checkEventExposure(
      keyEntityNamesHitInProse: inputs.hitNames,
      entityNamesInPriorProse: inputs.priorSeenNames,
      updateFactsDeltaCount: 0,
      recordedEventMemory: false,
      surfaceEstimateRatio: 0.9,
    );
    expect(check.newEntities, ['沈青梧']);
  });
}
