import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_content.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_structure.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart'
    show LmAppearance, ThemeCatalog;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// 玻璃交付缺陷守卫（2026-09-20 真机反馈三缺陷的回归锁）：
/// 1) 用户气泡文字=onPrimary（波尔多夜 primary 为浅酒粉，硬编码白不可读）；
/// 2) 抽屉主题：透明面板底 + 酒色 scrim（默认黑54 在暗页上呈死灰）；
/// 3) 全局场地接线：main.dart 的 MaterialApp builder 必须挂场地壳，
///    防止根导航推入的透明底页面再次失去幕布（日间渲染为黑）。
void main() {
  ChatMessage userMessage() => ChatMessage(
        messageId: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '夜航氛围描写',
        createdAt: DateTime(2026),
      );

  testWidgets('用户气泡（气泡模式）文字=onPrimary，双配色均不得为硬编码 Colors.white', (tester) async {
    final night = const BordeauxPaletteFamily().of(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
          Brightness.dark,
        ),
        home: Scaffold(
          body: BubbleMessageContent(
            message: userMessage(),
            isStreaming: false,
            isThinking: false,
            isUser: true,
            isSummary: false,
            colors: night,
          ),
        ),
      ),
    );

    final text = tester.widget<SelectableText>(
      find.descendant(
        of: find.byType(BubbleMessageContent),
        matching: find.byType(SelectableText),
      ),
    );
    final color = text.style!.color;
    expect(color, night.onPrimary, reason: '用户气泡文字必须随配色 onPrimary');
    expect(color, isNot(Colors.white), reason: '夜 primary 为浅色，白字不可读');

    // 日间档同断言（酒药丸+浅字）
    // ignore: prefer_const_declarations
    final day = const BordeauxPaletteFamily().of(Brightness.light);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
          Brightness.light,
        ),
        home: Scaffold(
          body: BubbleMessageContent(
            message: userMessage(),
            isStreaming: false,
            isThinking: false,
            isUser: true,
            isSummary: false,
            colors: day,
          ),
        ),
      ),
    );
    final dayText = tester.widget<SelectableText>(
      find.descendant(
        of: find.byType(BubbleMessageContent),
        matching: find.byType(SelectableText),
      ),
    );
    expect(dayText.style!.color, day.onPrimary);
  });

  test('抽屉主题：面板透明底 + scrim=配色 scrim（酒色，非默认黑54）', () {
    for (final brightness in Brightness.values) {
      final palette = const BordeauxPaletteFamily().of(brightness);
      final theme = const GlassStructure().assemble(palette, brightness);
      final drawerTheme = theme.drawerTheme;
      expect(
        drawerTheme.backgroundColor,
        Colors.transparent,
        reason: '面板底须透明（场地/内容由面板自绘）',
      );
      expect(
        drawerTheme.scrimColor,
        palette.scrim,
        reason: 'scrim 用配色 scrim（酒色），默认黑54 在暗页上呈死灰',
      );
    }
  });

  test('全局场地接线：main.dart 的 MaterialApp builder 挂场地壳（防拆线）', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('_GlassVenueShell'), reason: '场地壳组件消失？');
    expect(
      source,
      contains('builder: (context, child) =>'),
      reason: 'builder 接线消失？',
    );
    // 场地壳必须走主题接口（Classic 结构不受影响）。
    expect(source, contains('context.lmVenue('), reason: '场地接口调用消失？');
  });
}
