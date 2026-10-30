import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_focus_ring.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_page_transitions.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_components.dart';

/// 经典结构：**唯一一份**主题装配骨架 + 一张两行的明暗差异表。
///
/// 历史形态是 `_light()` / `_dark()` 两个各 ~330 行的复制体（本文件曾有
/// 699 行），20 个组件主题逐字节重复两遍——改一处配色槽要记得改两处，漏掉
/// 一处就只有单档走样，且只有 golden 才抓得到。现在整份主题只写一遍
/// （[_theme]），明暗差异收敛成 [_difference] 返回的两项：
///
/// | 差异项 | 日间 | 夜间 |
/// |---|---|---|
/// | `brightness` | `Brightness.light` | `Brightness.dark` |
/// | `colorScheme` | `ColorScheme.light` | `ColorScheme.dark` |
///
/// 日间**不传** `onPrimary`、夜间**传** —— 这是历史口径，不是疏漏：
/// `ColorScheme.light` 的 `onPrimary` 默认即 `Colors.white`，与 classic 日间
/// palette 同值；`ColorScheme.dark` 的默认是黑色，必须显式覆盖。两档最终
/// 取到的值一致，但构造路径保留原样，以免 `ColorScheme` / `ThemeData` 的
/// 内部派生出现非预期分支差异——这条由 8 张 parity golden 逐像素校验。
///
/// 不变量由 `test/core/theme/t11_classic_structure_guard_test.dart` 锁住：
/// 「本文件只出现一次 `ThemeData(`」+「两档除 brightness / colorScheme 外
/// 全部主题字段逐项相等」。
class ClassicStructure implements LmStructure {
  const ClassicStructure();
  @override
  LmComponentKit buildComponents() => const ClassicComponents();
  @override
  String get id => 'classic';

  @override
  ThemeData assemble(LmPalette palette, Brightness brightness) {
    final diff = _difference(palette, brightness);
    return _theme(
      palette,
      brightness: diff.brightness,
      colorScheme: diff.colorScheme,
    );
  }

  /// 明暗两档的**全部差异**。除记录里的两项，其余组件主题由 [_theme] 共用。
  ({Brightness brightness, ColorScheme colorScheme}) _difference(
    LmPalette palette,
    Brightness brightness,
  ) {
    if (brightness == Brightness.light) {
      return (
        brightness: Brightness.light,
        colorScheme: ColorScheme.light(
          primary: palette.primary,
          secondary: palette.accent,
          error: palette.error,
          onSecondary: palette.ink,
        ),
      );
    }
    return (
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: palette.primary,
        secondary: palette.accent,
        error: palette.error,
        onPrimary: palette.onPrimary,
        onSecondary: palette.ink,
      ),
    );
  }

  /// 两档共用的骨架。**本文件唯一构造 `ThemeData` 的地方**——守卫会数
  /// 「`ThemeData(` 出现次数」来防止明暗再次分叉成两份复制体。
  ThemeData _theme(
    LmPalette palette, {
    required Brightness brightness,
    required ColorScheme colorScheme,
  }) =>
      ThemeData(
        brightness: brightness,
        colorScheme: colorScheme,
        splashFactory: InkRipple.splashFactory,
        fontFamily: LmUiTextStyles.fontFamily,
        scaffoldBackgroundColor: palette.bg,

        // ── 页面过渡：scrim 钉 bg，杜绝过渡期 surface 层闪现（黑帧）────
        pageTransitionsTheme: lmPageTransitionsTheme(palette),

        // ── Text ─────────────────────────────────────────────────────────
        textTheme: const TextTheme(
          headlineLarge: LmUiTextStyles.display,
          titleLarge: LmUiTextStyles.title1,
          titleMedium: LmUiTextStyles.title2,
          titleSmall: LmUiTextStyles.title3,
          bodyLarge: LmUiTextStyles.body,
          bodyMedium: LmUiTextStyles.bodySm,
          bodySmall: LmUiTextStyles.caption,
          labelLarge: LmUiTextStyles.bodySm,
          labelSmall: LmUiTextStyles.overline,
        ),

        // ── Card ─────────────────────────────────────────────────────────
        cardTheme: CardThemeData(
          color: palette.surface,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rLg)),
          ),
        ),

        // ── AppBar ───────────────────────────────────────────────────────
        appBarTheme: AppBarTheme(
          backgroundColor: palette.bg,
          foregroundColor: palette.ink,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontFamily: LmUiTextStyles.fontFamily,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            height: 1.4,
            letterSpacing: -0.01,
            color: palette.ink,
          ),
        ),

        // ── NavigationBar ────────────────────────────────────────────────
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: palette.surface,
          indicatorColor: palette.primaryDim,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return IconThemeData(color: palette.primary, size: 22);
            }
            return IconThemeData(color: palette.faint, size: 22);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return LmUiTextStyles.caption.copyWith(
                color: palette.primary,
                fontWeight: FontWeight.w600,
              );
            }
            return LmUiTextStyles.caption.copyWith(color: palette.faint);
          }),
        ),

        // ── Dialog ───────────────────────────────────────────────────────
        // constraints： 规格给模态对话框的上限是 560dp，Flutter 只在
        // DialogTheme.constraints 为 null 时退到 `minWidth: 280`（无上限），
        // 于是长内容弹窗在宽屏会被 IntrinsicWidth 顶到接近整窗宽。
        // 这里补上规格上限；短弹窗由 IntrinsicWidth 按内容收缩，观感不变。
        dialogTheme: DialogThemeData(
          constraints: const BoxConstraints(
            minWidth: 280,
            maxWidth: LmLayout.dialogMaxWidth,
          ),
          backgroundColor: palette.surfaceElevated,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rXl)),
          ),
          titleTextStyle: LmNarrativeTextStyles.narrativeDisplay
              .copyWith(color: palette.ink, fontSize: 24, height: 1.3),
          contentTextStyle: LmUiTextStyles.body.copyWith(color: palette.muted),
          actionsPadding: const EdgeInsets.fromLTRB(
            LmSpacing.sLg,
            0,
            LmSpacing.sLg,
            LmSpacing.sLg,
          ),
        ),

        // ── BottomSheet ──────────────────────────────────────────────────
        bottomSheetTheme: BottomSheetThemeData(
          // 显式写下「底部浮层不通铺宽屏」的口径（值等于  默认，
          // 因此观感零变化；此前是隐式继承框架默认，不成口径）。
          constraints: const BoxConstraints(maxWidth: LmLayout.sheetMaxWidth),
          backgroundColor: palette.surfaceElevated,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(LmRadius.rXl)),
          ),
        ),

        // ── SnackBar ─────────────────────────────────────────────────────
        snackBarTheme: SnackBarThemeData(
          backgroundColor: palette.surfaceElevated,
          contentTextStyle: LmUiTextStyles.body.copyWith(color: palette.ink),
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rMd)),
          ),
          actionTextColor: palette.primary,
          dismissDirection: DismissDirection.horizontal,
        ),

        // ── Divider ──────────────────────────────────────────────────────
        dividerTheme: DividerThemeData(
          color: palette.divider,
          thickness: 1,
          space: 1,
        ),

        // ── Input ────────────────────────────────────────────────────────
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: palette.surfaceVariant,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rFull)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rFull)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius:
                const BorderRadius.all(Radius.circular(LmRadius.rFull)),
            borderSide: BorderSide(color: palette.primary, width: 1.5),
          ),
          hintStyle: LmUiTextStyles.bodySm.copyWith(color: palette.faint),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sLg,
            vertical: LmSpacing.sMd,
          ),
        ),

        // ── FilledButton：度量与 Elevated 同源（度量统一）────────────
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: palette.primary,
            foregroundColor: palette.onPrimary,
            disabledBackgroundColor: palette.primary.withValues(alpha: 0.38),
            disabledForegroundColor: palette.onPrimary.withValues(alpha: 0.38),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(LmRadius.rMd)),
            ),
            padding: LmButtonMetrics.solidPadding,
            minimumSize: LmButtonMetrics.minimumSize,
            textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
            elevation: LmButtonMetrics.flatElevation,
          ).copyWith(
            // 键盘焦点内环：onPrimary 2px。此前只吃 Material 默认
            // 12% 叠色，实测聚焦/未聚焦像素对比度变化仅 1.25:1；改后夜间档
            // 实测 8.09:1（日间档同法达标）。
            side: LmFocusRing.side(focused: () => LmFocusRing.solid(palette)),
          ),
        ),

        // ── ElevatedButton ───────────────────────────────────────────────
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: palette.primary,
            foregroundColor: palette.onPrimary,
            disabledBackgroundColor: palette.primary.withValues(alpha: 0.38),
            disabledForegroundColor: palette.onPrimary.withValues(alpha: 0.38),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(LmRadius.rMd)),
            ),
            padding: LmButtonMetrics.solidPadding,
            minimumSize: LmButtonMetrics.minimumSize,
            textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
          ).copyWith(
            // `ElevatedButton.styleFrom` 的 `elevation` 是**基数**——
            // 它把 hover 算成 `elevation + 2`、pressed 算成 `elevation + 6`
            // （见 material/elevated_button.dart 的 styleFrom 实现）。
            // 只写 `elevation: 0` 实测得到 hover 2 / pressed 6，扁平口径失效；
            // 必须用 copyWith 覆盖成全态 0。
            elevation: LmButtonMetrics.flatElevationProperty,
            // 键盘焦点内环：同 FilledButton。
            side: LmFocusRing.side(focused: () => LmFocusRing.solid(palette)),
          ),
        ),

        // ── TextButton ───────────────────────────────────────────────────
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: palette.primary,
            padding: LmButtonMetrics.textPadding,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(LmRadius.rSm)),
            ),
            minimumSize: LmButtonMetrics.minimumSize,
            textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
            elevation: LmButtonMetrics.flatElevation,
          ).copyWith(
            // 键盘焦点内环：ink 2px，对页面底色 ≥12:1。
            side: LmFocusRing.side(focused: () => LmFocusRing.plain(palette)),
          ),
        ),

        // ── OutlinedButton ───────────────────────────────────────────────
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.primary,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(LmRadius.rMd)),
            ),
            padding: LmButtonMetrics.solidPadding,
            minimumSize: LmButtonMetrics.minimumSize,
            textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
            elevation: LmButtonMetrics.flatElevation,
          ).copyWith(
            // 键盘焦点环：ink 4px。既有描边占住最外 1.5px，
            // 取 4px 才能让「新变化且 ≥3:1」的带达到 2.5px（SC 2.4.11 厚度）。
            side: LmFocusRing.side(
              focused: () => LmFocusRing.outlined(palette),
              idle: () => LmFocusRing.outlinedIdle(palette),
            ),
          ),
        ),

        // ── Chip ─────────────────────────────────────────────────────────
        chipTheme: ChipThemeData(
          backgroundColor: palette.surfaceVariant,
          selectedColor: palette.primaryDim,
          labelStyle: LmUiTextStyles.caption.copyWith(color: palette.ink),
          secondaryLabelStyle: LmUiTextStyles.caption.copyWith(
            color: palette.primary,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sSm,
            vertical: LmSpacing.s2xs,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rFull)),
          ),
          side: BorderSide.none,
        ),

        // ── FloatingActionButton ─────────────────────────────────────────
        // FAB **不**套扁平口径：浮起是 FAB 的成立条件（它靠 elevation 与
        // 内容层分离，钉 0 后只是一块方角色块）。此处保留 2（默认 6，
        // 已压低），是与「四类按钮钉 0」并列的显式例外，非遗漏。
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          elevation: 2,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(LmRadius.rMd)),
          ),
        ),

        // ── TabBar ───────────────────────────────────────────────────────
        tabBarTheme: TabBarThemeData(
          labelColor: palette.primary,
          unselectedLabelColor: palette.faint,
          indicatorColor: palette.primary,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle:
              LmUiTextStyles.caption.copyWith(fontWeight: FontWeight.w600),
          unselectedLabelStyle: LmUiTextStyles.caption,
        ),

        // ── Switch ───────────────────────────────────────────────────────
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return palette.primary;
            }
            return palette.faint;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return palette.primary.withValues(alpha: 0.5);
            }
            return palette.divider;
          }),
        ),

        // ── ProgressIndicator ────────────────────────────────────────────
        progressIndicatorTheme: ProgressIndicatorThemeData(
          color: palette.primary,
          linearTrackColor: palette.divider,
        ),
      );
}
