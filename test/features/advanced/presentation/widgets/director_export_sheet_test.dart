import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_export_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 稿件导出选项 sheet widget 测试
///
/// 选项渲染/切换 + 取消路径；导出动作涉及平台文件通道不在 widget 测试内触发。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatMessage message(String id, String role, String content) => ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime(2026),
      );

  AdvancedChatState stateWith(int rounds) => AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: [
          for (var i = 1; i <= rounds; i++) ...[
            message('u$i', 'user', '指令 $i'),
            message('a$i', 'assistant', '正文 $i'),
          ],
        ],
        retryCounts: const {},
        session: ChatSession(
          sessionId: 's1',
          title: '夜航试笔',
          mode: 'advanced',
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: rounds * 2,
        ),
      );

  Future<void> pumpSheet(WidgetTester tester, AdvancedChatState state) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => DirectorExportSheet.show(context, state),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('选项渲染：范围计数与内容两分组，默认全部+纯稿件', (tester) async {
    await pumpSheet(tester, stateWith(2));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('导出稿件'), findsOneWidget);
    expect(find.text('全部（共 2 幕）'), findsOneWidget);
    expect(find.text('当前幕（第 2 幕）'), findsOneWidget);
    expect(find.text('纯稿件'), findsOneWidget);
    expect(find.text('含幕后过程'), findsOneWidget);
  });

  /// 取选项行（tileKey）内的首个图标（选中态 radio）
  Icon tileIcon(WidgetTester tester, String tileKey) {
    return tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(ValueKey(tileKey)),
            matching: find.byType(Icon),
          )
          .first,
    );
  }

  testWidgets('切换选项：点含幕后过程与当前幕生效（选中态图标）', (tester) async {
    await pumpSheet(tester, stateWith(2));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('含幕后过程'));
    await tester.pump();
    expect(
      tileIcon(tester, 'export-content-backstage').icon,
      Icons.radio_button_checked,
    );
    expect(
      tileIcon(tester, 'export-content-manuscript').icon,
      Icons.radio_button_off,
    );

    await tester.tap(find.text('当前幕（第 2 幕）'));
    await tester.pump();
    expect(
      tileIcon(tester, 'export-scope-current').icon,
      Icons.radio_button_checked,
    );
    expect(
      tileIcon(tester, 'export-scope-all').icon,
      Icons.radio_button_off,
    );
  });

  testWidgets('取消返回 false', (tester) async {
    await pumpSheet(tester, stateWith(1));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('导出稿件'), findsNothing);
  });
}
