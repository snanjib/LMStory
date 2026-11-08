// 风格豁免：注册表测试逐步注册+断言，cascade 同上理由。
// ignore_for_file: cascade_invocations
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';

void main() {
  test('注册/更新/注销/查询', () async {
    final r = SpotlightRegistry();
    var notified = 0;
    r.addListener(() => notified++);

    Future<void> drainFrame() async {
      await Future<void>.delayed(Duration.zero);
    }

    r.register('a', const Rect.fromLTWH(0, 0, 100, 50));
    await drainFrame();
    expect(r.rectOf('a'), const Rect.fromLTWH(0, 0, 100, 50));
    expect(notified, 1);

    // 同 Rect 重复注册不通知
    r.register('a', const Rect.fromLTWH(0, 0, 100, 50));
    await drainFrame();
    expect(notified, 1);

    // 变化 Rect 通知
    r.register('a', const Rect.fromLTWH(10, 0, 100, 50));
    await drainFrame();
    final second = r.snapshot()['a'];
    expect(notified, 2);
    expect(second, const Rect.fromLTWH(10, 0, 100, 50));

    r.unregister('a');
    await drainFrame();
    expect(r.rectOf('a'), isNull);
    expect(notified, 3);
    expect(r.isNotEmpty, isFalse);

    // 未注册 id 注销为 no-op
    r.unregister('ghost');
    await drainFrame();
    expect(notified, 3);
  });

  test('上报器逐帧刷新（外部位移兜底通道）', () {
    final r = SpotlightRegistry();
    var rect = const Rect.fromLTWH(0, 0, 10, 10);
    r.registerReporter('a', () {
      r.register('a', rect);
      return true;
    });

    rect = const Rect.fromLTWH(0, 120, 10, 10); // 滚动位移
    r.refreshReporters();
    expect(r.rectOf('a'), const Rect.fromLTWH(0, 120, 10, 10));

    // 注销目标时上报器一并移除
    r.unregister('a');
    rect = const Rect.fromLTWH(0, 999, 10, 10);
    r.refreshReporters();
    expect(r.rectOf('a'), isNull);
  });

  test('目标元信息记录与路由状态变化通知', () async {
    final r = SpotlightRegistry();
    var notified = 0;
    r.addListener(() => notified++);

    Future<void> drainFrame() async {
      await Future<void>.delayed(Duration.zero);
    }

    r.register(
      'target1',
      const Rect.fromLTWH(0, 0, 100, 100),
    );
    await drainFrame();
    expect(r.metaOf('target1')?.isCurrentRoute, isTrue);
    expect(r.metaOf('target1')?.isPopupRoute, isFalse);
    expect(notified, 1);

    // 路由变为非当前顶层时，元信息更新并触发通知
    r.register(
      'target1',
      const Rect.fromLTWH(0, 0, 100, 100),
      isCurrentRoute: false,
    );
    await drainFrame();
    expect(r.metaOf('target1')?.isCurrentRoute, isFalse);
    expect(notified, 2);

    // 模态路由元信息记录
    r.register(
      'sheetBtn',
      const Rect.fromLTWH(10, 20, 50, 50),
      isPopupRoute: true,
    );
    await drainFrame();
    expect(r.metaOf('sheetBtn')?.isCurrentRoute, isTrue);
    expect(r.metaOf('sheetBtn')?.isPopupRoute, isTrue);
    expect(notified, 3);
  });
}
