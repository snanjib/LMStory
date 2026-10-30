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
        'read_story',
        'query_facts',
        'read_compact_summary',
        'read_skill',
        'ask_user',
        'finish_round',
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

    test('allTools 覆盖 12 工具且无重复', () {
      expect(ToolPermissions.allTools.length, 12);
      expect(ToolPermissions.allTools.toSet().length, 12);
    });
  });

  // finish_round 是每轮正文唯一交付通道，
  // 配成 deny/ask 会导致每轮无法正常交付（"能配但配了崩"）——读取侧
  // 一律按 allow 兜底，历史会话存的非 allow 值同样被兜底。
  group('B3：finish_round 锁死 allow', () {
    test('会话存 deny → 兜底 allow', () {
      final e = ToolPermissions.effective(
        session: const {'finish_round': 'deny'},
        global: const {},
        toolName: 'finish_round',
      );
      expect(e, ToolPermissionState.allow);
    });

    test('会话存 ask → 兜底 allow', () {
      final e = ToolPermissions.effective(
        session: const {'finish_round': 'ask'},
        global: const {},
        toolName: 'finish_round',
      );
      expect(e, ToolPermissionState.allow);
    });

    test('仅全局存 deny → 兜底 allow', () {
      final e = ToolPermissions.effective(
        session: null,
        global: const {'finish_round': 'deny'},
        toolName: 'finish_round',
      );
      expect(e, ToolPermissionState.allow);
    });

    test('其他工具不受锁影响（spawn 仍可 deny）', () {
      final e = ToolPermissions.effective(
        session: const {'spawn': 'deny'},
        global: const {},
        toolName: 'spawn',
      );
      expect(e, ToolPermissionState.deny);
    });
  });
}
