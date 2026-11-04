//  搭车项 · classic 侧 hover / pressed 逐状态对账（遗留）。
//
// ## 为什么需要它
//
//  把交互五态完备化只落在**玻璃 18 工厂**上；classic 侧当时明确记为
// 「hover / pressed 仍依赖 Material 默认实现，未逐个对账」（见
// `night-run-2026-09-21.md` 未修复清单）。 只补了 classic 的**键盘焦点**
// （`LmFocusRing`），hover / pressed 仍是空白。
//
// 本夹具把这句话变成数字：对 classic 结构**显式接线的四类按钮**（Filled /
// Elevated / Outlined / Text）与玻璃侧三个对照件（实心药丸 / 幽灵药丸 /
// chip）在四组合 × 双亮度下，用真实指针逼出 hover / pressed，逐像素测量
// 「相对静息态的变化量」，并额外测「hover → pressed 的增量」。
//
// 这不是「好看不好看」的评审，而是回答三个可证伪的问题：
//   1. Material 默认叠色在四组合下是否真的可感知（阈值 Δ8）；
//   2. 按下相对悬停是否有**额外**反馈（增量 > 0）；
//   3. 玻璃侧自建五态与 classic 侧 Material 默认是否在一个数量级。
//
// ## 三个必须记住的夹具坑（2026-09-22 实测，逐个踩过）
//
// 1. **`MaterialApp` 会补间主题切换**。同一棵树上换 `theme:`，`AnimatedTheme`
//    会用 200ms 把旧主题 lerp 到新主题。只 `pump(50ms)` 就截图，取到的是
//    **上一组合的混色**（本轮实测：classic 夜间 FilledButton 的「静息面色」
//    一度是紫色 `#7562b0`，而它真实面色是金色 `#d4a042`），于是 hover 的
//    Δmax 被抬到 106/145 的假高值。**换主题后必须等满一个
//    `kThemeAnimationDuration`（200ms）**，见 `_pump`。
// 2. **`InkHighlight` 淡入 200ms**。`moveTo` 之后只 `pump(60ms)` 会停在
//    30% 不透明度（8% × 30% ≈ 2.4% 叠色 → Δmax ≈ 3 < 阈值 8），表现为
//    「hover 完全没生效、changed=0」的假阴性。**必须再等一帧 + 一个完整
//    淡入窗**，见 `_settle`。
// 3. **测试环境的 `FocusManager.highlightMode` 恒为 `touch`** —— 这一条最要命。
//    `glass_factories.dart` 的 `_GlassInteractive` 用
//    `FocusableActionDetector.onShowHoverHighlight` 采集 hover，而该回调被
//    `shouldShowHoverHighlight = _hovering && enabled && _canShowHighlight`
//    门控，`_canShowHighlight` 只在 `highlightMode == traditional` 时为真。
//    测试环境走 `_defaultModeForPlatform` → `touch`；而
//    `FocusManager.handlePointerEvent` **只对 touch/stylus 置位、对 mouse 不置位**
//    （`focus_manager.dart` `handlePointerEvent` 的 switch 里 mouse 分支是空的），
//    所以「先用鼠标划一划」**永远回不到 traditional**。
//    后果：不处理的话，玻璃侧 18 工厂自建的 hover 态在本夹具里**完全不触发**，
//    能看到的 Δ 只是玻璃件内层 `InkWell` 的 Material 叠色（实测 Δ2–8），
//    读数与真机（桌面 → traditional → 自建 hover 生效）不符。
//    **处理：显式把 `highlightStrategy` 钉成 `alwaysTraditional`**（见 setUp），
//    此时 `_canShowHighlight` 恒真。副作用是**焦点**也一律显示——故断言里
//    额外校验「按下态 Δmax 不超过悬停态一个数量级」，一旦按压顺带点亮了
//    `LmFocusRing` 就会被抓住（本轮实测未触发，Material 按钮按下不取焦点）。
//
// ## 口径
//
// - **变化像素**：同一像素两态 max 通道差 ≥ 8 计为变化（沿用  /
//   同款判据）。
// - **Δmax**：变化像素中的最大通道差（峰值强度）。
// - **面色**：控件**内左侧采样点**（避开文字字形）的颜色，最直观。
// - hover / pressed **没有**正式 WCAG 阈值（SC 2.4.11 只管焦点），故本夹具
//   只报数 + 校验跨结构量级，不擅自发明门槛。
// - 产物：`test_screenshots/night-2026-09-21/t08_classic_states_report.md`
//   （gitignore）。
//
// ## 已登记缺口（刻意写成白名单，修好即红）
//
// **2026-09-22  后：本表已清空。** 原两条缺口（波尔多夜主色药丸白叠白
// Δ0、波尔多浅色 ghost 药丸 Δ8）的根因是白玻璃台阶「只叠白、不随底面翻转」；
//  把台阶方向改为由底面亮度派生后，两者实测 Δ18 / Δ17（见
// `test/core/theme/glass/t10_step_direction_guard_test.dart` 的增量表），
// 故从白名单删除。
//
// 保留空集合而不是删掉判据：`stale` 检查仍在，将来若有人往里加条目，
// 条目被修好时依旧会红。
//
// ## 顺带捞到的一条 Material 默认行为冲突（登记，不修）
//
//  `FilledButton` 的 `elevation` 在 **hover 时从 0 跳到 1**
// （`filled_button.dart` `_FilledButtonDefaultsM3.elevation`），于是悬停会凭空
// 长出一道 `colorScheme.shadow`（纯黑）阴影。classic 结构刻意扁平、且
// `ElevatedButton` 恒为 1（1→3 才变），两者 hover 观感因此不一致：
// 实测 classic 夜间 FilledButton 圆角外侧像素从页面底色 `244,245,247`
// 变成 `0,0,0`（Δ247），而同结构的 ElevatedButton 只有 Δ15。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

const double _pixelRatio = 2;
const Size _surface = Size(800, 600);

/// 「像素发生变化」阈值（max 通道差），与  /  同值。
const int _changeThreshold = 8;

/// 主题切换的补间时长（`kThemeAnimationDuration` 同值），必须等满再截图。
const Duration _themeSettle = Duration(milliseconds: 400);

const String _reportPath =
    'test_screenshots/night-2026-09-21/t08_classic_states_report.md';

/// 已登记的缺口（`组合/明暗 控件`）。命中即「按已知缺口放过，不算新问题」；
/// 反过来，白名单里某条若不再命中，测试也会失败，提示缺口已被修复、该删条目。
///
/// ** 后为空**：原两条缺口（波尔多夜主色药丸白叠白 Δ0、波尔多浅色
/// ghost 药丸 Δ8）同源——白玻璃台阶只叠白、方向不随底面翻转。台阶改为由底面
/// 亮度派生后实测 Δ18 / Δ17（见 `t10_step_direction_guard_test.dart`），
/// 故删条目。空集合保留判据：将来新加的条目一旦被修好仍会红。
const Set<String> _knownGaps = {};

typedef _Rgb = (int, int, int);

double _relativeLuminance(_Rgb c) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.$1) +
      0.7152 * channel(c.$2) +
      0.0722 * channel(c.$3);
}

double _contrastRatio(_Rgb a, _Rgb b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(_Rgb c) => '#${c.$1.toRadixString(16).padLeft(2, '0')}'
    '${c.$2.toRadixString(16).padLeft(2, '0')}'
    '${c.$3.toRadixString(16).padLeft(2, '0')}';

/// 单次状态对比的结果。
class _StateMeasure {
  const _StateMeasure({
    required this.changedPx,
    required this.maxChange,
    required this.contrastChangeMean,
  });

  final int changedPx;
  final int maxChange;

  /// 变化像素**均值**在两态之间的 WCAG 对比度（1.00 = 无变化）。
  final double contrastChangeMean;

  bool get perceivable => changedPx > 0 && maxChange >= _changeThreshold;

  @override
  String toString() => 'px=$changedPx Δmax=$maxChange '
      '对比度 ${contrastChangeMean.toStringAsFixed(2)}';
}

_StateMeasure _diff(Uint8List before, Uint8List after) {
  final bSum = <int>[0, 0, 0];
  final aSum = <int>[0, 0, 0];
  var n = 0;
  var maxChange = 0;
  for (var i = 0; i + 3 < before.length; i += 4) {
    var change = 0;
    for (var k = 0; k < 3; k++) {
      change = math.max(change, (after[i + k] - before[i + k]).abs());
    }
    if (change < _changeThreshold) continue;
    n++;
    for (var k = 0; k < 3; k++) {
      bSum[k] += before[i + k];
      aSum[k] += after[i + k];
    }
    if (change > maxChange) maxChange = change;
  }
  _Rgb mean(List<int> s) =>
      n == 0 ? (0, 0, 0) : (s[0] ~/ n, s[1] ~/ n, s[2] ~/ n);
  return _StateMeasure(
    changedPx: n,
    maxChange: maxChange,
    contrastChangeMean: n == 0 ? 1 : _contrastRatio(mean(bSum), mean(aSum)),
  );
}

Future<Uint8List> _shoot(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List out;
  await tester.binding.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    final data = await image.toByteData();
    out = Uint8List.fromList(data!.buffer.asUint8List());
    image.dispose();
  });
  return out;
}

/// 取图上一个点的颜色。
_Rgb _at(Uint8List img, Offset p) {
  final width = (_surface.width * _pixelRatio).round();
  final x = (p.dx * _pixelRatio).round().clamp(0, width - 1);
  final y = (p.dy * _pixelRatio).round().clamp(0, 1 << 20);
  final i = (y * width + x) * 4;
  return (img[i], img[i + 1], img[i + 2]);
}

/// classic 四类显式接线按钮。
Widget _classicControl(String name, GlobalKey buttonKey) => switch (name) {
      'FilledButton' => FilledButton(
          key: buttonKey,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      'ElevatedButton' => ElevatedButton(
          key: buttonKey,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      'OutlinedButton' => OutlinedButton(
          key: buttonKey,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      _ => TextButton(
          key: buttonKey,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
    };

/// 玻璃侧对照件。chip 特意加进来：它的**静息档就是 fill6**，正好落在
/// 「hover = 基档+1 / pressed = 基档+2」这条阶梯上，用于验证浅色档
/// `fill10` 与 `fill16` 同值是否把 hover / pressed 压成同色。
Widget _glassControl(String name, GlobalKey buttonKey) {
  if (name == 'Chip') {
    return GlassChip(key: buttonKey, label: '标签', onTap: () {});
  }
  return GlassPillButton(
    key: buttonKey,
    label: name == 'GhostPill' ? '取消' : '确认',
    variant:
        name == 'GhostPill' ? GlassPillVariant.ghost : GlassPillVariant.primary,
    onPressed: () {},
  );
}

/// 挂载并把主题补间跑完（坑 1）。
///
/// 底色用 `context.lm.palette.bg`（即琉璃结构下 `scaffoldBgOf` 的兜底色）：
/// 不铺底色的话 `RepaintBoundary` 抓到的是**透明**像素，透明底件
/// （ghost 药丸、chip 未选中、Outlined/TextButton）的面色会退化成
/// 预乘后的中灰，读数与真机对不上。
Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  GlobalKey boundaryKey,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (ctx) => Scaffold(
          backgroundColor: ctx.lm.palette.bg,
          body: RepaintBoundary(
            key: boundaryKey,
            // 底色必须铺在 **RepaintBoundary 内部**：`toImage()` 只合成
            // 边界自己那棵子树，Scaffold 由祖先 Material 画的底色**不在其中**，
            // 不铺的话透明底件（ghost/chip/Outlined/Text）抓到的是 alpha=0 的
            // 预乘中灰（实测 glass 浅色 ghost 静息面 = #000000 alpha=0）。
            child: ColoredBox(
              color: ctx.lm.palette.bg,
              child: SizedBox(
                width: _surface.width,
                height: _surface.height,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // 等满 AnimatedTheme 的 200ms 补间，否则静息态取到的是上一组合的混色。
  await tester.pump();
  await tester.pump(_themeSettle);
  // 上一个控件的按压可能把焦点留给了同名件；`alwaysTraditional` 下焦点环
  // 会以 2px `onPrimary` 出现在木框边缘（实测把 FilledButton 的 hover Δmax
  // 抬到 245），必须在取静息态前清干净。
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

/// 把 hover / pressed 的淡入跑完（坑 2）：先一帧让 controller 起跑，
/// 再等一个完整淡入窗。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<TestGesture> _hoverAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await tester.pump();
  await mouse.moveTo(at);
  await _settle(tester);
  return mouse;
}

/// 把鼠标挪开（`PointerHoverEvent` 不会改动 `FocusManager` 的
/// `_lastInteractionWasTouch`，因此**不会**污染后续组合的 hover 高亮）。
Future<void> _moveAway(WidgetTester tester, TestGesture mouse) async {
  await mouse.moveTo(const Offset(2, 2));
  await _settle(tester);
}

/// 全部用**鼠标**驱动 hover 与 pressed。
///
/// 用鼠标而不是 `tester.startGesture`（触摸）按，是为了让「按下」这一帧
/// 天然包含悬停态 —— 真实用户按下时指针必然在件上，观感即「悬停 + 按压」。
/// （玻璃 hover 的门控问题已由 setUp 里的 `alwaysTraditional` 解决，这里
/// 不再依赖指针类型。）
Future<void> _pressDown(
  WidgetTester tester,
  TestGesture mouse,
  Offset at,
) async {
  await mouse.moveTo(at);
  await _settle(tester);
  await mouse.down(at);
  await _settle(tester);
}

/// 一行对账数据。
class _Row {
  const _Row({
    required this.tag,
    required this.structure,
    required this.control,
    required this.hover,
    required this.pressed,
    required this.extra,
    required this.restColor,
    required this.hoverColor,
    required this.pressedColor,
  });

  final String tag;
  final String structure;
  final String control;
  final _StateMeasure hover;
  final _StateMeasure pressed;

  /// pressed 相对 hover 的额外变化（不可感知 = 按下与悬停看不出区别）。
  final _StateMeasure extra;

  final _Rgb restColor;
  final _Rgb hoverColor;
  final _Rgb pressedColor;

  String get id => '$tag $control';
}

void main() {
  const combos = <(String structure, String palette, Brightness brightness)>[
    ('classic', 'classic', Brightness.light),
    ('classic', 'classic', Brightness.dark),
    ('classic', 'bordeaux', Brightness.light),
    ('classic', 'bordeaux', Brightness.dark),
    ('glass', 'classic', Brightness.light),
    ('glass', 'classic', Brightness.dark),
    ('glass', 'bordeaux', Brightness.light),
    ('glass', 'bordeaux', Brightness.dark),
  ];

  const classicControls = <String>[
    'FilledButton',
    'ElevatedButton',
    'OutlinedButton',
    'TextButton',
  ];
  const glassControls = <String>['SolidPill', 'GhostPill', 'Chip'];

  testWidgets('classic / glass 侧 hover · pressed 逐状态对账（四组合 × 明暗）',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 坑 3：测试环境 `highlightMode` 恒为 touch，玻璃自建 hover 会全哑；
    // 钉成 alwaysTraditional 才有 hover 可测（详情见文件头注释）。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    final rows = <_Row>[];

    for (final (structure, palette, brightness) in combos) {
      final theme = ThemeCatalog.assemble(
        LmAppearance(structureId: structure, paletteId: palette),
        brightness,
      );
      final tag = '${structure}_$palette/${brightness.name}';
      final names = structure == 'glass' ? glassControls : classicControls;

      for (final name in names) {
        final boundaryKey = GlobalKey();
        final buttonKey = GlobalKey();
        final control = structure == 'glass'
            ? _glassControl(name, buttonKey)
            : _classicControl(name, buttonKey);

        // ── 静息 ─────────────────────────────────────────────
        await _pump(tester, theme, boundaryKey, control);
        final rest = await _shoot(tester, boundaryKey);

        final rect = tester.getRect(find.byKey(buttonKey));
        // 采样点：控件内左侧 6px（避开居中文字的字形）。
        final probe = Offset(rect.left + 6, rect.center.dy);

        // ── 悬停 ─────────────────────────────────────────────
        final mouse = await _hoverAt(tester, rect.center);
        final hover = await _shoot(tester, boundaryKey);

        // ── 按压（鼠标左键按下；真实操作里按下必然同时处于悬停态，
        //    故此处 pressed 图 = 悬停 + 按压，与「静息→按压」的真实观感一致）
        await _pressDown(tester, mouse, rect.center);
        final pressed = await _shoot(tester, boundaryKey);
        await mouse.up();
        await _moveAway(tester, mouse);
        await mouse.removePointer();
        await _settle(tester);

        rows.add(
          _Row(
            tag: tag,
            structure: structure,
            control: name,
            hover: _diff(rest, hover),
            pressed: _diff(rest, pressed),
            extra: _diff(hover, pressed),
            restColor: _at(rest, probe),
            hoverColor: _at(hover, probe),
            pressedColor: _at(pressed, probe),
          ),
        );
      }
    }

    final report = File(_reportPath);
    report.parent.createSync(recursive: true);
    report.writeAsStringSync(_render(rows));

    // ── 判定 ────────────────────────────────────────────────
    // 语义：
    //   1. hover / pressed **在静息态之上**都必须可感知（白名单除外）；
    //   2. pressed 必须相对 hover 有额外反馈（同上白名单除外）——
    //      否则「按下」与「悬停」在视觉上无差别，五态名存实亡。
    final reported = <String>[];
    for (final r in rows) {
      if (!r.hover.perceivable && !_knownGaps.contains(r.id)) {
        reported.add('【新】${r.id} 悬停不可感知：${r.hover} '
            '静息面 ${_hex(r.restColor)} → 悬停面 ${_hex(r.hoverColor)}');
      }
      if (!r.pressed.perceivable) {
        reported.add('【新】${r.id} 按压不可感知：${r.pressed} '
            '静息面 ${_hex(r.restColor)} → 按压面 ${_hex(r.pressedColor)}');
      }
      if (!r.extra.perceivable && !_knownGaps.contains(r.id)) {
        reported.add('【新】${r.id} 按压相对悬停无额外反馈：${r.extra} '
            '悬停面 ${_hex(r.hoverColor)} → 按压面 ${_hex(r.pressedColor)}');
      }
    }
    expect(reported, isEmpty, reason: reported.join('\n'));

    // 白名单自清理：缺口修好后这里会失败，提示删条目。
    final stale = _knownGaps
        .where((id) => !rows.any((r) => r.id == id && !r.hover.perceivable))
        .toList();
    expect(stale, isEmpty, reason: '以下已登记缺口现在可感知了，请从 _knownGaps 删除：$stale');
  });
}

String _render(List<_Row> rows) {
  String mark(_StateMeasure m) => m.perceivable ? '✅' : '❌';
  final buf = StringBuffer()
    ..writeln('# T08 · hover / pressed 逐状态对账报告')
    ..writeln()
    ..writeln('夹具：`test/core/theme/t08_classic_states_report_test.dart`')
    ..writeln('生成时间：2026-09-22')
    ..writeln()
    ..writeln('## 口径')
    ..writeln()
    ..writeln('- **变化像素**：同一像素两态 max 通道差 ≥ $_changeThreshold '
        '计为变化（沿用 T06-3 / T07-4 同款判据）。')
    ..writeln('- **Δmax**：变化像素中的最大通道差（峰值强度）。')
    ..writeln('- **面色**：控件内左侧 6px 采样点（避开字形）的颜色。')
    ..writeln('- **按压增量**：`悬停图 → 按压图` 之差；❌ 表示按下时相对悬停没有任何额外反馈。')
    ..writeln('- hover / pressed 无正式 WCAG 门槛（SC 2.4.11 只管焦点），本表只报数，不发明门槛。')
    ..writeln()
    ..writeln('## 明细')
    ..writeln()
    ..writeln('| 组合/明暗 | 结构 | 控件 | 静息面 | 悬停面 | 按压面 '
        '| 悬停 | px | Δmax | 按压 | px | Δmax | 按压增量 |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|---|---|---|');

  String row(_Row r) => '| ${r.tag} | ${r.structure} | ${r.control} '
      '| ${_hex(r.restColor)} | ${_hex(r.hoverColor)} | ${_hex(r.pressedColor)} '
      '| ${mark(r.hover)} | ${r.hover.changedPx} | ${r.hover.maxChange} '
      '| ${mark(r.pressed)} | ${r.pressed.changedPx} | ${r.pressed.maxChange} '
      '| ${mark(r.extra)} Δ${r.extra.maxChange} |';

  for (final r in rows) {
    buf.writeln(row(r));
  }

  void section(String title, String structure) {
    final sel = rows.where((r) => r.structure == structure).toList();
    if (sel.isEmpty) return;
    buf
      ..writeln()
      ..writeln('### $title')
      ..writeln()
      ..writeln('| 组合/明暗 | 控件 | 悬停 Δmax | 按压 Δmax | 按压增量 Δmax |')
      ..writeln('|---|---|---|---|---|');
    for (final r in sel) {
      buf.writeln('| ${r.tag} | ${r.control} | ${r.hover.maxChange} '
          '| ${r.pressed.maxChange} | ${r.extra.maxChange} |');
    }
  }

  section('classic 侧（Material 显式主题，未自建 hover/pressed 叠色）', 'classic');
  section('玻璃侧（自建五态：hover +1 档 / pressed +2 档）', 'glass');

  return buf.toString();
}
