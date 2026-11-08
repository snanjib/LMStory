import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_composer.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 世界观拼装引擎：骨架顺序（身份句→题材→文风→人称→用户补充）、
/// 未选不拼、自定义原样附加、产物不含输入格式约定。
void main() {
  const identity = '你是一位互动故事的叙述者，负责构建并驱动一个开放的世界。你绝不代用户说话、行动或做决定。';
  const xianxiaBlock =
      '这是一个东方修仙世界：灵气充盈，宗门林立，凡人可凭修炼问鼎长生。境界分明的修为体系、宗门恩怨、天材地宝与心魔劫数构成世界的运行逻辑。';
  const classicalBlock = '讲述风格古风雅韵：文白相间，用字考究，有说书人的从容，但不影响可读性。';
  const secondPersonBlock = '故事以第二人称讲述：主角就是『你』，描述你的所见所感与世界对你的回应。';
  const firstPersonBlock = '故事以第一人称讲述：由「我」来叙述，写「我」的所见所感与世界的回应。';

  WorldPromptTextSource texts() => const WorldPromptTextSource(
        identity: identity,
        genreBlocks: {'xianxia': xianxiaBlock, 'urban': '都市块'},
        styleBlocks: {'classical': classicalBlock},
        personBlocks: {
          WorldPerson.first: firstPersonBlock,
          WorldPerson.second: secondPersonBlock,
        },
        userSupplementPrefix: '用户补充：',
      );

  test('全默认（零选择零自定义）：只拼身份句（交给 AI 与组装器）', () {
    final output = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(),
      texts(),
    );
    expect(output, identity);
  });

  test('满选+自定义：按骨架顺序拼接，自定义原样附加', () {
    final output = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(
        genreId: 'xianxia',
        genreCustom: '主角是个失忆的镖师。',
        styleId: 'classical',
        person: WorldPerson.second,
      ),
      texts(),
    );
    expect(output, contains(identity));
    expect(output, contains(xianxiaBlock));
    expect(output, contains(classicalBlock));
    expect(output, contains(secondPersonBlock));
    expect(output, contains('用户补充：主角是个失忆的镖师。'));
    // 顺序：身份句 → 题材 → 文风 → 人称 → 补充
    expect(output.indexOf(identity), lessThan(output.indexOf(xianxiaBlock)));
    expect(
      output.indexOf(xianxiaBlock),
      lessThan(output.indexOf(classicalBlock)),
    );
    expect(
      output.indexOf(classicalBlock),
      lessThan(output.indexOf(secondPersonBlock)),
    );
    expect(
      output.indexOf(secondPersonBlock),
      lessThan(output.indexOf('用户补充：')),
    );
  });

  test('各维度独立选择：只拼所选块', () {
    final onlyStyle = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(styleId: 'classical'),
      texts(),
    );
    expect(onlyStyle, '$identity\n$classicalBlock');

    final onlyPerson = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(person: WorldPerson.first),
      texts(),
    );
    expect(onlyPerson, '$identity\n$firstPersonBlock');

    final onlyCustom = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(genreCustom: '  世界一句话  '),
      texts(),
    );
    expect(onlyCustom, '$identity\n用户补充：世界一句话');
  });

  test('未知选项 id 不拼（防脏数据带出多余块）', () {
    final output = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(genreId: 'not-exist'),
      texts(),
    );
    expect(output, identity);
  });

  for (final locale in AppLocale.values) {
    test('实际本地化文案在人称留空时不添加视角并保留用户设定：${locale.name}', () async {
      final blocks = (await locale.build()).directorWizard.rules.blocks;
      final source = WorldPromptTextSource(
        identity: blocks.identity,
        genreBlocks: {'altHistory': blocks.genre.altHistory},
        styleBlocks: {'plain': blocks.style.plain},
        personBlocks: {
          WorldPerson.first: blocks.person.first,
          WorldPerson.second: blocks.person.second,
          WorldPerson.third: blocks.person.third,
        },
        userSupplementPrefix: blocks.userSupplementPrefix,
      );
      final output = WorldPromptComposer.compose(
        const WorldQuestionnaireAnswers(
          genreId: 'altHistory',
          styleId: 'plain',
          genreCustom: '  A family of potters  ',
        ),
        source,
      );
      expect(output, contains('A family of potters'));
      expect(output, contains(blocks.genre.altHistory));
      expect(
        output,
        isNot(
          matches(
            '第[一二三]人称|全知|旁观|first.person|second.person|third.person|'
            'omniscient|observer|庙堂|江湖|court|jianghu',
          ),
        ),
      );
      for (final person in WorldPerson.values) {
        final specified = WorldPromptComposer.compose(
          WorldQuestionnaireAnswers(person: person),
          source,
        );
        expect(specified, contains(source.personBlocks[person]));
      }
    });
  }

  test('产物不含括号/引号输入约定（指引提及即可，不写入产物）', () {
    final output = WorldPromptComposer.compose(
      const WorldQuestionnaireAnswers(
        genreId: 'xianxia',
        styleId: 'classical',
        person: WorldPerson.second,
        genreCustom: '随便补点',
        styleCustom: '再补点',
      ),
      texts(),
    );
    expect(output, isNot(contains('括号')));
    expect(output, isNot(contains('引号')));
    expect(output, isNot(contains('动作')));
    expect(output, isNot(contains('输入格式')));
  });
}
