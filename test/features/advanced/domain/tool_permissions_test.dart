import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';

void main() {
  group('ToolPermissions 求值', () {
    test('全空 = 全 allow（内置默认）', () {
      final e = ToolPermissions.effective(
        session: null,
        global: const {},
        toolName: 'update_facts',
      );
      expect(e, ToolPermissionState.allow);
    });

    test('会话未设置（NULL）= 监督关：不继承全局 ask/deny，全 allow 运行', () {
      for (final tool in ToolPermissions.allTools) {
        final e = ToolPermissions.effective(
          session: null,
          global: const {
            'update_facts': 'ask',
            'spawn': 'ask',
            'read_skill': 'deny',
          },
          toolName: tool,
        );
        expect(e, ToolPermissionState.allow, reason: tool);
      }
    });

    test('全局 deny 被会话 allow 覆盖（逐工具后写优先）', () {
      final e = ToolPermissions.effective(
        session: const {'update_facts': 'allow'},
        global: const {'update_facts': 'deny'},
        toolName: 'update_facts',
      );
      expect(e, ToolPermissionState.allow);
    });

    test('会话未提名的工具回落全局', () {
      final e = ToolPermissions.effective(
        session: const {'spawn': 'deny'},
        global: const {'update_facts': 'ask'},
        toolName: 'update_facts',
      );
      expect(e, ToolPermissionState.ask);
    });

    test('监督预设：写入+控制 ask，只读与 ask_user/finish_round allow', () {
      for (final t in [
        'update_facts',
        'merge_entities',
        'update_story_anchor',
        'record_event_memory',
        'spawn',
      ]) {
        expect(ToolPermissions.supervised[t], 'ask', reason: t);
      }
      for (final t in [
        'search_story',
        'search_story_text',
        'read_story',
        'list_facts',
        'query_facts',
        'query_memory_changes',
        'read_compact_summary',
        'read_skill',
        'calc_eval',
        'calc_date',
        'ask_user',
        'finish_round',
        'finish_maintenance',
      ]) {
        expect(ToolPermissions.supervised[t], 'allow', reason: t);
      }
    });

    test('JSON 编解码往返 + 非法值拒绝', () {
      const map = {'spawn': 'deny', 'update_facts': 'ask'};
      final json = ToolPermissions.toJson(map);
      expect(ToolPermissions.fromJson(json), map);
      expect(ToolPermissions.fromJson('not json'), isNull);
      expect(ToolPermissions.fromJson('{"x": "maybe"}'), isNull);
      expect(ToolPermissions.fromJson('[]'), isNull);
    });

    test('旧 watchMode 迁移映射', () {
      expect(
        ToolPermissions.forLegacyWatchMode(watchMode: true),
        ToolPermissions.supervised,
      );
      expect(ToolPermissions.forLegacyWatchMode(watchMode: false), isNull);
      // 省略参数 = 显式 null（默认值），验证同一兜底路径
      expect(ToolPermissions.forLegacyWatchMode(), isNull);
    });

    test('allTools 覆盖 18 工具且无重复', () {
      expect(ToolPermissions.allTools.length, 18);
      expect(ToolPermissions.allTools.toSet().length, 18);
    });
  });

  // finish_round 与 finish_maintenance 是每轮正文与周期维护收尾唯一交付通道，
  // 配成 deny/ask 会导致流程卡死——读取侧一律按 allow 兜底。
  group('控制收尾工具锁死 allow', () {
    test('finish_round 与 finish_maintenance 会话存 deny → 兜底 allow', () {
      for (final tool in ['finish_round', 'finish_maintenance']) {
        final e = ToolPermissions.effective(
          session: {tool: 'deny'},
          global: const {},
          toolName: tool,
        );
        expect(e, ToolPermissionState.allow, reason: tool);
        expect(ToolPermissions.isLockedAllow(tool), isTrue, reason: tool);
      }
      expect(
        ToolPermissions.lockedAllowTools,
        containsAll(const ['finish_round', 'finish_maintenance']),
      );
    });

    test('finish_round 与 finish_maintenance 会话存 ask → 兜底 allow', () {
      for (final tool in ['finish_round', 'finish_maintenance']) {
        final e = ToolPermissions.effective(
          session: {tool: 'ask'},
          global: const {},
          toolName: tool,
        );
        expect(e, ToolPermissionState.allow, reason: tool);
      }
    });

    test('仅全局存 deny → 兜底 allow', () {
      for (final tool in ['finish_round', 'finish_maintenance']) {
        final e = ToolPermissions.effective(
          session: null,
          global: {tool: 'deny'},
          toolName: tool,
        );
        expect(e, ToolPermissionState.allow, reason: tool);
      }
    });

    test('其他工具不受锁影响（spawn 仍可 deny）', () {
      final e = ToolPermissions.effective(
        session: const {'spawn': 'deny'},
        global: const {},
        toolName: 'spawn',
      );
      expect(e, ToolPermissionState.deny);
      expect(ToolPermissions.isLockedAllow('spawn'), isFalse);
    });
  });
}
