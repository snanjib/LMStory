import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_text_fade.dart';

///  R：流式新增段淡入——段追踪器与进度纯逻辑单测
///
/// 追踪最近 350ms 留存窗口内的新增文本区间（chatbox
/// streaming-text-fade.ts 的语义移植）：只处理「追加增长」（旧文是全文
/// 前缀），替换/收缩（重生成、压缩）全量重置且不淡入，避免整段闪烁。
///
/// R 复验修复后的语义变化：
/// - 首次观察只把尾部 [streamingFadeFirstObservationTailCodeUnits] 码元
///   当作新增段——新消息首字照样浮现，而流式中途重挂（纯文本↔Markdown
///   段落切换、思考标签剥离）不会把整段历史文字重放淡入；
/// - 淡入改由「逐段颜色 alpha」表达，不再有原子盒与盒数预算，故原先的
///   切块函数与盒上限常量已移除。
void main() {
  final t0 = DateTime(2026, 9, 10, 12);

  group('常量单源（R1：三模式零私有调参）', () {
    test('淡入参数与 chatbox 参考一致', () {
      expect(streamingFadeDuration, const Duration(milliseconds: 300));
      expect(streamingFadeRetention, const Duration(milliseconds: 350));
      expect(streamingFadeFirstObservationTailCodeUnits, 40);
    });

    test('留存窗口长于淡入时长（动画完成后才回收，回收零视觉变化）', () {
      expect(
        streamingFadeRetention,
        greaterThan(streamingFadeDuration),
        reason: '窗口短于动画时，段会被半途回收造成透明度跳变',
      );
    });
  });

  group('streamingFadeProgress', () {
    test('刚出现为 0；中段线性推进；达到时长后恒为 1', () {
      final segment = (start: 0, end: 2, createdAt: t0);
      expect(streamingFadeProgress(segment, t0), 0);
      expect(
        streamingFadeProgress(
          segment,
          t0.add(const Duration(milliseconds: 150)),
        ),
        closeTo(0.5, 1e-9),
      );
      expect(
        streamingFadeProgress(segment, t0.add(streamingFadeDuration)),
        1,
      );
      expect(
        streamingFadeProgress(segment, t0.add(const Duration(seconds: 5))),
        1,
      );
    });

    test('时钟早于段创建时间取下界 0（不出现负透明度）', () {
      final segment = (start: 0, end: 2, createdAt: t0);
      expect(
        streamingFadeProgress(
          segment,
          t0.subtract(const Duration(milliseconds: 16)),
        ),
        0,
      );
    });
  });

  group('StreamingFadeSegmentTracker', () {
    test('首帧短文本→整段 [0,len]（新消息首字浮现）', () {
      final tracker = StreamingFadeSegmentTracker()..update('夜色沉了下去', t0);
      expect(tracker.segments, hasLength(1));
      expect(
        tracker.segments.single,
        (
          start: 0,
          end: 6,
          createdAt: t0,
        ),
      );
    });

    test('首帧长文本→只淡入尾部窗口（中途重挂不重放整段历史）', () {
      final tracker = StreamingFadeSegmentTracker();
      final long = '夜' * 200;
      tracker.update(long, t0);
      expect(tracker.segments, hasLength(1));
      expect(tracker.segments.single.end, long.length);
      expect(
        tracker.segments.single.start,
        long.length - streamingFadeFirstObservationTailCodeUnits,
        reason: '长文首次观察（含重挂）只把尾部窗口当新增段',
      );
    });

    test('首帧尾部切点不落在代理对中间', () {
      final tracker = StreamingFadeSegmentTracker();
      final text = 'a${'😀' * 200}';
      tracker.update(text, t0);
      final start = tracker.segments.single.start;
      final unit = text.codeUnitAt(start);
      expect(
        unit < 0xDC00 || unit > 0xDFFF,
        isTrue,
        reason: '起点不得是低代理（否则会切出半个 emoji）',
      );
      expect(tracker.segments.single.end, text.length);
    });

    test('追加增长→新增段区间正确', () {
      final tracker = StreamingFadeSegmentTracker();
      final t1 = t0.add(const Duration(milliseconds: 32));
      tracker
        ..update('夜色', t0)
        ..update('夜色沉了下去', t1);
      expect(tracker.segments, hasLength(2));
      expect(
        tracker.segments.last,
        (
          start: 2,
          end: 6,
          createdAt: t1,
        ),
      );
    });

    test('连续两次小追加→两段并存', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('第一', t0)
        ..update('第一段', t0.add(const Duration(milliseconds: 32)))
        ..update('第一段落', t0.add(const Duration(milliseconds: 64)));
      expect(tracker.segments, hasLength(3));
      expect(
        tracker.segments[1],
        (
          start: 2,
          end: 3,
          createdAt: t0.add(const Duration(milliseconds: 32)),
        ),
      );
      expect(
        tracker.segments[2],
        (
          start: 3,
          end: 4,
          createdAt: t0.add(const Duration(milliseconds: 64)),
        ),
      );
    });

    test('非 startsWith 替换→清空且不淡入，替换后再追加从新文尾部起段', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('abcdef', t0)
        ..update('abcXYZ', t0.add(const Duration(milliseconds: 32)));
      expect(tracker.segments, isEmpty, reason: '重生成替换不重放历史淡入');

      tracker.update('abcXYZ9', t0.add(const Duration(milliseconds: 64)));
      expect(tracker.segments, hasLength(1));
      expect(
        tracker.segments.single,
        (
          start: 6,
          end: 7,
          createdAt: t0.add(const Duration(milliseconds: 64)),
        ),
      );
    });

    test('收缩（变短）同样清空不淡入', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('abcdef', t0)
        ..update('abc', t0.add(const Duration(milliseconds: 32)));
      expect(tracker.segments, isEmpty);
    });

    test('留存窗口外的段被剔除（400ms > 350ms）', () {
      final tracker = StreamingFadeSegmentTracker();
      final t2 = t0.add(const Duration(milliseconds: 400));
      tracker
        ..update('ab', t0)
        ..update('abcd', t0.add(const Duration(milliseconds: 32)))
        ..update('abcdef', t2);
      // 0ms 与 32ms 两段均已过期，只剩本次新增段
      expect(tracker.segments, hasLength(1));
      expect(
        tracker.segments.single,
        (
          start: 4,
          end: 6,
          createdAt: t2,
        ),
      );
    });

    test('恰 350ms 仍在窗口内（严格大于才剔除）', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('ab', t0)
        ..update('abcd', t0.add(const Duration(milliseconds: 350)));
      expect(
        tracker.segments,
        hasLength(2),
        reason: '350ms 为留存窗口闭边界，动画 300ms 已完成但区间保留到过期',
      );
    });

    test('相同文本重复 update→不新增不清空（仅执行过期清扫）', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('ab', t0)
        ..update('ab', t0.add(const Duration(milliseconds: 1000)));
      expect(tracker.segments, isEmpty, reason: '无增长时过期段仍应被清扫');

      tracker.update('abc', t0.add(const Duration(milliseconds: 1100)));
      expect(tracker.segments, hasLength(1));
      expect(
        tracker.segments.single,
        (
          start: 2,
          end: 3,
          createdAt: t0.add(const Duration(milliseconds: 1100)),
        ),
      );
    });

    test('reset→清空并回到首观察态', () {
      final tracker = StreamingFadeSegmentTracker()
        ..update('abc', t0)
        ..reset();
      expect(tracker.segments, isEmpty);

      final t1 = t0.add(const Duration(milliseconds: 50));
      tracker.update('xyz', t1);
      expect(
        tracker.segments.single,
        (
          start: 0,
          end: 3,
          createdAt: t1,
        ),
      );
    });

    test('retention 可注入（窄窗口）', () {
      final tracker = StreamingFadeSegmentTracker(
        retention: const Duration(milliseconds: 100),
      )
        ..update('ab', t0)
        ..update('abcd', t0.add(const Duration(milliseconds: 101)));
      expect(tracker.segments, hasLength(1));
      expect(tracker.segments.single.start, 2);
    });

    test('首观察尾部长度可注入', () {
      final tracker = StreamingFadeSegmentTracker(
        firstObservationTailCodeUnits: 4,
      )..update('夜色沉了下去', t0);
      expect(
        tracker.segments.single,
        (
          start: 2,
          end: 6,
          createdAt: t0,
        ),
      );
    });
  });
}
