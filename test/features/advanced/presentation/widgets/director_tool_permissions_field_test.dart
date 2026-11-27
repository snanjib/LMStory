import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_permissions_field.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorToolPermissionsField Widget 测试
///
/// finish_round（提交本轮）是每轮正文唯一
/// 交付通道，权限 UI 锁死 allow——不渲染 ask/deny 选项，历史会话存的
/// deny/ask 值在展示与物化时都按 allow 兜底。其余 11 个工具三态不变。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );

  /// 取树上全部 12 工具行的 SegmentedButton
  List<SegmentedButton<ToolPermissionState>> allButtons(WidgetTester tester) =>
      tester
          .widgetList<SegmentedButton<ToolPermissionState>>(
            find.byType(SegmentedButton<ToolPermissionState>),
          )
          .toList();

  testWidgets('finish_round 与 finish_maintenance 行只渲染 allow 段（无 ask/deny 可选）',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        DirectorToolPermissionsField(
          sessionPermissions: null,
          globalPermissions: const {},
          onChanged: (_) {},
        ),
      ),
    );

    // 全部工具行各一个 SegmentedButton
    final buttons = allButtons(tester);
    expect(buttons, hasLength(ToolPermissions.allTools.length));

    // list_facts 与 finish_maintenance 均已渲染
    expect(find.text('list_facts'), findsOneWidget);
    expect(find.text('finish_maintenance'), findsOneWidget);

    // 恰好 2 行只有单段（finish_round 与 finish_maintenance），且均为 allow
    final single = buttons.where((b) => b.segments.length == 1).toList();
    expect(
      single,
      hasLength(ToolPermissions.lockedAllowTools.length),
      reason: '仅控制收尾工具行是单段',
    );
    for (final button in single) {
      expect(button.segments.single.value, ToolPermissionState.allow);
      expect(button.selected, {ToolPermissionState.allow});
    }

    // 其余工具行仍提供 deny 段（三态保持现状）
    final denySegments = [
      for (final b in buttons)
        ...b.segments.where(
          (s) => s.value == ToolPermissionState.deny,
        ),
    ];
    expect(
      denySegments,
      hasLength(
        ToolPermissions.allTools.length -
            ToolPermissions.lockedAllowTools.length,
      ),
    );
  });

  testWidgets('历史会话存锁定工具=deny：展示 allow 且物化为 allow', (tester) async {
    Map<String, String>? changed;
    await tester.pumpWidget(
      wrap(
        DirectorToolPermissionsField(
          sessionPermissions: const {
            'finish_round': 'deny',
            'finish_maintenance': 'deny',
          },
          globalPermissions: const {},
          onChanged: (v) => changed = v,
        ),
      ),
    );

    // 展示侧：锁定工具行（单段行）均选中 allow（读取侧兜底），而非 deny
    final buttons = allButtons(tester);
    final lockedButtons = buttons.where((b) => b.segments.length == 1).toList();
    expect(lockedButtons, hasLength(ToolPermissions.lockedAllowTools.length));
    for (final button in lockedButtons) {
      expect(button.selected, {ToolPermissionState.allow});
    }

    // 物化侧：改动任一其他工具（点第一行的 deny 段，触发选择变化）时，
    // 完整 map 里锁定工具固定写 allow（不允许把 deny 持久化下去）
    await tester.tap(
      find
          .descendant(
            of: find.byType(SegmentedButton<ToolPermissionState>).first,
            matching: find.byType(Text),
          )
          .last,
    );
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed, hasLength(ToolPermissions.allTools.length));
    expect(changed!['finish_round'], 'allow');
    expect(changed!['finish_maintenance'], 'allow');
  });
}
