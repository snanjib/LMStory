import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_prompts.dart';

void main() {
  group('ResourceAiPrompts.build', () {
    test('冻结前缀四分区齐全', () {
      final p = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      expect(p, contains('# 角色'));
      expect(p, contains('## 工作法'));
      expect(p, contains('## 工具规范'));
      expect(p, contains('## 写作规范目录'));
      expect(p, contains('update_draft'));
      expect(p, contains('finalize_draft'));
    });

    test('两次构建逐字节相等（缓存前提）', () {
      final a = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      final b = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      expect(a, equals(b));
    });

    test('工作法含软阶段句式', () {
      final p = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      expect(p, contains('概念定位'));
      expect(p, contains('先定名'), reason: '工作法第二条：名字是字段锚，先定名防返工');
      expect(p, contains('字段骨架'));
      expect(p, contains('开场'));
      expect(p, contains('缺口'));
    });

    test('skill 目录含三个规范名', () {
      final p = ResourceAiPrompts.build(kind: DraftKind.worldbook);
      expect(p, contains('card-crafting'));
      expect(p, contains('worldbook-crafting'));
      expect(p, contains('card-editing'));
    });

    test('卡/书模式措辞不同', () {
      final card = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      final book = ResourceAiPrompts.build(kind: DraftKind.worldbook);
      expect(card, contains('角色卡'));
      expect(book, contains('世界书'));
      expect(card, isNot(book));
    });

    test('编辑模式追加目标摘要段且在冻结前缀之后', () {
      final fresh = ResourceAiPrompts.build(kind: DraftKind.characterCard);
      final editing = ResourceAiPrompts.build(
        kind: DraftKind.characterCard,
        targetSummary: '目标卡「阿尔」：一位流浪剑客，2 词条内嵌书',
      );
      expect(editing, contains('阿尔'));
      expect(editing, contains('目标'));
      // 冻结前缀保持不变：编辑版以新建版为前缀（追加尾部）
      expect(editing.startsWith(fresh), isTrue);
    });
  });

  group('模型输入信封注入（presentation 中文字面量门禁的迁移目标）', () {
    test('编辑目标原文注入：标题行 + 原文', () {
      expect(
        buildEditTargetInjection('{"name":"阿尔"}'),
        '【编辑目标原文 JSON】\n{"name":"阿尔"}',
      );
    });

    test('附件参考材料注入：材料名 + 内容', () {
      expect(
        buildReferenceInjection('设定集.md', '剑客出身'),
        '【参考材料：设定集.md】\n剑客出身',
      );
    });
  });
}
