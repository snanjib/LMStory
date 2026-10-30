import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 对拍测试（2026-10-15 计划 §7「需求一关键」）：
/// 投影器（干跑）输出 vs FactApplier（实际落库）结果**一致性**——
/// 同一输入双跑比对，防「审批横幅看到的 diff ≠ 落库」。
void main() {
  final t = DateTime(2026, 10, 15, 12);
  const config = FactualConfig();

  FactualEntity character() => FactualEntity(
        entityId: 'ent_001',
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: '林晚',
        aliases: const [],
        importance: 5,
        createdTurn: 1,
        createdAt: t,
      );

  FactualAttribute personalityRow(String value) => FactualAttribute(
        attributeId: 'attr_1',
        entityId: 'ent_001',
        sessionId: 's1',
        attrKey: 'personality',
        value: value,
        importance: 4,
        createdAt: t,
      );

  /// 对拍一条 delta：先投影（快照），再落库（同一 repo 初始态），
  /// 比对「投影判定 applied/skipped」与「落库是否产生 history 行」
  /// 以及「投影 before」与「审计 oldValue」。
  Future<void> expectConsistent(
    FakeFactualRepository repo,
    FactsDelta delta, {
    List<FactualAttribute> seed = const [],
    int recentUpdates = 0,
  }) async {
    // 干跑（不影响库）
    final projection = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
      delta: delta,
      config: config,
      entity: repo.entitiesById['ent_001'],
      attrRows: seed,
      recentUpdates: recentUpdates,
    );
    // 落库（真跑）
    final applier = FactApplier(repository: repo);
    final history = await applier.applyDeltas('s1', [delta], 3, config);

    final projectedApplied =
        projection.outcome == FactsProjectionOutcome.applied;
    if (projectedApplied) {
      expect(history, hasLength(1), reason: '投影 applied → 落库应产生审计行');
      final h = history.single;
      // 值对比：投影 before 与审计 oldValue 同源
      expect(
        projection.before,
        h.oldValue,
        reason: '投影 before 与落库 oldValue 应一致',
      );
      // 投影 after（新值）与审计 newValue 一致
      expect(projection.after, h.newValue, reason: '投影 after 与落库 newValue 应一致');
    } else {
      expect(history, isEmpty, reason: '投影 skipped → 落库不应产生任何审计行');
    }
  }

  test('同输入双跑一致：正常修改（before/after 与审计 oldValue/newValue 对拍）', () async {
    final repo = FakeFactualRepository();
    final ent = character();
    repo.entitiesById['ent_001'] = ent;
    final row = personalityRow('冷静自持');
    repo.seedAttribute(row);

    await expectConsistent(
      repo,
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '热情冲动',
        confidence: 4,
      ),
      seed: [row],
    );
  });

  test('同输入双跑一致：值相同跳过 / 置信度门拦截 / list 拒改', () async {
    // 值相同
    var repo = FakeFactualRepository();
    repo.entitiesById['ent_001'] = character();
    final row = personalityRow('冷静自持');
    repo.seedAttribute(row);
    await expectConsistent(
      repo,
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '冷静自持',
        confidence: 5,
      ),
      seed: [row],
    );

    // 关键属性低置信度（importance=4 关键 + confidence=2 < 4 门）
    repo = FakeFactualRepository();
    repo.entitiesById['ent_001'] = character();
    repo.seedAttribute(personalityRow('冷静自持'));
    await expectConsistent(
      repo,
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '热情冲动',
        confidence: 2,
      ),
      seed: [personalityRow('冷静自持')],
    );

    // list 拒改
    repo = FakeFactualRepository();
    repo.entitiesById['ent_001'] = character();
    final listRow = FactualAttribute(
      attributeId: 'attr_2',
      entityId: 'ent_001',
      sessionId: 's1',
      attrKey: 'skills',
      value: '["御剑术"]',
      valueType: AttributeValueType.list,
      importance: 3,
      createdAt: t,
    );
    repo.seedAttribute(listRow);
    await expectConsistent(
      repo,
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '剑术',
        confidence: 5,
      ),
      seed: [listRow],
    );
  });

  test('同输入双跑一致：更新频率超限跳过', () async {
    final repo = FakeFactualRepository();
    repo.entitiesById['ent_001'] = character();
    final row = personalityRow('冷静自持');
    repo.seedAttribute(row);
    repo.recentUpdateCounts['ent_001'] = 4; // 3 轮 4 次上限

    await expectConsistent(
      repo,
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '热情冲动',
        confidence: 5,
      ),
      seed: [row],
      recentUpdates: 4,
    );
  });

  test('DK13U-4 防回归：钳制口径三处同源（effectiveApprovalTimeout）', () {
    // 开关开 + 0 值 → 钳 5（页面倒计时与 runner completer.timeout 同源）
    const c0 = AdvancedHitlConfig(approvalTimeoutMinutes: 0);
    expect(c0.effectiveApprovalTimeout, const Duration(minutes: 5));

    // 开关开 + 正常值 → 原值
    const c7 = AdvancedHitlConfig(approvalTimeoutMinutes: 7);
    expect(c7.effectiveApprovalTimeout, const Duration(minutes: 7));

    // 开关关 → null（页面无倒计时行、runner 不挂 .timeout）
    const cOff = AdvancedHitlConfig(approvalTimeoutEnabled: false);
    expect(cOff.effectiveApprovalTimeout, isNull);
    // 同盖 ask：提问横幅也永等（含 0=一直等待既有语义）
    expect(cOff.effectiveAskUserTimeout, isNull);
    const cOffZero = AdvancedHitlConfig(
      approvalTimeoutEnabled: false,
    );
    expect(cOffZero.effectiveAskUserTimeout, isNull);

    // 开关开时 ask 0=一直等待既有语义保留
    const cAsk0 = AdvancedHitlConfig(askUserTimeoutMinutes: 0);
    expect(cAsk0.effectiveAskUserTimeout, isNull);
    const cAsk5 = AdvancedHitlConfig(askUserTimeoutMinutes: 5);
    expect(cAsk5.effectiveAskUserTimeout, const Duration(minutes: 5));
  });
}
