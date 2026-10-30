import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';

/// CollapsibleSettingsSection / SettingsTile 测试（DOC-14 §3.4）。
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
      home: Scaffold(body: child),
    );
  }

  group('CollapsibleSettingsSection', () {
    testWidgets('点击标题行触发 onToggle', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(
        wrap(
          CollapsibleSettingsSection(
            title: '生成参数',
            isExpanded: true,
            onToggle: () => toggled++,
            child: const Text('温度滑块'),
          ),
        ),
      );

      await tester.tap(find.text('生成参数'));
      await tester.pump();
      expect(toggled, 1);
    });

    testWidgets('展开时显示子内容', (tester) async {
      await tester.pumpWidget(
        wrap(
          CollapsibleSettingsSection(
            title: '生成参数',
            isExpanded: true,
            onToggle: () {},
            child: const Text('温度滑块'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('温度滑块'), findsOneWidget);
      // 展开态箭头朝上
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
        0.5,
      );
    });

    testWidgets('折叠时不渲染子内容，箭头朝下', (tester) async {
      await tester.pumpWidget(
        wrap(
          CollapsibleSettingsSection(
            title: '生成参数',
            isExpanded: false,
            onToggle: () {},
            child: const Text('温度滑块'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('温度滑块'), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });
  });

  group('SettingsTile', () {
    testWidgets('渲染子内容并提供带边框容器', (tester) async {
      await tester.pumpWidget(
        wrap(const SettingsTile(child: Text('某配置项'))),
      );

      expect(find.text('某配置项'), findsOneWidget);
      // 带 Border 的 Container（DecoratedBox）
      expect(find.byType(DecoratedBox), findsWidgets);
    });
  });
}
