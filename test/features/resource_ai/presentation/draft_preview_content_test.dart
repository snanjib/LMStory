import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/draft_preview_content.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// 直接 pump 组件（预览内容本身不自持滚动，测试内套滚动容器模拟真实
  /// 嵌入场景，同时避免长内容在测试视口溢出）。
  Widget wrap(DraftState? draft) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DraftPreviewContent(draft: draft)),
        ),
      ),
    );
  }

  testWidgets('卡草稿分字段区块渲染：本地化标签 + 不渲染 rawJson 原文', (tester) async {
    final draft = DraftState.empty(DraftKind.characterCard).withCard(
      const CardDraft(
        fields: {CardField.name: '阿尔', CardField.description: '一位剑客'},
      ),
    );
    await tester.pumpWidget(wrap(draft));

    expect(find.text('角色卡字段'), findsOneWidget);
    expect(find.text('阿尔'), findsOneWidget);
    expect(find.text('一位剑客'), findsOneWidget);
    // 标签走本地化文案，不再是 jsonName
    expect(find.text('角色名'), findsOneWidget);
    expect(find.text('描述'), findsOneWidget);
    expect(find.text('name'), findsNothing);
    expect(find.text('description'), findsNothing);
    // 不渲染 JSON 原文（无 spec/chara_card_v2 等 JSON 痕迹）
    expect(find.textContaining('chara_card_v2'), findsNothing);
    expect(find.textContaining('{"'), findsNothing);
  });

  testWidgets('长文本字段用 markdown 渲染，name 用纯文本', (tester) async {
    final draft = DraftState.empty(DraftKind.characterCard).withCard(
      const CardDraft(
        fields: {
          CardField.name: '阿尔',
          CardField.description: '- 一位剑客\n- 沉默寡言',
        },
      ),
    );
    await tester.pumpWidget(wrap(draft));

    // description 是长文本字段 → markdown；name → 纯 Text
    expect(find.byType(SimpleMarkdownBody), findsOneWidget);
    expect(find.text('一位剑客'), findsOneWidget);
  });

  testWidgets('标签区块：tags 以顿号拼接纯文本渲染', (tester) async {
    final draft = DraftState.empty(DraftKind.characterCard).withCard(
      const CardDraft(tags: ['奇幻', '剑客']),
    );
    await tester.pumpWidget(wrap(draft));

    expect(find.text('标签'), findsOneWidget);
    expect(find.text('奇幻、剑客'), findsOneWidget);
  });

  testWidgets('书草稿渲染词条卡片与常驻/触发/停用标记', (tester) async {
    final draft = DraftState.empty(DraftKind.worldbook).withBook(
      const WorldbookDraft(
        name: '剑的世界',
        description: '一个关于剑的世界',
        entries: [
          WorldEntry(
            id: 'e1',
            keys: ['古剑'],
            comment: '主线道具',
            content: '一柄古剑',
            constant: true,
          ),
          WorldEntry(id: 'e2', keys: ['x'], content: 'c2', enabled: false),
        ],
      ),
    );
    await tester.pumpWidget(wrap(draft));

    expect(find.text('世界书词条（2）'), findsOneWidget);
    expect(find.text('世界书名称'), findsOneWidget);
    expect(find.text('剑的世界'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('一个关于剑的世界'), findsOneWidget);
    expect(find.text('主线道具'), findsOneWidget);
    expect(find.text('古剑'), findsWidgets);
    expect(find.text('一柄古剑'), findsOneWidget);
    expect(find.text('常驻'), findsOneWidget);
    expect(find.text('触发'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
  });

  testWidgets('空草稿（null / 未动笔）显示引导文案', (tester) async {
    await tester.pumpWidget(wrap(null));
    expect(find.textContaining('草稿还是空的'), findsOneWidget);

    await tester.pumpWidget(wrap(DraftState.empty(DraftKind.characterCard)));
    expect(find.textContaining('草稿还是空的'), findsOneWidget);
  });
}
