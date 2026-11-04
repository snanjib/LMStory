import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_action_bar.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/suggest_reply_overlay.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/controllers/agent_loop_diagnostics_controller.dart';
import 'package:lmstory/features/advanced/presentation/controllers/agent_round_trace_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_loop_diagnostics_page.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_entry_page.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_page.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_hitl_banner.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/presentation/widgets/message_edit_dialog.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/presentation/pages/resource_library_page.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_editor_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_preview_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompt_metadata.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/failure_bar.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../test_helpers/load_app_fonts.dart';

const _preview = ValueKey('creative-preview');
const _open = ValueKey('open-editor');
const _name = 'Harbor Archive / The Cartographer Who Remembers Every Crossing';
final _longText =
    List.filled(80, 'At dusk, the harbor keeper opens the archive. 傍晚，守港人打开档案。')
        .join('\n');

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<ProviderContainer> host(
    WidgetTester tester,
    String structure,
    AppLocale locale,
    Widget page, {
    Size size = const Size(320, 740),
    double scale = 1.6,
    double keyboard = 0,
    bool reduced = false,
    bool settle = true,
    _Loop? loop,
    _Settings? settings,
    _Resources? resources,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        intermediateConfigProvider
            .overrideWith((ref) async => const IntermediateConfig()),
        tokenCounterProvider.overrideWithValue(_Tokens()),
        settingsRepositoryProvider.overrideWithValue(settings ?? _Settings()),
        resourceLibraryRepositoryProvider
            .overrideWithValue(resources ?? _Resources()),
        chatRepositoryProvider.overrideWithValue(_Chat()),
        agentRoundTraceControllerProvider.overrideWith((ref, arg) => _Trace()),
        agentLoopDiagnosticsControllerProvider
            .overrideWith((ref) => loop ?? _Loop()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(intermediateConfigProvider.future);
    final theme = ThemeCatalog.assemble(
      LmAppearance(structureId: structure, paletteId: 'bordeaux'),
      locale == AppLocale.zhCn ? Brightness.light : Brightness.dark,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: withLoadedTestFonts(theme, withCjkFallback: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
                disableAnimations: reduced,
              ),
              child: RepaintBoundary(key: _preview, child: child),
            ),
            home: page,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    return container;
  }

  for (final structure in ['classic', 'glass', 'brutal', 'wonder']) {
    for (final locale in [AppLocale.zhCn, AppLocale.enUs]) {
      final variant = '$structure/${locale.languageCode}';
      testWidgets(
          '$variant compact failure controls remain reachable with the keyboard',
          (tester) async {
        final calls = <String>[];
        await host(
          tester,
          structure,
          locale,
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: FailureBar(
                maxHeight: 220,
                partialReplyAvailable: true,
                failureContext: const FailureContext(
                  errorCode: 'E104',
                  failedPhase: IntermediatePhase.generating,
                  errorMessage: 'Generation interrupted. 生成中断。',
                  retryable: true,
                ),
                onRetry: () => calls.add('retry'),
                onClear: () => calls.add('clear'),
                onContinueWithFts5: () => calls.add('fts'),
                onContinueFromFailed: () => calls.add('continue'),
                onAcceptPartial: () => calls.add('accept'),
              ),
            ),
          ),
          keyboard: 230,
          reduced: true,
        );
        final labels = [
          t.intermediate.chat.clearRound,
          t.intermediate.chat.failure.continueWithFts5,
          t.intermediate.chat.failure.acceptPartial,
          t.intermediate.chat.failure.continueWriting,
          t.intermediate.chat.retryRound,
        ];
        final scroll = find
            .descendant(
              of: find.byType(FailureBar),
              matching: find.byType(Scrollable),
            )
            .first;
        for (final label in labels) {
          await tester.ensureVisible(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          expect(tester.takeException(), isNull);
        }
        expect(scroll, findsOneWidget);
        expect(calls, ['clear', 'fts', 'accept', 'continue', 'retry']);
      });

      testWidgets(
          '$variant approval choices and rejection feedback remain distinct',
          (tester) async {
        final decisions = <({bool allow, bool always, String? feedback})>[];
        await host(
          tester,
          structure,
          locale,
          Scaffold(
            body: DirectorDecisionViewport(
              maxHeight: 260,
              child: DirectorApprovalBanner(
                prompt: const AgentApprovalPrompt(
                  toolName: 'update_facts',
                  summary: _name,
                ),
                timeout: const Duration(minutes: 5),
                showIntro: true,
                onResolve: ({required allow, always = false, feedback}) =>
                    decisions.add(
                  (allow: allow, always: always, feedback: feedback),
                ),
              ),
            ),
          ),
        );
        // 2026-10-15 批 C（P1）：共用批注区——拒绝一步直达，
        // 批注框内容即拒绝留言（旧两步「拒绝并留言」流程退役）
        for (final label in [
          t.advanced.approval.alwaysAllow,
          t.advanced.approval.allow,
        ]) {
          await tester.ensureVisible(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
        }
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(t.advanced.approval.deny));
        await tester.tap(find.text(t.advanced.approval.deny));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(t.advanced.approval.commentEntry));
        await tester.tap(find.text(t.advanced.approval.commentEntry));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Keep the original fact.',
        );
        await tester.ensureVisible(find.text(t.advanced.approval.deny));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.advanced.approval.deny));
        expect(decisions, [
          (allow: true, always: true, feedback: null),
          (allow: true, always: false, feedback: null),
          (allow: false, always: false, feedback: null),
          (allow: false, always: false, feedback: 'Keep the original fact.'),
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
          '$variant director question retains options and free-text submission',
          (tester) async {
        final answers = <String>[];
        await host(
          tester,
          structure,
          locale,
          Scaffold(
            body: DirectorDecisionViewport(
              maxHeight: 260,
              child: DirectorAskBanner(
                prompt: const AgentAskPrompt(
                  question: _name,
                  options: ['Wait by the harbor.'],
                ),
                onAnswer: answers.add,
                onSkip: () {},
                showIntro: true,
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.text('Wait by the harbor.'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Wait by the harbor.'));
        await tester.enterText(find.byType(TextField), 'Read the archive.');
        await tester.ensureVisible(find.byTooltip(t.common.confirm));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(t.common.confirm));
        expect(answers, ['Wait by the harbor.', 'Read the archive.']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$variant message actions fit a narrow reading column',
          (tester) async {
        final calls = <String>[];
        await host(
          tester,
          structure,
          locale,
          Scaffold(
            body: SizedBox(
              width: 200,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IntermediateMessageActions(
                    isUser: false,
                    canOperate: true,
                    windowRounds: 5,
                    onCopy: () => calls.add('story-copy'),
                    onRegenerate: () => calls.add('story-retry'),
                    onEdit: () => calls.add('story-edit'),
                    onDeleteRound: () => calls.add('story-delete'),
                  ),
                  BubbleMessageActions(
                    isUser: false,
                    messageContent: 'Opening',
                    alwaysVisible: true,
                    onCopy: () => calls.add('chat-copy'),
                    onQuote: () => calls.add('chat-quote'),
                    onEdit: () => calls.add('chat-edit'),
                    onDelete: () => calls.add('chat-delete'),
                    onRegenerate: () => calls.add('chat-retry'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester
            .tap(find.byTooltip(t.intermediate.chat.messageActions.copy).first);
        await tester
            .tap(find.byTooltip(t.intermediate.chat.messageActions.edit).first);
        expect(calls, ['story-copy', 'story-edit']);
        expect(tester.takeException(), isNull);
      });
      testWidgets(
          '$variant message editor keeps both save actions reachable with a keyboard',
          (tester) async {
        MessageEditResult? result;
        final launcher = Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _open,
              onPressed: () async {
                result = await MessageEditDialog.show(
                  context,
                  messageId: 'message',
                  initialContent: _longText,
                );
              },
              child: const Text('Open'),
            ),
          ),
        );
        await host(tester, structure, locale, launcher, keyboard: 230);
        for (final resend in [false, true]) {
          await tester.tap(find.byKey(_open));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField),
            'Edited opening. 修改后的开场。',
          );
          await tester.pump();
          final save = find.text(resend ? t.chat.saveAndResend : t.common.save);
          expect(tester.getRect(save).bottom, lessThan(740 - 230));
          expect(tester.takeException(), isNull);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(result?.messageId, 'message');
          expect(result?.content, 'Edited opening. 修改后的开场。');
          expect(result?.saveAndResend, resend);
        }
      });

      testWidgets(
          '$variant prompt editor saves the complete text with wrapping controls',
          (tester) async {
        final settings = _Settings();
        await host(
          tester,
          structure,
          locale,
          IntermediatePromptEditorPage(meta: promptFieldMetas.first),
          settings: settings,
        );
        final edited =
            List.filled(12, 'The full edited prompt. 完整提示词。').join('\n');
        await tester.enterText(find.byType(TextField), edited);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(ElevatedButton),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await Scrollable.ensureVisible(
          tester.element(find.byType(ElevatedButton)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
        expect(settings.saved, edited);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$variant preview keeps all stages and the tool definition readable',
          (tester) async {
        await host(
          tester,
          structure,
          locale,
          const IntermediatePromptPreviewPage(),
        );
        final extract = find.text(t.settings.intermediate.preview.extractTab);
        await tester.ensureVisible(extract);
        await tester.tap(extract);
        await tester.pumpAndSettle();
        final definition =
            find.text(t.settings.intermediate.preview.showToolDefinition);
        await tester.scrollUntilVisible(
          definition,
          200,
          scrollable: find
              .descendant(
                of: find.byType(TabBarView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(definition);
        await tester.pumpAndSettle();
        expect(
          find.text(t.settings.intermediate.preview.hideToolDefinition),
          findsOneWidget,
        );
        expect(find.byType(SelectableText), findsWidgets);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$variant director diagnostic header and controls can scroll on narrow screens',
          (tester) async {
        final loop = _Loop();
        await host(
          tester,
          structure,
          locale,
          const AgentLoopDiagnosticsPage(),
          loop: loop,
        );
        final run = find.text(t.settings.diagnostics.agentLoop.run);
        await tester.scrollUntilVisible(
          run,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(run);
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.settings.diagnostics.agentLoop.cancel));
        await tester.pumpAndSettle();
        expect(loop.runs, 1);
        expect(loop.cancels, 1);
        await tester.scrollUntilVisible(
          find.text(t.settings.diagnostics.agentLoop.sessionAggregate),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$variant round details retain lazy loading and full response text',
          (tester) async {
        final container = await host(
          tester,
          structure,
          locale,
          const AgentRoundTracePage(sessionId: 's', turnNumber: 1),
        );
        await tester.scrollUntilVisible(
          find.byType(ExpansionTile),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byType(ExpansionTile));
        await tester.pumpAndSettle();
        final controller = container.read(
          agentRoundTraceControllerProvider((sessionId: 's', turnNumber: 1))
              .notifier,
        ) as _Trace;
        expect(controller.detailsLoaded, 1);
        expect(find.text(_longText), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$variant resources keep content and deletion confirmation available',
          (tester) async {
        final resources = _Resources();
        await host(
          tester,
          structure,
          locale,
          const ResourceLibraryPage(),
          resources: resources,
        );
        await tester.scrollUntilVisible(
          find.text(_name),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(_name));
        await tester.pumpAndSettle();
        expect(find.text(_name), findsWidgets);
        await tester.tap(find.byTooltip(t.common.close));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(t.common.delete).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.common.cancel));
        await tester.pumpAndSettle();
        expect(resources.deletions, 0);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$variant suggestion states retain complete text and selection',
          (tester) async {
        int? selected;
        var retries = 0;
        Widget overlay({bool failed = false, bool generating = false}) =>
            Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Material(
                  child: SuggestReplyOverlay(
                    replies: failed || generating
                        ? const []
                        : [_longText, 'Wait by the harbor.'],
                    isGenerating: generating,
                    isExpanded: true,
                    isFailed: failed,
                    onSelect: (index) => selected = index,
                    onClose: () {},
                    onToggle: () {},
                    onRetry: () async {
                      retries++;
                      return true;
                    },
                  ),
                ),
              ),
            );
        await host(tester, structure, locale, overlay(), reduced: true);
        expect(find.text(_longText), findsOneWidget);
        final candidates = find.descendant(
          of: find.byType(SuggestReplyOverlay),
          matching: find.byType(Scrollable),
        );
        await tester.drag(candidates.first, const Offset(0, -300));
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getRect(candidates.first).center);
        expect(selected, 0);
        await host(
          tester,
          structure,
          locale,
          overlay(failed: true),
          reduced: true,
        );
        await tester.tap(find.text(t.intermediate.chat.suggestReply.retry));
        await tester.pumpAndSettle();
        expect(retries, 1);
        await host(
          tester,
          structure,
          locale,
          overlay(generating: true),
          reduced: true,
          settle: false,
        );
        expect(
          find.text(t.intermediate.chat.suggestReply.generating),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final locale in [AppLocale.zhCn, AppLocale.enUs]) {
    testWidgets('${locale.languageCode} normal-size creative page previews',
        (tester) async {
      final pages = <String, Widget>{
        'director-approval': Scaffold(
          body: SingleChildScrollView(
            child: DirectorApprovalBanner(
              prompt: const AgentApprovalPrompt(
                toolName: 'update_facts',
                summary: 'The harbor keeper opens the old archive. 修订守港人的经历。',
              ),
              timeout: const Duration(minutes: 5),
              showIntro: true,
              onResolve: ({required allow, always = false, feedback}) {},
            ),
          ),
        ),
        'director-question': Scaffold(
          body: SingleChildScrollView(
            child: DirectorAskBanner(
              prompt: const AgentAskPrompt(
                question:
                    'Which path will you take into the harbor? 你从哪条路进入港口？',
                options: [
                  'Follow the lights / 循着灯火',
                  'Wait for the courier / 等候信使',
                ],
              ),
              onAnswer: (_) {},
              onSkip: () {},
              showIntro: true,
            ),
          ),
        ),
        'suggestions': Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              child: SuggestReplyOverlay(
                replies: const [
                  'I open the archive and look for the courier. 我打开档案，寻找信使的行踪。',
                  'I wait by the harbor. 我在港口等候。',
                ],
                isGenerating: false,
                isExpanded: true,
                onSelect: (_) {},
                onClose: () {},
                onToggle: () {},
              ),
            ),
          ),
        ),
        'prompt-editor':
            IntermediatePromptEditorPage(meta: promptFieldMetas.first),
        'prompt-preview': const IntermediatePromptPreviewPage(),
        'director-loop': const AgentLoopDiagnosticsPage(),
        'director-round':
            const AgentRoundTracePage(sessionId: 's', turnNumber: 1),
        'director-entry': const AgentRoundTraceEntryPage(),
        'resources': const ResourceLibraryPage(),
      };
      for (final entry in pages.entries) {
        await host(
          tester,
          'classic',
          locale,
          entry.value,
          size: const Size(390, 844),
          scale: 1,
        );
        await _capture(tester, '${entry.key}-${locale.languageCode}');
        expect(tester.takeException(), isNull);
      }
      await host(
        tester,
        'classic',
        locale,
        const ResourceLibraryPage(),
        size: const Size(1024, 768),
        scale: 1,
      );
      await _capture(tester, 'resources-tablet-${locale.languageCode}');
      await host(
        tester,
        'classic',
        locale,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _open,
              onPressed: () => MessageEditDialog.show(
                context,
                messageId: 'm',
                initialContent: _longText,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
        size: const Size(390, 844),
        scale: 1,
      );
      await tester.tap(find.byKey(_open));
      await tester.pumpAndSettle();
      await _capture(tester, 'message-editor-${locale.languageCode}');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'dirty message back navigation keeps edits until discard is confirmed',
      (tester) async {
    await host(
      tester,
      'classic',
      AppLocale.enUs,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _open,
            onPressed: () => MessageEditDialog.show(
              context,
              messageId: 'm',
              initialContent: 'Opening',
            ),
            child: const Text('Open'),
          ),
        ),
      ),
      scale: 1,
    );
    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Edited opening');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(t.chat.unsavedChanges), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, t.common.cancel).last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Edited opening',
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['LMSTORY_VISUAL_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_preview));
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

class _Tokens extends TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length ~/ 3;
  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((text) => text.length ~/ 3).toList();
}

class _Settings implements SettingsRepository {
  String? saved;
  @override
  Future<void> setUserOverride(String key, dynamic value) async =>
      saved = value as String;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Resources implements ResourceLibraryRepository {
  int deletions = 0;
  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => [
        CharacterCard(
          cardId: 'a',
          name: _name,
          rawJson: '{"name":"Harbor","description":"An archive keeper."}',
          sourceFormat: 'json',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        CharacterCard(
          cardId: 'b',
          name: 'The Night Courier',
          rawJson: '{}',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
  @override
  Future<List<Worldbook>> getAllWorldbooks() async => [
        Worldbook(
          bookId: 'w',
          name: 'A Harbor That Remembers / 记得来路的港口',
          rawJson: '{"entries":[]}',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
  @override
  Future<void> deleteCharacterCard(String id) async => deletions++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chat implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => [
        ChatSession(
          sessionId: 'session-archive',
          messageCount: 10,
          title: _name,
          mode: 'advanced',
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Log implements AgentEventLogStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Trace extends AgentRoundTraceController {
  _Trace() : super(repository: _Log(), sessionId: 's', turnNumber: 1);
  int detailsLoaded = 0;
  @override
  Future<void> load() async {
    state = AgentRoundTraceState(
      isLoading: false,
      summary: const AgentTurnTraceSummary(
        turnNumber: 1,
        reason: 'completedByTool',
        steps: 1,
        promptTokens: 1024,
        completionTokens: 512,
        totalTokens: 1536,
        durationMs: 1200,
      ),
      steps: const [
        AgentStepTrace(
          stepIndex: 0,
          beginMs: 0,
          endMs: 1200,
          toolCalls: [],
          tools: [],
        ),
      ],
      stepDetails: {
        0: AgentStepTraceDetail(
          requestMessages: const [],
          responseText: _longText,
          toolResults: const [],
        ),
      },
    );
  }

  @override
  Future<void> loadStepDetail(int stepIndex) async => detailsLoaded++;
}

class _Resolver implements ConfigurationResolver {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Presets implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Gateway implements AgentLlmGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Loop extends AgentLoopDiagnosticsController {
  _Loop()
      : super(
          configurationResolver: _Resolver(),
          presetRepository: _Presets(),
          apiKeyLookup: (_) async => '',
          gateway: _Gateway(),
        ) {
    state = const AgentLoopDiagnosticsState(
      modelLabel: _name,
      summary: '1 turn · 3 steps · 1536 tokens',
      entries: [
        AgentDiagnosticEntry(
          kind: 'tool',
          text: 'Archive search completed',
          detail: 'search_story({"query":"harbor"}) → 2 records',
        ),
        AgentDiagnosticEntry(kind: 'result', text: 'Turn completed'),
      ],
    );
  }
  int runs = 0;
  int cancels = 0;
  @override
  Future<void> load() async {}
  @override
  Future<void> run() async {
    runs++;
    state = state.copyWith(isRunning: true);
  }

  @override
  void cancel() {
    cancels++;
    state = state.copyWith(isRunning: false);
  }
}
