import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';

void main() {
  group('AgentWorkSummary last 字段序列化', () {
    test('toJson：非 null 时写入，null 时缺省（旧 JSON 形态）', () {
      const withLast = AgentWorkSummary(
        steps: 3,
        totalTokens: 900,
        durationMs: 1200,
        lastPromptTokens: 800,
        lastCompletionTokens: 90,
        lastCacheReadTokens: 700,
      );
      final json = withLast.toJson();
      expect(json['lastPromptTokens'], 800);
      expect(json['lastCompletionTokens'], 90);
      expect(json['lastCacheReadTokens'], 700);

      const withoutLast = AgentWorkSummary(
        steps: 3,
        totalTokens: 900,
        durationMs: 1200,
      );
      expect(withoutLast.toJson().containsKey('lastPromptTokens'), isFalse);
    });

    test('fromJson：旧数据（无字段）解析为 null，不抛错', () {
      final s = AgentWorkSummary.fromJson({
        'steps': 2,
        'totalTokens': 500,
        'durationMs': 800,
        'deliveryChannel': 'tool_args',
      });
      expect(s.lastPromptTokens, isNull);
      expect(s.lastCompletionTokens, isNull);
      expect(s.lastCacheReadTokens, isNull);
    });

    test('fromJson：新数据 round-trip 保值', () {
      const origin = AgentWorkSummary(
        steps: 2,
        totalTokens: 500,
        durationMs: 800,
        lastPromptTokens: 400,
        lastCompletionTokens: 80,
        lastCacheReadTokens: 300,
      );
      final parsed = AgentWorkSummary.fromJson(origin.toJson());
      expect(parsed.lastPromptTokens, 400);
      expect(parsed.lastCompletionTokens, 80);
      expect(parsed.lastCacheReadTokens, 300);
    });

    test('copyWith 单独更新 lastPromptTokens（旧会话回填用）', () {
      const origin = AgentWorkSummary(
        steps: 2,
        totalTokens: 500,
        durationMs: 800,
      );
      final patched = origin.copyWith(lastPromptTokens: 12345);
      expect(patched.lastPromptTokens, 12345);
      expect(patched.steps, 2);
      expect(origin.lastPromptTokens, isNull);
    });
  });

  group('AgentWorkSummary styleLintHits 序列化（S4 风格漂移监测）', () {
    test('toJson：非 null 写入、null 缺省；fromJson round-trip 保值', () {
      const withHits = AgentWorkSummary(
        steps: 3,
        totalTokens: 900,
        durationMs: 1200,
        styleLintHits: 4,
      );
      expect(withHits.toJson()['styleLintHits'], 4);

      const withoutHits = AgentWorkSummary(
        steps: 3,
        totalTokens: 900,
        durationMs: 1200,
      );
      expect(withoutHits.toJson().containsKey('styleLintHits'), isFalse);

      final parsed = AgentWorkSummary.fromJson(withHits.toJson());
      expect(parsed.styleLintHits, 4);

      // 旧数据（实施前的 JSON）→ null，不参与漂移统计
      final legacy = AgentWorkSummary.fromJson({
        'steps': 2,
        'totalTokens': 500,
        'durationMs': 800,
      });
      expect(legacy.styleLintHits, isNull);

      // 0 = 干净轮：写入且解析保值（与 null 区分）
      final clean = AgentWorkSummary.fromJson(
        const AgentWorkSummary(
          steps: 1,
          totalTokens: 100,
          durationMs: 50,
          styleLintHits: 0,
        ).toJson(),
      );
      expect(clean.styleLintHits, 0);
    });
  });
}
