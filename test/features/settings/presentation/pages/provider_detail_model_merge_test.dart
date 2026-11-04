import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_detail_page.dart';

/// 拉模型字段级保手工合并的聚焦单测。
///
/// 口径：同 modelId 已存在的行，用户改过的字段（displayName 非空 /
/// capabilities 非空 / contextWindow、maxOutput 非空非零 / type）不被
/// 拉取的富化行整行覆盖；空白/默认字段允许被拉取行富化。
void main() {
  group('mergePreservingManualFields', () {
    test('existing 不存在——新行原样入列', () {
      const fetched = ModelInfo(
        modelId: 'gpt-4o',
        displayName: 'GPT-4o',
        capabilities: [ModelCapability.vision],
        contextWindow: 128000,
        maxOutput: 16384,
      );

      final merged = mergePreservingManualFields(null, fetched);

      expect(identical(merged, fetched), isTrue);
    });

    test('existing 带手工标注——手工字段全部保留，labels 随拉取行', () {
      const existing = ModelInfo(
        modelId: 'gpt-4o',
        displayName: '我的主力模型',
        type: ModelType.embedding,
        capabilities: [ModelCapability.reasoning],
        contextWindow: 999,
        maxOutput: 888,
      );
      const fetched = ModelInfo(
        modelId: 'gpt-4o',
        displayName: 'GPT-4o',
        capabilities: [ModelCapability.vision],
        contextWindow: 128000,
        maxOutput: 16384,
        labels: ['recommended'],
      );

      final merged = mergePreservingManualFields(existing, fetched);

      expect(merged.displayName, '我的主力模型');
      expect(merged.type, ModelType.embedding);
      expect(merged.capabilities, [ModelCapability.reasoning]);
      expect(merged.contextWindow, 999);
      expect(merged.maxOutput, 888);
      expect(merged.labels, ['recommended'], reason: '标签是拉取侧事实，随新行走');
    });

    test('existing 字段空白/默认——被拉取行富化（只增不改的另一面）', () {
      const existing = ModelInfo(modelId: 'gpt-4o');
      const fetched = ModelInfo(
        modelId: 'gpt-4o',
        displayName: 'GPT-4o',
        capabilities: [ModelCapability.vision],
        contextWindow: 128000,
        maxOutput: 16384,
      );

      final merged = mergePreservingManualFields(existing, fetched);

      expect(merged.displayName, 'GPT-4o');
      expect(merged.capabilities, [ModelCapability.vision]);
      expect(merged.contextWindow, 128000);
      expect(merged.maxOutput, 16384);
    });

    test('contextWindow/maxOutput 为 0 视为未标注——被拉取行覆盖', () {
      // 0 是「未知/无效」哨兵而非用户标注（parse 侧 null 才落库，
      // 手动编辑可能暂存 0），不得挡住拉取的富化值
      const existing = ModelInfo(modelId: 'm1', contextWindow: 0, maxOutput: 0);
      const fetched =
          ModelInfo(modelId: 'm1', contextWindow: 8192, maxOutput: 4096);

      final merged = mergePreservingManualFields(existing, fetched);

      expect(merged.contextWindow, 8192);
      expect(merged.maxOutput, 4096);
    });
  });
}
