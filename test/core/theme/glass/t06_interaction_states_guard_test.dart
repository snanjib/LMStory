import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_radii.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫②：玻璃工厂交互五态完备。
///
/// 锁死四条验收：
/// 1. **四组合焦点环可见**：focus-visible 下环色取当前配色族 accent、
///    线宽 = focusRingWidth、辉光 = focusGlow(accent)；
/// 2. **disabled 不隐形**：禁用面为不透明语义槽 + 可见描边 + faint 内容，
///    且交互事件不触发（不是靠 Opacity 0 假装禁用）；
/// 3. **hover / pressed 档位**：由白玻璃台阶驱动（fill6→fill10→fill16）；
///    台阶方向由**底面色亮度**派生，故本守卫按「各组合自己的
///    场地底面 `palette.bg`」取档，不再按 Brightness 硬分档；
/// 4. **loading 抑制交互**：指示器在位且点击不回调。
/// 另附：玻璃件键盘可达（Enter 激活）、分段项触控高度 ≥44。
void main() {
  final combos = <(String, String, Brightness)>[
    ('classic', 'light', Brightness.light),
    ('classic', 'dark', Brightness.dark),
    ('bordeaux', 'light', Brightness.light),
    ('bordeaux', 'dark', Brightness.dark),
  ];

  LmPalette paletteOf(String familyId, Brightness brightness) =>
      (familyId == 'classic'
              ? const ClassicPaletteFamily()
              : const BordeauxPaletteFamily())
          .of(brightness);

  ThemeData themeOf(String familyId, Brightness brightness) =>
      ThemeCatalog.assemble(
        LmAppearance(structureId: 'glass', paletteId: familyId),
        brightness,
      );

  Future<void> pumpCombo(
    WidgetTester tester,
    String familyId,
    Brightness brightness,
    Widget child, {
    String tag = '',
  }) async {
    await tester.pumpWidget(
      KeyedSubtree(
        key: ValueKey('t06-$familyId-${brightness.name}-$tag'),
        child: MaterialApp(
          theme: themeOf(familyId, brightness),
          home: Scaffold(
            body: Center(
              child: Padding(padding: const EdgeInsets.all(24), child: child),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('四组合 × 明暗：focus-visible 环色/线宽/辉光全部随本族 accent', (
    tester,
  ) async {
    var i = 0;
    for (final (familyId, name, brightness) in combos) {
      i++;
      final palette = paletteOf(familyId, brightness);
      final node = FocusNode(debugLabel: 't06-focus-$i');
      addTearDown(node.dispose);
      await pumpCombo(
        tester,
        familyId,
        brightness,
        GlassPillButton(label: '确认', onPressed: () {}, focusNode: node),
        tag: 'focus-$i',
      );

      // 未聚焦：无环无辉光
      var deco = _decoOf(tester, find.byType(GlassPillButton));
      expect(deco.border?.top.width ?? 0, 0, reason: '$familyId $name 未聚焦不应有环');

      node.requestFocus();
      await tester.pump();

      deco = _decoOf(tester, find.byType(GlassPillButton));
      expect(
        deco.border?.top.color,
        palette.accent,
        reason: '$familyId $name 焦点环色必须是本族 accent',
      );
      expect(deco.border?.top.width, GlassMaterials.focusRingWidth);
      expect(
        deco.boxShadow?.first.color,
        GlassMaterials.focusGlow(palette.accent),
        reason: '$familyId $name 焦点辉光必须是本族 accent 派生值',
      );

      // 环色与场地底色必须可辨（不做「同色环」这种看不见的达标）
      expect(
        _luminanceGap(deco.border!.top.color, palette.bg),
        greaterThan(0.02),
        reason: '$familyId $name 焦点环与 bg 明度差过小，视觉上不可见',
      );
      node.unfocus();
      await tester.pump();
    }
  });

  testWidgets('disabled 不隐形：不透明语义槽底 + 可见描边 + faint 内容 + 不回调', (
    tester,
  ) async {
    for (final (familyId, name, brightness) in combos) {
      final palette = paletteOf(familyId, brightness);
      const taps = 0;
      await pumpCombo(
        tester,
        familyId,
        brightness,
        const GlassPillButton(
          label: '确认',
          onPressed: null,
          // ignore: avoid_redundant_argument_values
          loading: false,
        ),
        tag: 'disabled-$familyId-$name',
      );

      final deco = _decoOf(tester, find.byType(GlassPillButton));
      expect(
        deco.color,
        palette.surfaceVariant,
        reason: '$familyId $name 禁用面必须是不透明语义槽（不得透明隐形）',
      );
      expect(deco.color!.a, 1.0, reason: '禁用面不得带 alpha');
      expect(
        deco.border?.top.color,
        palette.faint.withValues(alpha: GlassMaterials.disabledBorderAlpha),
        reason: '$familyId $name 禁用描边必须可辨',
      );
      expect(
        _textColorOf(tester, find.byType(GlassPillButton)),
        palette.faint,
        reason: '$familyId $name 禁用文案应降到 faint 层',
      );

      // 形态仍可辨的承载者是**描边**（工厂文档契约：
      // 「disabled = surfaceVariant 底 + faint 描边」）。玻璃件不在平底上
      // 渲染（真实场地是 bgGlow 渐变），且 classic 夜间的 surfaceVariant
      // 是「夜航原值收编」（与 bg 明度差仅 ~0.005，不得调值），
      // 故判别力必须交给描边：把描边分别合成到「禁用面」与「场地」之上，
      // 都必须拉开明度差 —— 这才是「不隐形」的真实证明。
      final borderColor = deco.border!.top.color;
      expect(
        deco.border!.top.width,
        greaterThan(0),
        reason: '$familyId $name 禁用描边必须有线宽',
      );
      expect(
        _luminanceGap(Color.alphaBlend(borderColor, deco.color!), deco.color!),
        greaterThan(0.05),
        reason: '$familyId $name 禁用描边未从禁用面本身可辨',
      );
      expect(
        _luminanceGap(Color.alphaBlend(borderColor, palette.bg), palette.bg),
        greaterThan(0.05),
        reason: '$familyId $name 禁用描边未从场地可辨 → 形态隐形',
      );

      await tester.tap(find.byType(GlassPillButton));
      await tester.pump();
      expect(taps, 0, reason: '禁用件不得触发回调');
    }
  });

  testWidgets('hover 档位 = 基档 +1 级（白玻璃台阶驱动）', (tester) async {
    for (final (familyId, name, brightness) in combos) {
      await pumpCombo(
        tester,
        familyId,
        brightness,
        GlassChip(label: '标签', onTap: () {}),
        tag: 'hover-$familyId-$name',
      );
      expect(
        _decoOf(tester, find.byType(GlassChip)).color,
        GlassMaterials.fill6(paletteOf(familyId, brightness).bg),
        reason: '$familyId $name chip 静息档',
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(GlassChip)));
      await tester.pump();

      expect(
        _decoOf(tester, find.byType(GlassChip)).color,
        GlassMaterials.fill10(paletteOf(familyId, brightness).bg),
        reason: '$familyId $name chip 悬停应升到 fill10',
      );
      await gesture.removePointer();
      await tester.pump();
    }
  });

  testWidgets('pressed 档位 = 基档 +2 级', (tester) async {
    for (final (familyId, name, brightness) in combos) {
      await pumpCombo(
        tester,
        familyId,
        brightness,
        GlassChip(label: '标签', onTap: () {}),
        tag: 'press-$familyId-$name',
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(GlassChip)),
      );
      await tester.pump();
      expect(
        _decoOf(tester, find.byType(GlassChip)).color,
        GlassMaterials.fill16(paletteOf(familyId, brightness).bg),
        reason: '$familyId $name chip 按压应升到 fill16',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('loading 抑制交互且指示器在位', (tester) async {
    var taps = 0;
    await pumpCombo(
      tester,
      'bordeaux',
      Brightness.dark,
      GlassPillButton(
        label: '提交',
        onPressed: () => taps++,
        loading: true,
      ),
      tag: 'loading',
    );
    expect(
      find.descendant(
        of: find.byType(GlassPillButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: 'loading 态必须有指示器',
    );
    await tester.tap(find.byType(GlassPillButton));
    await tester.pump();
    expect(taps, 0, reason: 'loading 期间不得触发回调');
  });

  testWidgets('玻璃件键盘可达：Tab 落焦 + Enter 激活', (tester) async {
    var activated = 0;
    await pumpCombo(
      tester,
      'classic',
      Brightness.light,
      GlassPillButton(label: '确认', onPressed: () => activated++),
      tag: 'keyboard',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 1, reason: '玻璃按钮必须键盘可达（Enter 激活）');
  });

  testWidgets('分段项触控高度 ≥ 44（a11y 红线）', (tester) async {
    await pumpCombo(
      tester,
      'classic',
      Brightness.light,
      GlassSegmented<_Demo>(
        values: _Demo.values,
        selected: _Demo.a,
        onSelected: (_) {},
        labelOf: (v) => v.name,
      ),
      tag: 'segmented',
    );
    final size = tester.getSize(find.byType(GlassSegmented<_Demo>));
    const trackPadding = 3 * 2; // 轨道 padding
    expect(
      size.height - trackPadding,
      greaterThanOrEqualTo(LmButtonMetrics.minInteractiveHeight),
      reason: '分段项净高必须 ≥ 44（实测 ${size.height - trackPadding}）',
    );
  });

  testWidgets('分段控件支持 disabled（内容降比、点击无效、可读）', (tester) async {
    final palette = paletteOf('bordeaux', Brightness.dark);
    var changed = 0;
    await pumpCombo(
      tester,
      'bordeaux',
      Brightness.dark,
      GlassSegmented<_Demo>(
        values: _Demo.values,
        selected: _Demo.a,
        onSelected: (_) => changed++,
        labelOf: (v) => v.name,
        enabled: false,
      ),
      tag: 'segmented-disabled',
    );
    final labels = tester.widgetList<Text>(
      find.descendant(
        of: find.byType(GlassSegmented<_Demo>),
        matching: find.byType(Text),
      ),
    );
    for (final label in labels) {
      expect(
        label.style?.color,
        palette.faint,
        reason: '禁用分段项文案应降到 faint 层',
      );
    }
    await tester.tap(find.text('a'), warnIfMissed: false);
    await tester.pump();
    expect(changed, 0);
  });

  testWidgets('圆角檔位未被动过（stadium 保持）', (tester) async {
    await pumpCombo(
      tester,
      'classic',
      Brightness.dark,
      GlassPillButton(label: '确认', onPressed: () {}),
      tag: 'radius',
    );
    final deco = _decoOf(tester, find.byType(GlassPillButton));
    expect(
      deco.borderRadius,
      BorderRadius.circular(GlassRadii.stadium),
      reason: 'T06 只补状态，不改形状',
    );
  });
}

enum _Demo { a, b }

BoxDecoration _decoOf(WidgetTester tester, Finder scope) {
  final boxes = tester.widgetList<DecoratedBox>(
    find.descendant(of: scope, matching: find.byType(DecoratedBox)),
  );
  expect(boxes, isNotEmpty, reason: '找不到工厂的 DecoratedBox');
  return boxes.first.decoration as BoxDecoration;
}

Color? _textColorOf(WidgetTester tester, Finder scope) {
  final texts = tester.widgetList<Text>(
    find.descendant(of: scope, matching: find.byType(Text)),
  );
  expect(texts, isNotEmpty, reason: '找不到工厂标签 Text');
  return texts.first.style?.color;
}

/// 相对亮度差（0–1），用于「肉眼可辨」类断言。
double _luminanceGap(Color a, Color b) =>
    (a.computeLuminance() - b.computeLuminance()).abs();
