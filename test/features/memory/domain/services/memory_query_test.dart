import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';

/// 记忆检索查询规范化单测
///
/// 覆盖审查确认的两类必然 miss：
/// - 多词/标点查询被当成整短语或"删标点粘连"（事实层 & 经历层）
/// - <3 rune 的中文短词在 trigram 通道恒不可召回（短词分流）
void main() {
  group('tokenize 切词', () {
    test('空格分隔的关键词列表逐词切分（不再整串当短语）', () {
      expect(
        MemoryQuery.tokenize('图书馆 值班员 禁书区'),
        ['图书馆', '值班员', '禁书区'],
      );
    });

    test('CJK 标点参与切分（不再删除并粘连）', () {
      expect(MemoryQuery.tokenize('林墨、剑冢'), ['林墨', '剑冢']);
      expect(MemoryQuery.tokenize('雨夜。旧宅；敲门'), ['雨夜', '旧宅', '敲门']);
      expect(MemoryQuery.tokenize('「荒庙」'), ['荒庙']);
    });

    test('中英标点与括号混合切分', () {
      expect(MemoryQuery.tokenize('林墨(主角)'), ['林墨', '主角']);
      expect(MemoryQuery.tokenize('林墨,剑冢; 荒庙/古碑'), [
        '林墨',
        '剑冢',
        '荒庙',
        '古碑',
      ]);
    });

    test('全空白 / 全标点 / null → 空列表（区分"缺检索词"）', () {
      expect(MemoryQuery.tokenize('   '), isEmpty);
      expect(MemoryQuery.tokenize('！！？。，'), isEmpty);
      expect(MemoryQuery.tokenize(null), isEmpty);
      expect(MemoryQuery.tokenize(''), isEmpty);
    });

    test('去重保序 + 条数上限', () {
      expect(MemoryQuery.tokenize('剑 剑 剑冢 剑'), ['剑', '剑冢']);
      expect(
        MemoryQuery.tokenize('a b c d e f g h i j', maxTerms: 3),
        hasLength(3),
      );
    });

    test('FTS5 语法字符被剔除（避免 MATCH 语法错误）', () {
      expect(MemoryQuery.tokenize('"旧书店"'), ['旧书店']);
      expect(MemoryQuery.tokenize('旧*书:店'), ['旧', '书', '店']);
    });

    test('tokenizeAll 合并多段查询并保序去重', () {
      expect(
        MemoryQuery.tokenizeAll(['林墨', '主角 林墨']),
        ['林墨', '主角'],
      );
      expect(MemoryQuery.tokenizeAll(['', null, '古碑']), ['古碑']);
    });
  });

  group('短词分流与 MATCH 表达式', () {
    test('isShortTerm：trigram 无法召回 <3 rune', () {
      expect(MemoryQuery.isShortTerm('老'), isTrue);
      expect(MemoryQuery.isShortTerm('老人'), isTrue);
      expect(MemoryQuery.isShortTerm('旧书店'), isFalse);
      expect(MemoryQuery.isShortTerm('a'), isTrue);
      expect(MemoryQuery.isShortTerm('abc'), isFalse);
    });

    test('buildMatchExpression：短词跳过、长词逐个引号 OR 连接', () {
      expect(
        MemoryQuery.buildMatchExpression(['老人', '旧书店', '密室']),
        '"旧书店"',
      );
      expect(
        MemoryQuery.buildMatchExpression(['旧书店', '禁书区']),
        '"旧书店" OR "禁书区"',
      );
      expect(MemoryQuery.buildMatchExpression(['老人']), isEmpty);
    });

    test('buildMatchExpression：内嵌引号转义为双引号', () {
      expect(
        MemoryQuery.buildMatchExpression(['a"b']),
        '"a""b"',
      );
    });
  });

  group('escapeLike', () {
    test(r'% _ \ 三个通配/转义字符均转义', () {
      expect(MemoryQuery.escapeLike('50%'), r'50\%');
      expect(MemoryQuery.escapeLike('a_b'), r'a\_b');
      expect(MemoryQuery.escapeLike(r'a\b'), r'a\\b');
      expect(MemoryQuery.escapeLike(r'100%_\'), r'100\%\_\\');
    });

    test('普通中文不改变', () {
      expect(MemoryQuery.escapeLike('旧书店'), '旧书店');
    });
  });
}
