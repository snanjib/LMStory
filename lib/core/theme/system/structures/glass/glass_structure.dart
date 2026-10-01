import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_page_transitions.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_components.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart'
    show GlassBackdrop;
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_radii.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_text_styles.dart';

/// 琉璃结构（Glass）：磨砂玻璃材质语言。
///
/// 结构配方只消费配色槽位与 white-alpha 台阶（解耦保证）；装配产出
/// 全局 ThemeData（底座），玻璃表面由工厂组件逐件 craft。场地渐变
/// （bgGlow）由 [GlassBackdrop] 工厂绘制，scaffoldBackgroundColor 仍为
/// bg（无装饰场景兜底）。
class GlassStructure implements LmStructure {
  const GlassStructure();
  @override
  LmComponentKit buildComponents() => const GlassComponents();

  @override
  String get id => 'glass';

  @override
  ThemeData assemble(LmPalette palette, Brightness brightness) {
    final isLight = brightness == Brightness.light;
    return ThemeData(
      brightness: brightness,
      splashFactory: InkRipple.splashFactory,
      fontFamily: GlassTextStyles.sansFamily,
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

      // ── 页面过渡：scrim 钉 bg，杜绝过渡期 surface 层盖住场地（黑帧）──
      pageTransitionsTheme: lmPageTransitionsTheme(palette),

      // ── Text：UI 层沿捕获阶梯；技术字幕层由工厂样式承载 ─────────
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

      // ── Card： fill6 + card 圆角 + 顶部内侧高光 ────────────────
      cardTheme: CardThemeData(
        color: GlassMaterials.fill6(palette.bg),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassRadii.card),
        ),
      ),

      // ── AppBar：透明浮在场地渐变上 ───────────────────────────────
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: LmUiTextStyles.title2.copyWith(color: palette.ink),
      ),

      // ── Buttons：主操作= 实体（夜间白药丸/日间酒药丸）。
      // 度量（min 44 / padding / 标签字重）与 Classic 同源 LmButtonMetrics，
      // 只保留 stadium 形状分化（度量统一）──────────────────────────
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          disabledBackgroundColor: palette.faint.withValues(alpha: 0.2),
          disabledForegroundColor: palette.faint,
          // 同结构 elevated 的口径：全态零 elevation。 默认 hover 抬 1
          // 会凭空长出一道纯黑阴影，而琉璃的阴影由本结构自己的材质系统
          // 表达（长阴影 /  浮起短阴影），不认  的 colorScheme.shadow。
          elevation: LmButtonMetrics.flatElevation,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
          ),
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          disabledBackgroundColor: palette.faint.withValues(alpha: 0.2),
          disabledForegroundColor: palette.faint,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
          ),
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
          // `ElevatedButton.styleFrom` 的 elevation 是基数
          //（hover = +2 / pressed = +6），只写 0 会得到 hover 2 / pressed 6。
          // 用 copyWith 覆盖成全态 0，与 classic 同口径。
        ).copyWith(elevation: LmButtonMetrics.flatElevationProperty),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          side: BorderSide(color: GlassMaterials.fill22(palette.bg)),
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
          ),
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.ink,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.textPadding,
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ),
      ),

      // ── Input：resting=surfaceVariant；input 圆角 ────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassRadii.input),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassRadii.input),
          borderSide: BorderSide(
            color: palette.accent,
            width: GlassMaterials.focusRingWidth,
          ),
        ),
        hintStyle: LmUiTextStyles.body.copyWith(color: palette.faint),
      ),

      // ── Dialog： 模态任务面（surfaceElevated+fill22 台阶）+ 顶部内侧
      // 高光描边 +  阴影；遮罩用配色 scrim 替代默认黑54，保持场地色性并
      // 拉开图底。圆角与模态/弹层同档（GlassRadii.card）──────────────────
      dialogTheme: DialogThemeData(
        // 宽屏上限（规格 560dp；Flutter 默认无上限，长内容弹窗会被
        // IntrinsicWidth 顶到接近整窗宽）。短弹窗按内容收缩，观感不变。
        constraints: const BoxConstraints(
          minWidth: 280,
          maxWidth: LmLayout.dialogMaxWidth,
        ),
        backgroundColor: GlassMaterials.modalSurface(
          brightness,
          palette.surfaceElevated,
        ),
        barrierColor: palette.scrim.withValues(alpha: 0.5),
        elevation: GlassMaterials.t2Elevation,
        shadowColor: GlassMaterials.t2ShadowColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassRadii.card),
          side: const BorderSide(color: GlassMaterials.topInnerHighlight),
        ),
      ),

      // ── Drawer： 平玻璃面板（面板自带场地由消费面包 GlassBackdrop）；
      // 遮罩用配色 scrim（酒色）替代默认黑54，避免抽屉区死灰 ────────
      drawerTheme: DrawerThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrimColor: palette.scrim,
      ),

      // ── BottomSheet： 由 GlassBottomSheet 工厂承载 ────────────
      // constraints：浮层宽屏上限显式写出（值等于  默认，观感零变化）。
      bottomSheetTheme: const BottomSheetThemeData(
        constraints: BoxConstraints(maxWidth: LmLayout.sheetMaxWidth),
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GlassRadii.card),
          ),
        ),
      ),

      // ── SnackBar： fill10 + stadium（floating 由消费面守卫）───
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: GlassMaterials.fill10(palette.bg),
        contentTextStyle: LmUiTextStyles.bodySm.copyWith(color: palette.ink),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassRadii.stadium),
        ),
      ),

      // ── Chip：stadium 药丸 ────────────────────────────────────────
      chipTheme: ChipThemeData(
        backgroundColor: GlassMaterials.fill6(palette.bg),
        selectedColor: GlassMaterials.fill16(palette.bg),
        //  对比度合规：chip 标签一律 ink（波尔多红线：白玻璃填充底上
        // 文字用 ink；muted 对 fill16/22 仅 4.61/3.76 不达标）。
        // 选中态前景经 secondaryLabelStyle 显式切换。
        labelStyle: LmUiTextStyles.caption.copyWith(color: palette.ink),
        secondaryLabelStyle: LmUiTextStyles.caption.copyWith(
          color: palette.ink,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassRadii.stadium),
        ),
      ),

      // ── Divider：装饰性 1px ───────────────────────────────────────
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
      ),

      // ── NavigationBar：surface 底（玻璃表面由工厂承载）──────────
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
