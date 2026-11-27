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

  group('缓存分项有效性（真实 0 / 缺失 / 异常）', () {
    test('端点显式上报 0 缓存是有效样本，命中率为 0 而非未知', () {
      const summary = AgentWorkSummary(
        steps: 1,
        totalTokens: 1000,
        durationMs: 500,
        lastInputTokens: 1000,
        lastCacheReadTokens: 0,
      );
      expect(summary.lastCacheHitRatio, 0);
      expect(summary.lastCacheHitRatio, isNotNull);
    });

    test('缺失缓存分项 → 命中率未知', () {
      const summary = AgentWorkSummary(
        steps: 1,
        totalTokens: 1000,
        durationMs: 500,
        lastInputTokens: 1000,
      );
      expect(summary.lastCacheHitRatio, isNull);
    });

    test('计量异常样本保留原值但命中率未知，且随 JSON 持久化', () {
      const summary = AgentWorkSummary(
        steps: 1,
        totalTokens: 1000,
        durationMs: 500,
        lastInputTokens: 1000,
        lastCacheReadTokens: 800,
        usageWarnings: ['cached_tokens 与 prompt_cache_hit_tokens 冲突'],
      );
      expect(summary.lastCacheReadTokens, 800, reason: '原值保留用于诊断');
      expect(summary.lastCacheHitRatio, isNull);

      final parsed = AgentWorkSummary.fromJson(summary.toJson());
      expect(parsed.usageWarnings, hasLength(1));
      expect(parsed.lastCacheHitRatio, isNull);
    });
  });

  group('positiveOrNullOrNull（累计器分项落 summary 前的口径闸）', () {
    test('正值保值', () {
      expect(positiveOrNullOrNull(1), 1);
      expect(positiveOrNullOrNull(152000), 152000);
    });

    test('非正值（端点未回 usage 时累计器留 0）映射 null，放行「—」/回填探针', () {
      expect(positiveOrNullOrNull(0), isNull);
      expect(positiveOrNullOrNull(-3), isNull);
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

  group('AgentWorkSummary 维护提示与大周期完成标记', () {
    test('默认 false 缺省写入；true 时往返保值且旧 JSON 兼容回落 false', () {
      const defaults = AgentWorkSummary(
        steps: 1,
        totalTokens: 100,
        durationMs: 50,
      );
      expect(defaults.maintenanceNudgeIssued, isFalse);
      expect(defaults.majorReviewCompleted, isFalse);
      expect(defaults.toJson().containsKey('maintenanceNudgeIssued'), isFalse);
      expect(defaults.toJson().containsKey('majorReviewCompleted'), isFalse);

      final legacy = AgentWorkSummary.fromJson({
        'steps': 2,
        'totalTokens': 300,
        'durationMs': 400,
      });
      expect(legacy.maintenanceNudgeIssued, isFalse);
      expect(legacy.majorReviewCompleted, isFalse);

      const active = AgentWorkSummary(
        steps: 6,
        totalTokens: 2000,
        durationMs: 3000,
        maintenanceNudgeIssued: true,
        majorReviewCompleted: true,
      );
      final json = active.toJson();
      expect(json['maintenanceNudgeIssued'], isTrue);
      expect(json['majorReviewCompleted'], isTrue);

      final parsed = AgentWorkSummary.fromJson(json);
      expect(parsed.maintenanceNudgeIssued, isTrue);
      expect(parsed.majorReviewCompleted, isTrue);

      final copied = active.copyWith(lastPromptTokens: 900);
      expect(copied.maintenanceNudgeIssued, isTrue);
      expect(copied.majorReviewCompleted, isTrue);
    });
  });
}
