import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';

/// 结构无关的统一浮层入口。
///
/// 业务代码只调 [showLmSheet] / [showLmDialog]，不再感知结构轴、不再
/// 自带面层：经典组合**参数逐参透传**（backgroundColor / elevation / shape /
/// barrierColor 与直接调 `showModalBottomSheet` / `showDialog` 等值，零视觉
/// 变化）；琉璃组合面层来自琉璃工厂（sheet = `GlassBottomSheet`，
/// dialog = 主题层玻璃模态面），遮罩统一配色 `palette.scrim`@50%（与抽屉
/// `drawerTheme.scrimColor` 同法，保留场地色性）。
///
/// 两个入口都会给浮层内容套一层键盘层（见 [_lmOverlayKeymap]）：
/// **Esc 关闭浮层**成为快捷键注册表里可枚举的一条绑定
/// （[LmShortcuts.idOverlayDismiss]），且尊重调用方的不可关闭声明。
///
/// 需要自定义高度 / `isScrollControlled` 的调用点同样走 [showLmSheet]；
/// 自绘内容需要「让出」面层时用 [LmOverlayContext.lmSheetFaceColor]
/// 把经典底色交给入口分流。
extension LmOverlayContext on BuildContext {
  /// 浮层遮罩色：琉璃 = `palette.scrim`@50%；经典 = null（走系统默认，
  /// 与直接调 show 系列等值）。
  Color? get lmOverlayBarrierColor {
    return lmUi.overlayBarrierColor(this);
  }

  /// 浮层面板底色：经典 = 调用方给定的语义槽原样（等值迁移既有自绘
  /// 面层）；琉璃 = transparent（琉璃面由 `GlassBottomSheet` 工厂承载，
  /// 自绘面层必须让位，否则遮住真玻璃）。
  Color lmSheetFaceColor(Color classicColor) =>
      lmUi.sheetFaceColor(this, classicColor);

  /// 页面级设置卡容器槽：经典 = 调用方给定槽位原样；琉璃 = 统一收敛到
  /// `palette.surfaceVariant`（同一琉璃页面上多套设置卡共用同一材质档，
  /// 消除「一张纯白一张异质」的割裂）。
  Color lmSettingCardFace(Color classicColor) =>
      lmUi.settingCardFaceColor(this, classicColor);
}

/// 底部浮层：`showModalBottomSheet` 的结构无关入口。
///
/// 经典组合所有参数原样透传；琉璃组合忽略调用方的 backgroundColor /
/// elevation / shape（面层与形状由 `GlassBottomSheet` 工厂锁定），遮罩取
/// [barrierColor]（调用方显式值优先，否则 `palette.scrim`@50%）。
///
/// [glassHandle] 仅琉璃组合生效：内容件已自绘拖拽把手（grabber）时传
/// false，避免双把手。
Future<T?> showLmSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  bool useSafeArea = false,
  bool isDismissible = true,
  bool enableDrag = true,
  Color? barrierColor,
  BoxConstraints? constraints,
  RouteSettings? routeSettings,
  bool glassHandle = true,
}) {
  if (!context.lmUi.ownsSheetSurface) {
    return showModalBottomSheet<T>(
      context: context,
      builder: (sheetContext) => _lmOverlayKeymap(
        context: sheetContext,
        dismissible: isDismissible,
        child: builder(sheetContext),
      ),
      isScrollControlled: isScrollControlled,
      backgroundColor: backgroundColor,
      elevation: elevation,
      shape: context.lmUi.sheetShape(context, shape),
      clipBehavior: context.lmUi.sheetClipBehavior(context, clipBehavior),
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      barrierColor: barrierColor ?? context.lmOverlayBarrierColor,
      constraints: constraints,
      routeSettings: routeSettings,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    constraints: constraints,
    routeSettings: routeSettings,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: barrierColor ?? context.lmOverlayBarrierColor,
    clipBehavior: Clip.antiAlias,
    builder: (sheetContext) => _lmOverlayKeymap(
      context: sheetContext,
      dismissible: isDismissible,
      child: sheetContext.lmUi.sheetSurface(
        sheetContext,
        builder(sheetContext),
        showHandle: glassHandle,
      ),
    ),
  );
}

/// 模态对话框：`showDialog` 的结构无关入口。
///
/// 经典组合所有参数原样透传（对话框内容件继续用 AlertDialog 等自带
/// 布局的组件，闭包上下文语义不变）；琉璃组合把遮罩统一到配色
/// `palette.scrim`@50%（调用方显式值优先），面层仍由玻璃结构的
/// `dialogTheme` 承载（模态任务面台阶）。
Future<T?> showLmDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => _lmOverlayKeymap(
      context: dialogContext,
      dismissible: barrierDismissible,
      child: builder(dialogContext),
    ),
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor ?? context.lmOverlayBarrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
  );
}

/// 浮层内容统一套的键盘层：把「Esc 关闭浮层」变成注册表里可枚举的一条绑定。
///
/// 此前 Esc 走的是框架 `ModalRoute` 的 `DismissIntent`（不可枚举、无描述、
/// 也不在快捷键清单里）。现在由统一入口安装
/// [LmShortcuts.idOverlayDismiss]，**尊重调用方的不可关闭声明**：
/// `barrierDismissible` / `isDismissible` 为 false 时不安装——Esc 保持无响应，
/// 与框架 `_DismissModalAction.isEnabled` 的口径一致（不会把「确认框」变成
/// 可以按 Esc 溜掉的框）。
///
/// 焦点链只多一个 `canRequestFocus: false` 的节点：不抢焦点、不占 Tab
/// 停靠点，浮层的焦点陷阱仍由 `ModalRoute` 自己的 `FocusScope` 保证。
Widget _lmOverlayKeymap({
  required BuildContext context,
  required bool dismissible,
  required Widget child,
}) =>
    LmShortcutHost(
      scope: LmShortcutScope.overlay,
      autofocus: false,
      handlers: {
        if (dismissible)
          LmShortcuts.idOverlayDismiss: () => Navigator.of(context).maybePop(),
      },
      child: child,
    );
