import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面窄窗侧栏抽屉入口的源码契约锁。
///
/// 桌面壳窗口 ≤ 断点+侧栏宽时侧栏被强制收起（`_sidebarForceHidden`），
/// 此时 `_sidebarVisible` 本就是 true——汉堡按钮若仍走"设 visible"路径
/// 将永远无效（内测真机实测：窄窗会话页无法唤出侧栏）。修复口径与移动
/// 端同构：窄窗收起态挂抽屉，汉堡改 `openDrawer()`。
///
/// MainLayout↔sidebar↔controller 全链 widget 夹具过重（同
/// main_layout_title_sync_wiring_test 的定界），源码契约是防回归的
/// 最小红线；宽度阈值本身由 t07/lm_layout 单源锚定。
void main() {
  final source = File(
    'lib/features/chat/presentation/pages/main_layout.dart',
  ).readAsStringSync();

  test('汉堡桌面分支：侧栏强制收起态必须改开抽屉', () {
    final start = source.indexOf('void _onHamburgerPressed()');
    expect(start, greaterThan(0), reason: '_onHamburgerPressed 消失？');
    final end = source.indexOf('void _onPopInvoked(', start);
    final body = source.substring(start, end);

    expect(
      body,
      contains('_sidebarForceHidden'),
      reason: '桌面分支须区分"侧栏被宽度判定收起"——否则窄窗汉堡永远无效',
    );
    // forceHidden 分支走抽屉：分支序为 isMobile → forceHidden → else
    final forceHiddenBranch = body.indexOf('} else if (_sidebarForceHidden) {');
    expect(forceHiddenBranch, greaterThan(0));
    final afterBranch = body.substring(forceHiddenBranch);
    expect(
      afterBranch.indexOf('openDrawer()'),
      lessThan(afterBranch.indexOf('} else {')),
      reason: 'forceHidden 分支应 openDrawer()，兜底 else 才是设 _sidebarVisible',
    );
  });

  test('桌面主区：窄窗收起态必须条件挂抽屉并下发 scaffoldKey', () {
    final start = source.indexOf('Widget _buildMainContentPage(');
    expect(start, greaterThan(0), reason: '_buildMainContentPage 消失？');
    final end = source.indexOf(
      '// ---------------------------------------------------------------------------',
      start,
    );
    final body = source.substring(start, end);

    // 抽屉构造：仅 forceHidden 时挂，宽度有上限（桌面 75% 会过宽）
    expect(body, contains('_sidebarForceHidden'));
    expect(body, contains('math.min(320,'));

    // 抽屉与 scaffoldKey 必须下发到全部三类会话页与主页
    for (final page in [
      'AdvancedChatPage(',
      'IntermediateChatPage(',
      'ChatModePage(',
      'HomePage(',
    ]) {
      final pageStart = body.indexOf(page);
      expect(pageStart, greaterThan(0), reason: '$page 不在桌面主区分发中？');
      final pageBody = body.substring(
        pageStart,
        body.indexOf(');', pageStart),
      );
      expect(
        pageBody,
        contains('scaffoldKey: _scaffoldKey'),
        reason: '$page 须挂 scaffoldKey（openDrawer 依赖）',
      );
      expect(
        pageBody,
        contains('drawer: narrowDrawer'),
        reason: '$page 须条件挂窄窗抽屉',
      );
    }
  });
}
