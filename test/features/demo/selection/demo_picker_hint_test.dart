import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型选择 sheet 说明横幅回归：
/// - 传入 hintText（演示作用域）→ 说明在列表顶部真实渲染；
/// - 不传（正式模型选择）→ 零渲染，不污染正式界面；
/// - 五个演示项长名换行不拦截点击。
/// 演示供应商五仿真模型清单（与 catalog 展示名一致）
const demoModels = <ModelInfo>[
  ModelInfo(modelId: 'demo-narrator-glm', displayName: '仿真 · GLM-5.3'),
  ModelInfo(
    modelId: 'demo-narrator-deepseek-v4.1-flash',
    displayName: '仿真 · DeepSeek-V4.1-Flash',
  ),
  ModelInfo(
    modelId: 'demo-narrator-glm-5.3-flash',
    displayName: '仿真 · GLM-5.3-Flash',
  ),
  ModelInfo(
    modelId: 'demo-narrator-kimi-k3.1-pro',
    displayName: '仿真 · Kimi-K3.1-Pro',
  ),
  ModelInfo(
    modelId: 'demo-narrator-mimo-v2.6-flash',
    displayName: '仿真 · MiMo-V2.6-Flash',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSheet(
    WidgetTester tester, {
    required void Function(String presetId, String modelId) onSelected,
    String? hintText,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith(
            (ref) => _DemoPresetSettingsNotifier(),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: DefaultModelPickerSheet(
                            selectedPresetId: 'demo-preset',
                            selectedModelId: null,
                            hintText: hintText,
                            onModelSelected: (presetId, modelId) async {
                              if (presetId == null || modelId == null) {
                                return;
                              }
                              onSelected(presetId, modelId);
                            },
                          ),
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 打开 sheet 并等装载链（initState 静默刷新）完成后列表渲染
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('演示说明横幅可见，五项逐一点选均真实回调（sheet 选中即关）', (tester) async {
    final picked = <String>[];
    for (final model in demoModels) {
      await pumpSheet(
        tester,
        hintText: '仿真模型使用预先录制的演示内容，无需联网。',
        onSelected: (_, modelId) => picked.add(modelId),
      );

      expect(
        find.text('仿真模型使用预先录制的演示内容，无需联网。'),
        findsOneWidget,
        reason: '提示必须在操作当时可见（sheet 内，非选后 toast）',
      );

      // 无预选时组默认折叠：先点组标题展开，再点模型项
      await tester.tap(find.text('演示模型（本地回放）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(model.displayName!));
      await tester.pumpAndSettle();
      // onModelSelected 已回调，sheet 自行关闭
      expect(picked.last, model.modelId);
    }
    expect(picked, hasLength(5));
    expect(picked.first, 'demo-narrator-glm');
    expect(picked, contains('demo-narrator-kimi-k3.1-pro'));
  });

  testWidgets('不传 hint（正式路径）零横幅渲染', (tester) async {
    await pumpSheet(
      tester,
      onSelected: (_, __) {},
    );
    expect(
      find.text('仿真模型使用预先录制的演示内容，无需联网。'),
      findsNothing,
      reason: '正式模型选择不显示仿真说明',
    );
    // 五项照常可选（先展开组）
    await tester.tap(find.text('演示模型（本地回放）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仿真 · GLM-5.3'));
    await tester.pump();
  });
}

/// 预置演示供应商（五仿真模型）的 SettingsNotifier 桩
class _DemoPresetSettingsNotifier extends SettingsNotifier {
  _DemoPresetSettingsNotifier()
      : super(
          presetRepo: _DemoPresetRepo(),
          templateRepo: _NoopTemplateRepo(),
          settingsRepo: _EmptySettingsRepo(),
        );
}

class _DemoPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'demo-preset',
          name: '演示模型（本地回放）',
          baseUrl: 'https://demo.invalid/v1',
          createdAt: DateTime(2026, 11, 7),
          updatedAt: DateTime(2026, 11, 7),
          cachedModels: demoModels,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepo implements TemplateRepository {
  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  Future<List<Template>> getAllTemplates() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _EmptySettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
