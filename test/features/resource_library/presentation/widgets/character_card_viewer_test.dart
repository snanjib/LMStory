import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/resource_content_viewer.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 角色卡图形化查看器：
/// - V2 富字段全量渲染（身份/标签/场景/开场白/替代开场白/长文区）
/// - 空字段整区不渲染
/// - 未消费简单字段收进「其他字段」折叠组（默认收起）
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ParsedCharacterCard fullCard() => const ParsedCharacterCard(
        name: '苏明远',
        description: '身形清瘦的守碑人，常年在荒庙后山巡视。',
        personality: '沉静、执拗，对碑文有近乎信仰的执着。',
        specVersion: 'v2',
        scenario: '暮色中的荒庙，碑文在风里若隐若现。',
        firstMes: '你推开门时，他正俯身擦拭一块残碑。',
        alternateGreetings: ['雨夜来客。', '碑前重逢。'],
        mesExample: '<START>\n用户：这是什么时候的碑？',
        tags: ['东方玄幻', '守碑人'],
        creatorNotes: '灵感来自一场雨夜的梦。',
        systemPrompt: 'You are a stoic stone keeper.',
        creator: '山客',
        nickname: '小远',
        age: '27',
        extraFields: [
          CardExtraField(key: 'custom_field', value: '一个未消费的字段值'),
        ],
        embeddedEntries: [
          NormalizedWorldEntry(
            keys: ['古碑'],
            secondaryKeys: [],
            comment: '',
            content: '庙后残碑，刻着无人能识的文字。',
            constant: false,
            enabled: true,
            vectorized: false,
          ),
        ],
      );

  Future<void> pumpCard(WidgetTester tester, ParsedCharacterCard card) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              // palette 在 build 期取（pump 前上下文不存在）
              child: Builder(
                builder: (context) => CharacterCardViewer(
                  card: card,
                  colors: context.lm.palette,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('V2 富字段样卡：身份/标签/长文/替代开场白/内嵌词条全渲染', (tester) async {
    await pumpCard(tester, fullCard());

    // 身份区键值
    expect(find.text('苏明远'), findsOneWidget);
    expect(find.text('小远'), findsOneWidget);
    expect(find.text('27'), findsOneWidget);
    expect(find.text('山客'), findsOneWidget);
    // 标签 chip 流
    expect(find.text('东方玄幻'), findsOneWidget);
    expect(find.text('守碑人'), findsOneWidget);
    // 场景/开场白/长文区
    expect(find.textContaining('暮色中的荒庙'), findsWidgets);
    expect(find.textContaining('你推开门时'), findsWidgets);
    expect(find.textContaining('1. 雨夜来客。'), findsWidgets);
    expect(find.textContaining('2. 碑前重逢。'), findsWidgets);
    expect(find.textContaining('身形清瘦的守碑人'), findsWidgets);
    expect(find.textContaining('沉静、执拗'), findsWidgets);
    expect(find.textContaining('<START>'), findsWidgets);
    expect(find.textContaining('灵感来自一场雨夜的梦'), findsWidgets);
    // 内嵌词条
    expect(find.textContaining('庙后残碑'), findsWidgets);
    // 其他字段折叠组在（默认收起，值不可见）
    expect(find.text('其他字段（1 个）'), findsOneWidget);
    expect(find.text('custom_field'), findsNothing);
  });

  testWidgets('空字段整区不渲染（最小卡：只有名字与描述）', (tester) async {
    await pumpCard(
      tester,
      const ParsedCharacterCard(
        name: '无名者',
        description: '只有一段描述。',
        personality: '',
        specVersion: 'v1',
        embeddedEntries: [],
      ),
    );

    expect(find.text('无名者'), findsOneWidget);
    expect(find.text('只有一段描述。'), findsWidgets);
    // 空区不出现
    expect(find.text('标签'), findsNothing);
    expect(find.text('场景'), findsNothing);
    expect(find.text('开场白'), findsNothing);
    expect(find.text('对话示例'), findsNothing);
    expect(find.text('作者注'), findsNothing);
    expect(find.text('系统提示'), findsNothing);
    expect(find.textContaining('其他字段'), findsNothing);
    expect(find.textContaining('内嵌世界书词条'), findsNothing);
    // 昵称/年龄/作者行不渲染
    expect(find.text('昵称'), findsNothing);
    expect(find.text('年龄'), findsNothing);
    expect(find.text('作者'), findsNothing);
  });

  testWidgets('其他字段折叠组：展开后渲染键值行', (tester) async {
    await pumpCard(tester, fullCard());

    await tester.ensureVisible(find.text('其他字段（1 个）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他字段（1 个）'));
    await tester.pumpAndSettle();

    expect(find.text('custom_field'), findsOneWidget);
    expect(find.text('一个未消费的字段值'), findsOneWidget);
  });
}
