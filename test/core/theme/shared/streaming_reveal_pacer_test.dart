import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_reveal_pacer.dart';

/// 平滑揭示配速——纯逻辑单测
///
/// 目标：把「已到达但还没显示」的文本按平滑速率放出，消除模型输出快时
/// 每 32ms 一整批字同时上屏的蹦字感；同时保证滞后有界（不超过
/// [streamingRevealMaxLag]）、首观察/替换不配速、不切断代理对。
void main() {
  const frame = Duration(milliseconds: 16);

  group('常量单源（R1：三模式共用，禁止模式私有调参）', () {
    test('滞后上限为 250ms，最小步长为 1 码元', () {
      expect(streamingRevealMaxLag, const Duration(milliseconds: 250));
      expect(streamingRevealMinStepCodeUnits, 1);
    });
  });

  group('首观察与替换不配速', () {
    test('首次观察（挂载时已有大段文本）直接到位', () {
      final pacer = StreamingRevealPacer();
      expect(pacer.advance('夜色沉下去的时候走廊尽头的灯还亮着', Duration.zero), 17);
    });

    test('替换为不同文本（非前缀）立即到位，不逐帧放出', () {
      final pacer = StreamingRevealPacer()..advance('旧的内容', Duration.zero);
      expect(pacer.advance('完全不同的新内容文字', Duration.zero), 10);
    });

    test('收缩（渲染端超前）立即对齐', () {
      final pacer = StreamingRevealPacer()
        ..advance('夜色沉了下去', Duration.zero)
        ..advance('夜色沉了下去，走廊', frame); // 配速中（落后）
      expect(pacer.advance('夜色', frame), 2);
    });

    test('reset 后回到首观察态', () {
      final pacer = StreamingRevealPacer()
        ..advance('夜色', Duration.zero)
        ..reset();
      expect(pacer.revealed, 0);
      expect(pacer.advance('新的一段文字', Duration.zero), 6);
    });

    test('snapTo 立即到位', () {
      final pacer = StreamingRevealPacer()
        ..advance('夜色', Duration.zero)
        ..advance('夜色沉了下去', frame)
        ..snapTo(6);
      expect(pacer.revealed, 6);
    });
  });

  group('追加增长配速', () {
    test('小积压按最小步长逐帧推进（写入边沿连续而非跳动）', () {
      final pacer = StreamingRevealPacer()
        ..advance('夜色', Duration.zero); // 首观察到位：2
      expect(pacer.advance('夜色沉了', frame), 3, reason: '积压 2，单帧只放 1 码元');
      expect(pacer.advance('夜色沉了', frame), 4);
      expect(pacer.advance('夜色沉了', frame), 4, reason: '已揭完不再前进');
    });

    test('大积压自适应加速：滞后不超过 maxLag', () {
      final pacer = StreamingRevealPacer()..advance('夜色', Duration.zero);
      final plenty = '夜色${'沉下去的时候走廊尽头的灯还亮着' * 5}';
      // 模拟连续 32ms 合帧的大批到达：每次到达后一帧内必须补完积压
      var revealed = 0;
      for (var flush = 0; flush < 5; flush++) {
        final target = 2 + (plenty.length - 2) * (flush + 1) ~/ 5;
        final grown = plenty.substring(0, target);
        revealed = pacer.advance(grown, const Duration(milliseconds: 32));
      }
      // 最后一次到达后，允许最多 maxLag 的滞后；这里再补两帧（配速窗口）
      var after = revealed;
      for (var i = 0; i < 16; i++) {
        after = pacer.advance(plenty, frame);
      }
      expect(after, plenty.length, reason: 'maxLag 量级内必须追平');
    });

    test('单帧揭示量不超过积压（不得越过已到达文本）', () {
      final pacer = StreamingRevealPacer()..advance('夜色', Duration.zero);
      expect(pacer.advance('夜色沉', const Duration(seconds: 5)), 3);
    });
  });

  group('代理对安全', () {
    test('揭示边界不落在低代理上（emoji 不裂开）', () {
      final pacer = StreamingRevealPacer()
        ..advance('a', Duration.zero); // 首观察到位：1
      // 增长 1 个 emoji（2 码元）：单步 1 会切在低代理 → 必须补到对尾
      const grown = 'a😀';
      final revealed = pacer.advance(grown, frame);
      expect(revealed, 3, reason: '补齐整个 emoji，不渲染半个字符');
    });
  });
}
