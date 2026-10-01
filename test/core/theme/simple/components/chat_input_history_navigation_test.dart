import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_chat_input.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 输入历史上/下键导航回归：
///
/// 1. 空输入按 ↑ 进入历史并显示最近一条；
/// 2. **已召回（文本非空）后再按 ↑ 能继续翻旧**——此前「仅空输入可翻」
///    让首次召回后永远停在第一条，第二条起不可达；
/// 3. 已召回后按 ↓ 前进到更新条目；翻过最新一条则恢复进入导航前的
///    原文（含空原文）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpInput(
    WidgetTester tester, {
    required FocusNode focusNode,
    List<String> history = const [],
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ChatModeInputArea(
                onSend: (_, __) {},
                onCancel: () {},
                isSending: false,
                isStreaming: false,
                focusNode: focusNode,
                inputHistory: history,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String editBoxText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('空输入↑进入历史，非空继续↑翻旧，↓前进并恢复原文', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await pumpInput(
      tester,
      focusNode: focusNode,
      history: const ['第一条', '第二条', '第三条'],
    );

    focusNode.requestFocus();
    await tester.pump();

    // 空输入 ↑ → 最近一条（index 0 = 最新）
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(editBoxText(tester), '第一条');

    // 非空再 ↑ → 继续翻旧（此前此处被 text.isEmpty 门拦死）
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(editBoxText(tester), '第二条');

    // ↓ → 前进回最新
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(editBoxText(tester), '第一条');

    // 再 ↓ → 翻过最新一条，恢复进入导航前的原文（空）
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(editBoxText(tester), '');
  });

  testWidgets('非导航态非空文本↑不劫持输入（多行编辑保护）', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await pumpInput(
      tester,
      focusNode: focusNode,
      history: const ['历史'],
    );
    focusNode.requestFocus();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '用户正在编辑的正文');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    // 未进入导航态：文本不被历史替换
    expect(editBoxText(tester), '用户正在编辑的正文');
  });
}
