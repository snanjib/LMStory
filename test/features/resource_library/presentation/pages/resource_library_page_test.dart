import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/presentation/pages/resource_ai_page.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/presentation/pages/resource_library_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 资源库页面删除入口异常兜底测试
///
/// 口径：删除（含跨会话级联）失败时仓储抛 [QueryException]，
/// 页面必须 catch 并给 floating SnackBar 反馈——此前异常直接逃逸到
/// 框架层，用户点删除无任何感知，资源看似未删。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(ResourceLibraryRepository repo) {
    return ProviderScope(
      overrides: [resourceLibraryRepositoryProvider.overrideWithValue(repo)],
      child: TranslationProvider(
        child: const MaterialApp(home: ResourceLibraryPage()),
      ),
    );
  }

  testWidgets('删除角色卡仓储抛错 → floating SnackBar 反馈删除失败，无异常逃逸', (tester) async {
    final repo = _FailingDeleteRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('测试卡'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    // 确认弹窗 → 确认删除
    // 确认键不再借用模板域「删除模板」，改 common.delete
    expect(find.textContaining('确定删除 "测试卡"'), findsOneWidget);
    // 弹窗补「删除资源」标题
    expect(find.text('删除资源'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 失败有反馈，且是浮层 SnackBar（repo 规矩）
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(find.textContaining('删除失败'), findsOneWidget);
    // 列表未刷新误删：条目仍在
    expect(find.text('测试卡'), findsOneWidget);
  });

  testWidgets('删除世界书仓储抛错 → 同样有 floating SnackBar 反馈', (tester) async {
    final repo = _FailingDeleteRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('测试书'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();

    expect(find.textContaining('确定删除 "测试书"'), findsOneWidget);
    // 同上——确认键 common.delete
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pumpAndSettle();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.text('测试书'), findsOneWidget);
  });

  // ── ：列表加载三态 ────────────────────────────────
  //
  // 此前 _reload 无守卫：仓储抛 QueryException 时异常逃逸到未捕获异步区，
  // 页面停留在无限转圈、无重试入口。
  testWidgets('列表加载失败 → 错误态 + 重试入口；重试成功恢复内容态', (tester) async {
    final repo = _FailingThenWorkingRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    // 第一次加载失败：不再无限转圈，展示错误态 + 重试
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('资源库加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试 → 仓储恢复 → 回到内容态
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('资源库加载失败'), findsNothing);
    expect(find.text('测试卡'), findsOneWidget);
  });

  testWidgets('重试仍失败 → 停留错误态，无异常逃逸', (tester) async {
    final repo = _AlwaysFailingLoadRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining('资源库加载失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // 仍失败：错误态保持（tester 不吞异常即代表无逃逸）
    expect(find.textContaining('资源库加载失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // ── ：删除成功反馈 + 屏障不可点关闭 ─────────────
  testWidgets('删除成功 → floating SnackBar「已删除」反馈，条目消失', (tester) async {
    final repo = _WorkingDeleteRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('测试卡'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 成功反馈（此前仅靠 tile 消失暗示成功）
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(find.textContaining('已删除 "测试卡"'), findsOneWidget);
    // 条目已消失
    expect(find.text('测试卡'), findsNothing);
  });

  testWidgets('屏障点击不关闭破坏性确认弹窗（须显式取消/确认）', (tester) async {
    final repo = _WorkingDeleteRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除 "测试卡"'), findsOneWidget);

    // 点弹窗外屏障：barrierDismissible=false，弹窗仍在
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除 "测试卡"'), findsOneWidget);
  });

  testWidgets('AI 建卡入口渲染 + 点击导航带 kind', (tester) async {
    await tester.pumpWidget(wrap(_FailingDeleteRepository()));
    await tester.pumpAndSettle();

    expect(find.text('AI 建角色卡'), findsOneWidget);
    expect(find.text('AI 建世界书'), findsOneWidget);

    await tester.tap(find.text('AI 建角色卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final pushed = tester.widget<ResourceAiPage>(
      find.byType(ResourceAiPage),
    );
    expect(pushed.kind, DraftKind.characterCard);
    expect(pushed.targetCardId, isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('AI 建世界书'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<ResourceAiPage>(find.byType(ResourceAiPage)).kind,
      DraftKind.worldbook,
    );
  });

  testWidgets('列表项 AI 编辑入口导航携带目标与留底', (tester) async {
    await tester.pumpWidget(wrap(_FailingDeleteRepository()));
    await tester.pumpAndSettle();

    // 卡条目与书条目各有一个编辑按钮
    expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final card = tester.widget<ResourceAiPage>(find.byType(ResourceAiPage));
    expect(card.kind, DraftKind.characterCard);
    expect(card.targetCardId, 'card-1');
    expect(card.originalRawJson, '{}');
    expect(card.targetSummary, contains('测试卡'));
  });
}

/// 删除成功的仓储 fake（成功反馈测试用）
class _WorkingDeleteRepository extends _FailingDeleteRepository {
  final _deletedCards = <String>{};

  @override
  Future<void> deleteCharacterCard(String cardId) async {
    _deletedCards.add(cardId);
  }

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => [
        for (final card in await super.getAllCharacterCards())
          if (!_deletedCards.contains(card.cardId)) card,
      ];
}

/// 首次加载抛 QueryException、重试恢复正常返回的仓储 fake
class _FailingThenWorkingRepository extends _FailingDeleteRepository {
  int loadCalls = 0;

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async {
    loadCalls++;
    if (loadCalls == 1) {
      throw const QueryException('Failed to load: db locked');
    }
    return super.getAllCharacterCards();
  }
}

/// 加载恒抛 QueryException 的仓储 fake
class _AlwaysFailingLoadRepository extends _FailingDeleteRepository {
  @override
  Future<List<CharacterCard>> getAllCharacterCards() async {
    throw const QueryException('Failed to load: db locked');
  }
}

/// 删除必抛 QueryException 的仓储 fake（模拟 DB 锁/损坏），
/// 读取正常返回一张卡 + 一本书。
class _FailingDeleteRepository implements ResourceLibraryRepository {
  @override
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  }) async {
    throw const QueryException('Failed to update character card: db locked');
  }

  @override
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  }) async {
    throw const QueryException('Failed to update worldbook: db locked');
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {
    throw const QueryException('Failed to delete character card: db locked');
  }

  @override
  Future<void> deleteWorldbook(String bookId) async {
    throw const QueryException('Failed to delete worldbook: db locked');
  }

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => [
        CharacterCard(
          cardId: 'card-1',
          name: '测试卡',
          rawJson: '{}',
          sourceFormat: 'v2',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => [
        Worldbook(
          bookId: 'book-1',
          name: '测试书',
          rawJson: '{}',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async => null;

  @override
  Future<Worldbook?> getWorldbook(String bookId) async => null;
}
