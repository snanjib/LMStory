import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/services/agent_style_lint.dart';

/// 完稿文风 lint 测试（体验重构  机检兜底层）
///
/// 验证各规则的命中/放行与反馈指令格式。
void main() {
  const lint = AgentStyleLint();

  group('AgentStyleLint 规则', () {
    test('1. 干净文本 → 通过', () {
      const text = '雨停了。他把伞收起来靠在门边。'
          '水顺着伞尖流成一小滩，映出门里那盏昏黄的灯。\n'
          '有人咳嗽了一声，很轻，像是从很远的地方传来。';
      expect(lint.lint(text).isClean, isTrue);
    });

    test('2. AI 高频词 → bannedWord', () {
      const text = '他的眼神彰显了岁月的沉淀。门开了，风灌进来。';
      final report = lint.lint(text);
      expect(report.violations.length, 2);
      expect(
        report.violations.every((v) => v.rule == 'bannedWord'),
        isTrue,
      );
    });

    test('3. 破折号 → emDash', () {
      const text = '他走了——没有回头。巷子很深，灯很暗。';
      expect(lint.lint(text).violations.first.rule, 'emDash');
    });

    test('4. 虚假对仗 → fakeContrast', () {
      const text = '他感到的不是恐惧，而是愤怒。握紧了拳头。指节发白。';
      final report = lint.lint(text);
      expect(
        report.violations.any((v) => v.rule == 'fakeContrast'),
        isTrue,
      );
    });

    test('5. 明喻堆积 → similePile', () {
      const text = '她仿佛看见了什么，宛如一扇门打开，犹如旧梦重来。'
          '他像是被钉在原地。风还在吹。';
      expect(
        lint.lint(text).violations.any((v) => v.rule == 'similePile'),
        isTrue,
      );
    });

    test('6. 开场客套 → opener', () {
      const text = '好的，我来续写。他推开门，雨还在下，屋里的灯没开。';
      expect(lint.lint(text).violations.first.rule, 'opener');
    });

    test('7. 句长方差过小 → sentenceVariance', () {
      // 8 个等长句（各 10 字），节奏单调
      final text = List.filled(
        8,
        '他慢慢地走过了那条长巷子。',
      ).join();
      expect(
        lint.lint(text).violations.any((v) => v.rule == 'sentenceVariance'),
        isTrue,
      );
    });

    test('8. 段落过长 → paragraphLength', () {
      final text = '风' * 500;
      expect(
        lint.lint(text).violations.any((v) => v.rule == 'paragraphLength'),
        isTrue,
      );
    });

    test('9. 空文本 → 通过（无正文不判）', () {
      expect(lint.lint('  ').isClean, isTrue);
    });

    test('10. 反馈指令：逐条列出且明确只改标记处', () {
      const text = '他彰显了沉淀——那一刻。';
      final feedback = lint.lint(text).buildFeedback();
      expect(feedback, contains('违反文风铁律'));
      expect(feedback, contains('[bannedWord]'));
      expect(feedback, contains('[emDash]'));
      expect(feedback, contains('只修正以上标记处'));
    });

    test('11. 翻案腔同族变体 → fakeContrast', () {
      const text = '与其说他懒，不如说他没上心。看似平静，实则暗流涌动。'
          '你以为他会拒绝，其实他一直在等。';
      final report = lint.lint(text);
      expect(
        report.violations.where((v) => v.rule == 'fakeContrast').length,
        3,
      );
    });

    test('12. 论述起手式 → opener', () {
      const text = '说白了，这件事没得谈。他推门进来，雨还下着。';
      expect(lint.lint(text).violations.first.rule, 'opener');
    });

    test('13. 无标点长段 → runNoPunctuation（长会话退化治理 S3）', () {
      // 68 字连跑无任何分隔符（按 [。！？] 分句只剩 1 句，方差检查全盲）
      const text = '他推开门走进屋里点起灯坐下又站起来走到窗边看着雨落下'
          '然后转身回到桌前翻开那本旧书一页一页地找着什么'
          '外面的雨还在下他一直没找到想找的那一页\n'
          '第二段正常。他坐下，喝水。';
      final report = lint.lint(text);
      final hits = report.violations.where((v) => v.rule == 'runNoPunctuation');
      expect(hits, hasLength(1));
      expect(hits.single.evidence, contains('第 1 段'));
      expect(hits.single.evidence, contains('无任何标点'));
      expect(hits.single.evidence, contains('断句'));
    });

    test('14. 对话体省略号与正常短段不误报', () {
      const text = '「你走吧……」她背过身去，肩膀在抖。\n'
          '「我……我只是想问一句。」\n'
          '雨停了，檐口还在滴水，一声，又一声。';
      expect(
        lint
            .lint(text)
            .violations
            .where((v) => v.rule == 'runNoPunctuation')
            .isEmpty,
        isTrue,
      );
    });

    test('15. 59 字连跑不命中、60 字命中（kNoPunctuationRunLimit 边界）', () {
      // 「他说」+ 58 走 = 60 字连跑（命中）；逗号后的 59 字连跑（不命中）
      final text = '他说${'走' * 58}，${'停' * 59}。';
      final hits = lint
          .lint(text)
          .violations
          .where((v) => v.rule == 'runNoPunctuation')
          .toList();
      expect(hits, hasLength(1));
      expect(hits.single.evidence, contains('第 1 段第 1 字起连续 60 字'));
    });

    test('16. 与既有检查共存：500 字无标点同段同时命中 paragraphLength', () {
      final text = '风' * 500;
      final rules = lint.lint(text).violations.map((v) => v.rule).toSet();
      expect(rules.contains('paragraphLength'), isTrue);
      expect(rules.contains('runNoPunctuation'), isTrue);
    });
  });
}
