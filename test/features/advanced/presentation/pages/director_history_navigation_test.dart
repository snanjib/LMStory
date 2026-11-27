import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

AdvancedChatState _history(int rounds, {bool shortLast = false}) {
  final day = DateTime(2026);
  final messages = <ChatMessage>[];
  for (var i = 1; i <= rounds; i++) {
    messages
      ..add(
        ChatMessage(
          messageId: 'u$i',
          sessionId: 'director',
          role: 'user',
          content: '指示 $i',
          createdAt: day,
        ),
      )
      ..add(
        ChatMessage(
          messageId: 'a$i',
          sessionId: 'director',
          role: 'assistant',
          content:
              '稿件 $i。${'她关上木门，雨声在屋檐下渐渐停了。' * (shortLast && i == rounds ? 1 : i == rounds ~/ 2 ? 140 : 18)}',
          createdAt: day,
        ),
      );
  }
  return AdvancedChatState(
    phase: IntermediatePhase.idle,
    messages: messages,
    retryCounts: const {},
    session: ChatSession(
      sessionId: 'director',
      title: '合成会话',
      mode: 'advanced',
      createdAt: day,
      lastActiveAt: day,
      messageCount: messages.length,
    ),
  );
}

Widget _page(
  AdvancedChatState state, {
  String? focus,
  bool pure = false,
  bool showBody = true,
  Future<void> Function(Iterable<int>)? onTurns,
  Future<void> Function(ChatMessage, int)? onSwitch,
}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
      home: Scaffold(
        body: !showBody
            ? const SizedBox.shrink()
            : DirectorChatBody(
                state: state,
                initialFocusMessageId: focus,
                pureReading: pure,
                onCopy: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onRegenerate: (_) {},
                onVisibleHistoryTurns: onTurns,
                onSwitchVariant: onSwitch,
              ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 65));
  }
}

Finder get _list => find.bySubtype<CustomScrollView>().first;
Finder _button(IconData icon) => find.byIcon(icon).hitTestable();
void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 780);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _atTop(WidgetTester tester, String id) {
  final row = find.byKey(ValueKey<String>(id)).last;
  expect(tester.getTopLeft(row).dy, closeTo(tester.getTopLeft(_list).dy, 1));
}

AdvancedChatState _compress(AdvancedChatState state, int turns) {
  return state.copyWith(
    compactedTurnBase: turns,
    messages: [
      ChatMessage(
        messageId: 'summary-$turns',
        sessionId: state.session.sessionId,
        role: 'system',
        content: '早期剧情摘要',
        isSummary: true,
        createdAt: DateTime(2026),
      ),
      ...state.messages.skip(turns * 2),
    ],
  );
}

Future<double> _readInto(
  WidgetTester tester,
  String prose,
  double distance,
) async {
  final text = find.text(prose);
  final position = tester.widget<CustomScrollView>(_list).controller!.position;
  final top = tester.getTopLeft(text).dy - tester.getTopLeft(_list).dy;
  position.jumpTo(position.pixels + top + distance);
  await tester.pump();
  await tester.drag(_list, const Offset(0, -60));
  await _settle(tester);
  final rect = tester.getRect(text);
  final viewport = tester.getRect(_list);
  expect(rect.top, lessThan(viewport.top - 80));
  expect(rect.bottom, greaterThan(viewport.top + 30));
  return rect.top;
}

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));
  for (final pure in [false, true]) {
    for (final latest in [true, false]) {
      testWidgets('轻点长稿件保持当前行，长按可选文（从最新打开 $latest，纯净阅读 $pure）', (tester) async {
        _phone(tester);
        final state = _history(30);
        final messages = [...state.messages];
        messages[messages.length - 1] = messages.last.copyWith(
          content: '最后一幕。' * 650,
        );
        final prose = (latest ? messages.last : messages[29]).content!;
        await tester.pumpWidget(
          _page(
            state.copyWith(messages: messages),
            focus: latest ? null : 'a15',
            pure: pure,
          ),
        );
        await _settle(tester);
        if (latest) {
          await tester.drag(_list, const Offset(0, 450));
          await _settle(tester);
        } else {
          await _readInto(tester, prose, 950);
        }
        await tester.pump(const Duration(seconds: 4));
        await _settle(tester);
        final paragraph = find.text(prose);
        final before = tester.getTopLeft(paragraph).dy;
        final viewport = tester.getRect(_list);
        expect(before, lessThan(viewport.top));
        expect(
          tester.getBottomRight(paragraph).dy,
          greaterThan(viewport.bottom),
        );
        for (final fraction in [.25, .65, .012, .985]) {
          await tester.tapAt(
            Offset(
              viewport.center.dx,
              viewport.top + viewport.height * fraction,
            ),
          );
          await _settle(tester);
          expect(tester.getTopLeft(paragraph).dy, closeTo(before, 1));
        }
        await tester.longPressAt(viewport.center);
        await _settle(tester);
        final selection = tester
            .widgetList<EditableText>(find.byType(EditableText))
            .singleWhere((w) => w.controller.text == prose)
            .controller
            .selection;
        expect(selection.textInside(prose), isNotEmpty);
        expect(tester.getTopLeft(paragraph).dy, closeTo(before, 1));
      });
    }
  }

  testWidgets('从最新内容打开后仍可将屏外文字移入视口', (tester) async {
    _phone(tester);
    final state = _history(30);
    final messages = [...state.messages];
    final prose = '最后一幕。' * 650;
    messages[messages.length - 1] = messages.last.copyWith(content: prose);
    await tester.pumpWidget(_page(state.copyWith(messages: messages)));
    await _settle(tester);
    final viewport = tester.getRect(_list);
    final text = tester
        .stateList<EditableTextState>(find.byType(EditableText))
        .singleWhere((s) => s.widget.controller.text == prose)
        .renderEditable;
    final target = text.getLocalRectForCaret(const TextPosition(offset: 250));
    expect(text.localToGlobal(target.center).dy, lessThan(viewport.top));
    text.showOnScreen(rect: target);
    await _settle(tester);
    expect(viewport.contains(text.localToGlobal(target.center)), isTrue);
  });
  for (final rounds in [30, 300]) {
    testWidgets('$rounds 轮首开、远处搜索、跳顶和回底只构建目标附近稿件', (tester) async {
      _phone(tester);
      final cards = <int>{};
      var newCards = 0;
      var builds = 0;
      void resetCounts() {
        cards.clear();
        newCards = 0;
        builds = 0;
      }

      final oldCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtBefore) {
        oldCallback?.call(element, builtBefore);
        if (element.widget.runtimeType.toString() == '_ManuscriptCard') {
          final index =
              element.findAncestorWidgetOfExactType<IndexedSemantics>()?.index;
          if (index != null) {
            cards.add(index);
            builds++;
            if (!builtBefore) newCards++;
          }
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = oldCallback);
      final loaded = <int>{};
      Future<void> request(Iterable<int> turns) async {
        loaded.addAll(turns);
      }

      final state = _history(rounds);
      void bounded(String phase) {
        debugPrint(
          'director_history rounds=$rounds phase=$phase '
          'distinctManuscripts=${cards.length} mounted=$newCards builds=$builds',
        );
        expect(
          cards.length,
          inInclusiveRange(1, 12),
          reason: '$phase 实际构建的不同稿件',
        );
        expect(newCards, lessThanOrEqualTo(12), reason: '$phase 新建稿件卡数');
        expect(builds, lessThanOrEqualTo(12), reason: '$phase 稿件卡总构建次数');
        resetCounts();
      }

      await tester.pumpWidget(_page(state, onTurns: request));
      await _settle(tester);
      bounded('打开最新');
      expect(loaded, contains(rounds));
      expect(loaded, isNot(contains(1)));

      final middle = rounds ~/ 2;
      await tester
          .pumpWidget(_page(state, focus: 'a$middle', onTurns: request));
      await _settle(tester);
      _atTop(tester, 'u$middle');
      bounded('远处深链');
      expect(loaded, contains(middle));

      // Move inside a single manuscript; there is no user bubble at the
      // top from which the old navigator could infer the surrounding turns.
      await tester.drag(_list, const Offset(0, -590));
      await _settle(tester);
      expect(find.text('指示 $middle').hitTestable(), findsNothing);
      await tester.tap(_button(Icons.keyboard_arrow_down));
      await _settle(tester);
      _atTop(tester, 'u${middle + 1}');
      await tester.tap(_button(Icons.keyboard_arrow_up));
      await _settle(tester);
      _atTop(tester, 'u$middle');
      resetCounts();

      await tester.tap(_button(Icons.keyboard_double_arrow_up));
      await _settle(tester);
      expect(
        tester
            .widget<CustomScrollView>(_list)
            .controller!
            .position
            .extentBefore,
        closeTo(0, 1),
      );
      bounded('跳到开头');
      await tester.tap(_button(Icons.keyboard_double_arrow_down));
      await _settle(tester);
      expect(
        tester.widget<CustomScrollView>(_list).controller!.position.extentAfter,
        closeTo(0, 1),
      );
      bounded('跳回最新');
    });
  }

  testWidgets('末轮不满一屏时可顶对齐，折叠回底键恢复真实文末', (tester) async {
    _phone(tester);
    final state = _history(20, shortLast: true);
    await tester.pumpWidget(_page(state, focus: 'u19'));
    await _settle(tester);
    await tester.drag(_list, const Offset(0, -40));
    await _settle(tester);
    await tester.tap(_button(Icons.keyboard_arrow_down));
    await _settle(tester);
    _atTop(tester, 'u20');
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(_button(Icons.keyboard_arrow_up), findsNothing);
    await tester.tap(_button(Icons.keyboard_double_arrow_down));
    await _settle(tester);
    final last = find.byKey(const ValueKey('u20')).last;
    expect(
      tester.getTopLeft(last).dy,
      greaterThan(tester.getTopLeft(_list).dy + 100),
    );
    expect(_button(Icons.keyboard_double_arrow_down), findsNothing);
  });

  testWidgets('纯净阅读的搜索及逐轮跳转从稿件开头开始', (tester) async {
    _phone(tester);
    final state = _history(30);
    await tester.pumpWidget(_page(state, focus: 'u15', pure: true));
    await _settle(tester);
    _atTop(tester, 'a15');
    expect(find.text('指示 15'), findsNothing);
    await tester.drag(_list, const Offset(0, -590));
    await _settle(tester);
    await tester.tap(_button(Icons.keyboard_arrow_up));
    await _settle(tester);
    _atTop(tester, 'a14');
    expect(find.text('指示 14'), findsNothing);
  });
  testWidgets('关闭重开恢复同一消息内的阅读位置', (tester) async {
    _phone(tester);
    final state = _history(30);
    await tester.pumpWidget(_page(state, focus: 'u15'));
    await _settle(tester);
    await tester.drag(_list, const Offset(0, -500));
    await _settle(tester);
    final marker = find.byKey(const ValueKey('a15')).last;
    final before = tester.getTopLeft(marker).dy;
    expect(before, lessThan(-100));
    await tester.pumpWidget(_page(state, showBody: false));
    await tester.pump();
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
  });

  for (final longOpening in [false, true]) {
    testWidgets('回顶后下一轮根据首轮是否已进入视口定位（长开篇 $longOpening）', (tester) async {
      _phone(tester);
      final history = _history(30);
      final state = longOpening
          ? history.copyWith(
              session: history.session.copyWith(title: '很长的开篇。\n' * 35),
            )
          : history;
      await tester.pumpWidget(_page(state));
      await _settle(tester);
      await tester.drag(_list, const Offset(0, 120));
      await _settle(tester);
      await tester.tap(_button(Icons.keyboard_double_arrow_up));
      await _settle(tester);
      final first = find.text('指示 1');
      expect(first.hitTestable(), longOpening ? findsNothing : findsOneWidget);
      final previous = _button(Icons.keyboard_arrow_up);
      final previousButton =
          find.ancestor(of: previous, matching: find.byType(IconButton));
      expect(tester.widget<IconButton>(previousButton).onPressed, isNull);
      await tester.tap(previous);
      await _settle(tester);
      expect(
        tester
            .widget<CustomScrollView>(_list)
            .controller!
            .position
            .extentBefore,
        closeTo(0, 1),
      );
      await tester.tap(_button(Icons.keyboard_arrow_down));
      await _settle(tester);
      _atTop(tester, longOpening ? 'u1' : 'u2');
    });
  }

  testWidgets('同一轮实点切到不同长度稿件时保留稿内位置，超出新版时显示新版开头', (tester) async {
    _phone(tester);
    final base = _history(30);
    final drafts = [
      const MessageVariantRecord(
        variantIndex: 0,
        createdAtMs: 0,
        content: '只剩一句。',
      ),
      MessageVariantRecord(
        variantIndex: 1,
        createdAtMs: 1,
        content: '换稿后院子里响起钟声。' * 90,
      ),
      MessageVariantRecord(
        variantIndex: 2,
        createdAtMs: 2,
        content: '第一稿描写雨后的山路。' * 155,
      ),
    ];
    AdvancedChatState selected(int index) => base.copyWith(
          messages: [
            ...base.messages.take(base.messages.length - 1),
            base.messages.last.copyWith(content: drafts[index].content),
          ],
          artifactsByTurnNumber: {
            30: StoryRoundArtifacts(
              sessionId: base.session.sessionId,
              turnNumber: 30,
              createdAt: DateTime(2026),
              currentVariantIndex: index,
            ),
          },
          variantsByTurn: {30: drafts},
        );
    int? requested;
    Future<void> onSwitch(ChatMessage message, int index) async {
      expect(message.messageId, 'a30');
      requested = index;
    }

    await tester
        .pumpWidget(_page(selected(2), focus: 'a30', onSwitch: onSwitch));
    await _settle(tester);
    for (final index in [1, 0]) {
      final arrow = find.byIcon(Icons.chevron_left).last;
      await tester.ensureVisible(arrow);
      await tester.pump();
      await tester.tap(arrow);
      expect(requested, index);
      final before = await _readInto(tester, drafts[index + 1].content!, 480);
      await tester
          .pumpWidget(_page(selected(index), focus: 'a30', onSwitch: onSwitch));
      await _settle(tester);
      final newText = find.text(drafts[index].content!);
      final id = find.byKey(const ValueKey('a30')).last;
      expect(find.descendant(of: id, matching: newText), findsOneWidget);
      if (index == 1) {
        expect(tester.getTopLeft(newText).dy, closeTo(before, 1));
      } else {
        final y = tester.getTopLeft(newText).dy - tester.getTopLeft(_list).dy;
        expect(y, inInclusiveRange(0, 30));
      }
    }
  });

  testWidgets('压缩前缀删掉原定位锚而保留正在读的稿件时维持消息与稿内偏移', (tester) async {
    _phone(tester);
    final state = _history(30);
    await tester.pumpWidget(_page(state, focus: 'u14'));
    await _settle(tester);
    final prose = state.messages[29].content!;
    final before = await _readInto(tester, prose, 410);
    await tester.pumpWidget(_page(_compress(state, 14), focus: 'u14'));
    await _settle(tester);
    final id = find.byKey(const ValueKey('a15')).last;
    final text = find.descendant(of: id, matching: find.text(prose));
    expect(tester.getTopLeft(text).dy, closeTo(before, 1));
    expect(
      tester.getBottomLeft(text).dy,
      greaterThan(tester.getTopLeft(_list).dy),
    );
  });

  for (final reopen in [false, true]) {
    testWidgets('正在读的稿件已被压缩时显示对应摘要（重开 $reopen）', (tester) async {
      _phone(tester);
      final state = _history(30);
      await tester.pumpWidget(_page(state, focus: 'u15'));
      await _settle(tester);
      await _readInto(tester, state.messages[29].content!, 410);
      if (reopen) {
        await tester.pumpWidget(_page(state, showBody: false));
        await tester.pump();
      }
      await tester.pumpWidget(
        _page(_compress(state, 16), focus: reopen ? null : 'u15'),
      );
      await _settle(tester);
      _atTop(tester, 'summary-16');
      expect(find.text('指示 17').hitTestable(), findsOneWidget);
      expect(find.text('指示 30').hitTestable(), findsNothing);
    });
  }

  testWidgets('内容完全容得下时从顶排版且四键不占触控', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 3600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _history(5);
    final short = state.copyWith(
      messages: [
        for (final m in state.messages) m.copyWith(content: m.messageId),
      ],
    );
    await tester.pumpWidget(_page(short));
    await _settle(tester);
    final p = tester.widget<CustomScrollView>(_list).controller!.position;
    expect(p.maxScrollExtent - p.minScrollExtent, closeTo(0, 1));
    expect(tester.getTopLeft(find.text('u1')).dy, lessThan(300));
    await tester.drag(_list, const Offset(0, -80));
    await _settle(tester);
    expect(_button(Icons.keyboard_double_arrow_down), findsNothing);
  });
  testWidgets('长稿中途切换纯净阅读保持同一行正文', (tester) async {
    _phone(tester);
    final state = _history(30);
    await tester.pumpWidget(_page(state, focus: 'a15'));
    await _settle(tester);
    await tester.drag(_list, const Offset(0, -500));
    await _settle(tester);
    final prose = find.text(state.messages[29].content!);
    final before = tester.getTopLeft(prose).dy;
    expect(before, lessThan(-100));
    for (final pure in [true, false]) {
      await tester.pumpWidget(_page(state, focus: 'a15', pure: pure));
      await _settle(tester);
      expect(tester.getTopLeft(prose).dy, closeTo(before, 1));
    }
  });

  testWidgets('幕后资料迟到时正在阅读的同一行正文保持原位', (tester) async {
    _phone(tester);
    final state = _history(30);
    await tester.pumpWidget(_page(state, focus: 'u15'));
    await _settle(tester);
    await tester.drag(_list, const Offset(0, -500));
    await _settle(tester);
    final prose = find.text(state.messages[29].content!);
    final before = tester.getTopLeft(prose).dy;
    expect(before, lessThan(-100));
    await tester.pumpWidget(
      _page(
        state.copyWith(
          artifactsByTurnNumber: {
            15: StoryRoundArtifacts(
              sessionId: 'director',
              turnNumber: 15,
              createdAt: DateTime(2026),
              agentTimeline: const [
                AgentTimelineBlock(
                  kind: AgentTimelineKind.narration,
                  stepIndex: 0,
                  text: '幕后记录',
                ),
              ],
            ),
          },
        ),
        focus: 'u15',
      ),
    );
    await _settle(tester);
    expect(tester.getTopLeft(prose).dy, closeTo(before, 1));
  });
}
