import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/experience_memory_tab.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// MEM-20：记忆浏览器经历列表的「未入索引」徽标
///
/// importance < importanceStorageThreshold（默认 3）的记忆按策略不建
/// memories_fts 行（FTS 通道搜不到，主表子串兜底可达）——行内标徽标，
/// 防"看得见却搜不到"的误解。最小 widget 测试：低分记忆行出现徽标文本，
/// 达门槛记忆行不出现。
void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpTab(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          experienceRepositoryProvider.overrideWithValue(_BadgeRepo()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeCatalog.assemble(
              const LmAppearance(),
              Brightness.light,
            ),
            home: const Scaffold(
              body: ExperienceMemoryTab(sessionId: 's1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('低重要度记忆行显示「未入索引」，达门槛记忆不显示', (tester) async {
    await pumpTab(tester);

    // importance=1（< 默认门槛 3）→ 恰好一行带徽标
    expect(find.text('未入索引'), findsOneWidget);
    // 三条记忆都渲染出来（importance 1/3/5），排除"没加载列表"的假绿
    expect(find.text('低分细节记忆'), findsOneWidget);
    expect(find.text('门槛记忆'), findsOneWidget);
    expect(find.text('高分关键记忆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('显式传入更高门槛时，处于门槛之下的记忆也标徽标', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          experienceRepositoryProvider.overrideWithValue(_BadgeRepo()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeCatalog.assemble(
              const LmAppearance(),
              Brightness.light,
            ),
            home: const Scaffold(
              body: ExperienceMemoryTab(
                sessionId: 's1',
                // 门槛提到 5：importance 1 与 3 的行都应带徽标（2 处）
                importanceStorageThreshold: 5,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未入索引'), findsNWidgets(2));
  });
}

class _BadgeRepo implements ExperienceRepository {
  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      [
        ExperientialMemory(
          memoryId: 'm-low',
          sessionId: sessionId,
          turnNumber: 1,
          importance: 1,
          tags: const [],
          createdAt: DateTime(2026),
          summary: '低分细节记忆',
        ),
        ExperientialMemory(
          memoryId: 'm-mid',
          sessionId: sessionId,
          turnNumber: 2,
          importance: 3,
          tags: const [],
          createdAt: DateTime(2026),
          summary: '门槛记忆',
        ),
        ExperientialMemory(
          memoryId: 'm-high',
          sessionId: sessionId,
          turnNumber: 3,
          importance: 5,
          tags: const [],
          createdAt: DateTime(2026),
          summary: '高分关键记忆',
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
