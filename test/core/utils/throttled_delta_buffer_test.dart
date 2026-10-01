import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/throttled_delta_buffer.dart';

/// ThrottledDeltaBuffer 单测（流式节流）
void main() {
  test('多 delta 合帧为一次回调（间隔内）', () async {
    final flushed = <String>[];
    ThrottledDeltaBuffer(flushed.add)
      ..add('你')
      ..add('好')
      ..add('，')
      ..add('世界');

    // 间隔内未冲刷
    expect(flushed, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(flushed, ['你好，世界'], reason: '同帧内到达的 delta 应合并成一次回调');
  });

  test('空 delta 不触发计时器；flushAndDispose 冲尾段', () async {
    final flushed = <String>[];
    final buffer = ThrottledDeltaBuffer(flushed.add)..add('');
    expect(flushed, isEmpty);

    buffer
      ..add('尾段')
      ..flushAndDispose();

    expect(flushed, ['尾段'], reason: '流终点必须即时冲刷，不等计时器');
  });

  test('自定义间隔（100ms 压缩写库场景）', () async {
    final flushed = <String>[];
    final buffer = ThrottledDeltaBuffer(
      flushed.add,
      interval: const Duration(milliseconds: 100),
    )..add('a');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(flushed, isEmpty, reason: '50ms < 100ms 间隔，不应冲刷');

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(flushed, ['a']);
    buffer.flushAndDispose();
  });

  test('flush 后计时器复位，后续 delta 重新计时', () async {
    final flushed = <String>[];
    final buffer = ThrottledDeltaBuffer(flushed.add)..add('第一批');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(flushed, ['第一批']);

    buffer.add('第二批');
    expect(flushed, hasLength(1), reason: '冲刷后不应立即再触发');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(flushed, ['第一批', '第二批']);
    buffer.flushAndDispose();
  });
}
