import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_edit_dialog.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateEditDialog 组件测试（简化 Fork）
///
/// 验证：
/// - 渲染：标题 / 初始内容 / 取消按钮 / 保存并重发按钮
/// - 初始状态：保存并重发按钮 disabled（_isDirty=false）
/// - 修改内容后：保存并重发按钮 enabled
/// - 清空内容后：保存并重发按钮 disabled（_canSave=false）
/// - 交互：取消 → null；保存并重发 → 新内容
/// - dirty 防误退：取消时弹确认丢弃弹窗；确认丢弃 → null；取消丢弃 → 保持编辑
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap() {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark)
            .copyWith(
          splashFactory: NoSplash.splashFactory,
        ),
        home: const Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: null,
              child: Text('host'),
            ),
          ),
        ),
      ),
    );
  }

  /// 启动编辑弹窗并返回 result Future
  Future<({String content, bool resend})?> launchDialog(WidgetTester tester) {
    final state = tester.state(find.byType(ElevatedButton));
    return IntermediateEditDialog.show(
      state.context,
      initialContent: '原始内容',
    );
  }

  /// 找到"保存并重发"按钮的 ElevatedButton widget
  Finder findSaveButton() {
    return find.ancestor(
      of: find.text('保存并重发'),
      matching: find.byType(ElevatedButton),
    );
  }

  group('IntermediateEditDialog', () {
    testWidgets('1. 渲染标题、初始内容、按钮文案', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      // 标题：t.intermediate.chat.messageActions.editTitle = "编辑消息"
      expect(find.text('编辑消息'), findsOneWidget);
      // 初始内容在 TextField 中
      expect(find.text('原始内容'), findsOneWidget);
      // 取消按钮
      expect(find.text('取消'), findsOneWidget);
      // 保存并重发按钮
      expect(findSaveButton(), findsOneWidget);
    });

    testWidgets('2. 初始状态：保存并重发按钮 disabled（_isDirty=false）', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(findSaveButton());
      // onPressed 为 null 表示 disabled
      expect(button.onPressed, isNull);
    });

    testWidgets('3. 修改内容后：保存并重发按钮 enabled', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '修改后的内容');
      await tester.pump();

      final button = tester.widget<ElevatedButton>(findSaveButton());
      expect(button.onPressed, isNotNull);
    });

    testWidgets('4. 清空内容后：保存并重发按钮 disabled（_canSave=false）', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      // 清空文本（输入空字符串）
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();

      final button = tester.widget<ElevatedButton>(findSaveButton());
      expect(button.onPressed, isNull);
    });

    testWidgets('5. 点取消返回 null（无修改时不弹丢弃确认）', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      final result = await future;
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('6. 修改后点保存并重发返回新内容', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '新内容');
      await tester.pump();

      await tester.tap(findSaveButton());
      final result = await future;
      await tester.pumpAndSettle();

      expect(result?.content, '新内容');
      expect(result?.resend, isTrue);
    });

    testWidgets('7. dirty 时点取消 → 弹出丢弃确认弹窗', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      // 修改内容变 dirty
      await tester.enterText(find.byType(TextField), '修改了');
      await tester.pump();

      // 点取消 → 触发 PopScope → 弹丢弃确认
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 丢弃确认弹窗出现：t.chat.unsavedChanges
      expect(find.text('有未保存的更改，确定要关闭吗？'), findsOneWidget);
      // 丢弃弹窗有"取消"按钮，编辑弹窗也有"取消"按钮 → 2 个
      expect(find.text('取消'), findsNWidgets(2));
      // 丢弃弹窗标题和按钮都用"确认"（t.common.confirm）→ 2 处
      expect(find.text('确认'), findsNWidgets(2));
    });

    testWidgets('8. dirty 时确认丢弃 → 关闭弹窗返回 null', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '修改了');
      await tester.pump();

      // 点取消 → 触发丢弃确认
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 点"确认"丢弃（用 find.ancestor 限定到 TextButton，排除标题 Text）
      final discardConfirmButton = find.ancestor(
        of: find.text('确认'),
        matching: find.byType(TextButton),
      );
      await tester.tap(discardConfirmButton);
      final result = await future;
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('9. dirty 时取消丢弃 → 保持编辑弹窗', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '修改了');
      await tester.pump();

      // 点取消 → 触发丢弃确认
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 点丢弃弹窗的"取消"（保留编辑）——丢弃弹窗的取消是第 2 个"取消"按钮
      // 用 find.ancestor 限定到 AlertDialog 中的 TextButton
      final discardCancelFinder = find.descendant(
        of: find.byType(TextButton),
        matching: find.text('取消'),
      );
      // 第一个"取消"是编辑弹窗的，第二个是丢弃弹窗的——但编辑弹窗已被 PopScope 拦截
      // 此时应只剩丢弃弹窗的"取消"可见
      await tester.tap(discardCancelFinder.last);
      await tester.pumpAndSettle();

      // 丢弃弹窗关闭，编辑弹窗仍在
      expect(find.text('编辑消息'), findsOneWidget);
      expect(find.text('保存并重发'), findsOneWidget);
      // 丢弃确认弹窗已消失
      expect(find.text('有未保存的更改，确定要关闭吗？'), findsNothing);
    });
  });
}
