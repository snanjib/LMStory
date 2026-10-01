import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_editor_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompt_metadata.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 提示词编辑器空串语义
///
/// 页头注释承诺「空串等价于恢复默认（移除覆盖）」，但 _save 此前只在
/// 值等于内置默认时移除覆盖——空串会落 setUserOverride(key, '')，而
/// PromptsConfig.fromJson 只对 null 回落常量 → 用户"全选删除→保存"得到
/// 永久空系统提示词。修复后 trim 空串一律 removeUserOverride。
class _RecordingSettingsRepo implements SettingsRepository {
  final List<String> removedKeys = [];
  final List<MapEntry<String, String>> setEntries = [];

  @override
  Future<void> removeUserOverride(String key) async => removedKeys.add(key);

  @override
  Future<void> setUserOverride(String key, dynamic value) async =>
      setEntries.add(MapEntry(key, value as String));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    _RecordingSettingsRepo repo, {
    PromptFieldMeta? meta,
  }) async {
    final field = meta ?? promptFieldMetas.first;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          intermediateConfigProvider.overrideWith(
            (ref) async => const IntermediateConfig(),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(home: IntermediatePromptEditorPage(meta: field)),
        ),
      ),
    );
    // 配置异步就绪 + EntryTransition 入场动画
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> saveNow(WidgetTester tester) async {
    // 保存按钮在 ListView 底部：滚入视口后点击（默认 800x600 视口下
    // 惰性未构建且在折叠线以下）
    final saveFinder = find.byType(ElevatedButton);
    await tester.scrollUntilVisible(
      saveFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(saveFinder);
    // _save 异步链（repo 调用 + invalidate + snackbar）跨微任务，多冲两帧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('空串保存 → 校验拦截（空就是空、每项必有值，D6-1）', (tester) async {
    final repo = _RecordingSettingsRepo();
    await pumpPage(tester, repo);

    // 初始值=内置默认（非空），全选删除后保存 → 拦截
    await tester.enterText(find.byType(TextField), '');
    await saveNow(tester);

    expect(
      find.text(t.settings.intermediate.prompts.emptyBlocked),
      findsOneWidget,
      reason: '空保存被拦截并给出可行动提示',
    );
    expect(repo.removedKeys, isEmpty);
    expect(repo.setEntries, isEmpty);
  });

  testWidgets('纯空白保存 → 同样被拦截', (tester) async {
    final repo = _RecordingSettingsRepo();
    await pumpPage(tester, repo);

    await tester.enterText(find.byType(TextField), '   \n  ');
    await saveNow(tester);

    expect(
      find.text(t.settings.intermediate.prompts.emptyBlocked),
      findsOneWidget,
    );
    expect(repo.removedKeys, isEmpty);
    expect(repo.setEntries, isEmpty);
  });

  testWidgets('非默认文本保存 → 正常写入覆盖', (tester) async {
    final repo = _RecordingSettingsRepo();
    await pumpPage(tester, repo);

    const custom = '自定义提示词内容（非默认）';
    await tester.enterText(find.byType(TextField), custom);
    await saveNow(tester);

    // _save 是否走完：成功 SnackBar 出现（定位断点用）
    expect(
      find.text(t.settings.intermediate.prompts.saved),
      findsOneWidget,
    );
    expect(repo.setEntries, hasLength(1));
    expect(repo.setEntries.single.key, promptFieldMetas.first.overrideKey);
    expect(repo.setEntries.single.value, custom);
    expect(repo.removedKeys, isEmpty);
  });
}
