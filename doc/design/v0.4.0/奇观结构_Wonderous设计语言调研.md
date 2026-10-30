# Wonderous 设计语言调研（为 LMStory 新主题结构设计服务）

- 状态：调研快照（只读调研，基于源码证据）
- 调研日期：2026-09-23
- 调研对象：gskinnerTeam/flutter-wonderous-app @ commit `747b945`（v2.2.7 线，2026-07-30），MIT
- 源码获取：只读克隆上述公开仓库至本地临时目录，逐行取证；克隆件可随时删除重取。
- 证据引用约定：文中 `file:line` 均为相对该仓库根的路径。所有断言均可按行号复核，无推测项。

---

## §1 设计命题与气质：为什么它显得"电影感 / 探索感"

拆开看，"电影感"不是某个单点特效，而是六个决策的叠加：

1. **深色剧场底**。全局黑 `#1E1B18` 作为多数页面的画布（`lib/styles/colors.dart:20`；Home 底色 `lib/ui/screens/home/wonders_home_screen.dart:159`；Timeline 底色 `lib/ui/screens/timeline/timeline_screen.dart:59`；Intro 底色 `lib/ui/screens/intro/intro_screen.dart:98`）。内容像放映一样被"打光"在黑底上。
2. **每奇迹一个深色世界**。8 组 bg/fg 深色配对色（`lib/styles/wonders_color_extensions.dart:4-28`），页面切换时用 `FadeColorTransition` 直接对底色做 alpha 淡入换幕（`lib/ui/common/fade_color_transition.dart:11-14`，用例 `lib/ui/wonder_illustrations/pyramids_giza_illustration.dart:28`）。色彩是"场景"，不是"主题"。
3. **三层景深视差**。插画强制拆 bg/mg/fg 三层（`lib/ui/wonder_illustrations/common/wonder_illustration_builder.dart` + `pyramids_giza_illustration.dart:17-24`），前景/中景随手势反向缩放（zoomAmt 正负相反，`pyramids_giza_illustration.dart:57,74-83`），上滑进入详情时前景放大速度 > 中景（`wonders_home_screen.dart:206-209,270-284` 的 `zoom: .4 * swipeAmt` vs `zoom: .05 * swipeAmt`）——摄影机推移感由此而来。
4. **氛围层永远在动**。云（`animated_clouds`）、GIF 滚筒纹理（roller GIF）、雾状渐变都在以 1500ms 级别的慢速漂移，叙事 UI 本身却快而安静。
5. **衬线大字 + 排版仪式感**。64px 衬线大标题（`styles.dart:99-101`）、首字母下沉 drop cap（`lib/ui/screens/editorial/widgets/_scrolling_content.dart:40-63`）、拱形裁切照片（`lib/ui/common/curved_clippers.dart`）、"博物馆图录"式引文与角标。
6. **克制的机制感**。按钮无涟漪（`NoSplash.splashFactory`，`lib/ui/common/controls/buttons.dart:149`）、按压只降透明度到 0.7（`buttons.dart:233-236`）、触觉反馈替代视觉噪音（`lib/ui/common/utils/app_haptics.dart:20-23`，翻页触发 `wonders_home_screen.dart:81`）。

**探索感**来自"藏"：collectible 藏在编辑内容流、照片网格四角与时间轴里（`lib/ui/common/hidden_collectible.dart`、`photo_gallery.dart:93-100`、`_scrolling_content.dart:69-85`），发现即庆祝。

**工程命题**：整套语言被压进一个全局 `AppStyle` 单例 `$styles`（`lib/styles/styles.dart:9-50`，取用 `lib/main.dart:115`），按屏幕最短边分 3 档 scale（1 / 1.1 / 1.2，`styles.dart:15-24`），由 `WondersAppScaffold` 在每帧布局时重建并下注入 Theme + DefaultTextStyle（`lib/ui/app_scaffold.dart:7-37`）。

---

## §2 几何系统

### 2.1 圆角词汇表（`lib/styles/styles.dart:206-211` 定义）

| Token | 值 | 用途 | 实际使用频次 |
|---|---|---|---|
| `corners.sm` | 4 | 微圆角 | 2 处 |
| `corners.md` | 8 | 卡片/按钮/缩略图默认 | 11 处直接引用 + 1 处裸写 `circular(8)`（`photo_gallery.dart:299`） |
| `corners.lg` | 32 | 大容器角 | 定义存在；直接裸写出现 1 处（`wonder_details_tab_menu.dart:54`） |
| 药丸化 | 99 / 999 / 1000 / 9999 | 胶囊按钮、进度点、渐变药丸 | 8+3+2+1 = 14 处 |

- 药丸写法证据：`grep "BorderRadius.circular(99"` → 8 处；`(999` → 3 处（含 `buttons.dart:265` 的圆形 hover、`_scrolling_content.dart:199` 的播放按钮底）；`(1000` → 2 处；`(9999` → 1 处。语义：**半径 >= 边长一半即"药丸/圆"**，不依赖具体值。
- 结构性异形不靠圆角，靠 CustomClipper：拱门五种（spade/pyramid/arch/wideArch/flatPyramid，`lib/ui/common/curved_clippers.dart:41-83`，`quadraticBezierTo`）与圆顶 `CurvedTopClipper`（`curved_clippers.dart:85-118`）；挖洞用 `Path.combine(PathOperation.difference, ...)`（`lib/ui/screens/photo_gallery/widgets/_animated_cutout_overlay.dart:66-80`，洞角 6px）。
- 图片网格间距用 `$styles.insets.md`（`photo_gallery.dart:194`）。

**几何结论：词汇表只有两极——8px 器物角与"药丸化"；中间值（16/24 圆角）不存在；异形交给 Clipper。**

### 2.2 间距（`styles.dart:221-234`）

`xxs=4, xs=8, sm=16, md=24, lg=32, xl=48, xxl=56, offset=80`（×scale）。8 阶梯、公差 4-8-16-8-16-8-24 的松紧节奏，页面级留白靠 `offset=80`。

### 2.3 尺寸约束（`styles.dart:213-219`）

- 内容最大宽三档：800 / 600 / 500（`_Sizes.maxContentWidth1/2/3`）；`minAppSize = 380×650`。
- 组件常量：Header 高 `64*scale`（`lib/ui/common/controls/app_header.dart:32`）、圆形按钮默认 48/28（`lib/ui/common/controls/circle_buttons.dart:16,56`）、箭头按钮 80×50（`_animated_arrow_button.dart:30-31`）、ribbon 高 48（`_animated_ribbon.dart:7`）。

### 2.4 阴影（`styles.dart:236-246`）

只有 3 组**文字**阴影：`textSoft`(α.25, y2, blur4) / `text`(α.6, y2, blur2) / `textStrong`(α.6, y4, blur6)。BoxShadow 全 app 仅少数几处：菜单选中格（α.3/blur3/spread3，`home_menu.dart:196-201`）、发现页图片双影（accent1 光晕 blur96 + 黑投影 blur16，`collectible_found_screen.dart:170-181`）。**UI 元素基本无投影，深度感来自分层而非 shadow。**

---

## §3 排版系统

### 3.1 字族角色制（`pubspec.yaml` fonts 段 + `styles.dart:52-95`）

| 角色 | 字族 | 说明 |
|---|---|---|
| 标题 titleFont | Tenor Sans | 静音优雅衬线感 sans |
| 奇迹大标题 wonderTitleFont | Yeseva One | 高装饰性展示字 |
| 引文 quoteFont | Cinzel Decorative（zh: Ma ShanZheng 书法体） | 按语区字族映射（`styles.dart:65-68`） |
| 正文 contentFont | Raleway（Regular/Italic/Medium/Bold/ExtraBold） | 启用 `FontFeature.enable('kern')`（`styles.dart:74-81`） |
| 等宽 monoTitleFont | B612 Mono | 数据/标注 |

全部为**本地 ttf**（`assets/fonts/` 共 15 个文件），**未使用 google_fonts**（pubspec 无该依赖）。

### 3.2 字号档位表（`styles.dart:97-174`；格式：sizePx/行高px/字重/字距%）

| 样式 | 规格 | 备注 |
|---|---|---|
| dropCase | 56/20 | 首字母下沉 |
| wonderTitle | 64/56 | 大标题 |
| h1 | 64/62 | |
| h2 | 32/46 | |
| h3 | 24/36 w600 | |
| h4 | 14/23 +5% w600 | 页头大写标签（`app_header.dart:44-56`） |
| title1 | 16/26 +5% | |
| title2 | 14/16.38 | 行高压到 1.17 |
| body / bodyBold | 16/26（w600） | 全局默认正文（`app_scaffold.dart:29`） |
| bodySmall / bodySmallBold | 14/23（w600） | |
| quote1 | 32/40 w600 **-3%** | 大引文收紧字距 |
| quote2 / quote2Sub | 21/32 w400；16/40 | |
| caption | 14/20 w500 italic | |
| callout | 16/26 w600 italic | |
| btn | 14/14 +2% w500 | 按钮大写标签 |

### 3.3 字距机制

`spacingPc` 以**百分比**声明、运行时换算 px：`letterSpacing = sizePx * spacingPc * 0.01`（`styles.dart:190`）。全库只有三种取值：+5%（标签）、+2%（按钮）、-3%（大引文）。行高同理用 px 声明换算 ratio（`styles.dart:184-189`）。

### 3.4 排版旁路模式

- 大标题内"虚词降级"：`of/the` 缩到 20px、首词后强制换行（`lib/ui/wonder_illustrations/common/wonder_title_text.dart:25-47`）；长标题自动降 56px（`wonder_title_text.dart:19-22`）。
- 超大装饰引号 90px（`lib/ui/screens/editorial/widgets/_large_simple_quote.dart:22`）。
- 按钮与页头文本"全大写 + `applyHeightToFirstAscent: false`"裁掉多余顶部行高（`buttons.dart:69-71`、`app_header.dart:44-45`）。
- 文字颜色用 DefaultTextStyle 传播而非逐个指定：`LightText` / `DarkText`（`lib/ui/common/themed_text.dart:17-37`）。
- 字重纪律：最重只到 w600 + Raleway 自带 Bold/ExtraBold 文件；大标题全部 w400，**装饰交给字族而非字重**。

---

## §4 动效系统

### 4.1 时长档位（`styles.dart:196-204`）

| Token | 值 | 语义 | 用例 |
|---|---|---|---|
| `pageTransition` | 200ms | 少用；主要作 stagger 延迟基准 | `home_menu.dart:136,158` |
| `fast`（全局默认） | 300ms | UI 反馈、淡入淡出、`Animate.defaultDuration`（`app_scaffold.dart:16`） | 20+ 处 |
| `med` | 600ms | 页内移动、翻页、指示器 | `wonders_home_screen.dart:114` |
| `slow` | 900ms | 氛围、图片切换 | `intro_screen.dart:152` |
| `extraSlow` | 1300ms | 长距离滚动吸附 | `_scrolling_viewport_controller.dart:28` |

- 直写 `Duration(milliseconds:)` 全库仅 4 处：300/400/250/150（hover 400ms 在 `buttons.dart:267`）。
- 复合节奏：以 `t = times.fast`(300ms) 为基数倍乘 `t*2..t*6` 编排"发现庆祝"整场（`collectible_found_screen.dart:33,82,110-121,159-191`）。
- 延迟字面量：500/600/300/250/200/150/100/50ms（`grep *.delayMs`），入场编排常用 `500.delayMs`（`_info_column.dart:56,64`、`intro_screen.dart:101`）。
- stagger：`.animate(interval: 50.delayMs)` 逐项入场（`home_menu.dart:157-159`）。

### 4.2 曲线语义表（全量 42 处，easeOut 家族 39 处 ≈ 93%）

| 曲线 | 次数 | 语义 | 代表证据 |
|---|---|---|---|
| `easeOut` | 22 | 万物入场默认 | `illustration_piece.dart:90`、`photo_gallery.dart:221` |
| `easeOutBack` | 6 | 小物件"弹到位"（罗盘旋转、分割线展开、事件 marker、列表 slide、滚动吸附） | `compass_divider.dart:44`、`home_menu.dart:137`、`_event_markers.dart:151`、`_scrolling_viewport.dart:51`、`_events_list.dart:63`、`_circular_title_bar.dart:49` |
| `easeOutExpo` | 5 | 爆发/庆祝（图片 0.3→1、粒子整体衰减、footer 纹理） | `collectible_found_screen.dart:189,201,138`、`_celebration_particles.dart:30` |
| `easeOutCubic` | 3 | 长距离缓动（翻页、按钮上移） | `wonders_home_screen.dart:115`、`collectible_found_screen.dart:243` |
| `easeInOut` | 3 | hover/循环 | `buttons.dart:268`、`home_menu.dart:217` |
| `easeInOutCubic` | 1 | shake | `collectible_item.dart:61` |
| `easeInExpo` | 1 | 放大消失（icon 冲屏） | `collectible_found_screen.dart:59` |
| `easeIn` | 1 | intro 前进 | `intro_screen.dart:73` |

**无 spring / 物理动画 / bounce / elastic**（`grep` 证实无 `SpringSimulation|Bouncing|Elastic` 类用法）；`easeOutBack` 是唯一的过冲来源（幅度小、用于旋转/滑动小物件）。

### 4.3 转场手法清单

1. **页面转场 = Cupertino（横向滑动推入）为默认**：自定义 `AppRoute` 默认返回 `CupertinoPage`，`useFade: true` 或系统减弱动态时改 `CustomTransitionPage + FadeTransition`（`lib/router.dart:130-161`）。**没有自定义 PageTransitionsTheme，没有共享轴/淡入手写转场**。
2. **全屏"模态"= 透明 Cupertino 路由 + `PopNavigatorUnderlay`（右滑任意处返回）**：菜单/发现页走 `appLogic.showFullscreenDialogRoute`（`lib/logic/app_logic.dart`），普通 dialog route 为 300ms 淡入 `PageRouteBuilder`（`lib/ui/common/utils/page_routes.dart:54-77`）。
3. **Hero 是页面间的真正"转场"**：标题 Hero（`wonder_title_text.dart:57-62`）、插画分层 Hero（`illustration_piece.dart:142-144`，tag=`$type-$fileName`）、collectible 双 Hero（icon 与大图分开，`collectible_item.dart:50-51`、`collectible_found_screen.dart:47-48,98-100`）。RectTween 直线插值（`wonder_hero.dart:14`）。
4. **手势驱动非时间驱动**：上滑进详情是"拖拽实时跟随 + 松手 reverse"，回放时长 = 当前位移秒数 × 0.5（`lib/ui/screens/home/_vertical_swipe_controller.dart:19-38`）；过滚返回页面用 `PopRouterOnOverScroll`（editorial_screen.dart:89）。
5. **滚动驱动视差**（占"动效感"另一半）：顶部插画 700px 内线性淡出（`editorial_screen.dart:106-112`）、标题 0.3× 下坠 + 150px 淡出（`editorial_screen.dart:145-154`）、列表项 1.35→1.0 缩放入场（`lib/ui/common/scaling_list_item.dart:47`）、pull-quote 随 y 坐标收拢（`_collapsing_pull_quote_image.dart:35-40`）。

### 4.4 减弱动态降级（三级）

1. 全局 `$styles.disableAnimations = mq.disableAnimations`（`app_scaffold.dart:20`）。
2. `maybeAnimate` 直接换 `NeverAnimate`（原样返回 child，`lib/logic/common/animate_utils.dart:16-45`）；`int.animateMs/delayMs` 扩展把时长/延迟归 1ms/0（`lib/ui/common/utils/duration_utils.dart:48-51`）。
3. 逐处显式降级：路由换 Fade（`router.dart:148`）、云层 `_anim.value = 1` 直达终态（`animated_clouds.dart:72`）、Hero 关闭（`illustration_piece.dart:142`）、swipe 回放 `1.ms`（`_vertical_swipe_controller.dart:20`）。

---

## §5 特效手法逐个拆解

### 5.1 `_celebration_particles.dart`（发现庆祝粒子）
`lib/ui/screens/collectible_found/widgets/_celebration_particles.dart:11-61`
- 引擎：`particle_field` 包 + `SpriteSheet`（21×23 单帧白色粒子 png `particle-21x23.png`），`blendMode: BlendMode.dstIn` 让粒子只做 alpha 贴片。
- 预算 1200 颗；每 tick 发射 `1200 ~/ 30` 递减；分布：半径 `d = min(w,h)*0.3` 的环带（0.8~1.0 d），速度 `v = d*0.08`，随机 0.5~1.5×；寿命 40 帧（`o.age > 40` 移除，每 3 帧换 sprite 帧）。
- 整体透明度 `easeOutExpo` 按 `1 - elapsed/fadeMs` 衰减（fadeMs 传入 `t*6 = 1800ms`，`collectible_found_screen.dart:82`）。
- 外包 `RepaintBoundary`（`:14`）。**要点：粒子是"预算递减的一次性爆发"，不是循环系统。**

### 5.2 `_animated_ribbon.dart`（横幅丝带）
`lib/ui/screens/collectible_found/widgets/_animated_ribbon.dart:11-48`
- 中央为纯色 Container（48px，accent1）+ 文字；两端各一张 `ribbon-end.png`，右端 `Transform.scale(scaleX:-1)` 翻转复用同一张图。
- 入场：两端从内侧 `(±8, 2)` 滑向外侧 `(±32, 10)`，400ms easeOut（`:42-47`），与中央色带"抻开"的错觉。**一张图 + 镜像 + 位移 = 丝带。**

### 5.3 `animated_clouds.dart`（云层换场）
`lib/ui/wonder_illustrations/common/animated_clouds.dart`
- **确定性随机**：每个奇迹一个硬编码 rndSeed（2/78/1/500/37/111/15/2，`:57-68`），`rndSeed = ...` 后生成 3 朵云（位置/缩放 0.7~1/双轴翻转随机，`:114-127`）——同一奇迹永远同一云布局，却免手摆。
- 换场：`didUpdateWidget` 时旧云存入 `_oldClouds`，新旧两套同 Stack：旧云位移 `-offset*curve` + `opacity 1-v`，新云 `+offset*(1-curve)` + `opacity v`（`:78-107`）；controller 1500ms，`Curves.easeOut.transform(_anim.value)` 手动取值。
- 渲染卫生：`RepaintBoundary > ClipRect > OverflowBox`（`:90-92`）；云图固定 `opacity .4`（`:154`）。
- 云本体是 1 张白色 png（`cloud-white.png`，`lib/assets.dart:21`）。

### 5.4 `_animated_era_text.dart`（纪元文字）
`lib/ui/screens/timeline/widgets/_animated_era_text.dart:11-14`
- `ValueKey(era)` 变化 → `maybeAnimate(key:...)` 重建 → `fadeIn().slide(begin: Offset(0,.2))`（默认 300ms/300ms）；`Semantics(liveRegion: true)` 同步播报。**"换 key 即换场"是全库最常用的入场模式**（同款：`_bottom_text_content.dart:78`、`artifact_details_screen.dart:99`）。

### 5.5 `_animated_cutout_overlay.dart`（挖洞遮罩，照片查看核心）
`lib/ui/screens/photo_gallery/widgets/_animated_cutout_overlay.dart`
- 结构：Stack = 照片 + `Animate(CustomEffect)` 驱动的黑罩；黑罩 = `ClipPath(_CutoutClipper)`。
- 洞：`Path.combine(difference, 全屏矩形, 圆角矩形(R=6))`（`:66-80`）。
- 动画：切图时洞尺寸 `1 → 0.75 → 1` 呼吸（`scaleAmt .25`，`:32,45-53`），`onComplete: reverse`；位移方向按 `swipeDir` 分轴缩（横滑只缩宽、竖滑只缩高）。
- 时长：cutout 用 `swipeDuration*0.5`（≈120ms），网格位移用 `swipeDuration = med*0.4 = 240ms`，easeOut（`photo_gallery.dart:40,197-198,221`）。
- **Web 降级**：Flutter Web ClipPath bug → 整个挖洞关闭，改为"未选中图上盖黑 70%"的朴素方案（`photo_gallery.dart:47,204-205,308-316`）。

### 5.6 `BlendMask`（子树混合模式）
`lib/ui/common/blend_mask.dart:4-46`
- 自定义 `RenderProxyBox`：`canvas.saveLayer(bounds, Paint()..blendMode=...)` 包住子树绘制（`:32-45`），并 `setWillChangeHint` 防 Skia 光栅缓存错绘（`:33-34`）。
- 用例 A（编辑页引文）：拱形照片上叠 `BlendMode.colorBurn` 的文字，文字与照片"蚀刻"在一起（`_collapsing_pull_quote_image.dart:89-90`）。
- 用例 B（时间轴）：未选中奇迹图 `BlendMode.luminosity, opacity .6` → 保留明度的"褪色"效果（`lib/ui/screens/timeline/widgets/_timeline_section.dart:31-33`）。

### 5.7 GIF 纹理层（`paint_textures.dart` + roller GIF）
`lib/ui/wonder_illustrations/common/paint_textures.dart:20-39`
- 白色 roller GIF（`roller-1/2-white.gif`，3.0x 约 1MB/张）被 `Image.asset(repeat: ImageRepeat.repeat)` 当**会自己动的无缝纹理**用——Flutter 原生循环播放 GIF，零代码动画。
- 单色化：`color:` 参数（默认 srcIn 着色）+ `opacity` Animation tween（0→0.75，`pyramids_giza_illustration.dart:30-37`）+ `cacheWidth: 2048` 控内存。这是插画 bg 层的"流云/星光"质感来源。

### 5.8 着色器：无
全仓 `grep FragmentProgram|fragment_shader|.frag|.glsl` 均为 0 命中；pubspec 无 shader 声明。**所有特效都是 Widget/CustomPainter/BlendMode/GIF 级实现。**

### 5.9 其他手法速记
- 开场径向渐变呼吸：`RadialGradient` 的 stops 与颜色随 ratio lerp，intro/detail 共享中点（`collectible_found_screen.dart:136-156`）。
- 发现页图片"上色发光"：双 BoxShadow（accent1 大光晕 + 黑投影）alpha 随 ratio 渐显（`collectible_finished_screen.dart:165-191`，即 `collectible_found_screen.dart:165-191`）。
- 背景模糊统一入口 `AppBackdrop`：`BackdropFilter` blur 15×strength；`settingsLogic.useBlurs=false`（Android 默认关，`lib/logic/settings_logic.dart:15`）时降级为黑 80% 遮罩（`lib/ui/common/app_backdrop.dart:16-33`）。
- 隐藏 collectible 的"呼吸提示"：`.shimmer`（4s 延迟）+ `.shake(hz:4)` + 双段 `.scale(1→1.1→1)` 循环（`collectible_item.dart:59-68`，`onPlay: repeat`）。
- intro 异形图：照片 + 黑色 mask png 叠加（`intro_screen.dart:362-380`）——用遮罩图而非 Clipper 得到手绘轮廓。

---

## §6 组件模式清单

| 模式 | 实现 | 证据 |
|---|---|---|
| 统一按钮工厂 `AppBtn` | primary=greyStrong/白字，secondary=白/黑字，`CircleBorder` 或 `corners.md`；`NoSplash`；按压 α0.7；Web hover 白 12% 400ms；焦点 accent1 3px 外框；禁用 α0.5；强制 semanticLabel | `lib/ui/common/controls/buttons.dart:130-207,214-273` |
| 圆形按钮 | CircleBtn 48 / CircleIconBtn 28 默认 | `circle_buttons.dart:16,56` |
| 页头 AppHeader | 黑底 64px、大写 h4 标题 + accent1 大写副标题、可透明模式 | `app_header.dart:26-60` |
| 探索式主页 | 无 tab bar：无限循环 PageView（`initialPage = count*100+idx`）+ 底部白色渐变"药丸"随上滑隆起（`BorderRadius.circular(99)`）+ 箭头按钮 + 圆点指示器 + 横竖屏双轴 | `wonders_home_screen.dart:67-69,355-383`；`lib/ui/common/gradient_container.dart:65-91` |
| 全屏菜单 | 模糊遮罩 + 3×3 圆角图标网格（选中 5px offWhite 描边）+ 列表 50ms stagger | `home_menu.dart:51-161,188-225` |
| 详情页斜切 Tab | 74px 圆角 home 钮 + 斜排文字标签（`diagonal_text_page_indicator`），横竖双轴、25~100px 自适应 | `lib/ui/screens/wonder_details/wonder_details_tab_menu.dart:4-56`；`lib/ui/common/controls/diagonal_text_page_indicator.dart:8` |
| 全屏照片墙 | 5×5 网格 + 挖洞黑罩 + `EightWaySwipeDetector`（阈值 30px，`roundToDouble` 归一为 8 向量）+ 方向键 + 选中图 scale 1.15 + 再点进 URL 查看器 | `photo_gallery.dart:34-46,130-148,214-238,265-275`；`lib/ui/common/controls/eight_way_swipe_detector.dart:30-48` |
| 时间轴 | 主视口 + 纪元文字 + 底部迷你时间轴 scrubber（拖拽倍率换算 jumpTo）+ 事件卡 500ms 防抖 + slide(-.1) 入场 | `timeline_screen.dart:43-104`；`_bottom_scrubber.dart:39-45`；`_event_popups.dart:12-49` |
| collectible 发现流 | 藏（编辑流 4 slot / 照片墙角标 / 时间轴）→ shimmer 循环提示 → 点击 `OpeningCard` 展开 → Hero 双链 → 庆祝页（swap@1050ms）→ 进收藏 | `hidden_collectible.dart:7-29`；`collectible_item.dart:40-72`；`collectible_found_screen.dart:25-29` |
| 收藏页 | `flutter_staggered_grid_view` + `ScalingListItem` 滚动缩放 + 新发现入口 | `lib/ui/screens/collection/`；`scaling_list_item.dart:37-53` |
| 测量驱动展开卡 OpeningCard | `TweenAnimationBuilder<Size>` + MeasurableWidget 双 builder | `lib/ui/common/opening_card.dart:28-64` |
| 桌面/键盘适配 | `TrackpadListener`（滚轮转手势）、`FullscreenKeyboardListScroller`、`PreviousNextNavigation`、`KeyboardArrowsListener` | `lib/ui/common/controls/trackpad_listener.dart` 等 |
| 语义/无障碍 | Semantics header/button/slider/liveRegion 全覆盖；`ExcludeSemantics` 配合装饰图 | 各屏；如 `photo_gallery.dart:277-297`、`_animated_era_text.dart:11` |
| 触觉 | 翻页/滑动 `AppHaptics.lightImpact`，Android 按钮统一轻震 | `app_haptics.dart:13-23`；`wonders_home_screen.dart:81`；`photo_gallery.dart:146` |

路由结构：`ShellRoute(WondersAppScaffold)` 包住全部页面；深层页面路径用 `_appendToCurrentPath` 相对拼接（`lib/router.dart:46-58,131-146`）。

---

## §7 明暗与资产策略

### 7.1 明暗：没有"暗色模式"，只有"暗色内容"
- `AppColors.isDark` 硬编码 `false`，`toThemeData()` 恒走 light 分支（`lib/styles/colors.dart:22,26-54`）；仓库内 `find *dark*` 资产为 0。**当前版本无双份资产/无主题切换**（早期版本的暗色方案已移除）。
- "暗"由三层内容构造：全局黑 `#1E1B18` 页面底（§1）＋每奇迹深色 bg/fg 配对（`wonders_color_extensions.dart:4-28`）＋白色素材靠透明度/着色融入（云 `opacity .4`、白色 GIF 纹理 tint、白色图标 `ColorFilter.mode(srcIn)`（`wonders_color_extensions.dart:31-33`））。
- 对 LMStory 的启示：**"暗色"可以做成资产策略（单份白色/中性素材 + 程序化着色），而不是两套素材。**

### 7.2 资产重量实测
- 总量：**48MB**（48,300,936 bytes）。分布：293 png、130 jpg、15 ttf、6 gif、4 svg；**webp 0 张**。
- 最大单件：`MaShanZheng-Regular.ttf` 5.86MB；`petra/4.0x/foreground-right.png` 3.09MB；3.0x 层普遍 0.5~1.5MB。
- 密度管线：全部插画/图标按 `2.0x/3.0x/4.0x` 三密度目录出货（`assets/images/*/2.0x...`）。
- 每奇迹资产包 = 分层插画（moon/主体/foreground-front/foreground-back 等 5~8 张透明 png）+ 4 张 Unsplash 照片 jpg + `flattened.jpg` + `wonder-button.png`。
- 公共资产：白色云 png、白色 roller GIF ×2、speckles png、ribbon-end png、21×23 粒子 png、intro 照片+mask、罗盘 svg ×2、图标白色 png ~21 枚（`assets/images/_common/`）。
- 字体承担气质：15 个 ttf 中 MaShanZheng 一个就占总量 12%。

---

## §8 LMStory 适配评估（按守卫纪律：时长 120-500ms 档位制、禁 bounce/elastic、减弱动态必须降级）

### 8.1 可直译（结构/ThemeData 装配 + 工厂组件即可落地）
1. **`AppStyle` token 单例 + 全局 `$styles` 门面 + 按 shortestSide 三档 scale**（styles.dart:9-50）——与 ThemeData 装配层完全兼容，是"结构"层的最佳范本。
2. **圆角双极词汇表**：`sm4/md8/lg32 + 药丸化(≥半边长)`；异形走 CustomClipper。ThemeData 里对应 `cardTheme/splitBorderRadius` 常量。
3. **间距 8 阶梯 + 内容最大宽三档（800/600/500）**。
4. **字族角色制 + `spacingPc` 百分比字距机制 + "全大写 + applyHeightToFirstAscent:false"标签法**；"虚词降级"标题排版可直接用于章节标题。
5. **时长 token 化 + `Animate.defaultDuration` 全局默认**——把 300/600/900/1300 重映射进 LMStory 档位即可沿用机制。
6. **AppBtn 工厂**（NoSplash + α0.7 按压 + 焦点描边 + 语义标签强制）与 **LightText/DarkText** 反色器。
7. **AppHeader、AppPageIndicator、OpeningCard、EightWaySwipeDetector、DashedLine、GradientContainer** 均为无资产依赖的通用组件。
8. **Hero tag 命名规约**（`$type-$fileName`、`collectible_icon_$id`）与"换 key 即入场"模式。
9. **三级减弱动态降级机制**（NeverAnimate / 时长归 1ms / 逐处直达终态）——正是 LMStory"减弱动态必须降级"的成熟实现，其架构可直接借鉴落地。
10. **文字阴影三档**（作为图片上文字的可读性方案）。

### 8.2 需翻译（手法成立、参数/曲线违反 LMStory 守卫）
1. **`Curves.easeOutBack` ×6**：全部是小物件（罗盘旋转、divider 展开、marker、slide 入场、滚动吸附）→ 换 `easeOutCubic`，"弹到位"的手感损失用位移幅度补偿。
2. **`easeOutExpo/easeInExpo` ×6 + 时长 900~1800ms 的庆祝编排**（粒子 1800ms、图片 0.3→1 用 `t*2..t*6`）：爆炸/收束感可在 120-500 档内用 `easeOutCubic` + 前后景 stagger 重排；1800ms 全局衰减属于氛围层，若保留必须定义"叙事动画 vs 环境循环动画"两类豁免口径。
3. **1500ms 云层换场 / `extraSlow=1300ms` 滚动吸附**：环境层与手势释放类各自单列档位或降级为直达终态。
4. **`pageTransition=200ms` 仅作 stagger 延迟基准**的用法可保留（延迟不等于时长）。
5. **拖拽跟随 + `reverse(from:)` 回放时长=位移×0.5s**（`_vertical_swipe_controller.dart:19-38`）：连续值手势应豁免档位制，但"松手回弹"要钉死在 ≤500ms 固定值。
6. **`AppBackdrop` BackdropFilter blur15**：需性能预算 + Android 式"关模糊"开关（Wonderous 自带降级模板可直接借）。
7. **`BlendMask` saveLayer**：限制在静态内容（引文、缩略图去饱和），禁入逐帧动画子树。
8. ** Cupertino 推入为默认页转场 + 淡入为减弱动态备胎**：与 LMStory 转场规范合并时保留"默认转场只有一个"的纪律。
9. **shimmer/shake 循环提示**（repeat + 4s 延迟）：改为有限次数/低频脉冲，并纳入减弱动态关停。

### 8.3 不可移植（依赖资产管线/外部服务/规模投入，需自产替代）
1. **三层插画视差系统**：每奇迹 5~8 张分层透明 png + 确定性种子云 + GIF 纹理层。LMStory 需建立"分层立绘/场景"资产管线（含 2x/3x 密度策略），这是最大的制作成本项。
2. **庆祝粒子（1200 颗 + sprite sheet + dstIn）**：可重写为 CustomPainter 粒子，但美术素材（粒子图）需自产。
3. **48MB 级资产体量、专用展示字族（含 5.86MB 中文书法体）**：中文叙事应用若引入书法体需包体权衡；字体是这套气质的半壁江山，不可省但可选择更轻的替代字族。
4. **Unsplash 在线照片墙、YouTube/Google Maps/Artifact API 集成**：与 LMStory 无关的域内容，整体剔除。

---

## §9 参考文件索引（路径相对 Wonderous 仓库根）

样式/结构
- `lib\styles\styles.dart` — AppStyle 全部 token（几何/排版/时长/阴影/尺寸）
- `lib\styles\colors.dart`、`lib\styles\wonders_color_extensions.dart` — 色板与 8 组场景配对色
- `lib\ui\app_scaffold.dart` — 样式注入/主题装配/减弱动态采集
- `lib\main.dart`、`lib\router.dart` — 装配入口与路由/转场策略
- `lib\ui\common\themed_text.dart` — DefaultTextStyle 反色器

动效/工具
- `lib\logic\common\animate_utils.dart`、`lib\ui\common\utils\duration_utils.dart` — flutter_animate 封装与降级
- `lib\ui\common\utils\page_routes.dart`、`lib\ui\common\utils\app_haptics.dart`
- `lib\ui\screens\home\_vertical_swipe_controller.dart` — 手势跟随回放

特效
- `lib\ui\screens\collectible_found\widgets\_celebration_particles.dart`、`_animated_ribbon.dart`
- `lib\ui\wonder_illustrations\common\animated_clouds.dart`、`paint_textures.dart`、`illustration_piece.dart`、`wonder_illustration_config.dart`
- `lib\ui\screens\photo_gallery\widgets\_animated_cutout_overlay.dart`
- `lib\ui\common\blend_mask.dart`、`curved_clippers.dart`、`fade_color_transition.dart`、`app_backdrop.dart`

组件
- `lib\ui\common\controls\buttons.dart`、`circle_buttons.dart`、`app_header.dart`、`eight_way_swipe_detector.dart`、`diagonal_text_page_indicator.dart`
- `lib\ui\common\opening_card.dart`、`scaling_list_item.dart`、`hidden_collectible.dart`、`collectible_item.dart`、`dashed_line.dart`、`gradient_container.dart`

页面范本
- 主页 `lib\ui\screens\home\wonders_home_screen.dart`；菜单 `lib\ui\screens\home_menu\home_menu.dart`
- 编辑页 `lib\ui\screens\editorial\editorial_screen.dart`（+ `_scrolling_content.dart`、`_collapsing_pull_quote_image.dart`）
- 时间轴 `lib\ui\screens\timeline\timeline_screen.dart`（+ `_bottom_scrubber.dart`、`_event_popups.dart`、`_timeline_section.dart`、`_animated_era_text.dart`）
- 照片墙 `lib\ui\screens\photo_gallery\photo_gallery.dart`；发现 `lib\ui\screens\collectible_found\collectible_found_screen.dart`
- Intro `lib\ui\screens\intro\intro_screen.dart`；详情 Tab `lib\ui\screens\wonder_details\wonder_details_tab_menu.dart`

资产
- `pubspec.yaml`（fonts 声明）；`assets\images\_common\`、`assets\images\<wonder>\{2.0x,3.0x,4.0x}`；`lib\assets.dart`（路径集中管理）
