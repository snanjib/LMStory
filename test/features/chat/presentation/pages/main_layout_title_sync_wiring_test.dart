import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// _refreshCurrentSession 的 family key 契约锁
///
/// 重命名/收藏等侧边栏写操作后的主区标题回填，必须把
/// applyExternalTitle 派发给**导航栈对象 current** 作 family key 的
/// controller——就地新建的会话物化后 nav stack 仍是 draft id，页面
/// watch 的是 draft key 的 provider；若改用 fresh（DB real id）作 key，
/// 会 read 出一个无人监听、非 autoDispose 的幽灵 controller（每次触发
/// 再造一个，永不回收），主区标题永远收不到（根因，
/// 8de2d391 的修复只覆盖「从列表打开」路径）。
///
/// MainLayout↔sidebar↔controller 全链 widget 夹具过重（0 测试盲区正是
/// 本缺陷温床），源码契约是防 key 回归的最小红线；CAS 行为层由
/// chat_repository_title_cas_test 锁定。
void main() {
  test('applyExternalTitle 的 family key 必须是导航栈对象 current', () {
    final source = File(
      'lib/features/chat/presentation/pages/main_layout.dart',
    ).readAsStringSync();

    // _refreshCurrentSession 方法体（从方法声明到下一个方法收口）
    final methodStart = source.indexOf('Future<void> _refreshCurrentSession');
    expect(methodStart, greaterThan(0), reason: '_refreshCurrentSession 消失？');
    final methodEnd = source.indexOf('void _selectSession(', methodStart);
    final body = source.substring(methodStart, methodEnd);

    for (final provider in [
      'advancedChatControllerProvider(current)',
      'intermediateChatControllerProvider(current)',
      'chatModeControllerProvider(current)',
    ]) {
      expect(
        body,
        contains(provider),
        reason: 'OH9-1 回归：$provider 未以导航栈对象 current 作 family '
            'key——重命名就地新建的会话将写进幽灵 controller，主区标题不同步且阶梯泄漏内存。',
      );
    }

    // 反向断言：不得再用 fresh 作 key（real id ≠ 页面 watch 的 draft key）
    expect(
      body,
      isNot(contains('Provider(fresh)')),
      reason: 'OH9-1 回归：fresh（real id）作 family key 会绕开页面正在 '
          'watch 的 draft key provider。',
    );
  });
}
