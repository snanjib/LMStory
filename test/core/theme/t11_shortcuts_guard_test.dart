import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_focus_order.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';

import '../../test_helpers/dart_source.dart';

///  守卫：桌面键盘交互层（`lib/core/theme/system/lm_shortcuts.dart`）。
///
/// 四条不变量（A 段验收口径）：
///
/// 1. **无重复绑定** —— 同一作用域内两个注册项落到同一组按键即失败；id 唯一。
/// 2. **无裸绑定（白名单闭集）** —— `lib/` 全域不得再出现 `CallbackShortcuts`，
///    也不得出现 `lm_shortcuts.dart` 之外的裸 `SingleActivator(` 字面量。
///    「白名单 = 只有一个文件」是把这张表钉成单源的机械保证。
/// 3. **关键操作均有绑定** —— 每个注册 id 必须有真实消费点（不能只登记不接线）；
///    id → 常量名的映射必须与注册表**等长**（新增注册项即强制补消费点）。
/// 4. **遍历顺序符合声明** —— `LmFocusOrder` 声明的区域次序真的接管 Tab
///    （行为用例：声明压过几何阅读顺序），且关键面确实做了声明（源码契约）。
///
/// 另含「消费包装件语义」（未知 id / 作用域不匹配 / 重复绑定当场抛错）与
/// 键位清单表落盘（可发现性交付物）。
void main() {
  // ── 1. 注册表自洽 ────────────────────────────────────────────────
  group('注册表自洽', () {
    test('同作用域内无重复按键绑定', () {
      expect(
        LmShortcuts.conflicts(),
        isEmpty,
        reason: '同一作用域里两个键位撞车——表一旦烂掉，后注册的那个永远收不到事件',
      );
    });

    test('id 全局唯一，且形如 <作用域>.<动作>', () {
      expect(LmShortcuts.duplicateIds(), isEmpty);
      final bad = <String>[];
      for (final shortcut in LmShortcuts.registry) {
        final expectedPrefix = '${shortcut.scope.name}.';
        if (!shortcut.id.startsWith(expectedPrefix) ||
            shortcut.id.length == expectedPrefix.length) {
          bad.add(shortcut.id);
        }
      }
      expect(bad, isEmpty, reason: 'id 前缀必须与 scope 一致：$bad');
    });

    test('每条注册项都有描述与至少一组按键', () {
      for (final shortcut in LmShortcuts.registry) {
        expect(shortcut.description.trim(), isNotEmpty, reason: shortcut.id);
        expect(shortcut.combos, isNotEmpty, reason: shortcut.id);
        expect(shortcut.keysLabel.trim(), isNotEmpty, reason: shortcut.id);
      }
    });

    test('描述必须为 ASCII（本文件位于 core/theme，受中文字面量门禁约束）', () {
      final cjk = RegExp(r'[\u4e00-\u9fa5]');
      for (final shortcut in LmShortcuts.registry) {
        expect(
          cjk.hasMatch(shortcut.description),
          isFalse,
          reason: '${shortcut.id} 的描述含中文——core/theme 下的中文字面量会被 '
              'check_chinese_literals.py 拦下；用户可见中文走 slang（本轮禁新增键， '
              '已登记需主控决策）',
        );
      }
    });

    test('primary 组合恰好展开为 control + meta 两支（不做平台映射）', () {
      for (final shortcut in LmShortcuts.registry) {
        for (final combo in shortcut.combos) {
          final activators = combo.activators.toList();
          expect(
            activators.length,
            combo.primary ? 2 : 1,
            reason: '${shortcut.id} / ${combo.label}：SingleActivator 不做平台映射， '
                '主修饰键必须展开成两支，否则 macOS 上这个键位是死的',
          );
          if (combo.primary) {
            expect(activators.where((a) => a.control).length, 1);
            expect(activators.where((a) => a.meta).length, 1);
            expect(activators.every((a) => a.shift == combo.shift), isTrue);
          }
        }
      }
    });

    test('键位锚定（顺手改键位必须显式改这里）', () {
      const expected = <String, String>{
        LmShortcuts.idNewChat: 'Ctrl/Cmd+N',
        LmShortcuts.idNewStory: 'Ctrl/Cmd+Shift+N',
        LmShortcuts.idSettings: 'Ctrl/Cmd+,',
        LmShortcuts.idGlobalSearch: 'Ctrl/Cmd+K',
        LmShortcuts.idSessionSearch: 'Ctrl/Cmd+F',
        LmShortcuts.idSessionSearchClose: 'Esc',
        LmShortcuts.idOverlayNext: 'Down',
        LmShortcuts.idOverlayPrev: 'Up',
        LmShortcuts.idOverlayDismiss: 'Esc',
        LmShortcuts.idControlActivate: 'Enter / Space',
      };
      expect(
        expected.keys.toSet(),
        LmShortcuts.registry.map((s) => s.id).toSet(),
        reason: '注册表新增/删除项后，键位锚定表必须同步',
      );
      for (final entry in expected.entries) {
        expect(LmShortcuts.byId(entry.key).keysLabel, entry.value);
      }
    });
  });

  // ── 2. 无裸绑定（白名单闭集）────────────────────────────────────
  group('无裸绑定', () {
    test('lib/ 全域无 CallbackShortcuts', () {
      final offenders = <String>[];
      for (final file in _libDartFiles()) {
        final code = stripDartComments(file.readAsStringSync());
        if (code.contains('CallbackShortcuts')) {
          offenders.add('${_relPath(file)}（${'CallbackShortcuts'.length}）');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '页面还在裸写 CallbackShortcuts（白名单为空集）：$offenders\n'
            '改用 LmShortcutHost + LmShortcuts.registry。',
      );
    });

    test('SingleActivator 字面量只许出现在 lm_shortcuts.dart', () {
      final outside = <String>[];
      var inside = 0;
      final pattern = RegExp(r'SingleActivator\(');
      for (final file in _libDartFiles()) {
        final rel = _relPath(file);
        final count = pattern
            .allMatches(stripDartComments(file.readAsStringSync()))
            .length;
        if (count == 0) continue;
        if (rel.endsWith('/lm_shortcuts.dart')) {
          inside = count;
        } else {
          outside.add('$rel（$count）');
        }
      }
      expect(
        outside,
        isEmpty,
        reason: '注册表之外还有裸 SingleActivator 字面量：$outside\n'
            '键位与平台变体必须来自 LmShortcuts（或 LmShortcuts.intentBindings）。',
      );
      expect(
        inside,
        greaterThanOrEqualTo(2),
        reason: 'lm_shortcuts.dart 必须在真正构造 SingleActivator '
            '（否则本守卫被空表骗过）',
      );
    });
  });

  // ── 3. 关键操作均有绑定（消费点覆盖）────────────────────────────
  group('关键操作均有绑定', () {
    test('注册表每一项都有真实消费点', () {
      // id → 调用点常量名。**必须与注册表等长**：新增注册项而忘了接线时，
      // 下面第一条断言就会红。
      const consumers = <String, String>{
        LmShortcuts.idNewChat: 'LmShortcuts.idNewChat',
        LmShortcuts.idNewStory: 'LmShortcuts.idNewStory',
        LmShortcuts.idSettings: 'LmShortcuts.idSettings',
        LmShortcuts.idGlobalSearch: 'LmShortcuts.idGlobalSearch',
        LmShortcuts.idSessionSearch: 'LmShortcuts.idSessionSearch',
        LmShortcuts.idSessionSearchClose: 'LmShortcuts.idSessionSearchClose',
        LmShortcuts.idOverlayNext: 'LmShortcuts.idOverlayNext',
        LmShortcuts.idOverlayPrev: 'LmShortcuts.idOverlayPrev',
        LmShortcuts.idOverlayDismiss: 'LmShortcuts.idOverlayDismiss',
        LmShortcuts.idControlActivate: 'LmShortcuts.idControlActivate',
      };
      expect(
        consumers.keys.toSet(),
        LmShortcuts.registry.map((s) => s.id).toSet(),
        reason: '注册表与「消费点清单」不等长——新注册的键位必须有页面接住',
      );

      final sources = <String, String>{
        for (final file in _libDartFiles())
          if (!_relPath(file).endsWith('/lm_shortcuts.dart'))
            _relPath(file): stripDartComments(file.readAsStringSync()),
      };

      final unbound = <String>[];
      for (final entry in consumers.entries) {
        final hit = sources.entries
            .where((e) => e.value.contains(entry.value))
            .map((e) => e.key)
            .toList();
        if (hit.isEmpty) unbound.add(entry.key);
      }
      expect(
        unbound,
        isEmpty,
        reason: '以下键位只登记未接线（用户按了没反应）：$unbound',
      );
    });
  });

  // ── 4. 遍历顺序符合声明 ─────────────────────────────────────────
  group('遍历顺序符合声明', () {
    test('区域序号严格递增（侧栏 → 会话区 → 内容页）', () {
      expect(
        LmFocusRegion.sidebar.order,
        lessThan(LmFocusRegion.conversation.order),
      );
      expect(
        LmFocusRegion.conversation.order,
        lessThan(LmFocusRegion.content.order),
      );
    });

    testWidgets('LmFocusOrder 声明的次序真的接管 Tab（压过几何阅读顺序）', (
      tester,
    ) async {
      // 故意把「声明在前」的区域放在**右边**：若声明的次序没生效、退回几何
      // 阅读顺序，Tab 就会先走左列——这条断言会红。
      final rightFirst = FocusNode(debugLabel: 'right-1');
      final rightSecond = FocusNode(debugLabel: 'right-2');
      final leftFirst = FocusNode(debugLabel: 'left-1');
      final leftSecond = FocusNode(debugLabel: 'left-2');
      addTearDown(() {
        for (final node in [rightFirst, rightSecond, leftFirst, leftSecond]) {
          node.dispose();
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: LmFocusTraversal(
            child: Row(
              children: [
                Expanded(
                  child: LmFocusOrder(
                    region: LmFocusRegion.conversation,
                    child: Column(
                      children: [
                        _Probe(node: leftFirst),
                        _Probe(node: leftSecond),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: LmFocusOrder(
                    region: LmFocusRegion.sidebar,
                    child: Column(
                      children: [
                        _Probe(node: rightFirst),
                        _Probe(node: rightSecond),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      rightFirst.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, rightFirst);

      FocusManager.instance.primaryFocus!.nextFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        rightSecond,
        reason: '同区域内部按阅读顺序（上→下）',
      );

      FocusManager.instance.primaryFocus!.nextFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        leftFirst,
        reason: 'sidebar 区域整体在 conversation 之前——几何上左列更早， '
            '声明必须压过几何，否则就是「声明了但没生效」',
      );

      FocusManager.instance.primaryFocus!.nextFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, leftSecond);

      // 走到末位后回绕到声明次序的首位
      FocusManager.instance.primaryFocus!.nextFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        rightFirst,
        reason: '遍历到头回绕，且回绕目标仍是声明次序的首位',
      );
    });

    test('关键面确实声明了区域（源码契约）', () {
      final mainLayout = stripDartComments(
        File(
          'lib/features/chat/presentation/pages/main_layout.dart',
        ).readAsStringSync(),
      );
      expect(mainLayout, contains('LmFocusTraversal('));
      final sidebarAt = mainLayout.indexOf('LmFocusRegion.sidebar');
      final conversationAt = mainLayout.indexOf('LmFocusRegion.conversation');
      expect(sidebarAt, greaterThan(0), reason: '桌面壳未声明侧栏区域');
      expect(
        conversationAt,
        greaterThan(sidebarAt),
        reason: '侧栏区域必须在主区之前声明（Row 内顺序即声明顺序）',
      );

      final settings = stripDartComments(
        File(
          'lib/features/settings/presentation/pages/settings_page.dart',
        ).readAsStringSync(),
      );
      expect(settings, contains('LmFocusTraversal('));
      expect(settings, contains('LmFocusRegion.content'));
    });
  });

  // ── 消费包装件语义 ───────────────────────────────────────────────
  group('LmShortcutHost 语义', () {
    testWidgets('未注册 id 当场抛错（不是静默失效）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LmShortcutHost(
            scope: LmShortcutScope.app,
            handlers: {'app.typo': () {}},
            child: const SizedBox.shrink(),
          ),
        ),
      );
      expect(tester.takeException(), isArgumentError);
    });

    testWidgets('作用域不匹配当场抛错', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LmShortcutHost(
            scope: LmShortcutScope.overlay,
            handlers: {LmShortcuts.idNewChat: () {}},
            child: const SizedBox.shrink(),
          ),
        ),
      );
      expect(tester.takeException(), isFlutterError);
    });

    testWidgets('未提供处理函数的注册项不安装绑定', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LmShortcutHost(
            scope: LmShortcutScope.session,
            handlers: {LmShortcuts.idSessionSearch: () => fired++},
            child: const SizedBox.shrink(),
          ),
        ),
      );
      // 只装了 session.search：同作用域的 searchClose(Esc) 不该生效
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(fired, 0, reason: '未提供 handler 的注册项不得安装绑定');

      // 正向对照：同一次构建里已提供 handler 的项照常生效
      await _press(tester, LogicalKeyboardKey.keyF, control: true);
      expect(fired, 1);
    });

    testWidgets('control 与 meta 两支都能触发（同一份注册项）', (tester) async {
      var fired = 0;
      final expectedActivators = LmShortcuts.byId(
        LmShortcuts.idSessionSearch,
      ).activators.toList();
      expect(expectedActivators.length, 2);

      for (final activator in expectedActivators) {
        await tester.pumpWidget(
          MaterialApp(
            home: LmShortcutHost(
              scope: LmShortcutScope.session,
              handlers: {LmShortcuts.idSessionSearch: () => fired++},
              child: const SizedBox.shrink(),
            ),
          ),
        );
        final modifier = activator.control
            ? LogicalKeyboardKey.controlLeft
            : LogicalKeyboardKey.metaLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(activator.trigger);
        await tester.sendKeyUpEvent(activator.trigger);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }
      expect(fired, 2, reason: '两支平台变体都必须触发同一条注册项');
    });
  });

  // ── 嵌套不吞键（本轮踩过的坑，必须锁死）────────────────────────────
  //
  // 直觉写法 `Shortcuts` + `Actions({LmShortcutIntent: ...})` 在**嵌套时互相吞键**：
  // `Actions.maybeFind` 按 Intent 的运行时类型在最近祖先里命中，且 `_castAction`
  // **不看 `isEnabled`**、命中即止。注册表共用一个 Intent 类型，于是内层 host 会
  // 替外层 host 接收全部 `LmShortcutIntent`，`handlers[id]` 取不到就静默 no-op
  // 并返回 handled。后果：会话页一打开壳层的 Ctrl+N 全哑；全局搜索浮层让统一
  // 浮层入口的 Esc 失效（对话框关不掉）。改用 `Focus.onKeyEvent` 后由键事件冒泡
  // 裁定——下面两条用例就是这条不变量的哨兵。
  group('嵌套不吞键', () {
    testWidgets('跨作用域嵌套：内层不得吞掉外层作用域的键', (tester) async {
      final inner = FocusNode(debugLabel: 'probe-inner');
      addTearDown(inner.dispose);
      var appFired = 0;
      var sessionFired = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: LmShortcutHost(
            scope: LmShortcutScope.app,
            autofocus: false,
            handlers: {LmShortcuts.idNewChat: () => appFired++},
            child: LmShortcutHost(
              scope: LmShortcutScope.session,
              autofocus: false,
              handlers: {LmShortcuts.idSessionSearch: () => sessionFired++},
              child: Focus(focusNode: inner, child: const SizedBox.shrink()),
            ),
          ),
        ),
      );
      inner.requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        inner,
        reason: '前置：焦点必须在最内层 host 的子树里，键事件才会一路冒泡',
      );

      await _press(tester, LogicalKeyboardKey.keyN, control: true);
      expect(
        appFired,
        1,
        reason: '会话页里 Ctrl/Cmd+N 必须仍然生效——内层 host 无权吞它',
      );
      expect(sessionFired, 0);

      await _press(tester, LogicalKeyboardKey.keyF, control: true);
      expect(sessionFired, 1, reason: '内层作用域的键由内层消费');
      expect(appFired, 1);
    });

    testWidgets('同作用域嵌套：内层不得吞掉它自己没绑定的键', (tester) async {
      final inner = FocusNode(debugLabel: 'probe-inner');
      addTearDown(inner.dispose);
      var dismissFired = 0;
      var nextFired = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: LmShortcutHost(
            scope: LmShortcutScope.overlay,
            autofocus: false,
            handlers: {LmShortcuts.idOverlayDismiss: () => dismissFired++},
            child: LmShortcutHost(
              scope: LmShortcutScope.overlay,
              autofocus: false,
              handlers: {LmShortcuts.idOverlayNext: () => nextFired++},
              child: Focus(focusNode: inner, child: const SizedBox.shrink()),
            ),
          ),
        ),
      );
      inner.requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.escape);
      expect(
        dismissFired,
        1,
        reason: '内层没绑 Esc，Esc 必须落到绑了它的外层—— '
            '全局搜索浮层套在统一浮层入口里，这里一旦吞掉对话框就关不掉',
      );
      expect(nextFired, 0);

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(nextFired, 1, reason: '内层绑了的键由内层消费（越靠内层优先级越高）');
      expect(dismissFired, 1);
    });
  });

  // ── 可发现性交付物 ───────────────────────────────────────────────
  test('键位清单表落盘（键位 / 作用 / 作用域 / id）', () {
    final table = LmShortcuts.keymapMarkdown();
    final rows = table.split('\n').where((l) => l.startsWith('|')).length;
    expect(
      rows,
      LmShortcuts.registry.length + 2,
      reason: '清单表行数必须等于注册项数（表头 + 分隔行 2 行）',
    );
    for (final shortcut in LmShortcuts.registry) {
      expect(table, contains('`${shortcut.id}`'));
      expect(table, contains('`${shortcut.scope.name}`'));
      expect(table, contains('`${shortcut.keysLabel}`'));
    }

    final dir = Directory('test_screenshots/night-2026-09-21');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}/t11_shortcut_keymap.md').writeAsStringSync(
      '# 键位清单表（T11 自动生成，勿手改）\n\n'
      '> 来源：`LmShortcuts.keymapMarkdown()`；「作用」为代码级英文描述， '
      '用户可见中文文案需 slang（见报告「需主控决策」）。\n\n'
      '$table',
    );
  });
}

class _Probe extends StatelessWidget {
  const _Probe({required this.node});

  final FocusNode node;

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: node, child: const SizedBox(width: 24, height: 24));
}

/// 按一次组合键（修饰键按下 → 主键按下/抬起 → 修饰键抬起）。
Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
}) async {
  final modifiers = <LogicalKeyboardKey>[
    if (control) LogicalKeyboardKey.controlLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
  ];
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

Iterable<File> _libDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _relPath(File file) => file.path.replaceAll(r'\', '/');
