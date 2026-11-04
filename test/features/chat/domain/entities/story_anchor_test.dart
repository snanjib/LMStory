import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';

/// 剧情锚实体测试（体验重构卡片 C）
void main() {
  group('StoryAnchor', () {
    test('1. 序列化往返：字段精确匹配', () {
      const anchor = StoryAnchor(
        updatedTurn: 5,
        arc: '古碑遗迹的真相',
        foreshadows: [
          AnchorForeshadow(text: '守碑人的身份'),
          AnchorForeshadow(text: '左手的旧伤', resolved: true),
        ],
        narrativeTime: '第三天黄昏',
        oneLiner: '主角进入古碑遗迹',
      );

      final restored = StoryAnchor.parse(StoryAnchor.stringify(anchor));

      expect(restored, isNotNull);
      expect(restored!.arc, '古碑遗迹的真相');
      expect(restored.narrativeTime, '第三天黄昏');
      expect(restored.oneLiner, '主角进入古碑遗迹');
      expect(restored.updatedTurn, 5);
      expect(restored.foreshadows.length, 2);
      expect(restored.foreshadows[0].text, '守碑人的身份');
      expect(restored.foreshadows[0].resolved, isFalse);
      expect(restored.foreshadows[1].resolved, isTrue);
    });

    test('2. openForeshadows 只含未兑现', () {
      const anchor = StoryAnchor(
        updatedTurn: 1,
        foreshadows: [
          AnchorForeshadow(text: 'a'),
          AnchorForeshadow(text: 'b', resolved: true),
          AnchorForeshadow(text: 'c'),
        ],
      );
      expect(anchor.openForeshadows.map((f) => f.text), ['a', 'c']);
    });

    test('3. isEmpty：全空为 true，任一有值为 false', () {
      expect(const StoryAnchor(updatedTurn: 1).isEmpty, isTrue);
      expect(
        const StoryAnchor(updatedTurn: 1, arc: '弧线').isEmpty,
        isFalse,
      );
      expect(
        const StoryAnchor(
          updatedTurn: 1,
          foreshadows: [AnchorForeshadow(text: '伏笔')],
        ).isEmpty,
        isFalse,
      );
    });

    test('4. parse 防御性：null/空/非法 JSON/空锚返回 null', () {
      expect(StoryAnchor.parse(null), isNull);
      expect(StoryAnchor.parse(''), isNull);
      expect(StoryAnchor.parse('not-json'), isNull);
      expect(StoryAnchor.parse('[]'), isNull);
      expect(StoryAnchor.parse('{"updatedTurn":1}'), isNull); // 空锚
    });

    test('5. stringify 空锚返回 null', () {
      expect(StoryAnchor.stringify(null), isNull);
      expect(
        StoryAnchor.stringify(const StoryAnchor(updatedTurn: 1)),
        isNull,
      );
    });

    test('6. copyWith 部分更新语义：null 保留旧值', () {
      const base = StoryAnchor(
        updatedTurn: 2,
        arc: '旧弧线',
        oneLiner: '旧进展',
      );
      final updated = base.copyWith(arc: '新弧线', updatedTurn: 3);

      expect(updated.arc, '新弧线');
      expect(updated.oneLiner, '旧进展');
      expect(updated.updatedTurn, 3);
    });
  });
}
