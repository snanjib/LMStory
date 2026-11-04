import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/breathing_dot.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/presentation/widgets/sidebar_session_item.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// SidebarSessionItem 测试
///
/// - isGenerating 行为：呼吸点 / star / chat 图标优先级
/// -  两行布局：模式标签 + 模式图标 + 会话标题
///
/// 权威设计：DOC-06A §侧边栏会话项。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatSession buildSession({
    bool isStarred = false,
    String mode = 'simple',
    String title = '测试会话',
  }) {
    return ChatSession(
      sessionId: 'sess-001',
      title: title,
      mode: mode,
      createdAt: DateTime(2026, 7),
      lastActiveAt: DateTime(2026, 7),
      messageCount: 0,
      isStarred: isStarred,
    );
  }

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.ltr,
            child: Material(child: child),
          ),
        ),
      ),
    );
  }

  SidebarSessionItem buildItem({
    required bool isGenerating,
    bool isStarred = false,
    String mode = 'simple',
    String title = '测试会话',
    bool isSelected = false,
  }) {
    return SidebarSessionItem(
      session: buildSession(
        isStarred: isStarred,
        mode: mode,
        title: title,
      ),
      index: 0,
      isSelected: isSelected,
      isGenerating: isGenerating,
      onTap: () {},
      onDelete: () {},
      onRename: () {},
      onToggleStar: () {},
      onCopy: () {},
    );
  }

  group('SidebarSessionItem isGenerating 行为', () {
    testWidgets('1. isGenerating=false：显示 chat 图标，不显示 BreathingDot',
        (tester) async {
      await tester.pumpWidget(wrap(buildItem(isGenerating: false)));

      expect(find.byType(BreathingDot), findsNothing);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    });

    testWidgets('2. isGenerating=true：显示 BreathingDot，不显示 chat 图标',
        (tester) async {
      await tester.pumpWidget(wrap(buildItem(isGenerating: true)));

      expect(find.byType(BreathingDot), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    });

    testWidgets('3. isGenerating=true 优先于 isStarred：即使加星也显示呼吸点',
        (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: true, isStarred: true)),
      );

      // 生成中：呼吸点显示，star 图标不显示
      expect(find.byType(BreathingDot), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('4. isGenerating=false + isStarred=true：显示 star 图标',
        (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false, isStarred: true)),
      );

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byType(BreathingDot), findsNothing);
    });
  });

  group('B4-6 两行布局', () {
    testWidgets('A. simple 模式：显示"对话"标签 + chat_bubble_outline 图标',
        (tester) async {
      await tester.pumpWidget(wrap(buildItem(isGenerating: false)));

      expect(find.text('对话'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.byIcon(Icons.auto_stories), findsNothing);
    });

    testWidgets('B. intermediate 模式：显示"故事"标签 + auto_stories 图标',
        (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false, mode: 'intermediate')),
      );

      expect(find.text('故事'), findsOneWidget);
      expect(find.byIcon(Icons.auto_stories), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    });

    testWidgets('C. 会话标题显示在第二行', (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false, title: '勇者的冒险旅程')),
      );

      // 模式标签和标题都应可见
      expect(find.text('对话'), findsOneWidget);
      expect(find.text('勇者的冒险旅程'), findsOneWidget);
    });

    testWidgets('D. 模式色彩区分：simple=primary, intermediate=accent',
        (tester) async {
      // simple 模式图标颜色 = primary
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false)),
      );
      await tester.pumpAndSettle();

      var icon = tester.widget<Icon>(
        find.byIcon(Icons.chat_bubble_outline),
      );
      const colors = ClassicPaletteValues.light;
      expect(icon.color, colors.primary);

      // intermediate 模式图标颜色 = accent
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false, mode: 'intermediate')),
      );
      await tester.pumpAndSettle();

      icon = tester.widget<Icon>(find.byIcon(Icons.auto_stories));
      expect(icon.color, colors.accent);
    });

    testWidgets('E. 选中状态：标题仍显示，模式标签仍显示', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildItem(
            isGenerating: false,
            isSelected: true,
            title: '选中的会话',
          ),
        ),
      );

      // 选中时两行内容都应可见
      expect(find.text('对话'), findsOneWidget);
      expect(find.text('选中的会话'), findsOneWidget);
    });

    testWidgets('F. 故事模式生成中：显示呼吸点 + "故事"标签', (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: true, mode: 'intermediate')),
      );

      // 生成中：呼吸点显示，模式图标不显示，但标签仍可见
      expect(find.byType(BreathingDot), findsOneWidget);
      expect(find.byIcon(Icons.auto_stories), findsNothing);
      expect(find.text('故事'), findsOneWidget);
    });

    testWidgets('G. advanced（导演）模式：显示"导演"标签 + theater_comedy 图标',
        (tester) async {
      await tester.pumpWidget(
        wrap(buildItem(isGenerating: false, mode: 'advanced')),
      );

      // 导演会话此前落入 else 分支显示"对话"，属 mode 误标 bug（解耦重构 0.2）
      expect(find.text('导演'), findsOneWidget);
      expect(find.byIcon(Icons.theater_comedy), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      expect(find.byIcon(Icons.auto_stories), findsNothing);
    });
  });
}
