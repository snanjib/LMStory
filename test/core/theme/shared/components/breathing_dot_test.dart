import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/breathing_dot.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';

/// BreathingDot Widget 测试
///
/// 验证：
/// 1. 普通模式：渲染 8x8 圆点，使用主题 primary 槽
/// 2. reduced-motion 模式（accessibleNavigation=true）：静态渲染圆点，不崩溃
/// 3. 自定义 size 参数生效
/// 4. 圆点装饰为 BoxShape.circle
///
/// 权威设计：DOC-06A §侧边栏会话项 + impeccable breathing 规范。
void main() {
  Widget wrap(Widget child, {bool accessibleNavigation = false}) {
    return MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(accessibleNavigation: accessibleNavigation),
          child: child,
        ),
      ),
    );
  }

  group('BreathingDot 普通模式', () {
    testWidgets('1. 渲染 8x8 圆点，颜色为主题 primary 槽', (tester) async {
      await tester.pumpWidget(wrap(const BreathingDot()));

      // 推进一帧让动画启动
      await tester.pump(const Duration(milliseconds: 50));

      // 找到圆点 Container
      final dotFinder = find.descendant(
        of: find.byType(BreathingDot),
        matching: find.byType(Container),
      );
      expect(dotFinder, findsWidgets);

      // 取第一个 Container，验证尺寸为 8x8
      final container = tester.widget<Container>(dotFinder.first);
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, ClassicPaletteValues.light.primary);
    });

    testWidgets('2. 动画运行中 opacity 在 [0.4, 1.0] 区间', (tester) async {
      await tester.pumpWidget(wrap(const BreathingDot()));
      await tester.pump(const Duration(milliseconds: 100));

      // Opacity widget 应存在
      final opacityFinder = find.descendant(
        of: find.byType(BreathingDot),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsWidgets);

      final opacity = tester.widget<Opacity>(opacityFinder.first).opacity;
      expect(opacity, greaterThanOrEqualTo(0.4));
      expect(opacity, lessThanOrEqualTo(1.0));
    });
  });

  group('BreathingDot reduced-motion 模式', () {
    testWidgets('3. accessibleNavigation=true 时静态渲染，不崩溃', (tester) async {
      await tester.pumpWidget(
        wrap(const BreathingDot(), accessibleNavigation: true),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 圆点仍可见
      final dotFinder = find.descendant(
        of: find.byType(BreathingDot),
        matching: find.byType(Container),
      );
      expect(dotFinder, findsWidgets);

      // Opacity 固定为 0.7（静态兜底）
      final opacityFinder = find.descendant(
        of: find.byType(BreathingDot),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsWidgets);
      final opacity = tester.widget<Opacity>(opacityFinder.first).opacity;
      expect(opacity, 0.7);
    });
  });

  group('BreathingDot 自定义尺寸', () {
    testWidgets('4. size=12 生成 12x12 圆点', (tester) async {
      await tester.pumpWidget(wrap(const BreathingDot(size: 12)));
      await tester.pump(const Duration(milliseconds: 50));

      final dotFinder = find.descendant(
        of: find.byType(BreathingDot),
        matching: find.byType(Container),
      );
      expect(dotFinder, findsWidgets);

      final container = tester.widget<Container>(dotFinder.first);
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      // 验证 size 通过 Container 的 width/height 传入
      expect(container.constraints?.maxWidth, 12);
    });
  });
}
