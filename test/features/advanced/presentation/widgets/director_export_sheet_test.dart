import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_export_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 稿件导出选项 sheet widget 测试
///
/// 选项、取消和延迟读取产物的实际 Markdown 导出。
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

  Future<void> pumpSheet(
    WidgetTester tester,
    AdvancedChatState state, {
    Future<Map<int, StoryRoundArtifacts>> Function()? loadArtifacts,
  }) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => DirectorExportSheet.show(
                    context,
                    state,
                    loadArtifacts: loadArtifacts,
                  ),
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
    var loads = 0;
    await pumpSheet(
      tester,
      stateWith(1),
      loadArtifacts: () async {
        loads++;
        return const <int, StoryRoundArtifacts>{};
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('导出稿件'), findsNothing);
    expect(loads, 0);
  });

  for (final backstage in [false, true]) {
    testWidgets(
      '部分轮次已加载时确认导出${backstage ? '含幕后过程' : '纯稿件'}，旧轮产物只读一次',
      (tester) async {
        final directory =
            Directory.systemTemp.createTempSync('lmstory-export-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File('${directory.path}/manuscript.md');
        final picker = _ExportFilePicker(file.path);
        // flutter_test does not register a desktop picker in its test isolate.
        FilePicker.platform = picker;
        final all = <int, StoryRoundArtifacts>{
          for (var turn = 1; turn <= 30; turn++)
            turn: StoryRoundArtifacts(
              sessionId: 's1',
              turnNumber: turn,
              createdAt: DateTime(2026),
              storyAnchor: StoryAnchor(updatedTurn: turn, arc: '第 $turn 幕场记'),
              agentTimeline: [
                AgentTimelineBlock(
                  kind: AgentTimelineKind.action,
                  stepIndex: 0,
                  action: AgentWorkStep(
                    toolName: 'search_story',
                    title: '第 $turn 幕翻阅记录',
                  ),
                ),
                AgentTimelineBlock(
                  kind: AgentTimelineKind.narration,
                  stepIndex: 1,
                  text: '第 $turn 幕播报',
                ),
              ],
            ),
        };
        final state = stateWith(30).copyWith(
          artifactsByTurnNumber: {30: all[30]!},
        );
        final pending = Completer<Map<int, StoryRoundArtifacts>>();
        var loads = 0;
        await pumpSheet(
          tester,
          state,
          loadArtifacts: () {
            loads++;
            return pending.future;
          },
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        if (backstage) await tester.tap(find.text('含幕后过程'));
        await tester.pump();
        expect(loads, 0);

        final confirm = find.text('导出');
        await tester.tap(confirm);
        await tester.tap(confirm);
        await tester.pump();
        expect(loads, 1);
        expect(picker.saves, 0);
        pending.complete(all);
        // The real desktop export writes asynchronously to the selected file.
        final saved = find.text(file.path);
        for (var i = 0; i < 100 && saved.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(saved, findsOneWidget);
        expect(picker.saves, 1);
        final markdown = file.readAsStringSync();
        expect(markdown, contains('## 第 1 幕\n'));
        expect(markdown, contains('正文 1\n'));
        expect(markdown, contains('- 当前弧线：第 1 幕场记'));
        expect(markdown, contains('- 当前弧线：第 30 幕场记'));
        for (final line in ['> 指令 1\n', '- 翻阅前情 · 第 1 幕翻阅记录', '- 播报：第 1 幕播报']) {
          expect(markdown, backstage ? contains(line) : isNot(contains(line)));
        }
      },
      skip: kIsWeb ||
          !(Platform.isMacOS || Platform.isLinux || Platform.isWindows),
    );
  }
}

class _ExportFilePicker extends FilePicker {
  _ExportFilePicker(this.path);
  final String path;
  int saves = 0;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saves++;
    return path;
  }
}
