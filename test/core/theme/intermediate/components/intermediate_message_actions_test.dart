import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateMessageActions 组件测试（简化 Fork）
///
/// 验证：
/// - 助手和用户消息统一显示：复制 / 重新生成 / 编辑 / 删除整轮
/// - canOperate=true：点击各动作触发对应回调
/// - canOperate=false：非复制动作弹 SnackBar 提示；复制仍可用
/// - 配色：canOperate=true 时删除用 error 色；canOperate=false 时用 faint 色
///
///  改造：横排 IconButton Row（Grok 风格 tap 显示），不再需要先打开
/// PopupMenu 菜单再选菜单项，直接 tap 对应 IconButton 即可触发回调。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// 一次性构造 widget 树 + Actions 组件，避免嵌套 trailing comma 问题
  Future<void> pumpActions(
    WidgetTester tester, {
    required bool isUser,
    required bool canOperate,
    required VoidCallback onCopy,
    required VoidCallback onRegenerate,
    required VoidCallback onEdit,
    required VoidCallback onDeleteRound,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark)
              .copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: Scaffold(
            body: Center(
              child: IntermediateMessageActions(
                isUser: isUser,
                canOperate: canOperate,
                windowRounds: 5,
                onCopy: onCopy,
                onRegenerate: onRegenerate,
                onEdit: onEdit,
                onDeleteRound: onDeleteRound,
              ),
            ),
          ),
        ),
      ),
    );
  }

  //  改造后：横排 IconButton 常驻显示，无需 openMenu(tester) helper。
  // 直接 tap 对应 IconButton 即可触发回调。

  group('IntermediateMessageActions - 动作列表', () {
    testWidgets('1. 助手消息：显示复制/重新生成/编辑/删除整轮', (tester) async {
      await pumpActions(
        tester,
        isUser: false,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      // 横排 IconButton 常驻显示，pumpActions 后立即可见
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    });

    testWidgets('2. 用户消息：显示复制/重新生成/编辑/删除整轮', (tester) async {
      await pumpActions(
        tester,
        isUser: true,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    });
  });

  group('IntermediateMessageActions - canOperate=true 回调', () {
    testWidgets('3. 点击复制触发 onCopy', (tester) async {
      var copyCalled = false;
      await pumpActions(
        tester,
        isUser: false,
        canOperate: true,
        onCopy: () => copyCalled = true,
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();

      expect(copyCalled, isTrue);
    });

    testWidgets('4. 点击重新生成触发 onRegenerate', (tester) async {
      var regenerateCalled = false;
      await pumpActions(
        tester,
        isUser: false,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () => regenerateCalled = true,
        onEdit: () {},
        onDeleteRound: () {},
      );

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pumpAndSettle();

      expect(regenerateCalled, isTrue);
    });

    testWidgets('5. 点击编辑触发 onEdit', (tester) async {
      var editCalled = false;
      await pumpActions(
        tester,
        isUser: true,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () => editCalled = true,
        onDeleteRound: () {},
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(editCalled, isTrue);
    });

    testWidgets('6. 点击删除整轮触发 onDeleteRound', (tester) async {
      var deleteCalled = false;
      await pumpActions(
        tester,
        isUser: false,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () => deleteCalled = true,
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(deleteCalled, isTrue);
    });
  });

  group('IntermediateMessageActions - canOperate=false', () {
    testWidgets('7. 点击非复制动作弹 SnackBar 提示窗口限制', (tester) async {
      var regenerateCalled = false;
      await pumpActions(
        tester,
        isUser: false,
        canOperate: false,
        onCopy: () {},
        onRegenerate: () => regenerateCalled = true,
        onEdit: () {},
        onDeleteRound: () {},
      );

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pumpAndSettle();

      // SnackBar 出现：t.intermediate.chat.messageActions.windowExceeded(count: 5)
      expect(find.text('只能操作最近 5 轮的消息'), findsOneWidget);
      // 回调未被调用
      expect(regenerateCalled, isFalse);
    });

    testWidgets('8. canOperate=false 时复制仍可用', (tester) async {
      var copyCalled = false;
      await pumpActions(
        tester,
        isUser: false,
        canOperate: false,
        onCopy: () => copyCalled = true,
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();

      expect(copyCalled, isTrue);
      // 无 SnackBar
      expect(find.text('只能操作最近 5 轮的消息'), findsNothing);
    });

    testWidgets('9. canOperate=false 时动作图标用 faint 色', (tester) async {
      await pumpActions(
        tester,
        isUser: false,
        canOperate: false,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      // 重新生成（disabled）的图标应为 faint 色
      final regenerateIcon = tester.widget<Icon>(
        find.byIcon(Icons.refresh_rounded),
      );
      expect(regenerateIcon.color, ClassicPaletteValues.dark.faint);

      // 复制（enabled）的图标应为 ink 色
      final copyIcon = tester.widget<Icon>(find.byIcon(Icons.copy_outlined));
      expect(copyIcon.color, ClassicPaletteValues.dark.ink);
    });

    testWidgets('10. canOperate=true 时删除动作用 error 色', (tester) async {
      await pumpActions(
        tester,
        isUser: false,
        canOperate: true,
        onCopy: () {},
        onRegenerate: () {},
        onEdit: () {},
        onDeleteRound: () {},
      );

      // 删除整轮的图标应为 error 色
      final deleteIcon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
      expect(deleteIcon.color, ClassicPaletteValues.dark.error);

      // 复制的图标应为 ink 色（非 error）
      final copyIcon = tester.widget<Icon>(find.byIcon(Icons.copy_outlined));
      expect(copyIcon.color, ClassicPaletteValues.dark.ink);
    });
  });
}
