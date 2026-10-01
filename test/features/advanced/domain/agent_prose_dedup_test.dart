import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/services/agent_prose_dedup.dart';

const _placeholder = '（草稿已并入稿件）';

String _prose([int len = 250]) => '雨停了，他把伞收起来，靠在门边。' * (len ~/ 14 + 1);

void main() {
  group('earlyMatch（L2 直播早折叠判定，§6.1）', () {
    test('prose 开头与 content 块前缀重合（空白差异容忍）→ 命中', () {
      final prose = _prose();
      final block = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: prose,
      );

      expect(AgentProseDedup.earlyMatch(prose, block), isTrue);
      // 归一化空白：块内多出的换行不破坏前缀比对
      final noisy = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: '${prose.substring(0, 100)}\n\n${prose.substring(100)}',
      );
      expect(AgentProseDedup.earlyMatch(prose, noisy), isTrue);
      // prose 开头不足 60 字（归一化后）不触发比对
      expect(
        AgentProseDedup.earlyMatch(prose.substring(0, 40), block),
        isFalse,
      );
    });

    test('前缀不重合 → 不命中', () {
      final block = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: '完全不同的开场白。${'内容' * 120}',
      );
      expect(
        AgentProseDedup.earlyMatch(_prose(), block),
        isFalse,
      );
    });

    test('思考块不参与比对', () {
      const thinking = AgentLiveBlock(
        kind: AgentLiveBlockKind.thinking,
        stepIndex: 0,
        text: '思考内容',
      );
      expect(AgentProseDedup.earlyMatch(_prose(), thinking), isFalse);
    });
  });

  group('earlyFold（L2 接线形态）', () {
    test('命中即把最近 content 块折叠为占位行，流块排除', () {
      final prose = _prose();
      final blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: prose,
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 1,
          text: '想想',
        ),
        // 当前流块（step1 正在追加的 prose 流头）——不得被折叠
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 1,
          text: prose.substring(0, 80),
        ),
      ];

      final folded = AgentProseDedup.earlyFold(
        blocks,
        prose,
        _placeholder,
        streamingStepIndex: 1,
      );

      expect(folded[0].text, _placeholder);
      expect(folded[1].text, '想想');
      expect(folded[2].text, prose.substring(0, 80), reason: '流本体保留，正文只在稿件卡出字');
    });

    test('无命中原样返回（同一列表实例）', () {
      const blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: '无关短播报',
        ),
      ];
      expect(
        AgentProseDedup.earlyFold(
          blocks,
          _prose(),
          _placeholder,
          streamingStepIndex: 1,
        ),
        same(blocks),
      );
    });
  });

  group('finalFold（L3 终局折叠，§6.2）', () {
    test('近拷贝命中：首/中/尾锚窗 + 长度比达标 → 折叠', () {
      final prose = _prose();
      final blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: prose, // 全量拷贝
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想想',
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 1,
          text: '正常播报一句话',
        ),
      ];

      final folded = AgentProseDedup.finalFold(prose, blocks, _placeholder);

      expect(folded[0].text, _placeholder);
      expect(folded[1].kind, AgentLiveBlockKind.thinking);
      expect(folded[2].text, '正常播报一句话', reason: '短播报不参与检测');
    });

    test('空白差异的近拷贝仍命中（锚窗归一化子串查找）', () {
      final prose = _prose();
      final noisy =
          '${prose.substring(0, 100)}\n\n${prose.substring(100, 200)}  ${prose.substring(200)}';
      final blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: noisy,
        ),
      ];

      expect(
        AgentProseDedup.finalFold(prose, blocks, _placeholder).first.text,
        _placeholder,
      );
    });

    test('部分复制不算：长度比超出 0.6~1.6 → 不折叠', () {
      final prose = _prose(300);
      final excerpt = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: prose.substring(0, 120), // 头部 40% 拷贝
      );
      final padded = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: '$prose${'膨胀的水文' * 100}', // 近两倍长度
      );

      final folded = AgentProseDedup.finalFold(
        prose,
        [excerpt, padded],
        _placeholder,
      );
      expect(folded[0].text, excerpt.text);
      expect(folded[1].text, padded.text);
    });

    test('锚窗全不命中（中段无关改写）→ 不折叠', () {
      final prose = _prose();
      final rewritten = '${prose.substring(0, 60)}这里被模型完全改写得面目全非无关原文'
          '${prose.substring(prose.length - 40)}';
      final blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: rewritten,
        ),
      ];

      final folded = AgentProseDedup.finalFold(prose, blocks, _placeholder);
      expect(folded.first.text, rewritten, reason: '残留当播报，不误伤');
    });

    test('多个命中块全部折叠；已折叠块不再命中（幂等）', () {
      final prose = _prose();
      final blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: prose,
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 1,
          text: prose,
        ),
      ];

      final folded = AgentProseDedup.finalFold(prose, blocks, _placeholder);
      expect(folded.every((b) => b.text == _placeholder), isTrue);

      final refolded = AgentProseDedup.finalFold(prose, folded, _placeholder);
      expect(refolded, same(folded));
    });

    test('prose 短于阈值或空 → 原样返回', () {
      const blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: '短文本',
        ),
      ];
      expect(
        AgentProseDedup.finalFold('', blocks, _placeholder),
        same(blocks),
      );
      expect(
        AgentProseDedup.finalFold(null, blocks, _placeholder),
        same(blocks),
      );
    });
  });
}
