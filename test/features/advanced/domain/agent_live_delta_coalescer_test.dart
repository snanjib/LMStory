import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/services/agent_live_delta_coalescer.dart';

///  批3：导演直播增量合帧器单测
///
/// 此前每个 SSE 文本/思考 delta 直接 state.copyWith——网络 delta 频率下
/// 页面+行构造按网络节奏重建。合帧后 UI 侧消费降到 ~30fps，且保持
/// AgentLiveTranscript 的块边界语义（跨 step/类型不串行拼接）。
void main() {
  group('AgentLiveDeltaCoalescer', () {
    test('同 step 同类型的连续增量在间隔到期时合并为一个 run', () {
      final runs = <List<AgentLiveDeltaRun>>[];
      final c = AgentLiveDeltaCoalescer(runs.add)
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 100,
            text: '第一',
          ),
        )
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 120,
            text: '第二',
          ),
        )
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 140,
            text: '第三',
          ),
        );
      expect(runs, isEmpty, reason: '间隔未到不冲刷');

      c.flush();
      expect(runs, hasLength(1));
      expect(runs.single, hasLength(1), reason: '同 step 同类型合并为单 run');
      expect(runs.single.single.text, '第一第二第三');
      expect(runs.single.single.atMs, 100, reason: 'run 时间取段首');
    });

    test('step 边界与类型边界都保持独立 run（不串行拼接）', () {
      final runs = <List<AgentLiveDeltaRun>>[];
      AgentLiveDeltaCoalescer(runs.add)
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 1,
            text: '正文A',
          ),
        )
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 2,
            atMs: 2,
            text: '正文B',
          ),
        )
        ..add(
          const AgentLiveDelta(
            thinking: true,
            stepIndex: 2,
            atMs: 3,
            text: '思考',
          ),
        )
        ..flush();

      expect(runs.single, hasLength(3));
      expect(runs.single[0], matchesRun(1, '正文A', thinking: false));
      expect(runs.single[1], matchesRun(2, '正文B', thinking: false));
      expect(runs.single[2], matchesRun(2, '思考', thinking: true));
    });

    test('空增量忽略；空冲刷不回调', () {
      var calls = 0;
      AgentLiveDeltaCoalescer((_) => calls++)
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 0,
            atMs: 0,
            text: '',
          ),
        )
        ..flush();
      expect(calls, 0);
    });

    test('discardPending 丢弃未冲刷增量（换轮残段不得落进新轮）', () {
      final runs = <List<AgentLiveDeltaRun>>[];
      final c = AgentLiveDeltaCoalescer(runs.add)
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 1,
            text: '旧轮尾巴',
          ),
        )
        ..discardPending()
        ..flush();
      expect(runs, isEmpty);

      // discard 后可继续用
      c
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 1,
            atMs: 2,
            text: '新轮',
          ),
        )
        ..flush();
      expect(runs, hasLength(1));
    });

    test('DK8-4：discardPending 销毁计时器——间隔到期后 onFlush 不再回调', () async {
      var calls = 0;
      AgentLiveDeltaCoalescer(
        (_) => calls++,
        interval: const Duration(milliseconds: 20),
      )
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 0,
            atMs: 0,
            text: '未冲刷残段',
          ),
        )
        ..discardPending();

      // 间隔（20ms）已过：add 武装的 Timer 随 discard 一并销毁，残段
      // 不落块（宿主 dispose 后 onFlush 写已销毁的 state 会 StateError）
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 0);
    });

    test('flush 后再来增量重新起计时（多帧合帧）', () {
      var calls = 0;
      AgentLiveDeltaCoalescer((_) => calls++)
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 0,
            atMs: 0,
            text: 'a',
          ),
        )
        ..flush()
        ..add(
          const AgentLiveDelta(
            thinking: false,
            stepIndex: 0,
            atMs: 1,
            text: 'b',
          ),
        )
        ..flush();
      expect(calls, 2);
    });
  });

  group('applyLiveDeltaRuns（纯函数：run 应用到 liveBlocks）', () {
    test('合并 run 应用后块结构与逐 delta 应用完全一致', () {
      final coalesced = applyLiveDeltaRuns(const [], const [
        AgentLiveDeltaRun(thinking: true, stepIndex: 0, atMs: 1, text: '思考甲'),
        AgentLiveDeltaRun(thinking: false, stepIndex: 0, atMs: 2, text: '正文甲'),
        AgentLiveDeltaRun(thinking: false, stepIndex: 0, atMs: 3, text: '正文乙'),
        AgentLiveDeltaRun(
          thinking: false,
          stepIndex: 1,
          atMs: 4,
          text: '下一步正文',
        ),
      ]);

      final sequential = AgentLiveTranscript.appendThinking(const [], 0, '思考甲');
      final s2 = AgentLiveTranscript.appendText(sequential, 0, '正文甲');
      final s3 = AgentLiveTranscript.appendText(s2, 0, '正文乙');
      final s4 = AgentLiveTranscript.appendText(s3, 1, '下一步正文');

      expect(coalesced.length, s4.length);
      for (var i = 0; i < s4.length; i++) {
        expect(coalesced[i].kind, s4[i].kind);
        expect(coalesced[i].stepIndex, s4[i].stepIndex);
        expect(coalesced[i].text, s4[i].text);
      }
    });
  });
}

Matcher matchesRun(int stepIndex, String text, {required bool thinking}) =>
    isA<AgentLiveDeltaRun>()
        .having((r) => r.thinking, 'thinking', thinking)
        .having((r) => r.stepIndex, 'stepIndex', stepIndex)
        .having((r) => r.text, 'text', text);
