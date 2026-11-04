import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';

/// AgentLiveTranscript 分段纯函数单元测试（2026-08-23 直播分块重构）
///
/// 验证：
/// - 同 step 同类型增量追加进末块
/// - step 切换 / 类型切换新开块（跨 step 思考与正文不串行）
/// - pickReplyBlock 收割判据（explicitReply > ≥200 字块 > 末个非空块）
/// - joinedThinking 按序空行连接全部非空思考段
void main() {
  test('同一步的中间发言和正文分别追加，完整正文仅修正正文块', () {
    var blocks = AgentLiveTranscript.appendText([], 0, '我先查看前情。', order: 1);
    blocks = AgentLiveTranscript.appendText(
      blocks,
      0,
      '夜色沉',
      source: AgentTextSource.finishRoundProse,
      order: 2,
    );
    expect(blocks.map((b) => b.text), ['我先查看前情。', '夜色沉']);
    blocks = AgentLiveTranscript.replaceStepText(blocks, 0, '夜色沉下来。', order: 2);
    expect(blocks.map((b) => b.text), ['我先查看前情。', '夜色沉下来。']);
    expect(blocks.map((b) => b.order), [1, 2]);
    expect(AgentLiveTranscript.manuscriptIndex(blocks), 1);
    expect(blocks.first.isManuscript, isFalse);
  });

  test('未确认纯文本不升格，终态确认后保留原始顺序', () {
    final blocks = AgentLiveTranscript.appendText([], 0, '短篇正文', order: 3);
    expect(AgentLiveTranscript.manuscriptIndex(blocks), -1);
    final picked = AgentLiveTranscript.pickReplyBlock(blocks: blocks)!;
    final confirmed =
        AgentLiveTranscript.confirmFallback(blocks, picked.promotedIndex!);
    expect(AgentLiveTranscript.manuscriptIndex(confirmed), 0);
    expect(confirmed.single.order, 3);
  });

  group('AgentLiveTranscript', () {
    test('pickReplyBlock：explicitReply 最优先，promotedIndex 为 null', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '直播文本');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '另一段');

      final picked = AgentLiveTranscript.pickReplyBlock(
        explicitReply: '  经 prose 参数交付的正文  ',
        blocks: blocks,
      );

      expect(picked!.text, '经 prose 参数交付的正文');
      expect(picked.promotedIndex, isNull);
    });

    test('pickReplyBlock：无 explicit 时取最后一个 ≥200 字文本块（跳过更晚的短块）', () {
      final long = '风' * 250;
      var blocks = AgentLiveTranscript.appendText(const [], 0, long);
      blocks = AgentLiveTranscript.appendText(blocks, 1, '收尾过渡话');

      final picked = AgentLiveTranscript.pickReplyBlock(
        blocks: blocks,
      );

      expect(picked!.text, long);
      expect(picked.promotedIndex, 0);
    });

    test('pickReplyBlock：兜底最后一个非空文本块（allowShortText）', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '过渡');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '短正文');
      blocks = AgentLiveTranscript.appendThinking(blocks, 1, '思考');

      final picked = AgentLiveTranscript.pickReplyBlock(blocks: blocks);

      expect(picked!.text, '短正文');
      expect(picked.promotedIndex, 1);
    });

    test('pickReplyBlock：allowShortText=false 时空块文本块跳过（预算尾巴门槛）', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '风' * 250);
      blocks = AgentLiveTranscript.appendText(blocks, 1, '仅一句过渡');

      final picked = AgentLiveTranscript.pickReplyBlock(
        blocks: blocks,
        allowShortText: false,
      );

      // 短块不达标但前面有 ≥200 块 → 取达标块
      expect(picked!.text, '风' * 250);

      final none = AgentLiveTranscript.pickReplyBlock(
        blocks: [AgentLiveTranscript.appendText(const [], 0, '仅一句过渡').first],
        allowShortText: false,
      );
      expect(none, isNull);
    });

    test('pickReplyBlock：全空 → null（提交不变量的判定基础）', () {
      expect(
        AgentLiveTranscript.pickReplyBlock(blocks: const []),
        isNull,
      );
      expect(
        AgentLiveTranscript.pickReplyBlock(
          blocks: [
            const AgentLiveBlock(
              kind: AgentLiveBlockKind.thinking,
              stepIndex: 0,
              text: '只有思考',
            ),
          ],
        ),
        isNull,
      );
    });

    test('removeStep：清除指定 step 的全部块（其余 step 保留）', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, 'step0 文本');
      blocks = AgentLiveTranscript.appendThinking(blocks, 0, 'step0 思考');
      blocks = AgentLiveTranscript.appendText(blocks, 1, 'step1 文本');

      blocks = AgentLiveTranscript.removeStep(blocks, 0);

      expect(blocks, hasLength(1));
      expect(blocks.single.stepIndex, 1);
      expect(blocks.single.text, 'step1 文本');
    });

    test('removeStep：目标 step 无块时原样返回', () {
      const blocks = [
        AgentLiveBlock(kind: AgentLiveBlockKind.text, stepIndex: 3, text: 'x'),
      ];
      expect(AgentLiveTranscript.removeStep(blocks, 0), same(blocks));
    });

    test('同 step 同类型：追加进末块', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '第一');
      blocks = AgentLiveTranscript.appendText(blocks, 0, '段正文');

      expect(blocks, hasLength(1));
      expect(blocks.single.kind, AgentLiveBlockKind.text);
      expect(blocks.single.stepIndex, 0);
      expect(blocks.single.text, '第一段正文');
    });

    test('step 切换：新开一块，前段保留原文', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '过渡话术');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '正式');

      expect(blocks, hasLength(2));
      expect(blocks[0].text, '过渡话术');
      expect(blocks[1].text, '正式');
      expect(blocks[1].stepIndex, 1);
    });

    test('类型切换（思考→正文→思考）：交错成块不串行', () {
      var blocks = AgentLiveTranscript.appendThinking(const [], 0, '想A');
      blocks = AgentLiveTranscript.appendText(blocks, 0, '写B');
      // 新 step 又来思考：不再拼到「想A」后面
      blocks = AgentLiveTranscript.appendThinking(blocks, 1, '想C');

      expect(blocks, hasLength(3));
      expect(blocks[0].kind, AgentLiveBlockKind.thinking);
      expect(blocks[0].text, '想A');
      expect(blocks[1].kind, AgentLiveBlockKind.text);
      expect(blocks[2].kind, AgentLiveBlockKind.thinking);
      expect(blocks[2].text, '想C');
    });

    test('appendThinking 与 appendText 同规则互不干扰', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '文本');
      blocks = AgentLiveTranscript.appendThinking(blocks, 0, '思考');

      expect(blocks, hasLength(2));
      expect(blocks.last.text, '思考');
    });

    test('joinedThinking：按序空行连接非空思考段，跳过空白段', () {
      var blocks = AgentLiveTranscript.appendThinking(const [], 0, '第一段思路');
      blocks = AgentLiveTranscript.appendText(blocks, 0, '正文');
      blocks = AgentLiveTranscript.appendThinking(blocks, 1, '  ');
      blocks = AgentLiveTranscript.appendThinking(blocks, 2, '第二段思路');

      expect(
        AgentLiveTranscript.joinedThinking(blocks),
        '第一段思路\n\n第二段思路',
      );
    });

    test('joinedThinking：无思考时为空串', () {
      final blocks = AgentLiveTranscript.appendText(const [], 0, '纯正文');

      expect(AgentLiveTranscript.joinedThinking(blocks), isEmpty);
    });

    test('isEmpty：仅含空白的文本段视为空', () {
      const block = AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 0,
        text: '  \n',
      );

      expect(block.isEmpty, isTrue);
    });
  });
}
