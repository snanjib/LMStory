import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// 统一页面过渡配方：`MaterialPageRoute` 过渡期 scrim 钉在 `palette.bg`；
/// 并让**每条路由自承载不透明场地**。
///
/// ── 为什么必须有这一层（黑帧修复，2026-09-21）──────────────────────
///
///  默认页过渡会在过渡全程向全屏画一层 scrim，底色默认取
/// `ColorScheme.surface`——
/// - Windows/Linux：`ZoomPageTransitionsBuilder`，
///   `page_transitions_theme.dart` 的 `backgroundColor ?? colorScheme.surface`，
///   由 `_ZoomEnterTransitionPainter._drawScrim` 逐帧 `drawRect` 上屏；
/// - Android：`PredictiveBackPageTransitionsBuilder` 在不支持预测式返回时
///   退化为 `FadeForwardsPageTransitionsBuilder`，同一默认（`colorScheme.surface`）；
/// - iOS/macOS：`CupertinoPageTransitionsBuilder` 平移过渡，无 scrim，不受影响。
///
/// 琉璃结构下所有 Scaffold 底色为透明（`scaffoldBgOf`），依赖根场地渐变透色；
/// 这层 surface scrim 恰好把场地整层盖住——波尔多夜间 `surface = #221420`，
/// 观感即「先黑一帧再出波尔多」。Classic 结构 `surface ≈ bg`，所以此前肉眼无感，
/// 但同一条缺陷其实两个结构都在。
///
/// 钉到 [LmPalette.bg] 后：过渡期底色与落地后的 scaffold 底色同源同值，
/// 四组合 × 明暗均无黑帧；Classic 观感不变（其 surface 本就近似 bg，
/// 钉 bg 后反而消除了 surface 与 bg 之间残存的色差闪烁）。
///
/// ── 为什么还要逐路由承载场地（叠印/黑区修复，2026-09-22）────────────
///
/// 真机缺陷：Android 左滑返回（预测式返回）时，上层页面缩小成圆角浮板，
/// **下层页面的内容从卡片内部透出来**（两层内容叠印）。
///
/// 病根与  同族，但更深一层：`PredictiveBackPageTransitionsBuilder` 的设计
/// 意图就是把上层路由缩小、露出下层路由——前提是**每层路由都是不透明的**。
/// 而此前「不透明底」来自 `main.dart` 里**位于 Navigator 之下**的单张根场地
/// 幕布：路由自身是透明的。框架在过渡期会把上层路由的
/// `overlayEntries.first.opaque` 置 false，于是两层路由同时被绘制——
/// 透明的上层路由内部直接露出下层路由的内容 → 叠印；
/// 任何一层都没有自绘制底色时 → 无绘制者区域（黑区）。
///
/// 换言之：**「透明路由 + 单一祖先场地」这个假设只在单层路由下成立。**
///  只补了 scrim 色，没有动摇这个前提，所以同类缺陷换了个位置又出现。
///
/// [LmRouteVenuePageTransitionsBuilder] 把 `child` 包进
/// `context.lmVenue(...)` 后仍按平台委派给原 builder：
/// - 稳态：逐路由自绘的场地与根场地窗口锚定、几何一致 → **逐像素等价**
///   （守卫 `t09_predictive_back_venue_guard_test.dart` 的稳态等价用例实证）；
/// - 过渡期：每条路由都自带不透明底，叠印与黑区同时消失；
/// - 一处改动覆盖全部路由（全仓 29 处 `MaterialPageRoute`，0 处 `PageRouteBuilder`），
///   业务代码零改动。
///
/// 根 `_GlassVenueShell`（`main.dart`）保留作兜底：非路由浮层
/// （dialog / sheet / drawer / 独立 Navigator 之外的场景）仍由它承接场地。
PageTransitionsTheme lmPageTransitionsTheme(LmPalette palette) {
  final scrim = palette.bg;
  return PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: LmRouteVenuePageTransitionsBuilder(
        PredictiveBackPageTransitionsBuilder(fallbackColor: scrim),
      ),
      TargetPlatform.iOS: const LmRouteVenuePageTransitionsBuilder(
        CupertinoPageTransitionsBuilder(),
      ),
      TargetPlatform.macOS: const LmRouteVenuePageTransitionsBuilder(
        CupertinoPageTransitionsBuilder(),
      ),
      TargetPlatform.windows: LmRouteVenuePageTransitionsBuilder(
        ZoomPageTransitionsBuilder(backgroundColor: scrim),
      ),
      TargetPlatform.linux: LmRouteVenuePageTransitionsBuilder(
        ZoomPageTransitionsBuilder(backgroundColor: scrim),
      ),
    },
  );
}

/// 路由级场地装饰器：把被推入路由的内容包进 [LmVenueContext.lmVenue]，
/// 然后按平台委派给原 [PageTransitionsBuilder]。
///
/// **场地包在被委派过渡的「里面」而不是「外面」**：这样缩放 / 圆角裁剪 /
/// 平移作用于「整张卡片（含它的场地）」，卡片才是一张完整、不透明的浮板；
/// 若包在外面，场地会保持全屏不动，卡片只剩内容在缩放——等于把预测式返回
/// 的「你正要回到哪去」这个语义抹掉。
///
/// 除插入这一层场地外，过渡行为（时长 / 曲线 / delegatedTransition）全部
/// 逐字段透传给 [delegate]，平台差异零改动。
///
/// 经典结构下 `lmVenue` 原样返回 child（经典页面本身不透明），
/// 因此本装饰器对 Classic 是纯粹的空操作——经典侧观感零变化。
class LmRouteVenuePageTransitionsBuilder extends PageTransitionsBuilder {
  const LmRouteVenuePageTransitionsBuilder(this.delegate);

  /// 被委派的平台原过渡（android=PredictiveBack / iOS,macOS=Cupertino /
  /// windows,linux=Zoom）。
  final PageTransitionsBuilder delegate;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      delegate.delegatedTransition;

  @override
  Duration get transitionDuration => delegate.transitionDuration;

  @override
  Duration get reverseTransitionDuration => delegate.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return delegate.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      context.lmVenue(child),
    );
  }
}
