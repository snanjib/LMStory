# Neubrutalism 设计语言调研（token 级规格提取）

> 日期：2026-09-23。性质：**只读调研档案**，服务 LMStory「新结构」候选评估（与 v0.4.0 已定稿的
> 琉璃×波尔多并列讨论，不推翻任何既有定稿结论）。
> 上位文档：`doc/design/v0.4.0/外观体系v2设计.md`
> （结构×配色族解耦三轴、17+1 槽、四档圆角、动效 token 均沿用其语境）。
> 方法：两个成品代码库逐行提取（Flutter 包 + Tailwind 库，file:line 可复查）+ 五篇规格文档 +
> Gumroad 案例材料 + 批评材料；**所有数值断言标注来源**，未取证处显式标注「未核实」。

---

## §1 风格定义与谱系（从粗野主义建筑到 UI）

**一句话定义（本文采用的基准句）**：Neubrutalism = 粗野主义 web 的「驯化版」——高对比、
块状布局、撞色平涂、粗黑描边、无模糊实心投影，但保留极好的排版与可读性。
来源：NN/g 定义「high contrast, blocky layouts, bold colors, thick borders, and
'unpolished' elements」
（https://www.nngroup.com/articles/neobrutalism/ ，2025-04-11，Hayat Sheikh）；
Malewicz 定义「a mix of regular brutalism in web design and more modern typography,
illustration and styling」（《Neubrutalism is taking over the web》，UX Collective，
2022-03-29，https://uxdesign.cc ）。

**谱系四段**：

1. **1950s 英国粗野主义建筑**：béton brut（清水混凝土）→「Brutalism」；Smithson 夫妇、
   Reyner Banham 1955 年 essay《The New Brutalism》创造该术语；代表作 Boston City Hall、
   Robarts Library（多伦多，1973）。
   来源：LogRocket https://blog.logrocket.com/ux-design/neubrutalism-web-design/ （2023-11）；
   Bejamas https://bejamas.com/insights/field-notes/neubrutalism-web-design-trend （2024-01-20）。
2. **1990s–2010s web 粗野主义**：裸 HTML、系统默认样式、Drudge Report 式表格布局——
   「真粗野主义」是混乱且无装饰的（NN/g 同文）。
3. **2021–2022 转折**：Gumroad 2021 改版成为最著名商业落地（见 §4）；Malewicz 2022-03
   命名性文章引爆讨论；Figma 社区跟进（Bejamas：「Figma 与 Gumroad 是最常启发其他创作者
   的例子」）。同时它是对 neumorphism/glassmorphism 疲劳的反动（Bejamas 同文：「rounded
   edges, subtle, pretty gradients, and soft, colorful shadows」的厌倦）。
4. **2023–2025 常规化与软化**：进入组件库时代（React/Tailwind/shadcn 生态出现成体系
   开源库）；同时出现「soft neubrutalism」变体（圆角、粉彩、阴影收敛；
   来源：WebSearch 汇总 medium.com/bootcamp 「Sleek forms with rounded edges, soft and
   colorful」，检索日 2026-09-23）。

**与「真粗野主义」的分界**（写进结构纪律用）：真粗野主义「embraced ugliness as ideology」，
neubrutalism「uses bold geometry as decoration」——它**不放弃极简与扁平，只弯折几条规则**，
可读性最大化是硬边界（designmd.app https://designmd.app/library/neubrutalism ；
Bejamas 同文）。designmd 称其为「punk rock in a good mood」。

---

## §2 Token 级规格提取（数值表，全部标注来源）

### 2.0 证据源一览

| 代号 | 源 | 性质 |
|---|---|---|
| [FB] | `github.com/infm5/neubrutalism_ui`（pub.dev 包 `neubrutalism_ui` 2.0.2，克隆至 /tmp） | Flutter 成品包，8 个组件 |
| [TW] | `github.com/ekmas/neobrutalism-components`（5.5k star，站点 www.neubrutalism.dev，克隆至 /tmp） | React+Tailwind v4 成品库，50+ 组件 |
| [MD] | https://designmd.app/library/neubrutalism | DESIGN.md 规格页（AI 可读格式） |
| [NN] | https://www.nngroup.com/articles/neobrutalism/ | NN/g 可用性机构规格建议 |
| [BJ] | https://bejamas.com/insights/field-notes/neubrutalism-web-design-trend | 趋势综述 |
| [LR] | https://blog.logrocket.com/ux-design/neubrutalism-web-design/ | 工程向综述（谱系+阴影几何） |
| [SV] | https://www.svgator.com/blog/what-is-neubrutalism （2024-08-27） | 视觉指南 |
| [FG] | https://cssauthor.com/neo-brutalism-ui-kit/ | Figma 社区 kit 集合页（32 个 kit 清单） |
| [GR] | Gumroad 线上品牌（miromiro.app 读其 live CSS；Brand New 2021-12-16 评论） | 商业落地 |

### 2.1 边框

| 项 | 值 | 来源 |
|---|---|---|
| 标准宽度档位 | **2px（控件）/ 3px（容器默认）/ 4px（重强调与 kit token）** | [TW] button.tsx:14 `border-2`；[FB] lib/src/neubrutalism_ui.dart:14 `neuBorder = 3.0`；[MD] `border: 3px solid #000`（推荐 2–4px）；[FG] 「hard 4px black borders and offset shadows」 |
| 颜色 | **纯黑**（[TW] 用 `oklch(0% 0 0)` 即 #000；[FB] `neuBlack = Colors.black`，neubrutalism_ui.dart:9） | [TW] src/styling/globals.css:24；[FB] 同上 |
| 是否唯一的边界语言 | 是——**层级靠边框+阴影，不靠背景色深浅**（[NN]：「solid lines — no reliance on gradients or shadows for structure」中阴影是几何块不是氛围光） | [NN] |
| 驯化变体 | 卡片可降为 1px 边 + 柔和阴影（见 §4 Gumroad 化）；[MD] 卡片规格 `1px border` + `0 2px 12px rgba(0,0,0,0.06)` | [MD] |

注意 [FB] 的缺口：Flutter 包的边框 `Border.all(color, width)` 无内/外对齐问题（Flutter 画在
逻辑边内），与 web 的 CSS border 行为一致，token 可直接迁移（[FB] neu_container.dart:116-119）。

### 2.2 阴影（本风格的第一识别符）

**唯一公式（三个独立来源完全一致）**：

```
shadow = offsetX offsetY 0 0 <border色>     // blur=0，spread=0，实心色块
默认 offset = (4, 4)，方向右下
```

- [TW] src/styling/globals.css:8-11,28：`--box-shadow-x/y: 4px`、
  `--shadow: var(--box-shadow-x) var(--box-shadow-y) 0px 0px var(--border)`
- [FB] lib/src/neubrutalism_ui.dart:15,18：`neuShadowBlurRadius = 0.0`、
  `neuOffset = Offset(4, 4)`（阴影色 `neuShadow = Color(0xFF080808)`，:11——**近黑而非纯黑**，
  与 [MD]「Don't: 纯 #000000，用 off-black/charcoal」不谋而合）
- [MD]：`box-shadow: 4px 4px 0 #000`，表述为「no blur, no spread, just a solid color block
  shifted **3–5px** on both axes」
- [NN]：「a black drop shadow offset by 4px」
- [LR]：阴影「never blurred… full color, usually black… positioned **45° diagonally**
  from the bottom」——45° 即 X=Y 的几何本质
- 变体偏移：[TW] 底部导航用 `shadow-nav: 4px 4px 0px 0px`（globals.css:62）同公式；
  [FG] 的 kit 用 6px offset shadow tokens（社区 kit 档位更大）
- 反向阴影：[TW] 定义 `--reverse-box-shadow-x/y: -4px`（globals.css:10-11），用于
  button `reverse` variant（button.tsx:18-19）：静止无阴影，hover 向左上位移 -4,-4 且
  阴影长出来——「浮起」方向的反演，是对 hover 语言的补充词汇。

**按压态公式（"按进纸里"）**：

- [TW] 主按钮：静止 = 元素在原地 + 阴影偏移 (4,4)；**hover = 元素 translate(4,4) 且
  `shadow-none`**——元素滑进阴影留下的空位，投影消失（button.tsx:14
  `hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none`）。
- [FB] 按钮同构：动画把元素从 Offset(0,0) 平移到 offset(4,4)，同时阴影 offset 实时取
  `widget.offset - _animation.value` 归零——同一物理隐喻（_button.dart:126-128,169,173-176）。
- 结论：**按压 = 阴影消失 + 元素位移 = 「按进纸里」**；这是可从两个代码库双重验证的
  风格核心交互，应原样保留为结构签名。

### 2.3 圆角词汇表（分歧最大的一档）

| 来源 | 圆角主张 |
|---|---|
| [FB] | 组件默认 **null（直角）**；SearchBar 默认 15（neu_search_bar.dart:144）、BottomNav 20（neu_bottom_nav.dart:90）——该包实际是「直角基调 + 局部大圆角」 |
| [TW] | 全库统一 `rounded-base = 5px`（globals.css:7,59）；例外全走 **药丸**：Switch 轨道/滑块、bubble reactions `rounded-full`（switch.tsx; bubble.tsx） |
| [MD] | 基础 8px；锐角效果 0px；按钮/卡片 0.5rem（其内部自认不一致并标注） |
| [FG] | kit 未见统一 radius token 声明（cssauthor 页未给出） |
| [NN]/[BJ] | 「angular geometric forms」「sharp/blocky」为主流印象 |

**综合词汇表（建议档位）**：`0（直角，默认）→ 4–8（控件小圆角）→ 12–20（大容器）→ 药丸（开关/标签/小反应钮）`。
四档封顶，与琉璃结构「四档闭锁」同构（外观体系v2 §2.4），迁移时心智模型不变。
**取舍规则**：直角服务「raw」身份与对齐网格；小圆角服务触屏控件的手指隐喻；药丸只给
开关类与 chip 类，不给主按钮（两个代码库中主按钮均为矩形系）。

### 2.4 色彩

**撞色逻辑**：

- 调色板上限 **2–3 个大胆颜色 + 黑 + 白**（[NN]：「palettes limited to 2–3 bold colors
  (e.g., black, neon green, electric blue)」）。
- 撞色对是**关系设计**而非孤立选色：典型对 red/blue、red/green（[BJ]「bright, clashing,
  high-contrast pairs」）；SVGator：撞色双方「desaturated in most cases（饱和度 ≤80%）」
  且**永远有一个主色主导**（https://www.svgator.com/blog/what-is-neubrutalism ）。
- **纯黑与纯白当骨架**：底色白、描边/文字黑，「embraces 'pure black' over desaturated
  palettes」（[BJ]）；[TW] 的 foreground/border/ring 全部 `oklch(0% 0 0)`
  （globals.css:20-25）。
- 参考实例色板：
  - [TW]：bg `hsl(214,95%,93%)`（浅蓝场地）+ main `hsl(217,100%,66%)`（饱和蓝主色）
    （globals.css:18,23）
  - [FB]：默认组件色 teal（`neuDefault1 = Colors.teal`，neubrutalism_ui.dart:10）
  - Gumroad：粉 `#FF90E8` / 黄 `#FFC900` / 柠檬绿 `#F1F333` / 海军蓝 `#00457C` + 黑白
    （miromiro.app 读 live CSS；Downgraf「Gumroad Pop」公式：白底 #FFFFFF + 黑 #000000 +
    粉 #FF90E8 + 黄 #FFC900）
  - [MD] 示例：黄 #FFEB3B / 红 #FF5252 / 蓝 #2196F3

**中性色的角色**：黑 = 结构（描边、阴影、正文）；白/近白 = 场地；彩色 = 填充砖块。
彩色面积大但**语义密度低**（装饰性填充），语义色仍需单列（[MD] checkbox error 态
`outline-red-500`，TW checkbox.tsx:18）。

**与任意配色族配对的可行性（LMStory 关键问题）**：可行，机制上无障碍——
因为 neubrutalism 的彩色只消费「填充」语义（bg-main、fill、accent 底），黑边黑影黑字是
**颜色无关的骨架**。Gumroad 本身就是「同结构换色板」的实证（粉/黄/柠檬/海军四色共享
同一套黑边白底语法）。落到 LMStory 三轴（结构×配色族解耦，外观体系v2 §2.10/D1）：
新结构只暴露「主填充槽 + 强调填充槽 + 语义槽」消费点，酒红波尔多的 #8C2440/#B3325A
（日间档，外观体系v2 §3.1）可直接充当填充色——但**酒红做大面积平涂填充时会丢「琉璃」
的深酒馆氛围，得到的是「酒标印刷」氛围**（见 §6 评估）。

### 2.5 排版

| 项 | 值 | 来源 |
|---|---|---|
| 字重阶梯 | **heading 700 / body 500（UI 基准）/ 正文长文 400** | [TW] globals.css:13-14（`--heading-font-weight: 700`、`--base-font-weight: 500`）；[MD] hero/H1 700、body 400、label 500 |
| 字体族 | 几何/怪诞 sans 单族制（DM Sans、Inter、Roboto 均被推荐为正文字），显示字可换怪诞体 | [TW] globals.css:16（DM Sans）；[NN]「pair chunky sans-serif headlines with neutral body fonts like Roboto or Inter」 |
| 大小写 | **全大写限于短 label/badge/按钮**（组件层证据：[TW] badge 用 text-xs + 无大写强制但社区惯例 uppercase 标签；[SV]「Powerful colors; Huge fonts; Strongly defined shapes」+ 大量 uppercase 标题案例）。长句禁全大写（可读性） | [SV]；[NN] 可读性规则 |
| 字号对比 | 标题 ≈ **2× 正文**为层级底线；hero `clamp(2.5rem, 5vw, 4rem)`、H1 2.25rem、H2 1.5rem、body 1rem、label 0.75–0.875rem | [NN]（2×）；[MD]（具体标尺） |
| 正文行高/行长 | 1.6 行高、**72ch 行长上限** | [MD] |
| 字距 | 标题 negative tracking（[TW] `tracking-tight`）；meta 小字 wide tracking（[TW] `tracking-widest`） | [TW] card.tsx:41 等 |
| [FB] 的缺位 | **字体 token 完全缺失**（包内不定义字重/字体）——说明字体不是该包的实现重点，规格须由结构层自带 | [FB] 全库 grep 无 TextStyle 字重常量 |

### 2.6 间距密度

- 基础单位 **8px**（0.5rem），最大宽度 1280–1300px 居中，侧边 1.5rem，区块间
  `clamp(4rem, 8vw, 8rem)`（[MD]）。
- 可用性建议：padding/margin **24–32px** 起步，「generous whitespace and padding balance
  the dense elements」（[NN]）——粗野不等于拥挤，**密度低是可读性的一部分**。
- 组件内距实测：button `h-10 px-4`（[TW] button.tsx:22）；card 内距 24px
  （`--card-spacing:--spacing(6)`，[TW] card.tsx:15）；dialog `p-6`；alert `px-4 py-3`。

### 2.7 动效

| 项 | 值 | 来源 |
|---|---|---|
| 时长 | 200–300ms（规格）；库默认 `transition-all`（≈150ms）；Flutter 包 100ms | [MD]；[TW] button.tsx:9；[FB] _button.dart:40 |
| 缓动 | **ease-out（规格主张）**；无弹跳是规格共识 | [MD]「ease-out, 200–300ms; transform/opacity only」 |
| hover/press 语言 | 位移（translate 4,4 + 阴影消失），**不是** 透明度/缩放/发光 | [TW] button.tsx:14-19；[FB] _button.dart:126-176 |
| 弹跳惯例 | [FB] 用了 `Curves.bounceInOut`（_button.dart:128）——**这是包作者的私货，与规格共识（ease-out）冲突**；LMStory 纪律（无弹跳无弹性，外观体系v2 §2.6）应直接判除 | [FB] vs [MD] 对照 |
| 入场 | fade + 16px translateY，420ms + 80ms 列表 stagger；只动 transform/opacity（性能纪律与琉璃一致） | [MD] |
| 大胆动画的边界 | 「animations… but they should always serve a purpose」（[SV]）；neubrutalism 比 minimalism 更允许动效，但限于引导 | [SV]；[BJ]「more structured, adds animation and illustration」 |

---

## §3 组件配方逐个拆解

> 每条给出：静止 token / hover / press / 选中·禁用，以及两库的差异注记。
> [TW] 行号均出自 `src/components/ui/`，[FB] 出自 `lib/src/`。

**Button**
- 静止：填充色块 + border-2 黑 + `shadow-shadow(4,4,0,0黑)`；高 36–44px（h-9/10/11，
  xs h-8）；radius=base 5px；字 500（[TW] button.tsx:9-29）。
- hover：translate(4,4) + 阴影消失（§2.2 按压公式）；`reverse` variant 反向
  （button.tsx:18-19）。
- focus：**2px 黑 ring + 2px offset**（button.tsx:9）——无障碍关键（[TW] 全库一致）。
- disabled：opacity-50 + pointer-events-none（button.tsx:9）。
- [FB]：50×50 起步（_button.dart:36-37），按压用 bounceInOut 100ms（上文已判除 bounce）。
- 文本按钮/图标按钮只是 child 换内容，token 完全同构（neu_text_button.dart:30-60；
  neu_icon_button.dart:94-124）。

**Card**
- 静止：border-2 + shadow(4,4) + 白底（`bg-background`）+ 内距 24px + radius base
  （[TW] card.tsx:15）；[FB] 同构（neu_card.dart:122-142，blurStyle 固定 solid）。
- 卡片**默认不带交互态**（无 hover 位移）——位移语言专属按钮，卡片保持静止是两库共识；
  可交互卡在 [TW] 的 dropdown/tabs 里用「hover 换填充色 + 长出边框」而非位移
  （tabs.tsx：`hover:bg-main hover:border-border`）。
- 驯化变体（Gumroad 化）：1px 边 + 柔和阴影 `0 2px 12px rgba(0,0,0,0.06)`（[MD]）。

**Input**
- 静止：h-10、border-2、**白底**（`bg-secondary-background`）、radius base、placeholder
  50% 黑（input.tsx:11）。
- focus：**2px 黑 ring + offset 2**（input.tsx:11）——注意 [TW] 输入框聚焦不加阴影不加色，
  全靠 ring；[MD] 变体：2px accent focus ring。
- 选择文本高亮用主色（`selection:bg-main`，input.tsx:11）。

**Checkbox**
- 16×16、**2px 黑 outline（代替 border）**、直角（size-4，无 radius）、选中 = 主色填充 +
  白色对勾、disabled opacity-50（checkbox.tsx:18-27）。

**Chip / Badge**
- border-2 黑 + radius base、`px-2.5 py-0.5`、text-xs、500 字重（badge.tsx）。
- 特殊词汇：**reaction 钮用 `rounded-full` 药丸** + border-2（bubble.tsx reactions 变体）
  ——小圆点阵列是直角世界里唯一的圆。

**Nav**
- 桌面导航条：border-2 + radius base + 内嵌 item「hover 填主色 + 补黑边 +
  字重 700（font-heading）」（navigation-menu.tsx）。
- 移动底部导航 [FB]：**悬浮卡**形态——radius 20、阴影方向反转为 `Offset(-1,-4)`（向上浮）、
  选中 = 色块填充 + 图标换色、滚动自动隐藏 300ms、选中动画 200ms easeInOut
  （neu_bottom_nav.dart:89-121,36）。
- Tab 条：轨道 border-2 + p-1，激活 thumb = 主色填充 + 黑边 + 700 字重（tabs.tsx）。

**Banner / Alert**
- border-2 + **shadow(4,4)**（与卡片唯一区别是常带语义色边/填充）+ `px-4 py-3`
  （alert.tsx）。语义仍以边框与图标表达，[MD] 错误态走 `outline-red-500` 体系。

**Tooltip**
- **白底 + border-2 黑**、radius base、无阴影（tooltip.tsx）——「贴纸」隐喻，浮层也走
  描边而非投影（与 shadow 完全 0 blur 的纪律一致）。

**Dialog（模态）**
- border-2 + shadow(4,4) + `p-6` + radius base；入场 `fade+zoom 95%、200ms`
  （dialog.tsx）。遮罩 = **黑 80%**（`--overlay: oklch(0% 0 0 / 0.8)`，globals.css:26）。

**Switch**
- **药丸**轨道 border-2、滑块白底黑边、checked = 主色填充、滑块位移 `translate-x-1`
  （switch.tsx）。

**Progress / Skeleton**
- 进度条：h-4、border-2、白轨道、主色填充（progress.tsx）。
- 骨架屏：**shimmer，不用 spinner**（[MD]）。

**Bubble（聊天气泡，LMStory 特供发现）**
- `max-w-[80%]`、border-2 黑、radius base、`px-3 py-2.5`、text-sm/leading-5；
  variant：default=主色填充/secondary=白/muted=场地浅蓝/**destructive=纯黑白**
  （bubble.tsx:21-40）。
- 评价：这是对 LMStory 会话页最直接的参照——**「描边气泡」与「玻璃气泡」共享完全相同的
  信息结构，只换材质层**；`.theoretical` 对齐（自己=主色填充，对方=白）也与 [TW] 的
  align end/start 机制一致（bubble.tsx:22,27-33）。

---

## §4 Gumroad 式商业驯化案例

**事件**：2021 年 Gumroad 全面改版（Brand New 收录于 2021-12-16，Armin 撰写
《New Logo and Identity for Gumroad》，标签：high-contrast sans serif、illustration、
mascot、**unicase**；https://www.underconsideration.com/brandnew/archives/new_logo_and_identity_for_gumroad.php ）。
designmd 叙事：「The turning point was Gumroad's 2021 redesign. Sahil Lavingia stripped
the product down to thick black borders, flat primary colors, and offset drop
shadows」——并给了著名的比喻：阴影像「a rectangle dragged two pixels southeast」。
（https://designmd.app/library/neubrutalism ）

**为什么是它**：NN/g 分析——Gumroad 用 raw 美学「align with its ethos of empowering
independent creators」，反 polish 本身就是品牌立场
（https://www.nngroup.com/articles/neobrutalism/ ）。Sahil Lavingia 的《The Minimalist
Entrepreneur》哲学（精益、反装饰）与改版互为表里（背景材料，与改版无直接设计稿证据，
标注为语境推断）。

**它如何「驯服」neubrutalism（收敛处）**：

1. **黑白骨架 + 彩色只做 accent**：白底、黑描边黑字是 90% 的世界；粉/黄/柠檬/海军
   （#FF90E8/#FFC900/#F1F333/#00457C，miromiro.app 读 live CSS；
   Downgraf「Gumroad Pop」公式）只在局部填充与按钮出现——正是 [NN]「2–3 bold colors」
   纪律的商业执行。
2. **统一的插画语法**：独角兽 mascot + 单一线条风格的插画系统（Brand New 标签
   illustration/mascot），杜绝了「random clip-art」廉价感（[MD] Don't 列表反证）。
3. **unicase 字标**：大小写混排的定制字（Brand New），把「怪诞字」收敛为可控的品牌资产。
4. **阴影克制的默认 offset**：叙事中的「two pixels southeast」暗示其生产环境阴影比
   社区 kit 的 4–6px 更小、更精致（designmd 转述口径）。

**它如何「放肆」（保留攻击性的地方）**：大字重、大色块、无 blur 实心阴影、
撞色并置一个不少——收敛的是**面积与数量**，不收敛**对比强度**。

**Figma 社区对照**（https://cssauthor.com/neo-brutalism-ui-kit/ 集合页）：高完成度 kit
（「Neo Brutalism UI Library」200+ 组件、「Neubrutalism Design System」token 化文件）
的共同做法：4px 黑边 + 6px shadow token、**颜色全部走 Figma variables（改主色 token 全库
换肤）**、亮 primary 只对 off-white 场地——与 Gumroad 同一收敛逻辑的工程化版本。

---

## §5 批评与对策（对比度 / 审美疲劳 / premium 化）

### 5.1 无障碍对比度

- **批评本身**：高对比「can help content to be more readable for some users」但
  「can also cause anxiety for others」（[BJ]）；NN/g 点名失败配对「yellow on cyan」，
  要求用对比检查器验证；「without balance, the style can overwhelm users and hinder
  accessibility」（[NN]）。LogRocket 列为该风格已知缺点（部分配色不达 WCAG、装饰性
  大写与怪诞体影响可读性）（[LR]）。
- **硬标准**：WCAG AA = 正文 4.5:1 / 大字与图形 3:1（stylekit.top neo-brutalist token 页、
  uxgirl.com、hellopm.co 均引此口径；检索日 2026-09-23）。
- **讽刺点与对策**：该风格的黑边黑影黑字**天然是 3:1 图形对比的最佳公民**（描边即
  非文本对比），真正风险只在**彩底彩字**。对策：彩色只做填充不承载文字，文字一律黑/白；
  每对彩底×文字预验算（LMStory 已有 §2.2 对比度档案方法论可直接复用，外观体系v2 §2.2）。
- 焦虑/过载对策：NN/g 三条——调色板 ≤3、标题 2× 正文、24–32px whitespace；
  加一条：大面积撞色禁入正文阅读区（[BJ] 行业适配判断的推广）。

### 5.2 审美疲劳与潮流风险

- 社区冷感实例：「It makes everything looking like a cartoon. I've yet to see many good
  examples aside Gumroad」（Graphic Design Forum，2023-04-29）；
  Fast Company《8 designers on the trends they want to die in 2025》（2024-12-26）收录
  过载批评（https://www.fastcompany.com/91252988/ ，全文付费墙未核，检索摘要）。
- 同时 Bejamas 2025-05 仍将其列为活跃趋势（[BJ] 更新日期）——**处于「主流化后期」**，
  不是新趋势红利期。
- 对策（对 LMStory）：把它当**结构语法**（几何/描边/按压语言）引入，而把**配色身份**
  留给自己的配色族——潮流褪色时褪的是「糖果色」，不是「黑边白底」骨架；
  Gumroad 六年未褪色正是此机制。

### 5.3 Premium 感的 neubrutalism（粗野 ≠ 粗糙）

- [MD] Don't 列表是最系统的「去廉价」清单：**不用纯 #000000（用 off-black）**、accent
  饱和度 ≤80%、禁 emoji 当图标（用 Lucide/Heroicons）、禁等宽三列（用 zig-zag/非对称）、
  禁 lorem ipsum 与死链。
- [FB] 的 `neuShadow = 0xFF080808`（非纯黑）与 [TW] 的 DM Sans 500 正文——两个成品库
  都在执行 off-black + 中字重的精修。
- SVGator：撞色「most cases desaturated」、whitespace 极大方——**克制才能 premium**。
- 结构性结论：premium neubrutalism = **几何纪律（网格对齐、统一档位、45° 阴影）×
  色彩预算（2–3 色）× 字体质量（好 sans + 正确字重）**。三者缺一即滑向「卡通」
  （Graphic Design Forum 的指控点）。

---

## §6 LMStory 适配评估

### 6.1 与「90% 纪律 + 10% 戏剧」的契合点

（原则出处：外观体系v2 §一成功判据④；concepts/README.md:55,74）

- **契合（可为）**：
  1. 阴影唯一公式、按压态唯一公式——**每个组件的状态语言是确定的**，这正是「纪律」的
     另一种写法（琉璃用材质台阶表达纪律，neubrutalism 用几何公式表达纪律）；
  2. 色彩预算思想同源：Gumroad 骨架 = 黑白 90% + 彩色 10%，与 LMStory「accent 面积
     ≤10%、每屏一颗白药丸」同构；
  3. 「戏剧」落点现成：按压「按进纸里」位移、reverse 阴影反演、45° 实心阴影——都是
     低成本高辨识的签名细节；
  4. 对比度方法论直接继承（4.5:1 档案 + 预验算纪律，外观体系v2 §2.2 口径沿用）。
- **冲突（须改造）**：
  1. **正文阅读区不可兼容**：本风格的一切语法（大色块、描边、硬阴影）都是 Operate 面
     语言；LMStory 正文承诺「零妥协可读性 + 沉浸」（外观体系v2 §一访客模式），阅读面必须
     豁免于该结构或降级为「纸面变体」（见 6.3）；
  2. **bounceInOut 私货必须判除**（[FB] _button.dart:128），违反无弹跳纪律；
  3. 全大写怪诞显示字与 LMStory「中文优先、禁合成斜体、字体资源收编」的排版纪律需要
     翻译：中文语境的「大字报感」应改用**字重 700 + 字号对比**实现，而非大写
     （大写只作用于拉丁 label）；
  4. 黑色遮罩 80% 比琉璃 scrim（#120A12 @60%）重得多，长会话工具面需验算疲劳感。

### 6.2 工具模式（Operate）下如何收敛

以访客模式语义为框（Operate=工具面扫描效率优先；Read=阅读面沉浸优先，外观体系v2 §一）：

1. **只换材质层，不动信息架构**：照 [TW] bubble 的证据，会话列表/设置/资源库的行、卡、
   输入、分段、chip 全部可平移为「描边 + 实心填充 + 位移按压」语法，工厂枚举
   （panel/card/listRow/pillButton/input/segmented/chip/banner/modal/snackBar）
   一一对应，不需要新增容器语法（对齐外观体系v2 §2.8「等」闭口的纪律）。
2. **收敛旋钮（工具面纪律）**：撞色对上限 2（主填充+强调填充，语义色另算）；
   阴影只在「可按压元素」出现（卡片静止零阴影，层级靠描边粗细 2/3/4px 表达）；
   每屏至多一个 shadow 按钮级主操作（等价「每屏一颗白药丸」的 T2 预算）。
3. **动效翻译**：150ms easeOutQuart 位移（去 bounce）+ reduced-motion 直接置终态——
   与琉璃动效 token 表完全同带宽（外观体系v2 §2.6），不新增第三套时长。
4. **mono 技术字幕层可原样保留**：neubrutalism 对 mono/技术风有天然亲和（[NN] 提及
   Windows 98 情结、monospace 复古元素），`//` 分区头语法在该结构里比在琉璃里更不违和。

### 6.3 结构×配色族配对评估（酒红波尔多实验）

- 机制可行（§2.4 结论）：把「黑边白底」当结构常量，波尔多的 primary #8C2440 当主填充、
  accent #B3325A 当强调填充（日间档锚值，外观体系v2 §3.1），即可得到「酒标印刷」风。
- **风险前置**：①酒红平涂面积大时，4.5:1 只约束文字不约束「焦虑感」，深酒红大面积
  在暗环境的可读边界需全档案复算；②「白底黑边」骨架会**吃掉夜间档**——该结构天生是
  日间/浅色结构（[TW] 场地即浅蓝白），夜间档要么反转为黑底白边（骨架翻转让结构常量
  失去「颜色无关」优势），要么承认该结构只发布日间档（**推荐后者**，明示「日间限定
  结构」与琉璃「夜间主场」互补）。
- 身份风险：Neubrutalism 是 2021–2025 高度曝光的公共风格，「换了台设备」的新鲜感收益
  低于琉璃（外观体系v2 §一成功判据①）；它的收益在**工具面的操作爽感**（明确可按压、
  状态零歧义），定位应是「效率结构」而非「品牌结构」。

### 6.4 落地前提（若立项）

1. token 层：边宽 3 档（2/3/4）、阴影 2 token（offset4,4 / offset-4,-4 reverse）、
   按压公式 1 条、radius 4 档、字重 3 档（400/500/700）——总量与琉璃相当；
2. 契约层：零新增配色槽（复用 17+1 槽的 primary/accent/语义槽做填充消费），结构常量
   （边色黑、阴影色、描边档）不进配色槽——与外观体系v2 §2.10 的结构/配色解耦协议一致；
3. 守卫测试预告：正文区零描边语法豁免清单、每屏 shadow 主操作 ≤1、accent 面积抽查
   ——照 §2.10 的 P4 守卫模式复制。

---

## §7 参考链接总表

**代码库（已克隆提取，file:line 见 §2/§3）**
1. infm5/neubrutalism_ui（Flutter 包，v2.0.2）：https://github.com/infm5/neubrutalism_ui
2. ekmas/neobrutalism-components（React+Tailwind，www.neubrutalism.dev）：
   https://github.com/ekmas/neobrutalism-components
3. （附）rational-kunal/NeoBrutalism（SwiftUI 版，未逐行提取）：https://github.com/rational-kunal/NeoBrutalism

**规格文档**
4. Bejamas，Web Design Trend: Neubrutalism（2024-01-20/2025-05 更新）：
   https://bejamas.com/insights/field-notes/neubrutalism-web-design-trend
5. NN/g，Neobrutalism: Definition and Best Practices（2025-04-11）：
   https://www.nngroup.com/articles/neobrutalism/
6. DESIGN.md Library — Neubrutalism：https://designmd.app/library/neubrutalism
7. LogRocket，Neubrutalism in web design（2023-11）：
   https://blog.logrocket.com/ux-design/neubrutalism-web-design/
8. SVGator，What Is The Neubrutalism Web Design Trend? A Visual Guide（2024-08-27）：
   https://www.svgator.com/blog/what-is-neubrutalism
9. Michal Malewicz，Neubrutalism is taking over the web（UX Collective，2022-03-29；
   原文 Medium 反爬，镜像 squareplanet.netlify.app，本文仅引其定义句）：
   https://uxdesign.cc

**Gumroad 案例与 Figma 社区**
10. Brand New，New Logo and Identity for Gumroad（2021-12-16，正文付费墙，标签信息可查）：
    https://www.underconsideration.com/brandnew/archives/new_logo_and_identity_for_gumroad.php
11. miromiro.app（读 Gumroad live CSS 色板）：https://miromiro.app
12. Downgraf，Neobrutalism examples（「Gumroad Pop」公式）：https://www.downgraf.com
13. cssauthor，Free Neo Brutalism UI Kit Collection（Figma kit 集合，2026-05）：
    https://cssauthor.com/neo-brutalism-ui-kit/

**批评与边界**
14. Fast Company，8 designers on the trends they want to die in 2025（2024-12-26）：
    https://www.fastcompany.com/91252988/
15. Graphic Design Forum，Thoughts on Neubrutalism?（2023-04-29）：
    https://www.graphicdesignforum.com
16. OpenReplay blog，High Contrast and Simple Layouts: How Neubrutalism…（2024-10，
    仅检索摘要，全文未取到）：https://blog.openreplay.com
17. Lagomorph，Neubrutalism: A Consideration, and Ruleset（2022-08-11；原链已从站内移除、
    Wayback 未收录，标题与日期经检索确认）：https://lagomor.ph
18. stylekit.top Neo-Brutalist UI Style（WCAG 4.5:1/3:1 口径）：https://www.stylekit.top

**LMStory 侧上下文**
19. `doc/design/v0.4.0/外观体系v2设计.md`
    （三轴解耦、17+1 槽、对比度档案、动效 token、「90% 纪律 + 10% 戏剧」）
20. `doc/design/v0.4.0/concepts/README.md`
    （视觉风格 prompt 与防翻车清单）

---

*本档案为只读调研产出；/tmp 克隆件（neubrutalism_ui、neobrutalism-components）可随时删除重取。
所有「file:line」以 2026-09-23 克隆的 HEAD 为准。*
