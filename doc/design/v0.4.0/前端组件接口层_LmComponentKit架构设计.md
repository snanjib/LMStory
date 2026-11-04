# 前端组件接口层（LmComponentKit）架构设计

> 状态：**已实施**（2026-09-23 评审定稿；设计原则"前端接口+实现，业务不动
> if-else"的落地设计；当前运行约定见《前端组件接口层_实现约定》）。
> 上位：`doc/design/v0.4.0/外观体系v2设计.md`（三轴架构；"追加主题不改核心"）。
> 事实底座：`doc/design/v0.4.0/前端组件接口层_现状盘点.md`（下称《盘点》，全部
> 断言带 file:line；本文引用处写作《盘点》§n）。

---

## §一 目标与非目标

**目标**：

1. 业务代码（features/ + core 非 structures 区）只依赖**抽象组件接口**
   `LmComponentKit`；新增一套外观结构 = 新增一个 Kit 实现 + 目录注册一行，
   **业务代码零改动**。
2. 消灭结构条件分支：现存 `isGlassSurface` / `isBrutalSurface` 分流扩展
   （`glass_surface.dart`、`brutal_surface.dart`、`lm_overlays.dart`）与
   home_page 式三元条件全部迁移到接口调用，并以**防退化守卫**禁止回潮。
3. classic/glass 渲染**零行为变化**（golden 零 diff 机器证明）——接口层是
   重新接线，不是重新设计。
4. 完成后"切结构 = 全 app 每页换骨"：几何、描边、阴影、按压、组件形态、
   会话面（气泡/输入区/会话行）随结构整体切换。

**非目标**：

- 不改 17+1 配色槽契约与 LmPalette/LmTokens 既有面。
- 不重写各结构既有工厂内部实现（Glass 18 件、Brutal 8 件原样包装）。
- 不在本层解决领域建模问题（DTO 规则见 §五，只做表现层解耦）。
- 不动模式轴既有行为（chat/intermediate/advanced 的模式语义）。

---

## §二 现状结论（详证见《盘点》）

1. **三套结构的"组件"规模极不均衡**：玻璃 18 件闭集、棱角 8 件、classic 结构层
   **零 widget**——classic 的组件实为两套模式组件库（conversation 13 公开类 ≈5173
   行、narrative 20+ 类 ≈9440 行）。
2. **重合词汇仅 7 个**；气泡、聊天输入区、会话行、AppBar、空状态、消息导航
   **只存在于模式组件库**——接口不含会话面，切结构就永远变不了聊天页
   （一期外观切换"只变两处"的根因之一）。
3. **迁移缝隙已经存在**：`Simple*/Intermediate*` 的 Radius/Spacing/TextStyles
   早已 typedef 到 `Lm*` 单源；`simple/components` 与 `intermediate/components`
   共 56 个文件**全是单行 re-export 垫片**，真身在 classic 结构层——业务引用
   面与实现面本来就是断开的，接口层可以"反转垫片"低摩擦接管。
4. **收口雏形已存在**：`AdaptiveSettingCard` 已是三结构同调用面；
   `showLmSheet/showLmDialog` 已收口浮层（features 内裸用=0）。反例：SnackBar
   92 处裸用散布 34 文件。
5. **实现性坑**：`_GlassInteractive`/`_BrutalInteractive` 五态采集器逐行同构；
   `SimpleSessionCard` 吃领域实体 `ChatSession`（领域倒灌结构层）；
   `SimpleMessageBubble` 24 参、`ChatModeInputArea` 19 参聚合大件；
   `SimpleTemplateCard` 为死代码（全仓 0 消费）。

---

## §三 分层架构

```
业务层（features/ + core 非 structures）
   只 import：core/theme/api/*（接口 + DTO + 枚举）
   取用方式：context.lmUi.card(...) / context.lmUi.messageBubble(...)
        │ 依赖倒置
        ▼
API 层  lib/core/theme/api/
   ├─ lm_component_kit.dart      抽象接口（v1，本文 §四）
   ├─ lm_component_defaults.dart ClassicUi 默认实现（回退基线）
   ├─ lm_dto.dart                表现层 DTO（LmBubbleData / LmSessionRowData…）
   ├─ lm_ui_scope.dart           LmComponents ThemeExtension + context.lmUi
   └─ lm_interactive.dart        五态采集器公共件（吸收两套 _Interactive 同构）
        │ 实现
        ▼
实现层  lib/core/theme/system/structures/<id>/
   ├─ 既有工厂原样保留（Glass 18 / Brutal 8）
   └─ <id>_ui.dart  class GlassUi implements LmComponentKit（包装工厂）
                     class BrutalUi implements LmComponentKit
                     class ClassicUi（在 api/defaults，classic 结构同款装配）
        │ 注册/组装
        ▼
目录轴  ThemeCatalog.assemble()：structure.buildKit(palette, brightness)
        → LmComponents ThemeExtension 注入（与 LmTokens 同通道）
```

**依赖铁律**：API 层不 import 任何 `structures/**`；structures 只 import API；
业务层只 import API。方向由防退化守卫固化（§七）。

---

## §四 接口 v1 草案（签名级）

> 范围裁决依据《盘点》§4 业务块归纳（16 名词）+ 三结构语言清单并集。
> v1 = 通用原语全体 + 会话面最可见三件（气泡/输入区/会话行）；其余会话面
> （动作条/分叉导航/消息导航/骨架三态）入 v1.1，接口预留命名空间不预占签名。
> 参数名以本节为准落地时微调；**每个方法的 ClassicUi 实现必须逐像素等于
> 迁移前该表面的既有渲染**（golden 锚定）。

```dart
/// 前端组件接口 v1。实现方：ClassicUi（默认回退）/ GlassUi / BrutalUi / WonderUi…
/// 约束：方法只增不改签（v1 冻结）；新能力走 v1.1 命名空间；缺省落 ClassicUi。
abstract interface class LmComponentKit {
  String get id;

  // ── A. 通用原语（三结构重合 7 词汇 + 高频词汇）──────────────────

  /// 卡片/面板：level 表达层级（琉璃=T0/T1 台阶；棱角=描边三档；classic=现卡片）。
  Widget card({required Widget child, EdgeInsetsGeometry? padding,
      VoidCallback? onTap, LmCardLevel level = LmCardLevel.rest});

  /// 主操作按钮（每屏至多一颗）：label 走 Kit 排版；loading 抑制交互。
  Widget primaryButton({required String label, required VoidCallback? onPressed,
      bool loading = false});

  /// 次级/幽灵按钮。
  Widget secondaryButton({required String label, required VoidCallback? onPressed});

  /// 危险操作按钮（error 色）。
  Widget destructiveButton({required String label, required VoidCallback? onPressed});

  /// 输入框：单行/多行由 [maxLines]；焦点表达走结构语言（棱角=描边加粗）。
  Widget input({required TextEditingController controller, String? hint,
    FocusNode? focusNode, int maxLines = 1, ValueChanged<String>? onSubmit});

  /// 过滤/标签 chip：selected 语义由结构表达（棱角=描边升档+撞色）。
  Widget chip({required String label, bool selected = false, VoidCallback? onTap});

  /// 分段控件（结构现有 segmented 消费面收口）。
  Widget segmented({required List<String> labels, required int selected,
      required ValueChanged<int> onChanged});

  /// 列表行/资源行：leading/tailing 放原语级 Widget（图标、开关），不放领域件。
  Widget listRow({required Widget title, Widget? subtitle, Widget? leading,
      Widget? trailing, VoidCallback? onTap});

  /// 设置卡（一级分类卡，AdaptiveSettingCard 的接口化归宿）。
  Widget settingCard({required Widget title, Widget? subtitle, Widget? trailing,
      VoidCallback? onTap});

  /// 设置分区（分组标题 + 分组容器）。
  Widget settingSection({required String title, required List<Widget> children});

  /// 分区标题（页面内小节头）。
  Widget sectionHeader({required String title, String? action});

  /// 空状态。
  Widget emptyState({required String title, String? description,
      Widget? action});

  /// 语义横幅（信息/警告/错误）。
  Widget banner({required String text, LmBannerKind kind = LmBannerKind.info});

  /// 确认对话框（走 showLmDialog 收口）。
  Future<bool> confirmDialog({required BuildContext context, required String title,
      required String body, String confirmLabel, String cancelLabel});

  /// 底部弹层（走 showLmSheet 收口）。
  Future<T?> sheet<T>({required BuildContext context, required WidgetBuilder builder});

  /// Snack 轻提示（92 处裸 SnackBar 的收口归宿）。
  void snackBar({required BuildContext context, required String text});

  /// 开关/勾选原语（设置页尾随控件）。
  Widget toggle({required bool value, required ValueChanged<bool> onChanged});
  Widget checkbox({required bool value, required ValueChanged<bool?> onChanged});

  // ── B. 会话面（v1 最可见三件；v1.1 预留：动作条/分叉导航/消息导航/三态骨架）──

  /// 消息气泡：数据经 [LmBubbleData]（表现层 DTO，禁领域实体）。
  /// 结构在此表达气泡语言（棱角=直角+描边；琉璃=现行玻璃面；classic=现行）。
  Widget messageBubble({required LmBubbleData data});

  /// 聊天输入区：附件/发送/停止等动作以 [LmInputAction] 枚举表达，
  /// 布局语言归结构。
  Widget chatInput({required LmChatInputState state,
      required ValueChanged<LmInputAction> onAction});

  /// 会话列表行：[LmSessionRowData] 为表现层 DTO。
  Widget sessionRow({required LmSessionRowData data, required VoidCallback onTap,
      bool selected = false});

  // ── C. 形态槽（长尾一次性表面的几何/形态取用口）────────────────

  LmShapeSlots get shapes;
}

/// 形态槽：长尾表面不再就地写 SimpleRadius/BorderRadius.circular。
abstract interface class LmShapeSlots {
  BorderRadius cardRadius;      // classic=rLg 现值 / 玻璃=GlassRadii.card / 棱角=0
  BorderRadius fieldRadius;     // 输入类
  BorderRadius pillRadius;      // 药丸（classic/玻璃=stadium；棱角=cornerField）
  BorderSide cardBorder;        // 棱角=ink frameCard；其余=none
  List<BoxShadow> restShadow;   // 棱角=Offset(4,4) 实心块（可按压件）；其余=无
  double pressShift;            // 棱角=4；其余=0（按压位移轴，配合 LmMotion）
}
```

**设计裁决理由**：

- **方法返回 Widget 而非返回样式**：三套结构的签名交互不可归约为主题参数
  （琉璃按压=缩放、棱角=平移进纸、奇观=Hero+触觉），只有组件级接口能承载
  交互语言；几何长尾用 `shapes` 槽补，避免接口爆炸。
- **DTO 规则**：跨入 API 的数据一律表现层 DTO（`LmBubbleData` 等，字段为
  原语/枚举/Widget），**禁止领域实体**（修复 `SimpleSessionCard` 吃
  `ChatSession` 的倒灌，见《盘点》§5）。
- **聚合大件分层**：24 参/19 参大件（SimpleMessageBubble/ChatModeInputArea）
  的参数面在 DTO 化时收敛为"数据 DTO + 动作枚举"，实现内部可保留原有私
  有分解。

---

## §五 实现与回退

| 实现 | 位置 | 构成 | 回退角色 |
|---|---|---|---|
| ClassicUi | `api/lm_component_defaults.dart` | 包装既有模式组件库（conversation/narrative 真身，经现有 re-export 链） | **默认回退**：任何 Kit 未实现/新增方法的基线；v1 冻结期全方法实现 |
| GlassUi | `structures/glass/glass_ui.dart` | 包装既有 18 件玻璃工厂 + 场地件 | — |
| BrutalUi | `structures/brutal/brutal_ui.dart` | 包装既有 8 件棱角工厂 | — |
| WonderUi | （奇观结构实施产出） | 按《奇观结构_Wonderous设计语言调研》§6 组件清单新写 | 证明"新结构=一套实现"的验收案例 |

- **零行为变化义务**：ClassicUi/GlassUi 的每个方法实现 = 原 calling 处的现渲染
  路径包装；迁移前后 golden 零 diff 是合并门。
- **回退机制**：`ThemeCatalog.assemble` 组装 Kit 时，若结构实现缺失某能力
  （v1.1 扩展期），落 ClassicUi 对应方法——结构实现可 `Mixin` 只写差异化方法。
- **死代码清理**：`SimpleTemplateCard`（0 消费）在实施阶段删除，不进接口。

---

## §六 注入与组装

1. `LmStructure` 接口追加 `LmComponentKit buildKit(LmPalette palette,
   Brightness brightness)`（classic/glass/brutal 各自实现；classic 返回
   ClassicUi 单例）。
2. `ThemeCatalog.assemble()` 在既有 `LmTokens` 旁注入
   `LmComponents(kit)` ThemeExtension；提供 `context.lmUi` 扩展
   （兜底 = ClassicUi，镜像 `context.lm` 的 fallback 范式）。
3. **场地/背景接口化**：`glassVenue()`/`scaffoldBgOf()` 条件迁入
   Kit——`Widget venue({required Widget child})` + `Color scaffoldBg(Color
   fallback)`；路由级转场（LmRouteVenuePageTransitionsBuilder）与根壳兜底改调
   Kit，`glass_surface.dart`/`brutal_surface.dart` 两文件删除。
4. **五态采集器归一**：`_GlassInteractive`/`_BrutalInteractive` 的同构逻辑
   上提为 `api/lm_interactive.dart`（states 回调：hovered/pressed/focused/
   disabled/loading），各结构实现只写差异化视觉——行为等价由既有守卫钉住。

---

## §七 防退化守卫（把"不许 if-else"变成机器证明）

历史方案中的守卫路径已失效；现行约束与验证以源码和测试为准：

1. **依赖方向守卫**：扫描 `lib/features/**` 与 `lib/core/**`（豁免
   `core/theme/api/**`、`core/theme/system/structures/**`）——
   禁止 import `structures/glass/`、`structures/brutal/`（白名单过渡期逐阶段清空，
   只减不增）。
2. **结构分支守卫**：禁止业务层出现 `structureId ==` / `isGlassSurface` /
   `isBrutalSurface` 判定（现有 3 处随迁移删除）。
3. **SnackBar 收口守卫**：features 层 `SnackBar(` 直用数只减不增，目标归零
   （现行 92 处/34 文件，实施阶段消化）。
4. 既有 lm_motion / q5 / golden 守卫全量继续生效（零行为变化的锚）。

---

## §八 迁移策略

**两步法（垫片反转 → 显式换名）**：

1. **第一步（覆盖跃迁）**：`simple/components`、`intermediate/components`
   的 56 个 re-export 垫片**反转为分发实现**（同名 widget 内部转调
   `context.lmUi`）。效果：**绝大部分业务文件零编辑**，切结构即刻全表面生效；
   classic/glass 路径由 ClassicUi/GlassUi 等值包装保真。
2. **第二步（显式化，随阶段进行）**：业务调用点从垫片同名件改名到
   `context.lmUi.*` 显式接口，垫片目录最终清空删除；每阶段一个 commit +
   walkthrough 截图。

**实施阶段（按可见度排序，单阶段连续执行）**：

| 阶段 | 表面 | 主要动作 |
|---|---|---|
| B0 | 架构层落地 | API 文件 + 三实现 + 注入 + 守卫（先 ClassicUi 等值包装，golden 验证） |
| B1 | 壳/首页/侧栏 | 垫片反转首批 + venue 接口化 + 三件套显式化 |
| B2 | 设置全层级 | 一级卡/全部子页设置行/分区/开关/下拉 |
| B3 | 会话页（chat） | 气泡/输入区/消息导航/SnackBar 收口（92 处） |
| B4 | 故事模式（intermediate） | 气泡/HistoryPanelShell/生成/提取小窗/阅读卡 |
| B5 | 资源库/AI 建卡/导演/帮助/诊断 | 长尾清扫 |
| B6 | 守卫收紧 + 垫片清空 | 白名单归零，删两 surface 分流文件 |

---

## §九 验收标准

1. 切换棱角：**任一页面**几何/描边/组件形态均呈棱角语言（walkthrough 全页面
   截图矩阵，不再是三件套）——用户判据"换了台设备"。
2. classic/glass golden 零 diff（等值包装的机器证明）；`flutter test` 全绿。
3. 防退化守卫全绿：业务层零结构 import、零结构分支、SnackBar 直用归零。
4. 新结构演练：WonderUi 以"仅新增实现文件 + 目录注册"接入（由奇观结构实施
   验证），业务 diff 为零。
5. 相关设计文档同步更新。

---

## §十 定稿默认（执行前可调整）

| # | 事项 | 默认 | 备选 |
|---|---|---|---|
| K1 | 接口命名 | `LmComponentKit` / `context.lmUi` | LmUiKit / context.ui |
| K2 | v1 会话面范围 | 气泡+输入区+会话行三件；动作条等 v1.1 | 会话面全体入 v1（范围膨胀风险） |
| K3 | DTO 规则 | 表现层 DTO 禁领域实体 | 直用领域实体（否：倒灌固化） |
| K4 | 迁移法 | 垫片反转两步法 | 全量直改业务调用点（慢且易漏） |
| K5 | SnackBar 92 处 | 本波收口归零 | 留实施阶段尾声（否：守卫无法只减不增锁定） |
| K6 | 死代码 | SimpleTemplateCard 删除 | 保留（否：零消费无意义） |
