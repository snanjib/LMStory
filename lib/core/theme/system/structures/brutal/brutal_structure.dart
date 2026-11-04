import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_page_transitions.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_components.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_text_styles.dart';

/// 棱角结构（Brutal）：Neubrutalism 的工程翻译——票据/图章的印刷语言。
///
/// 层级用描边粗细表达（行内 2 / 卡片 3 / 浮层 4），色彩只做功能标注，
/// 按压把元素按进纸里（签名交互由 [BrutalMaterials] 与工厂组件承载）。
/// 结构配方只消费配色槽位（解耦保证）；黑白骨架占 90%（bg/surface
/// 槽承担"纸"；日间 ink、夜间 dividerStrong 承担结构"墨"），配色族槽位
/// 承担 10% 撞色（primary/accent 做功能块与状态标注）。
///
/// 红线：禁 blur、禁渐变、禁 bounce；卡片静止零阴影（阴影只在可按压
/// 元素，且由工厂组件的按压位移轴承载， elevation 无法表达该几何）；
/// 浮层（dialog/sheet）用描边与 scrim 表达，不引入投影层级。
class BrutalStructure implements LmStructure {
  const BrutalStructure();
  @override
  LmComponentKit buildComponents() => const BrutalComponents();

  @override
  String get id => 'brutal';

  @override
  ThemeData assemble(LmPalette palette, Brightness brightness) {
    final frame = BrutalMaterials.frameOf(palette);
    final frameInline =
        BorderSide(color: frame, width: BrutalRadii.frameInline);
    final isLight = brightness == Brightness.light;
    return ThemeData(
      brightness: brightness,
      splashFactory: InkRipple.splashFactory,
      fontFamily: LmUiTextStyles.fontFamily,
      colorScheme: isLight
          ? ColorScheme.light(
              primary: palette.primary,
              onPrimary: palette.onPrimary,
              secondary: palette.accent,
              onSecondary: palette.ink,
              error: palette.error,
              surface: palette.surface,
              onSurface: palette.ink,
            )
          : ColorScheme.dark(
              primary: palette.primary,
              onPrimary: palette.onPrimary,
              secondary: palette.accent,
              onSecondary: palette.ink,
              error: palette.error,
              surface: palette.surface,
              onSurface: palette.ink,
            ),
      scaffoldBackgroundColor: palette.bg,

      // ── 页面过渡：共享单源（scrim 钉 bg 的  黑帧修复全结构受益）──
      pageTransitionsTheme: lmPageTransitionsTheme(palette),

      // ── Text：BrutalTextStyles 字重分化（标题/标签 w700、正文 w500）──
      textTheme: const TextTheme(
        headlineLarge: BrutalTextStyles.display,
        titleLarge: BrutalTextStyles.title1,
        titleMedium: BrutalTextStyles.title2,
        titleSmall: BrutalTextStyles.title3,
        bodyLarge: BrutalTextStyles.body,
        bodyMedium: BrutalTextStyles.bodySm,
        bodySmall: BrutalTextStyles.caption,
        labelLarge: BrutalTextStyles.bodySm,
        labelSmall: BrutalTextStyles.labelUpper,
      ),

      // ── Card：frameCard 描边 + 直角 + elevation 0（静止零阴影，
      // 层级靠描边；可按压卡由工厂组件承载阴影与位移）────────────────
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
          side: BorderSide(color: frame, width: BrutalRadii.frameCard),
        ),
      ),

      // ── AppBar：纸面一体（bg 底），结构分隔线由消费面按需表达 ────
      appBarTheme: AppBarTheme(
        backgroundColor: palette.bg,
        foregroundColor: palette.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: BrutalTextStyles.title2.copyWith(color: palette.ink),
      ),

      // ── Buttons：cornerField 圆角 + frameInline 描边；度量（min 44 /
      // padding / 标签字重）全结构同源 LmButtonMetrics，只分化形状与
      // 描边（度量统一）。全态零 elevation——签名阴影与按压位移由
      // BrutalButton 工厂承载， elevation 表达不了 offset(4,4) 几何。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          disabledBackgroundColor: palette.surfaceVariant,
          disabledForegroundColor: palette.faint,
          elevation: LmButtonMetrics.flatElevation,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
            side: frameInline,
          ),
          textStyle: LmButtonMetrics.label(BrutalTextStyles.bodySm),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          disabledBackgroundColor: palette.surfaceVariant,
          disabledForegroundColor: palette.faint,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
            side: frameInline,
          ),
          textStyle: LmButtonMetrics.label(BrutalTextStyles.bodySm),
          // styleFrom 的 elevation 是基数（hover +2 / pressed +6），
          // copyWith 覆盖成全态 0（与 classic/glass 同口径）。
        ).copyWith(elevation: LmButtonMetrics.flatElevationProperty),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          disabledForegroundColor: palette.faint,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          side: frameInline,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
          ),
          textStyle: LmButtonMetrics.label(BrutalTextStyles.bodySm),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.ink,
          disabledForegroundColor: palette.faint,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.textPadding,
          textStyle: LmButtonMetrics.label(BrutalTextStyles.bodySm),
        ),
      ),

      // ── Input：白纸底 + frameInline 描边；聚焦描边转 3px
      //（焦点表达走描边加粗，不走辉光）──────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
          borderSide: frameInline,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
          borderSide: frameInline,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
          borderSide: BorderSide(
            color: frame,
            width: BrutalMaterials.focusFrameWidth,
          ),
        ),
        hintStyle: BrutalTextStyles.body.copyWith(color: palette.faint),
      ),

      // ── Dialog：frameOverlay 描边 + scrim 遮罩（浮层走描边不走投影，
      // elevation 0；TW 库 dialog 遮罩黑 80% 在此收敛为配色 scrim，
      // 与长会话工具面的疲劳度红线折中）────────────────────────────
      dialogTheme: DialogThemeData(
        constraints: const BoxConstraints(
          minWidth: 280,
          maxWidth: LmLayout.dialogMaxWidth,
        ),
        backgroundColor: palette.surfaceElevated,
        barrierColor: palette.scrim,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
          side: BorderSide(color: frame, width: BrutalRadii.frameOverlay),
        ),
        titleTextStyle: BrutalTextStyles.title2
            .copyWith(color: palette.ink, fontSize: 24, height: 1.3),
        contentTextStyle: BrutalTextStyles.body.copyWith(color: palette.muted),
        actionsPadding: const EdgeInsets.fromLTRB(
          LmSpacing.sLg,
          0,
          LmSpacing.sLg,
          LmSpacing.sLg,
        ),
      ),

      // ── Drawer：surface 纸面 + frameOverlay 描边 + scrim 遮罩 ──────
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        scrimColor: palette.scrim,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
          side: BorderSide(color: frame, width: BrutalRadii.frameOverlay),
        ),
      ),

      // ── BottomSheet：surfaceElevated + 直角 + frameOverlay 描边；
      // 浮层宽屏上限显式写出（值等于  默认）────────────────────────
      bottomSheetTheme: BottomSheetThemeData(
        constraints: const BoxConstraints(maxWidth: LmLayout.sheetMaxWidth),
        backgroundColor: palette.surfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
          side: BorderSide(color: frame, width: BrutalRadii.frameOverlay),
        ),
      ),

      // ── SnackBar：描边卡（floating 由消费面守卫）——行内档描边 +
      // 零 elevation（轻浮层提示，不进投影层级）──────────────────────
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.surface,
        contentTextStyle: BrutalTextStyles.body.copyWith(color: palette.ink),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
          side: frameInline,
        ),
        actionTextColor: palette.primary,
        dismissDirection: DismissDirection.horizontal,
      ),

      // ── Chip：cornerField 圆角 + frameInline 描边（药丸只给开关类，
      // chip 不做药丸）；标签一律 ink（对比度合规）─────────────────
      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceVariant,
        selectedColor: palette.primaryDim,
        labelStyle: BrutalTextStyles.caption.copyWith(color: palette.ink),
        secondaryLabelStyle: BrutalTextStyles.caption.copyWith(
          color: palette.ink,
          fontWeight: FontWeight.w700,
        ),
        side: frameInline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
        ),
      ),

      // ── Divider：装饰性 1px（内容分隔沿用槽位；结构分隔线由
      // dividerStrong 槽在消费面表达）────────────────────────────────
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
      ),

      // ── NavigationBar：surface 纸面 + 撞色预算内的 primaryDim 指示 ──
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.primaryDim,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),

      extensions: [
        LmTokens(
          structureId: id,
          paletteId: '',
          palette: palette,
          material: (isLight ? ColorScheme.light : ColorScheme.dark)(
            primary: palette.primary,
            onPrimary: palette.onPrimary,
            secondary: palette.accent,
            onSecondary: palette.ink,
            error: palette.error,
            surface: palette.surface,
            onSurface: palette.ink,
          ),
        ),
      ],
    );
  }
}
