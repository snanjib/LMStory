import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_readable_color.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_thinking_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/load_app_fonts.dart';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    if (Platform.environment['LMSTORY_CAPTURE_UI'] == '1') {
      await loadAppFonts(withSystemCjkFallback: true);
      final cjkFile = File('/System/Library/Fonts/Hiragino Sans GB.ttc');
      if (cjkFile.existsSync()) {
        final bytes = cjkFile.readAsBytesSync();
        for (final family in ['Roboto', 'Microsoft YaHei']) {
          await (FontLoader(family)
                ..addFont(Future.value(ByteData.sublistView(bytes))))
              .load();
        }
      }
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
  });
  Widget wrap(
    Widget child, {
    LmAppearance appearance = ThemeCatalog.defaults,
    Brightness brightness = Brightness.dark,
    double scale = 1,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(appearance, brightness),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(420, 800),
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('capture'),
                child: ColoredBox(
                  color: ThemeCatalog.assemble(appearance, brightness)
                      .extension<LmTokens>()!
                      .palette
                      .bg,
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      DefaultTextStyle(
                        style: const TextStyle(
                          fontFamilyFallback: ['LMSerifSC'],
                        ),
                        child: child,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('活跃思考仅预览末三视觉行，结束后完全折叠', (tester) async {
    final content = List.generate(100, (i) => '第$i段没有换行的中文思考').join();
    await tester.pumpWidget(
      wrap(DirectorThinkingBlock(content: content, active: true), scale: 2),
    );
    await tester.pump();
    expect(find.byType(ThinkingTailPreview), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    final height = tester.getSize(find.byType(ThinkingTailPreview)).height;
    expect(height, lessThan(150));
    await tester
        .pumpWidget(wrap(DirectorThinkingBlock(content: content), scale: 2));
    expect(find.byType(ThinkingTailPreview), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('展开限高并保留手动阅读状态到完成', (tester) async {
    final content = List.generate(200, (i) => '思考第$i段\n').join();
    await tester.pumpWidget(
      wrap(DirectorThinkingBlock(content: content, active: true)),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.getSize(find.byType(SingleChildScrollView).first).height,
      lessThanOrEqualTo(240),
    );
    await tester
        .pumpWidget(wrap(DirectorThinkingBlock(content: '$content\n结束')));
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(ThinkingTailPreview), findsNothing);
  });

  testWidgets('整组收起仍显示活跃尾部，下一步等待时撤下', (tester) async {
    const timeline = [
      AgentTimelineBlock(
        kind: AgentTimelineKind.thinking,
        stepIndex: 0,
        text: '正在构思第一段\n正在构思第二段\n第三段\n第四段',
      ),
    ];
    await tester.pumpWidget(
      wrap(
        const DirectorWorkGroup(
          timeline: timeline,
          live: true,
          activity: AgentActivity.thinking,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pump();
    expect(find.byType(ThinkingTailPreview), findsOneWidget);
    await tester.pumpWidget(
      wrap(
        const DirectorWorkGroup(
          timeline: timeline,
          live: true,
          activity: AgentActivity.waitingResponse,
          activeStepIndex: 1,
        ),
      ),
    );
    expect(find.byType(ThinkingTailPreview), findsNothing);
    expect(find.text('等待模型响应…'), findsOneWidget);
  });

  for (final structure in ThemeCatalog.structures) {
    for (final palette in ThemeCatalog.palettes) {
      for (final brightness in Brightness.values) {
        testWidgets('${structure.id}/${palette.id}/${brightness.name} 思考层次与对比度',
            (tester) async {
          final appearance =
              LmAppearance(structureId: structure.id, paletteId: palette.id);
          final theme = ThemeCatalog.assemble(appearance, brightness);
          final colors = theme.extension<LmTokens>()!.palette;
          final text = directorReadableColor(colors);
          for (final bg in [colors.bg, colors.surface]) {
            final a = text.computeLuminance();
            final b = bg.computeLuminance();
            expect(
              a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05),
              greaterThanOrEqualTo(4.5),
            );
          }
          await tester.pumpWidget(
            wrap(
              const DirectorThinkingBlock(
                content: '正在核对人物的前情。\n接下来整理这一幕的因果。\n让角色的选择推动故事。',
                active: true,
              ),
              appearance: appearance,
              brightness: brightness,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          if (Platform.environment['LMSTORY_CAPTURE_UI'] == '1' &&
              structure.id == 'classic') {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final data =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              await File(
                '/private/tmp/lmstory-thinking-${palette.id}-${brightness.name}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }
}
