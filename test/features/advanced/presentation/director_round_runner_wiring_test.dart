import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AgentToolDeps.currentAnchor 生产接线契约
///
/// update_story_anchor 的部分更新以 `draft.storyAnchor ?? currentAnchor()`
/// 为基底，finish_round 伏笔清点闸门同源兜底。该参数此前只在测试里接线，
/// 生产构造点（DirectorRoundRunner.runRound 内的 AgentToolDeps）漏传恒
/// null——单字段更新以空锚为基底静默清空弧线/伏笔，清点闸门在其设计主
/// 场景（本轮未动锚）恒不触发。工具级语义已有
/// agent_session_tools_test.dart「部分更新」用例覆盖；本测试锁的是
/// 「生产构造点必须接线」这一层——runner 全链桩过重，源码契约是防
/// 「测试接线掩盖生产断线」复发的最小红线。
void main() {
  test('DirectorRoundRunner 的 AgentToolDeps 构造必须接线 currentAnchor', () {
    final source = File(
      'lib/features/advanced/presentation/controllers/director_round_runner.dart',
    ).readAsStringSync();

    // deps 构造段（从 AgentToolDeps( 到 buildAgentTools 收口）
    final depsStart = source.indexOf('AgentToolDeps(');
    final depsEnd = source.indexOf('deniedTools:', depsStart);
    expect(depsStart, greaterThan(0), reason: 'AgentToolDeps 构造点消失？');
    final depsBlock = source.substring(depsStart, depsEnd);

    expect(
      depsBlock,
      contains('currentAnchor:'),
      reason:
          'DK6-1 回归：生产 AgentToolDeps 未接线 currentAnchor——update_story_anchor 部分更新将清空会话锚，伏笔清点闸门失效。',
    );
  });

  test('DK8-3：coreBlocks 的 getKeyEntities 必须剔除注入停用词条', () {
    // coreBlocks 装配抽至共享服务
    // assembleDirectorCoreBlocks（注入面与场记板视图同源），取数调用
    // 随迁；组合行为（破格不豁免停用）仍由 factual_repository_impl_test
    // 的组合口径用例锁定。
    final service = File(
      'lib/features/advanced/domain/services/director_core_blocks.dart',
    ).readAsStringSync();

    final callStart = service.indexOf('factual.getKeyEntities(');
    expect(callStart, greaterThan(0), reason: 'coreBlocks 取数调用消失？');
    final callBlock = service.substring(
      callStart,
      service.indexOf(');', callStart),
    );

    expect(
      callBlock,
      contains('excludeInjectionDisabled: true'),
      reason: 'DK8-3 回归：coreBlocks 漏传停用过滤，停用词条仍进世界状态块（批 J-b：不进任何注入桶）。',
    );

    // 接线红线：runner 的注入面必须经共享服务取数（防「测试接线掩盖
    // 生产断线」复发——runner 内不得再出现旁路 getKeyEntities 注入调用）
    final runner = File(
      'lib/features/advanced/presentation/controllers/director_round_runner.dart',
    ).readAsStringSync();
    expect(
      runner,
      contains('assembleDirectorCoreBlocks('),
      reason: 'G-24 回归：runner 注入面未走共享装配服务，场记板视图将与注入面失同源。',
    );
  });

  test('G-05/G-07：系统裁决时刻必须写 state 计数（toast 数据面）', () {
    final runner = File(
      'lib/features/advanced/presentation/controllers/director_round_runner.dart',
    ).readAsStringSync();
    expect(
      runner,
      contains('overflowHealedTick: state.overflowHealedTick + 1'),
      reason: 'G-05 回归：溢出自愈钩子未通知 UI。',
    );
    expect(
      runner,
      contains('hitlAskTimeoutTick: state.hitlAskTimeoutTick + 1'),
      reason: 'G-07 回归：ask 超时裁决未通知 UI。',
    );
    expect(
      runner,
      contains('hitlApprovalTimeoutTick: state.hitlApprovalTimeoutTick + 1'),
      reason: 'G-07 回归：审批超时裁决未通知 UI。',
    );

    final page = File(
      'lib/features/advanced/presentation/pages/advanced_chat_page.dart',
    ).readAsStringSync();
    expect(
      page,
      contains('overflowHealedToast'),
      reason: 'G-05 回归：页面未消费自愈计数弹提示。',
    );
  });
}
