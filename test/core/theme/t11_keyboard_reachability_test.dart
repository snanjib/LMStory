import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/global_search_dialog.dart';
import 'package:lmstory/i18n/strings.g.dart';

///  键盘可达性：浮层的三条硬口径（A 段验收）。
///
/// 用**真实浮层**（统一入口 `showLmDialog` / `showLmSheet` + 真实全局搜索
/// 对话框）而不是自造探针：
///
/// 1. **Esc 关闭** —— 只关浮层这一层，不连带 pop 主页面；`barrierDismissible:
///    false` 的浮层按 Esc 必须无响应（不放宽调用方的不可关闭声明）。
/// 2. **焦点陷阱** —— Tab 在浮层内回绕，绝不逃到下层页面。
/// 3. **关闭后焦点归位** —— 焦点回到打开浮层的那个控件，键盘用户不被打回根节点。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _FakeChatRepository repo;
  late FocusNode opener;
  late BuildContext hostContext;

  setUp(() {
    repo = _FakeChatRepository();
    opener = FocusNode(debugLabel: 'opener');
    repo.results = [
      SearchResult(
        sessionId: 's1',
        sessionName: '会话一',
        messageId: 'm1',
        content: '深夜便利店的故事。',
        role: 'assistant',
        createdAt: DateTime(2026),
      ),
    ];
  });

  tearDown(() {
    opener.dispose();
  });

  /// 主页面：一个可聚焦的「打开」控件 + 一个按钮（露出 hostContext）。
  Future<void> pumpHost(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [chatRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  hostContext = context;
                  return Center(
                    child: Focus(
                      focusNode: opener,
                      child: ElevatedButton(
                        onPressed: () => unawaited(
                          showLmDialog<void>(
                            context: context,
                            builder: (_) =>
                                GlobalSearchDialog(onResultSelected: (_) {}),
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSearchDialog(WidgetTester tester) async {
    unawaited(
      showLmDialog<void>(
        context: hostContext,
        builder: (_) => GlobalSearchDialog(onResultSelected: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Esc 关闭浮层，且只关浮层这一层', (tester) async {
    await pumpHost(tester);
    await openSearchDialog(tester);
    expect(find.byType(GlobalSearchDialog), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(GlobalSearchDialog), findsNothing, reason: 'Esc 必须关掉浮层');
    expect(
      find.text('open'),
      findsOneWidget,
      reason: 'Esc 只能关浮层这一层——主页面被连带 pop 掉说明关了两层',
    );
  });

  testWidgets('barrierDismissible: false 的浮层按 Esc 无响应', (tester) async {
    await pumpHost(tester);
    unawaited(
      showLmDialog<void>(
        context: hostContext,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(title: Text('stubborn')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('stubborn'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.text('stubborn'),
      findsOneWidget,
      reason: '不可关闭的浮层（确认框）不得因为统一键盘层变成可以按 Esc 溜掉',
    );
  });

  testWidgets('焦点陷阱：Tab 在浮层内回绕，绝不外逃', (tester) async {
    await pumpHost(tester);
    await openSearchDialog(tester);
    final dialogElement = tester.element(find.byType(GlobalSearchDialog));

    for (var i = 0; i < 15; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull, reason: '第 ${i + 1} 次 Tab 后焦点丢失');
      expect(
        _isWithin(focused!.context, dialogElement),
        isTrue,
        reason: '第 ${i + 1} 次 Tab 后焦点逃出浮层，落到了下层页面',
      );
    }

    // 反向（Shift+Tab）同样不得外逃
    for (var i = 0; i < 15; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(_isWithin(focused!.context, dialogElement), isTrue);
    }
  });

  testWidgets('关闭浮层后焦点归位到打开它的控件', (tester) async {
    await pumpHost(tester);
    opener.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, opener);

    await openSearchDialog(tester);
    expect(
      _isWithin(
        FocusManager.instance.primaryFocus!.context,
        tester.element(find.byType(GlobalSearchDialog)),
      ),
      isTrue,
      reason: '前置：打开后焦点应进入浮层（对话框输入框自动获焦）',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus,
      opener,
      reason: '关闭后焦点必须归位——否则键盘用户每次关浮层都被打回根节点，'
          'Tab 要从头走一遍',
    );
  });

  testWidgets('底部浮层（showLmSheet）Esc 同样可关', (tester) async {
    await pumpHost(tester);
    unawaited(
      showLmSheet<void>(
        context: hostContext,
        builder: (_) => const SizedBox(
          height: 160,
          child: Center(child: Text('sheet-body')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sheet-body'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.text('sheet-body'),
      findsNothing,
      reason: '浮层 Esc 口径对 sheet 同样成立',
    );
    expect(find.text('open'), findsOneWidget);
  });
}

/// [context] 是否落在 [ancestor] 的子树内（含自身）。
bool _isWithin(BuildContext? context, Element ancestor) {
  if (context == null) return false;
  if (context == ancestor) return true;
  var found = false;
  context.visitAncestorElements((element) {
    if (element == ancestor) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

class _FakeChatRepository implements ChatRepository {
  List<SearchResult> results = [];

  @override
  Future<List<SearchResult>> searchMessages(String query) async => results;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
