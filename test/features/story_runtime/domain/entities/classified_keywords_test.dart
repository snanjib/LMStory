import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';

void main() {
  group('ClassifiedKeywords', () {
    test('5 类字段默认为空列表', () {
      const kw = ClassifiedKeywords();
      expect(kw.characters, isEmpty);
      expect(kw.items, isEmpty);
      expect(kw.locations, isEmpty);
      expect(kw.actions, isEmpty);
      expect(kw.plots, isEmpty);
    });

    test('entityTerms 合并 characters + items + locations（FTS5 通道）', () {
      const kw = ClassifiedKeywords(
        characters: ['李逍遥'],
        items: ['七星剑'],
        locations: ['蜀山'],
        actions: ['斩妖'],
        plots: ['灵儿被掳'],
      );
      expect(kw.entityTerms, ['李逍遥', '七星剑', '蜀山']);
    });

    test('eventTerms 合并 actions + plots（Vector 通道）', () {
      const kw = ClassifiedKeywords(
        actions: ['斩妖', '寻人'],
        plots: ['灵儿被掳'],
      );
      expect(kw.eventTerms, ['斩妖', '寻人', '灵儿被掳']);
    });

    test('flatten 合并全部 5 类', () {
      const kw = ClassifiedKeywords(
        characters: ['李逍遥'],
        items: ['七星剑'],
        locations: ['蜀山'],
        actions: ['斩妖'],
        plots: ['灵儿被掳'],
      );
      expect(kw.flatten().length, 5);
    });

    test('isEmpty 当全部 5 类为空时返回 true', () {
      const kw = ClassifiedKeywords();
      expect(kw.isEmpty, isTrue);
    });

    test('length 返回全部 5 类总长度', () {
      const kw = ClassifiedKeywords(
        characters: ['a', 'b'],
        items: ['c'],
        actions: ['d', 'e', 'f'],
      );
      expect(kw.length, 6);
    });
  });
}
