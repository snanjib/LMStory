# LMStory Simple 模式视觉规范

> **2026-10-03 当前边界**：首页默认为“新对话 / 新导演”并排入口（导演开关门控，v0.4.0 起默认开启，实验性）；故事入口默认隐藏（设置 → 故事模式设置 开启后回到“新对话 / 新建故事 / 新导演”三卡布局）；无 HUD。文中旧 Schema 或 HUD 展望不属于视觉规范，也不是当前计划。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-06A |
| 版本 | v2.3 |
| 日期 | 2026-07-27 |
| 状态 | 初稿 |
| 前置文档 | LMStory-DOC-06（设计基础）|
| 配套文档 | LMStory-DOC-06B（中级模式视觉规范）|

---

## 0. 文档定位

本文档定义 Simple 模式（v0.1）的完整视觉语言，是 Simple 模式 UI 实现的权威参考。共享的设计基础（间距、圆角、图标、通用 AppBar、响应式、设置页面、基础组件、主题架构）见 DOC-06 设计基础，本文档只定义 Simple 模式**独立**的视觉部分：色彩、字体、页面布局、页面设计、交互、动效、业务组件、设计令牌。

当本文档与 DOC-06 冲突时，Simple 模式范围内以本文档为准。

Simple 模式定位为"可自由配置的 AI 对话工具"（类 ChatBox），设计哲学是**工具消失于任务**——克制、安静、高效。所有实现严格对标 ChatBox。

---

## 1. Simple 色彩系统

Simple 模式采用**柔和暖灰中性色 + 单一强调色**策略（Restrained，≤10% 强调色）。色彩命名基于语义角色（bg/surface/ink/...），而非视觉描述。

### 1.1 Light Theme ("Daylight")

| 角色 | 色值 | 用途 | 示例 |
|------|------|------|------|
| bg | `#F4F5F7` | 页面背景 | Scaffold 背景 |
| surface | `#FFFFFF` | 卡片、面板背景 | 消息气泡、设置卡片 |
| surfaceElevated | `#EEF0F3` | 提升层表面 | Dialog 背景 |
| surfaceVariant | `#E7E9ED` | 变体表面 | 输入框背景 |
| ink | `#22222E` | 主要文字 | 标题、正文 |
| muted | `#6E6E80` | 次要文字 | 时间戳、标签 |
| faint | `#767680` | 占位符、禁用 | 输入框提示、未选中图标 |
| primary | `#4338CA` | 主强调色 | 选中状态、主按钮 |
| primaryDim | `#1F4338CA` (12% opacity) | 主强调色淡化 | NavigationBar indicator |
| accent | `#9E7520` | 辅强调色 | 次要高亮 |
| accentDim | `#1F9E7520` (12% opacity) | 辅强调色淡化 | — |
| divider | `#DDE0E5` | 分割线 | 列表分隔 |
| success | `#1A8A52` | 成功状态 | 连接成功 |
| warning | `#A07A20` | 警告状态 | Token 即将耗尽 |
| error | `#B02E2E` | 错误状态 | API 调用失败 |
| scrim | `#66161616` (40% opacity) | 遮罩层 | Modal 背景 |

### 1.2 Dark Theme ("Twilight")

| 角色 | 色值 | 用途 | 示例 |
|------|------|------|------|
| bg | `#1A1A22` | 页面背景 | Scaffold 背景 |
| surface | `#242430` | 卡片、面板背景 | 消息气泡、设置卡片 |
| surfaceElevated | `#30303C` | 提升层表面 | Dialog 背景 |
| surfaceVariant | `#292934` | 变体表面 | 输入框背景 |
| ink | `#ECECF0` | 主要文字 | 标题、正文 |
| muted | `#9595A2` | 次要文字 | 时间戳、标签 |
| faint | `#8A8A95` | 占位符、禁用 | 输入框提示、未选中图标 |
| primary | `#5C5CE8` | 主强调色 | 选中状态、主按钮 |
| primaryDim | `#265C5CE8` (15% opacity) | 主强调色淡化 | NavigationBar indicator |
| accent | `#C9983A` | 辅强调色 | 次要高亮 |
| accentDim | `#26C9983A` (15% opacity) | 辅强调色淡化 | — |
| divider | `#383842` | 分割线 | 列表分隔 |
| success | `#2EA86A` | 成功状态 | 连接成功 |
| warning | `#C49A30` | 警告状态 | Token 即将耗尽 |
| error | `#C43838` | 错误状态 | API 调用失败 |
| scrim | `#B3161616` (70% opacity) | 遮罩层 | Modal 背景 |

### 1.3 色彩语义解析

```dart
// 通过 Brightness 自动解析
final colors = SimpleColors.of(Theme.of(context).brightness);
// colors.bg, colors.surface, colors.ink, colors.primary, ...
```

### 1.4 ~~旧色彩系统（已废弃）~~

> **已废弃**：以下为 v1.0 设计的赛博朋克风格色彩，已被双模式设计系统替代。保留仅作历史参考。
>
> | 角色 | 色值 | 状态 |
> |------|------|------|
> | 主色 (Primary) `#7C4DFF` | → 已废弃，替换为 primary `#4338CA`/`#5C5CE8` |
> | 辅色 (Secondary) `#00E5FF` | → 已废弃，替换为 accent `#9E7520`/`#C9983A` |
> | 强调色 (Accent) `#FF4081` | → 已废弃，替换为 error `#B02E2E`/`#C43838` |
> | 背景色 `#0A0E27` | → 已废弃，替换为 bg `#F4F5F7`/`#1A1A22` |
> | 表面色 `#141836` | → 已废弃，替换为 surface `#FFFFFF`/`#242430` |

---

## 2. Simple 字体层级

字体族：**Inter** — 产品 UI 金标准，清晰、专业、不喧宾夺主。

> **v0.1 实际实现**：~~SF Pro / 思源黑体~~ 已废弃，替换为 Inter。

| 层级 | Token 名 | 字号 | 字重 | 行高 | 字间距 | 用途 | 示例 |
|------|---------|------|------|------|--------|------|------|
| 展示 | display | 28px | w700 | 1.3 | -0.02 | 大标题 | — |
| 标题 1 | title1 | 22px | w700 | 1.35 | -0.015 | 页面标题 | "设置" |
| 标题 2 | title2 | 18px | w600 | 1.4 | -0.01 | 区块标题 | AppBar 标题 |
| 标题 3 | title3 | 16px | w500 | 1.45 | 0 | 卡片标题 | 会话卡片标题 |
| 正文 | body | 15px | w400 | 1.6 | 0 | 正文内容 | 聊天消息内容 |
| 小正文 | bodySm | 14px | w400 | 1.55 | 0 | 辅助正文 | 设置项描述 |
| 说明 | caption | 12px | w500 | 1.5 | 0.02 | 时间戳、标签 | 消息时间 |
| 标注 | overline | 11px | w600 | 1.4 | 0.06 | 极小说明 | 导航栏标签 |

> **v0.1 实际实现差异**：旧文档中 title1=20px/w700、title2=18px/w600、title3=16px/w400、body=14px/w400、caption=12px/w400、overline=11px/w400。实际代码已更新为上表值。以代码为准。

---

## 3. Simple 页面布局规范

### 3.1 主布局 MainLayout（侧边栏 + 主内容区）

应用根入口为 `MainLayout`（`lib/features/chat/presentation/pages/main_layout.dart`，在 `main.dart` 中作为 `MaterialApp.home`），采用 ChatBox 风格的「侧边栏 + 主内容区」布局，通过响应式断点适配桌面与移动端。

```
┌─────────────┬──────────────────────────────┐
│  ChatSidebar │      主内容区 (Expanded)      │
│   240dp      │  HomePage / ChatModePage   │
│  （可折叠）   │                              │
└─────────────┴──────────────────────────────┘
```

| 区域 | 桌面端（width ≥ 600） | 移动端（width < 600） |
|------|----------------------|----------------------|
| 侧边栏 | 固定 `Row` 列，宽度 240dp，可折叠（`_sidebarVisible`，折叠后宽度 0） | 隐藏为 `Drawer` 抽屉，宽度 = 屏宽 × 0.75，通过汉堡菜单打开 |
| 主内容区 | `Expanded` 占满剩余宽度 | 全屏 |
| 切换入口 | 侧边栏头部「折叠」按钮 / 主区 AppBar 汉堡菜单（仅侧边栏折叠时显示） | 主区 AppBar 汉堡菜单（`showHamburgerMenu=true`） |

**关键交互**（导航栈模型）：
- 导航栈 `List<ChatSession?>`：null = 主界面（HomePage），ChatSession = 会话（含草稿）
- 侧边栏选中会话 → 桌面端 replace 栈顶，移动端 push 入栈 → 主内容区渲染 `ChatModePage(session:...)`（内嵌，非命名路由 push）
- 栈顶为 null → 主内容区渲染 `HomePage`（主界面，含 App 标题/Logo、新建对话大按钮、最近会话列表、设置入口、高级模式预留开关）
- 新建对话 → 创建草稿会话（`__draft_` 前缀，不入库）→ 首条消息发送时才入库为真实会话
- 移动端不嵌套 `Scaffold`：内层 `ChatModePage`/`HomePage` 作为顶层 `Scaffold` 以正确处理状态栏安全区，`Drawer` 通过参数下传并由共享 `_scaffoldKey` 控制
- 状态栏安全距离：所有界面顶部统一通过 `MediaQuery.of(context).padding.top` 处理，侧边栏顶部亦同

> **设计演进**：v0.1 初稿设计为「HomePage + 底部 2 Tab NavigationBar」，后改为 ChatBox 风格侧边栏布局（HomePage 一度被弃用）。当前实现重新引入 `HomePage` 作为**主界面**（app 入口页面），与侧边栏布局共存：主内容区在导航栈为空时渲染 HomePage，选中会话后渲染 ChatModePage。移动端返回键依次回退导航栈至主界面，主界面两次返回退出 app。原 `SessionsPage`（`sessions_page.dart`）已删除。

### 3.2 ChatSidebar 组件

侧边栏（`lib/features/chat/presentation/widgets/chat_sidebar.dart`）自上而下包含：

| 区块 | 内容 |
|------|------|
| 头部 | 应用图标 + 标题 + 全局搜索按钮（打开 `GlobalSearchDialog`）+ 本地过滤按钮（切换搜索框）+ 折叠按钮（仅桌面端） |
| 搜索框 | 本地过滤（按会话标题模糊匹配），切换显隐 |
| 会话列表 | `ReorderableListView`，排序规则：收藏置顶在前，同组内按 `sortOrder` 升序；支持拖拽自定义排序（拖拽后重排 sortOrder 为 0,1000,2000...） |
| 会话项操作 | 长按/侧滑菜单：删除 / 重命名 / 收藏切换 / 复制 |
| 底部 | New Chat 按钮（primaryDim 背景）+ 返回主界面按钮（onGoHome 非空时显示）+ Settings 按钮 |

### 3.3 路由结构

```
MaterialApp.home = MainLayout
  ├── ChatSidebar（侧边栏/抽屉）
  │     ├── 选中会话 → 主内容区渲染 ChatModePage(session)
  │     ├── New Chat → 创建草稿会话（__draft_ 前缀，不入库）
  │     ├── 返回主界面 → 清空导航栈至 [null]（onGoHome 回调）
  │     ├── 全局搜索 → GlobalSearchDialog（覆盖层）
  │     └── Settings → push SettingsPage
  └── 主内容区（导航栈 List<ChatSession?>）
        ├── HomePage（栈顶为 null 时，app 主界面）
        │     ├── App 标题/Logo
        │     ├── 新建对话大按钮 → 创建草稿会话
        │     ├── 最近会话列表（最多 5 个）→ 选中会话
        │     ├── 设置入口 → push SettingsPage
        │     └── 高级模式预留开关（v0.2）
        └── ChatModePage（栈顶为 ChatSession 时）
              ├── AppBar 右上角菜单 → 会话设置/清空/删除
              ├── 模型选择 → DefaultModelPickerSheet（BottomSheet，2026-07-24 v1.4 改造）
              └── 会话设置 → SessionSettingsSheet（BottomSheet）
```

> **实现说明**：v0.1 不使用命名路由，会话切换、模型选择、会话设置等均通过内嵌 Widget 或 `showModalBottomSheet` 完成，设置页通过 `Navigator.push`（`MaterialPageRoute`）跳转。移动端返回键通过 `PopScope` 拦截：Drawer 打开时关闭 Drawer；导航栈长度 > 1 时 pop 栈顶；栈顶为主界面时两次返回退出 app。

---

## 4. Simple 模式页面设计

### 4.1 会话列表（ChatSidebar）

> **实现位置**：会话列表内嵌于侧边栏 `ChatSidebar`（见 §3.2），不再作为独立页面存在。

**布局结构**（侧边栏会话列表区域）：
```
会话列表（ReorderableListView）
├── SidebarSessionItem（会话项，两行布局）
│   ├── Row 1：[mode icon] 模式标签（对话/故事，色彩区分）
│   │   └── 右侧：star 指示器 + 拖拽把手 + 三点菜单（hover/选中态显示）
│   └── Row 2：会话标题（caption 字号，muted 色，最多 1 行超出省略）
└── ...

空状态
└── 引导文案 "暂无会话"
```

**SidebarSessionItem 规范**（两行布局）：
- **两行布局**：Row 1 显示模式标签（对话/故事），Row 2 显示会话标题
- **模式色彩区分**：
  - 对话（simple）：`SimpleColors.primary`（indigo），图标 `chat_bubble_outline`
  - 故事（intermediate）：`SimpleColors.accent`（warm amber，呼应夜航暖色调），图标 `auto_stories`
- **排版**：Row 1 模式标签 bodySm(14px) w500 + 模式色；Row 2 标题 caption(12px) w400 + muted 色
- **选中态**：primaryDim 背景；Row 2 标题 → ink 色 + w500
- **Star 指示器**：starred 且非生成中时显示在 Row 1 右侧（`Icons.star` 14px，accent 色），
  不再覆盖模式图标——让模式信息始终可见
- **长按/侧滑菜单**：删除（error 色）/ 重命名 / 收藏切换 / 复制
- **排序**：收藏置顶在前，同组按 sortOrder 升序
- **拖拽**：支持自定义排序，拖拽后重排 sortOrder
- **生成中指示器**：`isGenerating=true` 时 Row 1 左侧图标位显示
  `BreathingDot`（8px 圆点，SimpleColors.primary，opacity 呼吸动画），
  覆盖模式图标，但模式标签仍显示。优先级：isGenerating > isStarred。
  状态来源：MainLayout 遍历导航栈所有会话，聚合 Simple.isStreaming /
  Intermediate 流式阶段（drafting/draftingRetry/revising/revisingRetry）的
  sessionId 集合，传给 ChatSidebar.generatingSessionIds。

> **设计演进**：旧文档（v0.1 初稿）描述独立的 `SessionsPage`（`/` 路由，NavigationBar Tab 0）+ `SimpleSessionCard`。实际实现改为侧边栏内嵌的 `SidebarSessionItem`。原 `SessionsPage`/`SimpleSessionCard` 已废弃：`SessionsPage` 已删除，`SimpleSessionCard` 组件不再被引用。

### 4.2 聊天页 (ChatModePage)

**渲染方式**：由 `MainLayout` 主内容区内嵌（非命名路由），当选中会话时渲染。

**布局结构**：
```
AppBar
├── 返回 → 会话列表
├── 标题（单行，对标 ChatBox Header）
│   ├── 主标题：会话标题（title2，ink）
│   └── 移除供应商名显示（对标 ChatBox Header，仅显示会话标题）
└── 菜单 (more_vert)
    ├── 选择模型 → DefaultModelPage (push)
    ├── 会话设置 → SessionSettingsSheet (BottomSheet)
    ├── 压缩上下文 → 流式压缩（isCompressing 时禁用），成功后弹窗询问是否更新标题
    ├── 清空消息
    └── 删除会话

消息列表（可滚动）
├── 用户消息气泡
│   └── SimpleMarkdownBody（Markdown 渲染）
├── 助手消息气泡
│   ├── ThinkingSection（思考/推理内容，可折叠）
│   ├── SimpleMarkdownBody（Markdown 渲染）
│   └── ToolCallSection（工具调用详情，可折叠）
├── 摘要消息（特殊样式，可展开/编辑/删除，对标 ChatBox SummaryMessage）
│   ├── 展开：显示摘要内容 + 编辑/删除按钮
│   ├── 编辑：打开 MessageEditDialog 修改摘要文本
│   ├── 删除：确认弹窗 → 删除摘要 + CompactionPoint → 原始消息恢复到上下文
│   ├── 流式生成中（isStreaming=true，对标 ChatBox CompactionStatus）：
│   │   ├── 折叠态：标签行显示 _BouncingDotsIndicator + "正在生成摘要..."（accent 色）；下方小窗预览
│   │   │   （高度 80px，SingleChildScrollView reverse 滚动）实时显示流式内容最后约 240 字符 + _StreamingCursor
│   │   │   闪烁光标；content 为空时显示 _BouncingDotsIndicator 占位
│   │   └── 展开态：SimpleMarkdownBody 完整内容 + 末尾 _StreamingCursor 闪烁光标；不显示编辑/删除按钮
│   └── 失败摘要（isSummary && error != null）：CompactionFailedCard 常驻卡片
│       ├── 视觉：error tint 背景（alpha 0.06）+ error 色全边框（alpha 0.25），禁用侧边条（遵循 impeccable 规则）
│       ├── 顶部：error_outline 图标 + "压缩失败"标题 + 关闭 IconButton
│       ├── 中部：错误信息（默认 3 行预览 + 省略号 + "展开更多/收起"按钮，error 色紧凑 InkWell）
│       │   + 已生成的部分摘要（SimpleMarkdownBody 渲染）
│       ├── 底部：重试按钮（TextButton.icon，error 色）
│       ├── 重试 → 删除失败摘要 → 重新触发流式压缩
│       └── 关闭 → 删除失败摘要消息（无 CompactionPoint，安全）
├── SimpleForkNav（分支导航："1/3" + 左右箭头）
└── StreamingIndicator（流式输出指示器）

输入区域（固定在底部）
├── 引用预览块（quoteText 非空时显示，最上方）
├── 附件预览区（图片/文件缩略图，横向滚动，可删除）
├── 输入行
│   ├── 停止按钮（流式输出时显示，左侧）
│   └── ChatInput（文本输入框，rXs 微圆角，surfaceVariant 背景）
│       └── 发送按钮（suffixIcon，输入框内右侧）
└── 工具栏（输入行下方）
    ├── 左侧：附件按钮（+ 图标）+ 上下文用量触发器（显示"已用/上限"格式，如 `~12K / 128K`，超 80% 上下文窗口显示警告色）
    └── 右侧：会话设置按钮（齿轮图标）+ 模型选择芯片（显示当前模型名）
```

**输入区域工具栏规范**（对标 ChatBox InputBox 工具栏）：
- 附件按钮：28×28 圆形，surfaceVariant 背景，add_rounded 图标，非流式输出时显示
- 上下文用量触发器：overline 字号，faint 色；显示"已用/上限"格式（如 `~12K / 128K`）；超过上下文窗口 80% 时显示 warning 色；点击弹出上下文用量详情面板（BottomSheet，含"压缩对话"按钮，对标 ChatBox TokenCountMenu）
  - contextWindow 来源：模型缓存的 `contextWindow` 字段；未知时使用默认值 96000（对标 ChatBox `DEFAULT_CONTEXT_WINDOW`）
  - 已用 token：当前上下文消息的 token 总量估算
- 会话设置按钮：28×28 圆形，surfaceVariant 背景，tune 图标，点击弹出 SessionSettingsSheet
- 模型选择芯片：rFull 胶囊形，surfaceVariant 背景，smart_toy_outlined 图标 + 模型名 + 下拉箭头，点击弹出 DefaultModelPickerSheet（2026-07-24 v1.4 改造，原 ModelSelectorSheet 已废弃移除）

**引用预览块规范**（对标 ChatBox quote preview）：
- 触发条件：用户点击消息操作栏的"引用"按钮，`state.quoteText` 非空时显示
- 位置：输入区域最上方（附件预览区之上）
- 样式：accentDim 背景（accent 色 12% opacity tint），rSm 圆角，**禁用侧边条 border**（遵循 impeccable 规则，用背景色 tint + 图标传达语义）
- 内容：format_quote 图标（14px，accent 色）+ 引用文本前 100 字符（超出显示 '...'）+ 关闭按钮（close 图标，14px，faint 色）
- 文本样式：caption 字号，muted 色，斜体，单行显示（换行替换为空格）
- 关闭按钮：点击后调用 `clearQuote()` 清除 `state.quoteText`
- 发送行为：发送时将引用文本格式化为 markdown 引用块（每行加 `>` 前缀）拼接到用户输入前，发送后自动清除引用

**MessageBubble 规范**：
- 布局方式（对标 ChatBox 列占位）：
  - 使用 Row + Expanded，头像占据独立列，内容用 Expanded 撑满剩余空间
  - 头像列不挤压消息内容：Expanded 自动占据头像之外的剩余空间，不手动减去头像宽度
  - 每行只分为：1 个头像列宽度 + 消息内容宽度，头像正下方不显示消息
- 头像位置规则（对标 ChatBox）：
  - Standard 模式：用户和 AI 头像都在左侧
  - Bubble 模式：用户头像在右侧，AI 头像在左侧
  - 连续消息（isConsecutive）时用 32px 等宽占位保持对齐，不显示头像图标
- 最大宽度（对标 ChatBox）：
  - User 消息（Bubble 模式）：可用宽度的 92%（右对齐，增大宽度减少移动端换行）
  - Assistant 消息：撑满剩余空间（左对齐，与标准模式宽度一致）
  - Standard 模式：所有消息撑满剩余空间（左对齐）
- 圆角：rLg (16)
- 内边距：sMd (12)
- User 消息（Bubble 模式）：
  - 背景色：primaryDim
  - 文字颜色：ink
  - 对齐：右对齐
- User 消息（Standard 模式）：
  - 背景色：transparent（无背景，偏离 ChatBox Classic，与助手消息统一）
  - 文字颜色：ink
  - 对齐：左对齐
- Assistant 消息（Bubble 模式）：
  - 背景色：surface
  - 文字颜色：ink
  - 对齐：左对齐
- Assistant 消息（Standard 模式）：
  - 背景色：transparent（无背景）
  - 文字颜色：ink
  - 对齐：左对齐
- 操作按钮（编辑/删除/重发）：
  - 尺寸：24×24
  - 颜色：muted
  - 位置：消息气泡下方
  - 显示策略（对标 ChatBox，适配移动端）：
    - 最后一条助手消息：始终显示
    - 其他消息：点击消息内容切换显示/隐藏，3 秒后自动隐藏
    - 使用 onTap 而非 onLongPress，避免触发文字选择
    - 不可见时不渲染（返回 `SizedBox.shrink()`），避免留白和"不可见但可点击"的体验问题
    - `SimpleMessageBubble` 为 StatefulWidget，维护 `_actionsVisible` 状态 + 3 秒自动隐藏定时器

**进入会话滚动定位规范**（对标 ChatBox）：
- 触发条件：会话首次加载消息完成（`previous.messages` 为空且 `next.messages` 非空，非流式状态）
- 定位策略：有缓存 → 恢复上次查看的位置（`ScrollPositionCache.restore`）；无缓存 → 即时跳到底部（最新消息）
- 即时定位（无动画）：使用 `jumpTo` 而非 `animateTo`，用户进入会话直接看到目标位置，不显示滚动过程
- 滚动位置保存：`ChatModePage.dispose()` 时通过 `ScrollPositionCache.save(sessionId, offset)` 保存当前滚动偏移量
- 偏移量边界保护：恢复时 `offset.clamp(0, maxScrollExtent)`，避免消息数量变化后越界
- 列表渲染方向：`ListView.builder` 设 `reverse: true`，itemBuilder 内做 index 反转映射（`msgIndex = messages.length - 1 - adjustedIndex`），数据层 `state.messages` 仍保持升序（旧→新）。reverse 后进入会话天然在底部（offset = 0），无需 `jumpTo(maxScrollExtent)` 构建全部历史消息，**根治长对话进入卡顿/ANR**
- offset 语义切换：reverse 后 `0 = 底部（最新）`，`maxScrollExtent = 顶部（最旧）`；所有"跳顶/跳底"逻辑的 offset 值互换（`0 ↔ maxScrollExtent`）；`_atBottom` 判定改为 `offset <= 50`；`_findFirstVisibleIndex` 改为视口相交判定（方向无关）

**流式自动滚动规范**（对标 ChatBox）：
- 触发条件：`state.isStreaming == true` 且 state 发生变化时
- 滚动策略：仅在用户已在底部附近（`_atBottom == true`）时自动滚动到底部
- 避免打断用户查看历史：用户向上滚动查看历史消息时，流式更新不会强制拉回底部
- 实现：`ref.listen` 监听 `chatModeControllerProvider` 变化，触发 `_scrollToBottom()`

**生成中指示器规范**（对标 ChatBox）：
- **发送后/重生成后占位气泡**：当 `isStreaming == true` 且 `currentAssistantMessageId == null`（尚未收到首个 token）时，在消息列表末尾渲染一个空的助手消息气泡（复用 `SimpleMessageBubble`，`isStreaming: true` + `isGenerating: true`），自动显示旋转头像 + BouncingDotsIndicator。首个 token 到达后，占位气泡被真实助手消息替换。**regenerate/editAndResend 时**，占位气泡通过 `state.generatingAnchorUserMsgId` 关联到 Fork 锚点，显示 SimpleForkNav 分支导航，用户可在生成过程中切换到旧分支查看（切换时不取消生成，进入后台流式模式，生成完成后新分支作为已完成消息存在，不强制切换回生成分支）
- **等待首个 token**：`_BouncingDotsIndicator` — 三个 accent 色圆点（6×6），交错弹跳动画（1200ms 周期，4px 弹跳高度），在助手消息内容为空且流式输出开始时显示
  - **复用场景**：摘要流式生成中（`_CompactionSummaryCard` 的 `isStreaming=true`）的折叠态小窗占位、展开态空内容占位也复用此组件
  - **避免重复动画**：摘要卡片展开态的标签栏（`_buildHeader`）改用静态 `auto_awesome_outlined` 图标，不显示 `_BouncingDotsIndicator`，因为内容区已承载加载动画/光标。仅折叠态标签栏显示三点动画
- **流式输出中**：`_StreamingCursor` — 1.5×14 accent 色闪烁竖线（540ms 淡入淡出周期），跟在内容末尾
  - **复用场景**：摘要流式生成中（`_CompactionSummaryCard` 的 `isStreaming=true`）的折叠态小窗预览末尾、展开态内容末尾也复用此组件
- **头像旋转动画**：`_MessageAvatar` — 生成中时显示 refresh_rounded 图标 + 1500ms 旋转动画（RotationTransition），替代默认 smart_toy_outlined 图标

**ErrorMessage 规范**（错误持久化，对标 ChatBox）：
- 触发条件：助手消息 `error` 字段非空且非流式输出状态
- 位置：消息气泡内，主内容之后、ToolCallSection 之前
- 样式：error 色 8% 透明背景 + error 色 25% 透明边框，rSm 圆角
- 内容：error_outline 图标（16px，error 色）+ 错误文本（bodySm 字号，error 色）
- **展开/收起交互**（v0.1 新增）：默认 `maxLines: 3` + `TextOverflow.ellipsis` 折叠为 3 行预览；右下角"展开更多/收起"按钮（紧凑 InkWell，overline 字号 + 上下箭头图标，error 色保持视觉一致性）；点击切换为 `maxLines: null` 显示完整错误内容
- 持久性：错误信息随消息持久化到 DB，切换分支时快照包含 error 字段
- **错误展示唯一入口**：错误仅在消息气泡内展示，不在输入框上方另设错误提示条（原 `SimpleErrorToast` 已移除）。用户通过消息卡片的"重新生成"按钮重试

**MessageMeta 规范**（消息元信息行，v0.1 新增，对标 ChatBox tips 数组）：
- 位置：消息气泡下方，操作按钮之上
- 组件：`_MessageMeta`（StatelessWidget）+ `_MetaTip`（数据类，含 label + tooltip?）
- 显示顺序（对标 ChatBox Message.tsx tips 数组）：
  1. 模型名（仅助手消息，受 showModelName 控制）
  2. Tokens 用量（仅助手消息，受 showTokenUsed 控制，格式 "N tokens"）
  3. 字数统计（受 showWordCount 控制，格式 "N words"）
  4. 首字延迟（仅助手消息，受 showFirstTokenLatency 控制，格式 "X.Xs"）
  5. 时间戳（受 showTimestamp 控制，格式 HH:mm / MM/dd HH:mm / yyyy/MM/dd HH:mm）
- 分隔符：`·`（中点，U+00B7），第 2 项起前缀
- 样式：11px monospace + faint 色 + height 1.4（caption 令牌的变体）
- 布局：Wrap + WrapCrossAlignment.center + spacing s2xs
- 显示条件：
  - 生成中（isStreaming=true）不显示 tokens/字数/首字延迟（对标 ChatBox !msg.generating）
  - 各条目受 DisplayPreferences 对应开关控制
  - 数据缺失时跳过该条目（如 tokensUsed 为 null 时不显示 tokens 行）
- 数据来源：
  - 模型名：`ChatMessage.modelName`（兜底使用 widget.modelNameFallback）
  - Tokens：`ChatMessage.tokensUsed`（来自 API usage.total_tokens）
  - 字数：`_countWords(content)`（中文按字符，英文按空格分词）
  - 首字延迟：`ChatMessage.firstTokenLatency`（毫秒，首个文本 token 到达时计算）
  - 时间戳：`ChatMessage.createdAt`
- 单位词硬编码英文（tokens/words/s）— 技术缩写跨语言可读（对标 ChatBox）

> **v0.1 实际实现差异**：
> - 旧文档 User 消息背景 `#7C4DFF`（primary 实色），实际使用 primaryDim（半透明）
> - 旧文档 Assistant 消息背景 `#141836`，实际使用 surface
> - 新增 **SimpleMarkdownBody** 组件（Markdown 渲染），旧文档无此组件
> - 新增 **SimpleForkNav** 组件（替代旧 BranchIndicator），使用 ForkAnchor 数据结构
> - 新增 **模型选择器** 在输入区域（DefaultModelPickerSheet，2026-07-24 v1.4 改造：原 ModelSelectorSheet 双 dropdown 已废弃，统一为按供应商分组的单菜单 + 可折叠子列表，对标 ChatBox MobileModelSelector；ModelSelectorSheet 文件已删除）
> - 旧文档含 TokenCountChip，v0.1 已实现为**上下文用量触发器**（可点击，显示 ~12K/128K 格式，点击弹出详情面板含压缩按钮），对标 ChatBox TokenCountMenu
> - Standard 模式用户消息背景由 surfaceVariant 改为 transparent（偏离 ChatBox Classic，与助手消息统一无背景风格）

**SimpleForkNav 规范**（对标实际实现 `lib/core/theme/system/structures/classic/conversation/simple_fork_nav.dart`）：
- 位置：消息气泡下方，居中
- 背景：transparent（透明，无独立容器）
- 圆角：无（非胶囊形，纯文本+图标行）
- 内边距：仅底部 s2xs（sXs 顶部无边距）
- 文字：caption，faint 色（非 muted）
- 箭头按钮：16×16，muted 色（非 primary）
- 显示格式："◀ 1/3 ▶"（箭头在两侧，序号居中）

**SimpleMarkdownBody 规范**（对标 ChatBox Markdown.tsx，`lib/core/theme/system/structures/classic/conversation/simple_markdown_body.dart`）：

渲染能力（对标 ChatBox）：
- **GFM 扩展语法**：表格、任务列表、删除线、自动链接（通过 `ExtensionSet.gitHubFlavored`）
- **代码语法高亮**：基于 `flutter_highlighting`，亮色用 `github` 主题、暗色用 `github-dark` 主题
- **代码块组件**（`SimpleCodeBlock`，独立文件 `simple_code_block.dart`）：
  - 语言标签（右上角胶囊徽章，surfaceVariant 底 + muted 字 + rXs 圆角）
  - 折叠/展开按钮（>7 行自动折叠，显示首尾 3 行；展开后显示全部，i18n `codeExpand`/`codeCollapse`）
  - 复制按钮（`Icons.copy_outline` 16×16 + muted 色，点击复制代码 + SnackBar 反馈）
  - Mermaid 降级提示（语言为 `mermaid` 时，不渲染图表，显示 `mermaidNotSupported` 提示条 + 完整源码）
  - 代码块背景：surfaceVariant
  - 代码块圆角：rMd (12)
- **LaTeX 数学公式**（`SafeLatexElementBuilder`，独立文件 `simple_latex_builder.dart`）：
  - 行内公式 `$...$`（`LatexInlineSyntax`）+ 块级公式 `$$...$$`（`LatexBlockSyntax`）
  - 基于 `flutter_math_fork` 渲染，try-catch 容错（不支持的命令降级为纯文本）
  - 字号跟随 `fontScale` 缩放，mathStyle 跟随 Brightness（亮色 display、暗色 display）
- **链接点击**：`onTapLink` 调用 `url_launcher.launchUrl` 打开外部浏览器（`LaunchMode.externalApplication`）；非 http(s) 链接或启动失败回退到剪贴板 + SnackBar 提示
- 基础 Markdown：粗体、斜体、行内代码、引用块、有序/无序列表、分隔线、标题（H1-H6）
- 引用块装饰：surfaceVariant 底 + rSm 圆角 + 左侧 3px primary 边框
- 表格：FlexColumnWidth 自适应列宽，divider 色 1px 边框，表头 w600 字重
- 字号缩放：所有元素按 `fontScale`（small=0.9 / medium=1.0 / large=1.15）等比缩放

**SimpleMessageNavigation 规范**（对标实际实现 `lib/core/theme/system/structures/classic/conversation/simple_message_navigation.dart`）：
- 用途：长对话中的快速消息定位浮标（滑动时出现，停止后自动消失）
- 位置：聊天页消息列表右侧浮层（Stack + Positioned）
- 容器：surfaceElevated 背景，rSm (8) 圆角，sXs 阴影（变窄设计）
- 布局：垂直排列 4 个按钮 + 分割线
  - 顶部 2 按钮：跳到顶部（↑）、上一条用户消息（▲）
  - 分割线：divider 色，左右 s2xs 缩进
  - 底部 2 按钮：下一条用户消息（▼）、跳到底部（↓）
- 图标：16×16，muted 色
- 内边距：sSm (8px)，保持 40x40 触控目标
- 交互：MouseRegion 检测 hover（桌面端），鼠标进入显示、离开延迟隐藏
- 动效：AnimatedOpacity + AnimatedSlide，200ms duration，Curves.easeOut
- 不透明度：显示时 0.85（降低不透明度，避免遮挡阅读）
- 显示策略（对标 ChatBox MessageNavigation）：
  - 桌面端：鼠标 hover 消息列表右侧区域时显示，离开后 2s 隐藏
  - 移动端：滚动时显示（`_isScrollActive = true`），停止滚动 2s 后自动隐藏；在底部时不显示

### 4.3 会话设置 BottomSheet (SessionSettingsSheet)

**布局结构**：
```
标题："会话设置" + 关闭按钮

API 供应商
├── 下拉选择（含"使用默认供应商（当前：xxx）"选项，xxx 为全局生效供应商名）
└── 切换后重置 modelId

模型
├── 下拉选择（含"使用默认模型（当前：xxx）"选项，xxx 为全局生效模型名，按当前供应商过滤）
└── 无可用模型时显示提示

系统提示词
├── 标签行右侧："选择模板"按钮（仅有模板时显示，primary 色，bookmark_outline 图标）
├── 多行输入框（1-5 行，空值 = 使用默认，hint 显示全局默认提示词预览）
└── "选择模板"按钮点击弹出模板列表弹窗（AlertDialog），选中后填入输入框，用户可继续编辑

温度
├── 滑块（0.0 - 2.0，步长 0.01，默认值取全局配置）
└── 当前值显示（点击可手动输入）

Top P
├── 滑块（0.0 - 1.0，步长 0.01，默认值取全局配置）
└── 当前值显示（点击可手动输入）

最大 Token 数
└── 输入框（空值 = 使用默认，hint 显示全局默认 max tokens 值）

最大上下文消息数
├── 非线性滑块（无限制 / 2 / 4 / 6 / 8 / 10 / 20 / 50 / 100）
└── 当前值显示

流式输出
└── 开关（默认值取全局配置）

思考预算（条件显示：仅当当前生效模型标记 reasoning capability 时显示）
├── 标签：i18n key "chat.sessionSettings.reasoningEffort"
├── 列表式选择器（5 个选项，对标通用设置 _SelectionOption 样式）
│   ├── 跟随全局（notSet，NULL = 回退到全局默认，显示"当前生效：xxx"）
│   ├── 禁用（disabled，显式关闭思考——发送厂商原生关闭参数）
│   ├── 低（low）
│   ├── 中（medium）
│   └── 高（high）
├── 选项间用 Divider 分隔（indent: sLg）
└── 选中项右侧显示 check 图标（primary 色）

删除会话
└── 红色边框按钮（点击弹确认弹窗）
```

**设计规范**：
- 容器背景：surface
- 顶部圆角：rLg (16)
- 标题：title2，ink
- 标签：caption，muted
- 输入框背景：surfaceElevated，圆角 rXs（4px 微圆角，2026-07-20 修订：原 rMd 改为 rXs 对齐用户偏好"直角边缘"），无边框
- 滑块轨道：primaryDim
- 滑块激活：primary
- 开关激活：primary
- 删除按钮：error 文字 + error 30% 透明边框
- **DropdownButtonFormField 规范**（防 RenderFlex overflow）：
  - 必须设置 `isExpanded: true`，让下拉项占据可用宽度
  - 下拉项 Text 必须设置 `maxLines: 1` + `overflow: TextOverflow.ellipsis`
  - 适用于所有 DropdownButtonFormField 使用场景（会话设置、模型选择 Sheet 等）
- **Text overflow 防护规范**（防 RenderFlex overflow，适用于所有 Row 中的 Text）：
  - Row 中的 Text 必须用 `Expanded` 或 `Flexible` 包裹，并设置 `maxLines: 1` + `overflow: TextOverflow.ellipsis`
  - 禁止在 Row 中直接使用 `Text + Spacer + 按钮` 的模式（Spacer 在空间不足时收缩到 0，但其他固定宽度组件仍可能 overflow）；改用 `Expanded(Text) + 按钮`，让 Text 占用剩余空间并自动截断
  - `Row(mainAxisAlignment: spaceBetween)` 中的双 Text 模式同理：左侧 Text 用 `Expanded` 包裹，右侧 Text 固定，中间用 `SizedBox(width: ...)` 间隔
  - 长按显示完整内容：对可能被截断的 Text（如模型名、会话标题），用 `Tooltip(triggerMode: TooltipTriggerMode.longPress)` 包裹，点击则触发外层 `onTap`（注意：`TooltipTriggerMode.tap` 会拦截点击事件，导致外层 InkWell.onTap 不触发）
  - `Expanded(child: Text(...))` 即使有 Expanded 限制宽度，也必须设置 `maxLines`，否则 Text 会换行导致垂直方向 overflow

**_ReasoningEffort 选择器规范**（v0.1 新增）：
- 容器：surfaceVariant 背景 + rLg 圆角
- 标签：caption，muted（i18n key `chat.sessionSettings.reasoningEffort`）
- 选项组件：`_ReasoningEffortOption`（列表式，对标通用设置 `_SelectionOption` 样式）
- 选项布局：InkWell + Padding(sLg, sMd) + Row[Expanded(Text body, ink, maxLines:1, ellipsis) + 选中时 check 图标(20px, primary)]
- 选项间用 `Divider(height: 1, indent: sLg, color: divider)` 分隔
- **显示条件**：仅当 `_currentModelSupportsReasoning` 为 true 时显示
  - `_currentModelSupportsReasoning` getter：基于 `ConfigurationResolver.resolveModelDisplayInfo` 解析出的 `_modelDisplayInfo.supportsReasoning`（已综合考虑会话级 modelId 与全局默认 modelId 的优先级）
  - 当使用默认模型时也能正确判断能力（不再要求会话有明确 modelId）
- **5 个选项**：跟随全局（NULL）/ 禁用 / 低 / 中 / 高
- **"跟随全局"项显示当前全局档位**：当会话级为 NULL（跟随全局）时，在标签下方显示"当前生效：xxx"（xxx 为全局当前值的中文名）
- 选中即持久化（`_updateSession(_session.copyWith(reasoningEffort: ...))`），无需显式保存
- **DeepSeek 等仅支持启用/禁用的模型**：仍显示 5 档，但低/中/高在 API 请求层均等同启用（由 `ChatModeController._sendToApi` 统一处理为 `reasoning_effort` 参数）
- **disabled 与 null 语义差异**（2026-07-28 修订）：
  - `null`（跟随全局）→ 不发参数，跟随模型默认行为（对思考模型通常为开启思考）
  - `disabled`（显式禁用）→ 发送厂商原生关闭参数（如 DeepSeek-V3.1+ 用 `thinking:{type:disabled}`，Qwen3 用 `enable_thinking:false`），强制关闭思考
  - 不支持关闭的纯思考模型（DeepSeek-R1、OpenAI o-series）选 disabled 时退化为不发参数

> **v0.1 实际实现差异**：
> - 旧文档使用旧色彩值，已替换为 Simple 模式色彩令牌
> - 旧文档描述"自动压缩开关 + 重置/保存按钮"，实际实现改为：自动保存（onChangeEnd/onChanged 即时持久化），新增"API 供应商选择"、"系统提示词"、"最大上下文消息数"、"删除会话"按钮
> - 设置项变更即时持久化（对标 ChatBox 的 disableAutoSave=false 模式），无需显式保存
> - **系统提示词新增"选择模板"功能**（LMStory 增强，偏离 ChatBox——ChatBox 仅有纯文本框）：标签行右侧显示"选择模板"按钮（仅当存在系统提示词模板时显示），点击弹出 AlertDialog 模板列表，选中后填入输入框。原因：LMStory 已有模板系统（TemplateRepository），复用现有资产
> - **思考预算选择器**（v0.1 新增，对标 ChatBox reasoning effort 配置）：条件显示（模型支持 reasoning 时），5 档列表式选择器，会话级覆盖全局默认

> **v1.1 变更记录**（2026-07-12）：
> - **会话设置面板显示当前生效配置值**：修复打开面板时所有"使用默认"项显示空白的问题。现在通过 `ConfigurationResolver.resolveSettings` 和 `resolveModelDisplayInfo` 解析生效配置，在各"使用默认"项中追加"（当前：xxx）"显示全局生效值
>   - API 供应商下拉："使用默认供应商（当前：供应商A）"
>   - 模型下拉："使用默认模型（当前：gpt-4o）"
>   - 系统提示词输入框 hint："使用默认提示词（当前：你是一个有用的…）"
>   - 最大 Token 数输入框 hint："默认（当前：4096）"
>   - 温度/Top P 滑块默认值取全局配置（不再硬编码 0.7/1.0）
>   - 流式输出开关默认值取全局配置（不再硬编码 true）
>   - 思考预算"使用默认"项："使用默认（当前：中）"
> - **思考预算显示条件优化**：基于 `ConfigurationResolver.resolveModelDisplayInfo` 解析出的 `_modelDisplayInfo.supportsReasoning` 判断（已综合考虑会话级 modelId 与全局默认 modelId 优先级），使用默认模型时也能正确显示思考预算选项

### 4.4 模型选择 BottomSheet (DefaultModelPickerSheet)

> **2026-07-24 v1.4 双菜单→单菜单改造**：原 `ModelSelectorSheet`（双 dropdown：供应商 + 模型）已废弃并删除文件。Simple 模式所有需要选择模型的场景统一复用 `DefaultModelPickerSheet`：
> - 输入框工具栏的模型选择芯片（轻量快速切换）
> - 会话设置 sheet 中的"模型"卡片入口
> - 设置 → 对话模式默认配置 → 标题模型 / 默认模型
>
> 设计目标：对标 ChatBox MobileModelSelector，按供应商分组展示 + 可折叠子列表，避免长模型列表滚动疲劳。

**布局结构**：
```
AppBar 标题（动态：选择模型 / 标题模型 / 会话模型）

可选：清除/使用全局配置 tile
└── 图标 layers_clear_outlined + 文案（仅会话级模式显示）

供应商分组列表（按 ApiPreset 分组）
├── _ProviderGroup（StatefulWidget，可折叠）
│   ├── 组标题行（点击切换折叠状态）
│   │   ├── chevron 图标（keyboard_arrow_down，收起时朝右）
│   │   ├── 供应商名称（bodyUi w600，muted）
│   │   └── 模型数量 badge（caption，faint 色，rXs 圆角，如 "12"）
│   └── AnimatedSize 模型列表容器（展开时显示）
│       └── 模型项
│           ├── 模型名称（body，ink）
│           ├── 模型 ID（caption，faint）
│           ├── 能力 badge（vision/reasoning/toolUse/webSearch）
│           └── 选中标记（check_circle，primary）
└── ...

空状态：图标 + "暂无模型" + "去配置"按钮 → ProviderListPage
```

**关键交互**：
- 默认折叠状态：包含当前选中模型的供应商默认展开，其他默认收起
- 点击组标题切换折叠状态（AnimatedSize 200ms easeOutCubic 动画）
- 点击模型项 → `onModelSelected` 回调持久化 → sheet 关闭 → 显示成功 snackbar
- 可选 `clearLabel`：会话级模式提供"使用全局配置"按钮，返回 `(null, null)` 表示跟随全局
- 可选 `onBeforeSelect` 钩子：嵌入模型切换时已有向量会失效，弹确认对话框
- `modelType` 参数过滤：默认 `ModelType.chat`，嵌入场景传 `ModelType.embedding`；旧数据（type=null）回退展示全部

**视觉规范**：
- 配色：SimpleColors 主题（bg/surface/surfaceElevated/ink/muted/faint/primary）
- 字体：SimpleTextStyles（title2/body/bodySm/caption）
- 圆角：SimpleRadius.rXs（4px 微圆角，对齐用户偏好）
- 间距：SimpleSpacing（sLg/sMd/sSm/sXs）
- AppBar：`SimpleAppBar` 自定义组件（surface 背景 + ink 文字）

**复用场景与参数差异**：

| 场景 | selectedPresetId/ModelId | title | clearLabel | successMessage | onModelSelected |
|------|--------------------------|-------|------------|----------------|-----------------|
| 全局默认模型 | 全局配置值 | "选择模型" | null（不显示） | "已设为默认模型" | 默认 setDefaultModel 路径 |
| 会话级模型覆盖 | 会话字段值 | "模型" | "使用全局配置" | "模型已更新" | controller.updateSession |
| 标题模型 | 全局 title_model 值 | "标题模型" | null | "标题模型已更新" | setUserOverride(common.title_model_*) |
| 嵌入模型（故事模式用 IntermediateModelPickerSheet 夜航主题版本） | 全局 embedding 值 | "嵌入模型" | null | "嵌入模型已保存" | setUserOverride(intermediate.embedding_*) |

**会话级卡片入口（SessionSettingsSheet._buildModelCard）**：
- 视觉：`SimpleSettingCard`（icon smart_toy_outlined + 标题"模型" + 副标题）
- 副标题规则：
  - 会话级已配 preset+model → "供应商名 · 模型名"
  - 会话级为 null，全局已配 → "全局：供应商名 · 模型名"
  - 都未配 → "未配置"
- 点击 → `_showModelPicker` 弹出 `DefaultModelPickerSheet`

---

### 4.5 新手引导页 (OnboardingPage)

**实现位置**：`lib/features/onboarding/presentation/pages/onboarding_page.dart`，6 步详细版新手引导流程。

**双入口模式**（通过 `OnboardingPage.isReview` 参数区分）：

| 入口 | isReview | 触发位置 | 右上角按钮 | 完成行为 |
|------|---------|---------|-----------|---------|
| 首次启动 | `false` | `MainLayout.build` 顶部检测 `onboardingProvider.completed == false` 时全屏覆盖 | "跳过" | 调用 `OnboardingNotifier.markCompleted` 写入 SharedPreferences key `onboarding_completed` |
| 设置重看 | `true` | 帮助 Wiki「新手引导」条目（**2026-08-23 核实**：实际入口在帮助 Wiki，`SettingsPage` 底部无入口卡片——本表原记载失实） | "关闭" | `Navigator.maybePop`，**不写入** completed（用户可重复访问） |

**状态管理**：`OnboardingNotifier`（StateNotifier）维护 `OnboardingState(isLoading, completed)`，`isLoading` 用于避免引导未加载完显示主界面闪烁。`MainLayout` 在 build 顶部 `ref.watch(onboardingProvider)`，`isLoading` 时显示启动屏（BrandLogo + 加载指示，H1 修复 2026-08-23——此前为 `SizedBox.shrink` 白屏），未完成时返回 `OnboardingPage()`。

**布局结构**：
```
Scaffold（bg 背景）
├── AppBar
│   └── actions：右上角 TextButton（"跳过" / "关闭"，bodySm + muted 色）
└── SafeArea
    └── Column
        ├── 步骤指示器（_buildStepIndicator）
        │   ├── 文案 "第 X / 6 步"（caption + faint）
        │   └── 分段进度条（6 段，current=primary / done=muted / pending=surfaceVariant）
        ├── Expanded：PageView（6 步，animateToPage 220ms easeOutCubic）
        │   ├── Step 1：_buildWelcomeStep
        │   ├── Step 2：_buildModesStep
        │   ├── Step 3：_buildApiKeyStep
        │   ├── Step 4：_buildTemplateStep
        │   ├── Step 5：_buildMemoryStep
        │   └── Step 6：_buildReadyStep
        └── 底部导航栏（_buildBottomBar）
            ├── 上一步按钮（首步隐藏）
            └── 下一步按钮 / 开始使用按钮（末步变为"开始使用"）
```

**6 步流程内容**：

| 步骤 | 标题 | 副标题/描述 | 关键组件 |
|------|------|------------|---------|
| 1. 欢迎介绍 | `onboarding.welcome.title` | 副标题 primary 色 + 描述 muted 色 | `_HeroIcon`（auto_stories，96×96） |
| 2. 双模式说明 | `onboarding.modes.title` | 副标题 muted 色 | 双 `_ModeCard` 对比：对话（chat_outlined + primary）/ 故事（auto_stories_outlined + accent） |
| 3. API Key 配置 | `onboarding.apiKey.title` | 描述 API Key 作用 | "去配置" TextButton（primary，跳转 ProviderListPage） |
| 4. 提示词模板 | `onboarding.template.title` | 介绍内置模板 + 自定义 | "去查看" TextButton（primary，跳转 TemplateManagementPage） |
| 5. 记忆机制 | `onboarding.memory.title` | 介绍记忆流程 | `_MemoryFlowDiagram`（4 步流程图：输入 → 提取 → 检索 → 注入） |
| 6. 开始使用 | `onboarding.ready.title` | 引导完成 | "开始使用" _PrimaryButton（primary 背景，触发 `_finish`） |

**视觉规范**：

| 属性 | 规范 |
|------|------|
| 背景 | `SimpleColors.bg`（页面）+ `surface`（卡片） |
| 主标题 | display 28px w700，ink 色（Step 1）/ title1 22px w700，ink 色（其他步） |
| 副标题 | title3 16px w500，primary 色（Step 1）/ bodySm 14px w400，muted 色（其他步） |
| 描述 | body 15px w400，muted 色 |
| 圆角 | 全部使用 `SimpleRadius.rXs`（4px 微圆角，对齐用户"直角边缘"偏好） |
| 步骤指示器 | 分段进度条（6 段），高度 3px，段间距 4px，current=primary / done=muted / pending=surfaceVariant |
| `_HeroIcon` | 96×96，primaryDim 背景，rXs 圆角，Icons.auto_stories + primary 色 |
| `_ModeCard` | Column 布局：48×48 图标（iconBg 背景）+ title2 标题 + bodySm 描述 |
| `_PrimaryButton` | rXs 圆角，primary 背景，ink 反色文字，sMd 内边距 |
| `_MemoryFlowDiagram` | 4 个 `_FlowNode`（圆形数字 + 文字）+ 箭头分隔，bodySm 字号 |
| 底部导航 | Row：上一步（TextButton + muted） / 下一步（FilledButton + primary） |

**翻译键**（`lib/i18n/zh_CN.i18n.yaml` → `onboarding` 章节）：
- 通用：`title` / `entrySubtitle`（设置页入口卡片）/ `skip` / `prev` / `next` / `done` / `close` / `stepIndicator(current, total)`
- 6 步文案：`welcome.{title,subtitle,desc}` / `modes.{title,subtitle,chatTitle,chatDesc,storyTitle,storyDesc}` / `apiKey.{title,subtitle,desc,action}` / `template.{title,subtitle,desc,action}` / `memory.{title,subtitle,desc,flow1,flow2,flow3,flow4}` / `ready.{title,subtitle,desc,action}`

**设置页入口**（`lib/features/settings/presentation/pages/settings_page.dart`，2026-07-27 简化）：
- 设置主页底部「帮助」入口卡片直接跳转 `WikiHomePage`（使用手册主目录，详见 §4.6）
- 新手引导从 `WikiHomePage` 第一部分「开始使用」→「新手引导」条目点击进入，传 `isReview: true`
- 「首次启动」入口不受影响，仍由 `MainLayout` 全屏覆盖触发

> **设计原则**：遵循 impeccable `onboard.md` 指南——Show Don't Tell（每步配 hero 图标或流程图示）/ Time to Value（Step 3/4 提供可选 CTA 按钮直接跳配置页，不强制）/ Context Over Ceremony（6 步而非 10 步，每步信息密度足够）。视觉与 Simple 模式整体语言一致，避免使用饱和强调色，圆角统一 rXs。

---

### 4.6 使用手册主目录 (WikiHomePage)

**实现位置**：`lib/features/help/presentation/pages/wiki_home_page.dart`，2026-07-26 新增（2026-07-27 取代原 `HelpSettingsPage`）。

**背景**：原 v1.4 的「帮助页（HelpSettingsPage）」只承载新手引导 + 故事模式原理 wiki 两个区块，无法作为整个软件的统一说明书。重构为 WikiHomePage，参考 iOS/Android 系统设置搜索样式——顶部固定搜索框 + 7 个用户视角章节 + 每章节下若干条目，作为产品完整说明书入口。已实现条目可点击进入子页，待建设条目显示「即将上线」标签。

**设置主页入口卡片**（`lib/features/settings/presentation/pages/settings_page.dart`）：
- 位置：设置主页底部，诊断信息卡片之后，作为最后一个 `SimpleSettingCard`
- 图标：`Icons.help_outline`
- 标题：`t.help.title`（"帮助"）
- 副标题：`t.help.entrySubtitle`（"使用入门与原理说明"）
- 点击：`_navigateTo(context, const WikiHomePage())`

**布局结构**：
```
Scaffold（bg 背景）
├── SimpleAppBar（title: "LMStory 使用手册"）
└── Column
    ├── WikiSearchBar（顶部固定搜索框）
    │   ├── 容器：surfaceVariant 背景 + rLg 圆角 + sMd padding
    │   ├── prefixIcon: Icons.search_rounded（muted 色，20px）
    │   ├── suffixIcon: Icons.close_rounded（有输入时显示，18px）
    │   ├── 不自动聚焦（避免移动端键盘弹出遮挡列表）
    │   └── onChanged: 实时过滤（标题 + 副标题，小写匹配）
    └── Expanded
        └── _query.isEmpty
            ? ListView（章节列表）
            │   └── for each section: WikiSectionView
            │       ├── 章节标题（title1 + w700）
            │       ├── 章节副标题（caption + muted）
            │       └── for each entry: WikiEntryView
            │           ├── pageBuilder != null → SimpleSettingCard（可点击）
            │           └── pageBuilder == null → 禁用样式 + 「即将上线」标签
            └── ListView（搜索结果，扁平化匹配条目）
                └── 空结果 → 居中 Icons.search_off_rounded + noResults 文案
```

**7 个用户视角章节**（i18n key `help.wikiHome.section{1-7}Title/Subtitle`）：

| # | 章节 | 副标题 | 条目数 | 实现状态 |
|---|------|--------|--------|---------|
| 1 | 开始使用 | 入门与基本操作 | 3 | 1.3 新手引导已实现（→ OnboardingPage isReview:true），1.1/1.2 阶段 2 |
| 2 | 对话模式用法 | 创建会话、发送消息、消息操作 | 6 | 阶段 3 实现 |
| 3 | 故事模式用法 | 创建故事、四步生成、记忆库 | 7 | 阶段 3 实现 |
| 4 | 故事模式原理 | 看懂背后的设计 | 4 | 4.1-4.4 已实现（含宏摘要机制） |
| 5 | 配置与个性化 | API 供应商、模型、提示词、外观 | 7 | 阶段 4 实现 |
| 6 | 数据与维护 | 导入导出、备份、诊断 | 4 | 阶段 4 实现 |
| 7 | 附录 | FAQ、术语表、功能索引 | 4 | 阶段 4 实现 |

**视觉规范**：

| 属性 | 规范 |
|------|------|
| 背景 | `SimpleColors.bg` |
| 搜索框背景 | `surfaceVariant` + rLg 圆角 |
| 搜索框 hint | body 15px + muted 色 |
| 搜索框输入文本 | body 15px + ink 色 |
| 章节标题 | title1 22px w700，ink 色（非 uppercase eyebrow 套路） |
| 章节副标题 | caption 12px w500，muted 色 |
| 章节间距 | sLg（16px），章节内条目间距 sSm（8px） |
| 已实现条目 | 复用 `SimpleSettingCard`（icon + title + subtitle + chevron_right） |
| 待建设条目 | surfaceVariant 背景 + rLg 圆角 + faint 色图标/文本 + 「即将上线」小标签（surfaceElevated 背景 + rXs 圆角） |
| 「即将上线」标签 | caption 11px + muted 色 |
| 列表 padding | sLg / sMd / sLg / s2xl（上/左/右/下） |
| 空搜索结果 | Icons.search_off_rounded 56px faint 色 + noResults body 文案 muted 色 |

**翻译键**（`lib/i18n/zh_CN.i18n.yaml` → `help.wikiHome` 章节）：
- 主页：`title` / `searchHint` / `noResults` / `comingSoon`
- 章节：`section{1-7}Title` / `section{1-7}Subtitle`
- 条目：`entry_{section}_{index}_title` / `entry_{section}_{index}_subtitle`（共 35 条目）

**文件拆分**（2026-07-27 重构，满足 ≤500 行规则）：

| 文件 | 职责 |
|------|------|
| `lib/features/help/presentation/pages/wiki_home_page.dart` | 主页面 StatefulWidget：搜索状态 + 章节列表/搜索结果列表编排（约 135 行） |
| `lib/features/help/presentation/widgets/wiki_data.dart` | `WikiSection` / `WikiEntry` 数据结构 + `buildWikiSections(context)` 工厂方法（约 325 行，包含 7 章节 35 条目配置） |
| `lib/features/help/presentation/widgets/wiki_search_bar.dart` | `WikiSearchBar` 组件：圆角搜索框 + 搜索图标 + 清除按钮 |
| `lib/features/help/presentation/widgets/wiki_section_view.dart` | `WikiSectionView` 组件：章节标题 + 副标题 + 条目列表 |
| `lib/features/help/presentation/widgets/wiki_entry_view.dart` | `WikiEntryView` 组件：根据 `pageBuilder` 是否为 null 显示已实现/待建设两种样式 |

> **设计原则**：参考 iOS/Android 系统设置搜索——顶部固定搜索框（不自动聚焦避免键盘遮挡）+ 实时过滤匹配 + 章节分组列表。已实现条目复用 `SimpleSettingCard` 与设置主页视觉一致；待建设条目用 faint 色弱化 + 「即将上线」标签明确状态。拒绝嵌套卡片，章节标题用 title1 + caption 层级组合。所有 wiki 子页共享 `WikiPageScaffold` 骨架（见 §4.6.1）。

---

#### 4.6.1 wiki 子页通用骨架 (WikiPageScaffold)

**实现位置**：`lib/features/help/presentation/widgets/wiki_page_scaffold.dart`

3 个 wiki 子页共用的骨架：AppBar + 可滚动正文。

```
Scaffold（bg 背景）
├── SimpleAppBar（title 来自子页）
└── ListView.separated
    ├── padding: sLg / sLg / sLg / s2xl
    ├── separatorBuilder: SizedBox(sXl) — 章节间 24px 节奏间距
    └── children: 子页传入的章节列表
```

设计要点：
- 章节间靠 spacing 节奏区分，不靠 border 或 background
- 不使用 Card 嵌套，让内容直接呼吸
- 章节间距 24px（sXl）+ 末尾 32px（s2xl）留白

#### 4.6.2 WikiSection 组件

**实现位置**：`lib/features/help/presentation/widgets/wiki_section.dart`

无步骤编号的章节卡片，用于记忆机制 / 失败处理子页。

| 属性 | 规范 |
|------|------|
| 标题 | title2 18px w600，ink 色 |
| 正文 | body 15px w400，muted 色，行高 1.7（提升可读性） |
| 间距 | 标题与正文间 sSm（8px） |

#### 4.6.3 WikiStepCard 组件

**实现位置**：`lib/features/help/presentation/widgets/wiki_step_card.dart`

带步骤编号的章节卡片，仅四步生成流程子页使用。

| 属性 | 规范 |
|------|------|
| 步骤编号 | 32×32 圆形 badge（primary 色填充 + rFull 圆角），bodySm 14px w600 surface 反色文字 |
| 标题 | title2 18px w600，ink 色 |
| 正文 | body 15px w400，muted 色，行高 1.7 |
| 布局 | Row（编号 + SizedBox sMd + Expanded(Column(标题 + 正文))） |

> **设计原则**：步骤编号是真实有序序列（1→2→3→4→5→6），不是装饰性「01/02/03」scaffolding。impeccable 设计指南允许真实序列使用编号，禁止纯装饰性的全 section 编号 eyebrow。

#### 4.6.4 wiki 子页内容

12 个子页内容来源：用户产品 wiki（2026-07-26 / 2026-07-27），由设计文档 DOC-08/09/10/11 及源码实现提炼。

| 子页 | 内容章节 |
|------|---------|
| `FirstLaunchWikiPage`（第一次打开 App，2026-07-27 新增） | 引言 + 主视觉示意图（FirstLaunchFlowDiagram） + 6 步引导（WikiStepCard 紧凑列表） + API Key 提示卡片 |
| `HomeOverviewWikiPage`（界面总览，2026-07-27 新增） | 引言 + 主视觉示意图（HomeLayoutDiagram） + 侧边栏 4 区域（_SidebarBlock） + 模式切换卡片 |
| `SessionOperationWikiPage`（创建与切换会话，2026-07-27 新增） | 引言 + 主视觉示意图（SessionOperationDiagram） + 6 步 WikiStepCard + 全局搜索 + 平台差异 |
| `MessageFlowWikiPage`（发送消息与查看回复，2026-07-27 新增） | 引言 + 主视觉示意图（MessageFlowDiagram） + 3 步输入框要点 + 流式输出体验 |
| `MessageActionsWikiPage`（消息操作，2026-07-27 新增） | 引言 + 主视觉示意图（MessageActionsDiagram） + 6 步 WikiStepCard（含继续生成） + 分支说明 |
| `MessageNavigationWikiPage`（消息导航，2026-07-27 新增） | 引言 + 主视觉示意图（FloatingNavDiagram） + 4 步 WikiStepCard + 自动隐藏机制 |
| `SessionSettingsWikiPage`（会话设置，2026-07-27 新增） | 引言 + 主视觉示意图（SessionSettingsDiagram） + 3 步优先级说明 + 重置为全局 |
| `CompactionFlowWikiPage`（上下文管理与压缩，2026-07-27 新增） | 引言 + 主视觉示意图（CompactionFlowDiagram） + 触发条件 + 3 步流程 + 失败处理 |
| `StoryVsChatWikiPage`（故事模式与对话模式的区别，2026-07-27 新增） | 引言 + 主视觉示意图（StoryVsChatDiagram） + 两种模式定位（WikiStepCard 对比） + 何时选哪个 + 模式切换 |
| `FirstStoryWikiPage`（创建第一个故事，2026-07-27 新增） | 引言 + 主视觉示意图（FirstStoryFlowDiagram，3 步流程 + 嵌入模型缺失 Banner） + 3 步 WikiStepCard + 系统提示词 + 嵌入模型 + 首条消息 |
| `StoryFlowWikiPage`（四步生成流程） | 引言短文 + 主流程图（FlowOverviewDiagram） + 编辑部角色图（RoleFlowDiagram） + 6 个 FlowStepCard + 视觉时间轴（VisualFlowTimeline） |
| `StoryMessageActionsWikiPage`（故事模式消息操作，2026-07-27 新增） | 引言 + 主视觉示意图（StoryMessageActionsDiagram，4 种操作 + Fork 窗口限制） + 4 步 WikiStepCard + 窗口说明 + 与对话模式差异 |
| `StoryFailureWikiPage`（失败处理） | 引言 + 5 个 WikiSection（原子事务/各阶段失败处理/UI 保留/手动重试/事实层降级） |
| `StorySessionSettingsWikiPage`（故事会话设置，2026-07-27 新增） | 引言 + 主视觉示意图（StorySessionSettingsDiagram，4 步骤模型 + 6 区段） + 4 步骤模型说明 + 6 步 WikiStepCard + 失败状态可修改 |
| `MemoryBrowserWikiPage`（记忆库浏览器，2026-07-27 新增） | 引言 + 主视觉示意图（MemoryBrowserDiagram，双 Tab + 4 种操作） + 双 Tab 说明（WikiStepCard） + 4 种操作说明 + 进入入口 |
| `StoryMemoryWikiPage`（记忆机制） | 引言 + 7 个 WikiSection（两类记忆对比/经历类/事实类/向量化内容/检索查询源/三重防护/5 层健康度） |
| `MacroSummaryWikiPage`（宏摘要机制，2026-07-27 新增） | 引言 + 主视觉示意图（MacroSummaryOverviewDiagram） + 双触发卡片 + 边界跳过 + 失败降级 + UI 表现 |
| `ApiProviderWikiPage`（API 供应商管理，2026-07-27 新增） | 引言 + 主视觉示意图（ApiProviderDiagram，7 个内置模板 + 自定义 2 步流程） + 4 步 WikiStepCard（名称/协议/Host/API Key） + 模型管理 + 进入入口 |
| `ModelStrategyWikiPage`（模型选择策略，2026-07-27 新增） | 引言 + 主视觉示意图（ModelStrategyDiagram，3 层优先级 + 故事 4 步骤） + 3 步 WikiStepCard（对话默认/故事 4 步骤/会话级覆盖） + 嵌入模型 + 标题模型 + 进入入口 |
| `PromptTemplateWikiPage`（提示词模板系统，2026-07-27 新增） | 引言 + 主视觉示意图（PromptTemplateDiagram，3 种类型 + 4 种操作） + 4 步 WikiStepCard（创建/编辑/复制/删除） + 内置模板 + 应用方式 + 进入入口 |
| `StoryPromptCustomWikiPage`（故事模式提示词自定义，2026-07-27 新增） | 引言 + 主视觉示意图（StoryPromptCustomDiagram，10 段列表 + 编辑器 3 区块） + 10 步 WikiStepCard（默认角色/生成后缀/关键词提取/审查后缀/事件摘要/宏摘要/生成注入/记忆注入/事实提取/世界设定注入） + 拼接预览 + 修改检测 + 进入入口 |
| `AppearanceWikiPage`（外观与主题，2026-07-27 新增） | 引言 + 主视觉示意图（AppearanceDiagram，3 主题模式 + 字体 10 档） + 2 步 WikiStepCard（主题模式/字体大小） + 故事模式夜航主题 + 进入入口 |
| `LanguageInputWikiPage`（语言与输入，2026-07-27 新增） | 引言 + 主视觉示意图（LanguageInputDiagram，3 语言选项 + 发送快捷键） + 2 步 WikiStepCard（界面语言/发送快捷键） + 进入入口 |
| `AdvancedSettingsWikiPage`（高级设置，2026-07-27 新增） | 引言 + 主视觉示意图（AdvancedSettingsDiagram，3 区块 + 5 档思考预算） + 3 步 WikiStepCard（思考预算/超时/标题模型） + 流式输出开关 + 进入入口 |

**实现位置**：
- `lib/features/help/presentation/pages/first_launch_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/home_overview_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/session_operation_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/message_flow_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/message_actions_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/message_navigation_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/session_settings_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/compaction_flow_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/story_vs_chat_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/first_story_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/story_message_actions_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/story_session_settings_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/memory_browser_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/api_provider_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/model_strategy_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/prompt_template_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/story_prompt_custom_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/appearance_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/language_input_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/advanced_settings_wiki_page.dart`（2026-07-27 新增）
- `lib/features/help/presentation/pages/story_flow_wiki_page.dart`（v2 图形化版，2026-07-26）
- `lib/features/help/presentation/pages/story_memory_wiki_page.dart`
- `lib/features/help/presentation/pages/story_failure_wiki_page.dart`
- `lib/features/help/presentation/pages/macro_summary_wiki_page.dart`（2026-07-27 新增）

**公共组件**（2026-07-27 提取）：
- `lib/features/help/presentation/widgets/wiki_section_title.dart`：WikiSectionTitle 章节标题（标题 + 可选副标题），从 macro_summary_wiki_page 和 story_flow_wiki_page 提取私有 _SectionTitle 消除重复

#### 4.6.5 四步流程页 v2 图形化组件（2026-07-26 重构）

四步流程页从纯文字版重构为图形化版，新增 4 个组件：

**FlowOverviewDiagram**（`lib/features/help/presentation/widgets/flow_overview_diagram.dart`）

主流程图，6 节点竖向，节点间用虚线连接。

| 属性 | 规范 |
|------|------|
| 节点尺寸 | 56×56 圆形，primaryDim 背景，primary 色图标（28px） |
| 节点间距 | s2xs + 24px 虚线 + s2xs |
| 虚线 | 2px 宽，dashHeight 4，dashSpace 3，faint 色 |
| 节点文案 | 标题 title2 w700 ink 色 + 动作 bodySm muted 色 |
| 节点数据 | 起草/提取/检索/润色/摘要/入库（硬编码在组件内） |

**RoleFlowDiagram**（`lib/features/help/presentation/widgets/role_flow_diagram.dart`）

编辑部比喻图，5 角色横向滚动 + chevron_right 连接。

| 属性 | 规范 |
|------|------|
| 容器 | surface 背景 + rLg 圆角 + divider 边框 + sLg padding |
| 角色卡 | 88px 宽，48×48 圆形图标（primaryDim 背景） |
| 角色文案 | 角色名 bodySm w600 ink 色 + 职责 caption muted 色 |
| 连接符 | chevron_right 图标，faint 色，20px |
| 角色数据 | 实习编辑/资料员/档案管理员/主编/归档员（硬编码） |

**FlowStepCard**（`lib/features/help/presentation/widgets/flow_step_card.dart`）

增强版步骤卡片，比原 WikiStepCard 多了图标 + 输入输出图 + 要点列表。

| 属性 | 规范 |
|------|------|
| 容器 | surface 背景 + rLg 圆角 + divider 边框 + sLg padding |
| 编号 badge | 32×32 圆形，primary 背景，surface 反色文字 bodySm w700 |
| 图标 badge | 40×40，primaryDim 背景，rMd 圆角，22px primary 色图标 |
| 输入/输出框 | surfaceVariant 背景 + rXs 圆角 + sSm/sXs padding，标签 overline + 值 bodySm |
| 输入值 | muted 色，输出值 primary 色（强调产出） |
| 输入输出连接 | arrow_forward 图标，faint 色，18px |
| 要点列表 | 圆点 4×4 primary 色 + bodySm muted 色短句，间距 s2xs |

**VisualFlowTimeline**（`lib/features/help/presentation/widgets/visual_flow_timeline.dart`）

视觉时间轴，5 节点竖向，主回复节点高亮。

| 属性 | 规范 |
|------|------|
| 容器 | surface 背景 + rLg 圆角 + divider 边框 + sLg padding |
| 普通节点 | 24×24 圆形，primaryDim 背景，surface 反色图标 14px |
| 高亮节点 | 32×32 圆形（主回复），primary 背景，surface 反色图标 18px |
| 节点文案 | 名称 body w500/w700 + 描述 caption muted 色 |
| 连接线 | 2px 宽，divider 色，高 20px，左缩进 20px 对齐节点中心 |
| 节点数据 | 生成面板/提取小窗/检索小窗/主回复（高亮）/摘要小窗（硬编码） |

> **设计原则**：v2 重构基于用户反馈「文字太多不够直观」，遵循 impeccable 设计指南——拒绝大段文字堆砌，每个章节配独立图示。图形组件内的文案以"硬编码"方式写入组件（不通过 i18n），因为这些是固定的流程节点名（如「起草」「检索」），不随语言变化的术语结构；i18n 只承载可变文案（步骤标题/输入/输出/要点）。

#### 4.6.6 宏摘要机制页示意图组件（2026-07-27 新增）

宏摘要机制页（`MacroSummaryWikiPage`）从纯文字版重构为图形化版，新增 1 个组件 + 复用现有 `_SectionTitle` / `_TriggerCard` 局部组件。

**MacroSummaryOverviewDiagram**（`lib/features/help/presentation/widgets/macro_summary_overview_diagram.dart`）

主视觉示意图，展示「3 个微摘要 → 聚合成 1 条宏摘要」的关系。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角 + sLg padding |
| 布局 | Row（flex 2 : flex 1 : flex 2），左：3 个微摘要节点 / 中：聚合箭头 / 右：宏摘要节点 |
| 微摘要节点 | 24×24 圆形（primaryDim 背景 + primary 内圆 10px） + bodySm w500 标签 + caption muted 描述 |
| 微摘要间距 | 节点间用 2px 宽虚线连接（高 16px，左缩进 11px 对齐圆心） |
| 聚合箭头 | Icons.arrow_forward_rounded（primary 色 22px） + caption w600 primary 色文案 |
| 宏摘要节点 | 48×48 圆形（primary 背景） + Icons.library_add_check_outlined（surface 色 24px） + bodySm w700 标签 + caption muted 描述 |
| 文案来源 | i18n key `help.macroWiki.diagramMicroLabel/Desc` / `diagramAggregateLabel` / `diagramMacroLabel/Desc`（4 个 key，无硬编码） |

**宏摘要机制页布局**：

```
WikiPageScaffold（title: "宏摘要机制"）
├── 引言短文（body + muted + height 1.7）
├── WikiSectionTitle（overviewTitle + overviewSubtitle）
├── MacroSummaryOverviewDiagram（主视觉示意图）
├── WikiSectionTitle（triggersTitle + triggersSubtitle）
├── _TriggerCard（trigger1：Icons.flag_outlined + 双触发-边界触发文案）
├── _TriggerCard（trigger2：Icons.timer_outlined + 双触发-周期触发文案）
├── WikiSectionTitle（skipTitle）+ 边界跳过短文
├── WikiSectionTitle（fallbackTitle）+ 失败降级短文
└── WikiSectionTitle（uiTitle）+ UI 表现短文
```

**翻译键**（`lib/i18n/zh_CN.i18n.yaml` → `help.macroWiki` 章节）：
- 主页：`title` / `intro`
- 示意图：`overviewTitle` / `overviewSubtitle` / `diagramMicroLabel` / `diagramMicroDesc` / `diagramAggregateLabel` / `diagramMacroLabel` / `diagramMacroDesc`
- 双触发：`triggersTitle` / `triggersSubtitle` / `trigger1Title` / `trigger1Body` / `trigger2Title` / `trigger2Body`
- 边界跳过：`skipTitle` / `skipBody`
- 失败降级：`fallbackTitle` / `fallbackBody`
- UI 表现：`uiTitle` / `uiBody`

> **设计原则**：基于用户反馈「文字太多不直观，示意图优先」，宏摘要机制页采用主视觉示意图 + 短句要点的形式，拒绝大段文字堆砌。示意图内的文案全部通过 i18n 承载（与 §4.6.5 四步流程页 v2 的硬编码策略不同——宏摘要页的节点文案是可变的产品文案，非固定术语结构）。双触发机制用并列卡片（`_TriggerCard`）对比展示边界触发 vs 周期触发，比纯文字段落更清晰。

#### 4.6.7 第一次打开 App 页示意图组件（2026-07-27 新增）

「第一次打开 App」页（`FirstLaunchWikiPage`）顶部主视觉，展示「启动 App → 新手引导 → 主界面」的 3 节点流程。

**FirstLaunchFlowDiagram**（`lib/features/help/presentation/widgets/first_launch_flow_diagram.dart`）

| 属性 | 规范 |
|------|------|
| 容器 | 无独立容器，节点直接 Column 排列，节点间用虚线连接 |
| 节点尺寸 | 48×48 圆形（rFull），普通态 primaryDim 背景 + primary 色 24px 图标，高亮态 primary 背景 + surface 色 24px 图标 |
| 节点间距 | 24px 竖向虚线（左缩进 23px 对齐节点中心，与 FlowOverviewDiagram 同风格） |
| 虚线 | 2px 宽，dashHeight 4，dashSpace 3，faint 色 |
| 节点文案 | 标签 title2 w600/w700 ink 色（高亮态 w700）+ 描述 bodySm muted 色 |
| 数字徽章 | accent 色背景 + surface 色 caption 10px w700 文字，定位 right:-4 / top:-4，clipBehavior: Clip.none 允许溢出 |
| 节点数据 | 启动 App / 新手引导（高亮，badge='6'）/ 主界面（i18n 驱动，3 组 diagramStartLabel/Desc + diagramGuideLabel/Desc + diagramHomeLabel/Desc） |

**节点内部组件**：
- `_FlowNode`：圆形图标 + 标签 + 描述横向排列，可选 highlight 与 badge
- `_DashedLine`：竖向虚线连接器（CustomPaint + _DashedLinePainter）

**视觉传达**：首次启动 → 必经 6 步引导（节点 2 高亮 + accent 数字徽章强调"6"）→ 进入主界面

> **设计原则**：节点 2 用 primary 实色背景 + accent 数字徽章强调"新手引导"是首次启动的核心环节，节点 1/3 用 primaryDim 弱化背景表达"启动"和"主界面"是入口/出口状态。虚线连接沿用 §4.6.5 FlowOverviewDiagram 风格保持视觉一致。文案全部通过 i18n 承载（与 §4.6.6 MacroSummaryOverviewDiagram 同策略），因为是可变的产品文案。

#### 4.6.8 界面总览页示意图组件（2026-07-27 新增）

「界面总览」页（`HomeOverviewWikiPage`）顶部主视觉，展示首页 5 个区域从上到下的布局结构。

**HomeLayoutDiagram**（`lib/features/help/presentation/widgets/home_layout_diagram.dart`）

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角 + sLg padding（整体框选所有区域） |
| 区域块 | `_LayoutBlock`：36×36 圆角图标（rMd） + body w600 标签 + caption muted 描述 |
| 区域分隔 | `_SectionDivider`：1px 细虚线（dashWidth 4 / dashSpace 3，faint 色），模拟布局分隔线（非连接线） |
| 区域数量 | 5 个区域：顶部标题 / API Key 提示（条件显示）/ 双卡入口 / 最近会话 / 设置入口 |
| 文案来源 | i18n key `help.homeOverview.diagram*Label/Desc`（10 个 key，无硬编码） |

**特殊区块组件**：

| 组件 | 用途 | 规范 |
|------|------|------|
| `_LayoutBlock` | 普通区块（标题/最近会话/设置入口） | 36×36 图标方框（primaryDim 或 surfaceElevated 背景，区分主次） + 标签 + 描述横向排列 |
| `_ConditionalBlock` | 条件显示区块（API Key 提示） | warning 色 1.5px 虚线边框（strokeAlignOutside） + warning 色 20px 图标 + 标签 + 描述，表达"可选/条件渲染" |
| `_EntryCardsBlock` | 双卡入口区块（模式切换） | 顶部 label + caption 描述，下方 Row(Expanded _MiniCard × 2) 横向并列 |
| `_MiniCard` | 模式入口小卡片 | surface 背景 + rSm 圆角 + sXs/sSm padding，16px 图标 + caption w500 文字（对话=primaryDim/primary，故事=accentDim/accent） |

**视觉传达**：首页 = 标题区 + API Key 提示（可选，warning 虚线边框表达条件显示）+ 双卡入口（对话 vs 故事，色彩区分）+ 最近会话 + 设置入口

> **设计原则**：用 `_ConditionalBlock` 的 warning 虚线边框直观传达"API Key 提示区域仅在未配置时显示"的条件渲染语义，比纯文字说明更清晰。`_EntryCardsBlock` 用双卡并列+色彩区分（primary vs accent）展示模式切换功能，与 §4.1 SidebarSessionItem 的模式色彩规范保持一致。所有文案通过 i18n 承载，因为是可变的产品文案。

#### 4.6.9 对话模式用法页示意图组件（2026-07-27 新增）

第二部分「对话模式用法」6 个子页的主视觉示意图组件，设计原则一致：i18n 驱动文案、节点 + 标签 + 描述结构、primaryDim/primary 区分主次、Container surface/surfaceVariant 框选。

**SessionOperationDiagram**（`lib/features/help/presentation/widgets/session_operation_diagram.dart`）

用于「创建与切换会话」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 上段 | 创建流程 3 节点横向（点击新建 → 输入消息 → 发送保存），节点 2 高亮 |
| 下段 | 侧边栏 6 操作矩阵（GridView 3 列：新建/重命名/收藏/复制/拖拽/删除） |
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 下段容器 | surface 背景 + rLg 圆角 + divider 边框 + sMd padding |
| 节点尺寸 | 36×36 圆形，普通态 primaryDim + primary 色 18px 图标，高亮态 primary + surface 色 18px 图标 |
| 节点连接 | chevron_right_rounded 图标，faint 色 20px |
| 操作矩阵 | _OpCell：22px 图标 + caption 11px label，删除操作用 error 色，其他用 primary 色 |
| 操作图标 | 新建=Icons.add_outlined / 重命名=Icons.edit_outlined / 收藏=Icons.star_border（accent 色）/ 复制=Icons.content_copy / 拖拽=Icons.drag_indicator / 删除=Icons.delete_outline（error 色）——全部对齐 `sidebar_session_item.dart` 实际代码 |
| 文案来源 | i18n key `help.sessionOp.diagram*Label/Desc`（6 个 diagram + 6 个 op key） |

**MessageFlowDiagram**（`lib/features/help/presentation/widgets/message_flow_diagram.dart`）

用于「发送消息与查看回复」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 上段 | 输入区域结构 4 区块（引用预览 opt / 附件预览 opt / 文本输入框 / 工具栏） |
| 下段 | 流式输出时序 3 节点横向（发送 → 占位气泡 → 首 token），节点 2 高亮 |
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 下段容器 | surface 背景 + rLg 圆角 + divider 边框 + sMd padding |
| 区块样式 | _InputBlock：18px primary 图标 + bodySm w600 label + caption muted desc，opt 用 accent 色 badge 标记 |
| 流式节点 | 32×32 圆形（高亮态 primary 实色，否则 primaryDim），caption 11px label |
| 文案来源 | i18n key `help.messageFlow.block*Label/Desc` + `stream*Label/Desc`（11 个 key） |

**MessageActionsDiagram**（`lib/features/help/presentation/widgets/message_actions_diagram.dart`）

用于「消息操作」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 上段 | 消息气泡结构（用户气泡 + 助手气泡 + 操作按钮行） |
| 下段 | 显示策略说明（图标 + 标题 + 描述） |
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 下段容器 | surface 背景 + rLg 圆角 + divider 边框 + sMd padding |
| 气泡样式 | _MiniBubble：28×28 圆形头像（user=primary/surface+person，assistant=surface+primary+smart_toy）+ rMd 圆角内容容器（user=primaryDim，assistant=surface） |
| 操作按钮 | _OpBadge：14px 图标 + caption 11px label 横向，6 项操作顺序：重新生成(refresh_rounded) / 继续生成(arrow_downward) / 引用(format_quote) / 复制(copy_outlined) / 编辑(edit_outlined) / 删除(delete_outline)，删除用 error 色，其他用 muted 色——全部对齐 `simple_message_bubble.dart` 实际代码 |
| 文案来源 | i18n key `help.messageActions.diagram*Title/Desc` + `op*` + `*BubbleLabel`（12 个 key） |

**FloatingNavDiagram**（`lib/features/help/presentation/widgets/floating_nav_diagram.dart`）

用于「消息导航」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 左侧 | 4 个浮动按钮纵向（跳顶/上一条用户/下一条用户/跳底） |
| 右侧 | 自动隐藏时序 3 节点（滚动中 → 停止滚动 → 2 秒后隐藏），节点 3 高亮 |
| 容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding（整体）+ 右侧 surface 子容器 |
| 按钮样式 | _NavButton：28×28 圆形（surface 背景 + primary 1.5px 边框 + primary 色 16px 图标）+ bodySm w600 label + caption desc |
| 按钮图标 | 跳顶=Icons.keyboard_double_arrow_up（双箭头表「跳到端点」）/ 上一条用户=Icons.keyboard_arrow_up（单箭头表「逐条翻动」）/ 下一条用户=Icons.keyboard_arrow_down / 跳底=Icons.keyboard_double_arrow_down——全部对齐 `simple_message_navigation.dart` 实际代码（v1.9 修正：原 wiki 4 个图标全部对应错） |
| 时序节点 | _TimelineRow：20×20 圆形（高亮 primary，否则 primaryDim）+ caption 10px label |
| 时序连接 | _TimelineConnector：2px 宽 12px 高 faint 色竖线 |
| 文案来源 | i18n key `help.messageNav.diagram*Title` + `btn*` + `timeline*`（13 个 key） |

**SessionSettingsDiagram**（`lib/features/help/presentation/widgets/session_settings_diagram.dart`）

用于「会话设置」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 上段 | 三级配置优先级链 3 节点横向（会话级 > 全局默认 > 内置兜底），节点 1 高亮 |
| 下段 | 设置 Sheet 4 个区段（模型与供应商 / 提示词 / 生成参数 / 上下文窗口） |
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 下段容器 | surface 背景 + rLg 圆角 + divider 边框 + sMd padding |
| 优先级节点 | _PriorityLevel：32×32 圆形（高亮 primary，否则 primaryDim）+ caption 10px label + 9px desc |
| 区段样式 | _SectionItem：28×28 primaryDim 圆角矩形 + primary 色 16px 图标 + bodySm w600 label + caption desc |
| 文案来源 | i18n key `help.sessionSettings.diagram*Title` + `level*Label/Desc` + `section*`（13 个 key） |

**CompactionFlowDiagram**（`lib/features/help/presentation/widgets/compaction_flow_diagram.dart`）

用于「上下文管理与压缩」页顶部主视觉。

| 属性 | 规范 |
|------|------|
| 上段 | 自动压缩触发条件（warning 图标 + 标题 + 阈值公式容器） |
| 下段 | 压缩流程 4 节点纵向（发送前预检 → 命中阈值 → 流式生成摘要 → 上下文替换），节点 2 高亮 |
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 下段容器 | surface 背景 + rLg 圆角 + divider 边框 + sMd padding |
| 阈值公式容器 | surface 背景 + rSm 圆角 + caption 11px muted 文本 |
| 流程节点 | _FlowStep：36×36 圆形（高亮 primary，否则 primaryDim）+ bodySm w600 label + caption desc |
| 节点连接 | _DashedLine：2px 宽 16px 高竖向虚线（dashHeight 3，dashSpace 2，faint 色，左缩进 17px 对齐节点中心） |
| 文案来源 | i18n key `help.compactionFlow.diagram*Title/Formula` + `flow*Label/Desc`（10 个 key） |

> **设计原则**：6 个组件统一采用「上段 + 下段」结构展示「主视觉 + 补充说明」，上段用 surfaceVariant 背景框选主视觉，下段用 surface + divider 边框展示辅助说明。所有文案通过 i18n 承载，与 §4.6.6/4.6.7/4.6.8 同策略——因为是可变的产品文案而非固定术语。节点高亮用 primary 实色背景强调重点步骤（如草稿会话、命中阈值、首 token），普通节点用 primaryDim 弱化背景表达流程上下文。

#### 4.6.10 故事模式用法页示意图组件（2026-07-27 新增）

第三部分「故事模式用法」5 个子页的主视觉示意图组件，设计原则与 §4.6.9 对话模式用法一致：i18n 驱动文案、上段 + 下段结构、primaryDim/primary 区分主次。其中 StoryVsChatDiagram 采用左右双栏对比布局，其余 4 个组件（FirstStoryFlowDiagram / StoryMessageActionsDiagram / StorySessionSettingsDiagram / MemoryBrowserDiagram）统一采用「上段 surfaceVariant 主视觉 + 下段 surface 辅助说明」结构。

**StoryVsChatDiagram**（`lib/features/help/presentation/widgets/story_vs_chat_diagram.dart`）

用于「故事模式与对话模式的区别」页顶部主视觉，左右双栏对比 4 维度（入口/配色/字体/输入文案）。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding |
| 双栏布局 | Row + Expanded，中间 1px divider 分隔（sSm horizontal margin） |
| 栏顶部 | 28×28 圆形 accentColor/dimColor 背景 + 图标 16px + bodySm w700 标题 |
| 4 行维度 | muted 14px 图标 + caption 11px 文字，s2xs vertical padding |
| 文案来源 | i18n key `help.storyVsChat.columnChat/Story` + `chat*/story*` 8 个 key（共 10 个） |
| 颜色对比 | 对话模式用 primary/primaryDim；故事模式用 accent/accentDim（呼应夜航暖色调） |

**FirstStoryFlowDiagram**（`lib/features/help/presentation/widgets/first_story_flow_diagram.dart`）

用于「创建第一个故事」页顶部主视觉，3 步流程 + 嵌入模型缺失 Banner。

| 属性 | 规范 |
|------|------|
| 上段容器 | surfaceVariant 背景 + rLg 圆角 + sMd padding，Row + 3 个 _FlowStep + chevron_right 分隔 |
| 流程节点 | _FlowStep：图标（高亮 primary，否则 primaryDim 背景 + primary 色图标）+ bodySm w600 label + caption 11px desc |
| 下段容器 | surface 背景 + rMd 圆角 + warning 色 1.5px 边框，Banner 提示嵌入模型缺失 |
| Banner 右侧 | warning 色实色胶囊 + caption 11px surface 色 action 文字 |
| 文案来源 | i18n key `help.firstStory.flow*Label/Desc` + `banner*` 6 个 key（共 9 个） |

**StoryMessageActionsDiagram**（`lib/features/help/presentation/widgets/story_message_actions_diagram.dart`）

用于「故事模式消息操作」页顶部主视觉，4 种操作横排 + Fork 窗口限制示意。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，4 种操作 _OpBadge 横排（spaceAround） |
| 操作图标 | copy_outlined/refresh_rounded/edit_outlined/delete_outline，22px，颜色：ink/muted/muted/error |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，primary 色 window 图标 + 窗口说明 + 4 个 _RoundChip |
| _RoundChip | active=primaryDim 背景 + primary 色 w600 文字；inactive=surfaceVariant 背景 + divider 边框 + faint 色 w400 文字 |
| 文案来源 | i18n key `help.storyMessageActions.diagram*Title/Desc` + `op*` 8 个 key（共 11 个） |
| 图标对齐 | 对齐 `intermediate_message_actions.dart` 实际代码（refresh_rounded 非 refresh_outlined） |

**StorySessionSettingsDiagram**（`lib/features/help/presentation/widgets/story_session_settings_diagram.dart`，2026-07-27 新增）

用于「故事会话设置」页顶部主视觉，4 步骤模型 + 6 个设置区段。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，4 步骤 _PhaseBadge 横排 + chevron_right 分隔 |
| 步骤徽章 | 32×32 圆形 primaryDim 背景 + primary 色图标 16px + caption 10px w600 label |
| 步骤图标 | edit_outlined（草稿）/ search_outlined（提取）/ auto_fix_high_outlined（润色）/ summarize_outlined（摘要） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，6 个 _SectionItem 纵向列表 |
| 区段项 | 28×28 rSm 圆角 primaryDim 背景 + primary 色 16px 图标 + bodySm w600 label + caption 11px desc |
| 区段图标 | layers_outlined/description_outlined/tune_outlined/view_module_outlined/build_circle_outlined/memory_outlined |
| 文案来源 | i18n key `help.storySessionSettings.diagram*Title/Desc` + `phase*` + `section*` 19 个 key |
| 对齐 | 区段顺序对齐 `intermediate_session_settings_sheet.dart` 实际代码（phaseModels→prompt→gen→context→toolCalling→memory） |

**MemoryBrowserDiagram**（`lib/features/help/presentation/widgets/memory_browser_diagram.dart`，2026-07-27 新增）

用于「记忆库浏览器」页顶部主视觉，双 Tab 结构 + 4 种操作。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，2 个 _TabCard 横排（sSm 间距） |
| Tab 卡片 | rMd 圆角，高亮=primaryDim 背景 + primary 边框 + primary 色图标/文字；非高亮=surface 背景 + divider 边框 + muted/ink 色图标/文字 |
| Tab 图标 | history_outlined（经历类）/ account_tree_outlined（事实类） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，4 种 _OpBadge 横排（spaceAround） |
| 操作图标 | search/add_circle_outline/edit_outlined/delete_outline，22px，颜色：primary/success/muted/error |
| 文案来源 | i18n key `help.memoryBrowser.diagram*Title` + `tab*` + `op*` 10 个 key |
| 对齐 | Tab 顺序对齐 `memory_browser_page.dart` 实际代码（经历类 Tab 0 + 事实类 Tab 1）；图标对齐 `experience_memory_tab.dart` / `factual_memory_tab.dart` |

> **设计原则**：5 个组件延续 §4.6.9 对话模式用法页的设计策略——i18n 驱动文案、上段 surfaceVariant 主视觉 + 下段 surface 辅助说明。但故事模式相关组件增加了 accent/accentDim 色彩呼应夜航主题（如 StoryVsChatDiagram 故事模式栏用 accent 而非 primary）。所有图标严格对齐实际代码实现，避免 wiki 文档与 UI 显示文案不一致。

#### 4.6.11 配置与个性化页示意图组件（2026-07-27 新增）

第五部分「配置与个性化」7 个子页的主视觉示意图组件，设计原则与 §4.6.9/10 一致：i18n 驱动文案、上段 surfaceVariant 主视觉 + 下段 surface 辅助说明、primaryDim/primary 区分主次。所有图标对齐实际设置页代码实现。

**ApiProviderDiagram**（`lib/features/help/presentation/widgets/api_provider_diagram.dart`）

用于「API 供应商管理」页顶部主视觉，7 个内置模板 + 自定义 2 步流程。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Wrap 排列 8 个 _TemplateChip（7 内置 + 1 自定义） |
| 模板胶囊 | rFull 圆角 + sSm/s2xs padding；高亮=primaryDim 背景 + primary 边框 + primary 色 w600；非高亮=surface 背景 + divider 边框 + muted 色 w400 |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 2 个 _FlowStep + chevron_right 分隔 |
| 流程节点 | _FlowStep：primaryDim/surfaceVariant 背景 + bodySm w600 label + caption 11px desc |
| 文案来源 | i18n key `help.apiProvider.builtin*` 8 个 + `customStep*` 4 个（共 12 个） |
| 对齐 | 模板列表对齐 `provider_templates.dart` 实际代码（7 内置 + 1 自定义） |

**ModelStrategyDiagram**（`lib/features/help/presentation/widgets/model_strategy_diagram.dart`）

用于「模型选择策略」页顶部主视觉，3 层优先级 + 故事模式 4 步骤。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 3 个 _LayerItem + chevron_right 分隔 |
| 层级项 | _LayerItem：primaryDim/surface 背景 + primary/divider 边框 + 18px 图标 + caption w600 label + caption 10px desc |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 4 个 _PhaseBadge + chevron_right 分隔 |
| 步骤徽章 | _PhaseBadge：28×28 rFull primaryDim 背景 + 14px primary 色图标 + caption 10px w600 label |
| 文案来源 | i18n key `help.modelStrategy.layer*` 6 个 + `story*` 8 个（共 14 个） |
| 对齐 | 4 步骤图标对齐 §4.6.10 StorySessionSettingsDiagram（edit/search/auto_fix_high/summarize） |

**PromptTemplateDiagram**（`lib/features/help/presentation/widgets/prompt_template_diagram.dart`）

用于「提示词模板系统」页顶部主视觉，3 种类型 + 4 种操作。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 3 个 _TypeCard（sXs 间距） |
| 类型卡片 | _TypeCard：primaryDim/surface 背景 + primary/divider 边框 + 20px 图标 + caption w600 label + caption 10px desc |
| 类型图标 | description_outlined（系统提示词）/ compress_outlined（压缩模板）/ build_circle_outlined（工具定义） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 4 个 _OpBadge（spaceAround） |
| 操作图标 | add_circle_outline（success）/ edit_outlined（primary）/ copy_outlined（muted）/ delete_outline（error），22px |
| 文案来源 | i18n key `help.promptTemplate.type*` 6 个 + `op*` 4 个（共 10 个） |

**StoryPromptCustomDiagram**（`lib/features/help/presentation/widgets/story_prompt_custom_diagram.dart`）

用于「故事模式提示词自定义」页顶部主视觉，10 段列表 + 编辑器 3 区块。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Wrap 排列 10 个 _SegmentChip |
| 段落胶囊 | rFull 圆角 + sSm/s2xs padding + surface 背景 + divider 边框 + ink 色 w500 文字 |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，纵向 3 个 _EditorBlock |
| 编辑器块 | _EditorBlock：Row + 16px primary 色图标 + bodySm w600 label + caption 11px desc（Expanded） |
| 编辑器图标 | edit_outlined（编辑区）/ lightbulb_outline（使用场景）/ history_outlined（默认值预览） |
| 文案来源 | i18n key `help.storyPromptCustom.seg*` 10 个 + `editor*` 6 个（共 16 个） |
| 对齐 | 10 段顺序对齐 `intermediate_prompt_metadata.dart` 实际代码 |

**AppearanceDiagram**（`lib/features/help/presentation/widgets/appearance_diagram.dart`）

用于「外观与主题」页顶部主视觉，3 主题模式 + 字体 10 档。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 3 个 _ThemeCard（sXs 间距） |
| 主题卡片 | _ThemeCard：primaryDim/surface 背景 + primary/divider 边框 + 20px 图标 + caption w600 label + caption 10px desc |
| 主题图标 | dark_mode_outlined（深色）/ light_mode_outlined（浅色）/ brightness_auto_outlined（跟随系统） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 2 个 _FontEnd + 中间 10 档刻度条 |
| 字体刻度 | 10 个小竖条，第 4 个（index=3，对应 15 px 默认值）用 primary 色，其余 faint 色 |
| 默认值徽章 | primaryDim 背景 + rFull 圆角 + primary 色 w600 文字「15 px · 默认值」 |
| 文案来源 | i18n key `help.appearance.theme*` 6 个 + `font*` 6 个（共 12 个） |

**LanguageInputDiagram**（`lib/features/help/presentation/widgets/language_input_diagram.dart`）

用于「语言与输入」页顶部主视觉，3 语言选项 + 发送快捷键。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 3 个 _LangCard（sXs 间距） |
| 语言卡片 | _LangCard：primaryDim/surfaceVariant/surface 背景 + primary/divider 边框 + 20px 图标 + caption w600 label + caption 10px desc |
| 语言图标 | check_circle（中文可用，primary）/ schedule_outlined（英文预告，faint）/ schedule_outlined（跟随系统预告，faint） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，2x2 网格 4 个 _SendKeyCard（sXs 间距）+ 底部换行键提示行 |
| 快捷键卡片 | _SendKeyCard：primaryDim/surfaceVariant 背景 + primary/divider 边框 + Row + 18px 图标 + Expanded(Column(label+desc)) |
| 快捷键图标 | keyboard_return（Enter）/ arrow_upward（Shift+Enter）/ keyboard_command_key（Ctrl+Enter）/ send（按钮发送） |
| 文案来源 | i18n key `help.languageInput.lang*` 6 个 + `sendKey*` 8 个 + `newlineKey*` 4 个（共 18 个） |
| 对齐 | 语言选项 disabled 状态对齐 `language_selector_section.dart` 实际代码（英文/跟随系统预告状态） |

**AdvancedSettingsDiagram**（`lib/features/help/presentation/widgets/advanced_settings_diagram.dart`）

用于「高级设置」页顶部主视觉，3 区块 + 5 档思考预算。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 3 个 _BlockCard（sXs 间距） |
| 区块卡片 | _BlockCard：primaryDim/surface 背景 + primary/divider 边框 + 20px 图标 + caption w600 label + caption 10px desc |
| 区块图标 | psychology_outlined（思考预算）/ timer_outlined（超时）/ title_outlined（标题模型） |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 5 个 _ReasoningBadge（spaceAround） |
| 预算徽章 | _ReasoningBadge：primary/surfaceVariant 背景 + rFull 圆角 + primary/divider 边框 + caption 10px w600 label + caption 9px desc |
| 文案来源 | i18n key `help.advancedSettings.block*` 6 个 + `reasoning*` 10 个（共 16 个） |
| 对齐 | 5 档顺序对齐 `default_reasoning_effort_section.dart` 实际代码（未配置/禁用/低/中/高） |

> **设计原则**：7 个组件延续 §4.6.9/10 的设计策略——i18n 驱动文案、上段 surfaceVariant 主视觉 + 下段 surface 辅助说明。配置页组件更强调"分类清晰"——上段展示主分类（模板/类型/层级/区块），下段展示子项或操作。所有图标严格对齐实际设置页代码实现（如 dark_mode_outlined 对齐 ThemeSelectorSection 实际图标），避免 wiki 与 UI 不一致。

#### 4.6.12 数据与维护页示意图组件（2026-07-27 新增）

第六部分「数据与维护」4 个子页的主视觉示意图组件。设计原则与 §4.6.9/10/11 一致：i18n 驱动文案、所有图标对齐实际设置页代码实现。本组组件更强调"安全/危险语义对比"——使用 error 色调标注清空操作，success 色调标注保留项或追加模式，warning 色调标注风险提示，primary 色调标注常规操作。

**DataExportDiagram**（`lib/features/help/presentation/widgets/data_export_diagram.dart`）

用于「数据导出与导入」页顶部主视觉，3 类备份内容 + API Key 开关 + 2 种导入模式。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，纵向 3 个 _ExportItem + 末尾 API Key 开关徽章 |
| 内容项 | _ExportItem：Row + 28×28 rSm primary/surface 容器 + 16px 图标 + bodySm w600 label + caption 11px desc + 18px 勾选框（highlight 用 check_box，否则 check_box_outline_blank） |
| 内容图标 | forum_outlined（会话，highlight）/ cloud_outlined（供应商）/ tune_outlined（偏好） |
| API Key 徽章 | warning 12% alpha 背景 + rSm 圆角 + 14px key_rounded 图标 + caption 11px w600 文字 |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，Row + 2 个 _ImportModeCard（sSm 间距） |
| 模式卡片 | _ImportModeCard：色彩 8% alpha 背景 + 30% alpha 边框 + rMd 圆角 + 18px 图标 + bodySm w700 label + caption 11px desc |
| 模式色彩 | append 用 success 色 + add_circle_outline 图标；overwrite 用 error 色 + delete_forever_outlined 图标 |
| 文案来源 | i18n key `help.dataExport.exportItem*` 6 个 + `importMode*` 4 个 + `exportApiKey*` 2 个（共 12 个） |
| 对齐 | 3 类内容对齐 `ExportOptionsSheet` 实际勾选项；2 种模式对齐 `ImportModeSheet` 实际按钮文案 |

**DataRecoveryDiagram**（`lib/features/help/presentation/widgets/data_recovery_diagram.dart`）

用于「数据恢复与表修复」页顶部主视觉，孤立消息恢复 2 步流程 + 表结构修复 3 个动作。

| 属性 | 规范 |
|------|------|
| 上段 | surfaceVariant 背景 + rLg 圆角，Row + 2 个 _RecoveryStep + chevron_right 分隔 + 底部 success 色结果提示 |
| 恢复步骤 | _RecoveryStep：primaryDim/surface 背景 + rMd 圆角 + bodySm w700 label + caption 11px desc |
| 下段 | surface 背景 + rLg 圆角 + divider 边框，顶部 primaryDim 策略徽章 + 纵向 3 个 _RepairAction |
| 策略徽章 | primaryDim 背景 + rSm 圆角 + 14px shield_outlined 图标 + caption 11px w600 文字 |
| 修复动作 | _RepairAction：Row + 24×24 rFull primaryDim 圆 + caption w700 序号 + bodySm w600 label + caption 11px desc |
| 文案来源 | i18n key `help.dataRecovery.recovery*` 6 个 + `repair*` 8 个（共 14 个） |
| 对齐 | "纯增量策略" 对齐 `app_database.dart` 的 `repairSchema` 实际实现（CREATE IF NOT EXISTS + ALTER ADD COLUMN） |

**ClearDataDiagram**（`lib/features/help/presentation/widgets/clear_data_diagram.dart`）

用于「清除所有数据」页顶部主视觉，会清空的 4 类表 vs 会保留的 2 类配置。

| 属性 | 规范 |
|------|------|
| 上段 | error 6% alpha 背景 + rLg 圆角 + error 25% alpha 边框，顶部 error 色标题行 + 纵向 4 个 _ClearItem |
| 清空项 | _ClearItem：Row + 14px close_rounded error 图标 + bodySm w600 label + caption 11px desc |
| 清空项分类 | 会话和消息（chat_sessions/messages/分支）/ 故事模式记忆（经历/事实/中间产物）/ 压缩点（compaction_points）/ 失败历史（failure_logs） |
| 下段 | success 8% alpha 背景 + rLg 圆角 + success 30% alpha 边框，顶部 success 色标题行 + 纵向 2 个 _KeepItem |
| 保留项 | _KeepItem：Row + 14px check_rounded success 图标 + 28×28 rSm success 12% alpha 容器 + 16px 图标 + bodySm w600 label + caption 11px desc |
| 保留项图标 | cloud_outlined（API 供应商，对齐 api_presets 表）/ description_outlined（提示词模板，对齐 templates 表） |
| 文案来源 | i18n key `help.clearData.clear*` 8 个 + `keep*` 4 个（共 12 个） |
| 对齐 | 4 类清空内容对齐 `app_database.dart` 的 `recreateConversationTables` DROP 列表（10 张表归为 4 类展示）；2 类保留项对齐未在 DROP 列表中的 api_presets/templates 表 |

**DiagnosticsDiagram**（`lib/features/help/presentation/widgets/diagnostics_diagram.dart`）

用于「诊断信息」页顶部主视觉，5 个区块纵向排列（状态概览 / 日志级别 / 调试开关 / 运行日志 / 失败历史）。

| 属性 | 规范 |
|------|------|
| 容器 | 单一 surfaceVariant 背景 + rLg 圆角，5 个区块用 Divider 分隔 |
| 区块标题 | _BlockHeader：Row + 22×22 rFull primary 圆 + caption 11px w700 surface 色序号 + bodySm w700 ink 色 title |
| 区块 1 状态概览 | 2 个 _BlockRow：失败记录数（error 色）+ 当前日志级别（primary 色） |
| 区块 2 日志级别 | Wrap 排列 4 个 _LevelChip：debug（faint）/ info（success）/ warn（warning）/ error（error） |
| 级别胶囊 | _LevelChip：色彩 12% alpha 背景 + 40% alpha 边框 + rFull 圆角 + caption 11px w600 文字 |
| 区块 3 调试开关 | 5 个 _SwitchRow：toggle_off_outlined 16px faint 图标 + caption 11px muted 文字 |
| 区块 4 运行日志 | 3 个 _BlockRow：FileLogSink 文件 / 末尾 500 行 / 按级别着色（均 primary 色） |
| 区块 5 失败历史 | 2 个 _BlockRow：failure_logs 表 / 点击展开详情（均 error 色） |
| 区块行 | _BlockRow：Row + 6×6 rFull 色彩圆点 + RichText（label w600 ink + desc muted，caption 11px 1.5 行高） |
| 文案来源 | i18n key `help.diagnostics.overview*` 4 个 + `level*` 8 个 + `debug*` 10 个 + `log*` 6 个 + `failure*` 4 个（共 32 个） |
| 对齐 | 5 个区块顺序对齐 `diagnostics_page.dart` 实际代码（_OverviewCard / _LogLevelCard / _DebugLogOptionsCard / LogViewer / FailureHistory）；4 个日志级别对齐 `LogLevel` 枚举；5 个调试开关对齐 `DebugLogField` 枚举 |

> **设计原则**：4 个组件延续 §4.6.9/10/11 的设计策略——i18n 驱动文案、上段 surfaceVariant 主视觉 + 下段 surface 辅助说明。本组组件更强调"安全/危险语义对比"——DataExportDiagram 用 success/error 色区分追加 vs 覆盖模式；ClearDataDiagram 用 error/success 色对比清空 vs 保留；DataRecoveryDiagram 用 primary 色突出"纯增量策略"的安全特性；DiagnosticsDiagram 用多色（primary/error/warning/faint/success）区分 5 个区块的语义角色。所有图标和分类严格对齐实际代码实现（如 4 类清空内容对齐 `recreateConversationTables` 的 DROP 列表），避免 wiki 与 UI 不一致。

#### 4.6.13 附录页示意图组件（2026-07-27 新增）

第七部分「附录」4 个子页的主视觉示意图组件。设计原则与 §4.6.9/10/11/12 一致：i18n 驱动文案、所有图标对齐实际代码实现。本组组件更强调"分类与状态语义"——使用多色区分不同分类的语义角色（错误码体系、术语分组、功能模块、版本状态）。

**FaqDiagram**（`lib/features/help/presentation/widgets/faq_diagram.dart`）

用于「故障排除 FAQ」页顶部主视觉，3 类错误码体系卡片纵向排列，按模式区分色彩。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角，纵向 3 个 _ErrorCodeCard（sSm 间距） |
| 错误码卡片 | _ErrorCodeCard：surface 背景 + rMd 圆角 + 色彩 30% alpha 边框，Row + 4×48 rXs 色彩侧边条 + Expanded 内容列 |
| 内容列 | bodySm w700 色彩色 title + RichText caption 11px（行 1：count · countDesc w600 muted；行 2：strategy · strategyDesc 普通 muted） |
| 色彩区分 | Simple 对话模式用 primary（indigo）；Intermediate 故事模式用 accent（warm amber，呼应夜航）；通用错误用 muted（中性灰） |
| 文案来源 | i18n key `help.faq.diagram*Title` 3 个 + `simpleCount/intermediateCount/commonCount` 3 个 + `*CountDesc` 3 个 + `simpleStrategy/intermediateStrategy/commonStrategy` 3 个 + `*StrategyDesc` 3 个（共 18 个） |
| 对齐 | 3 类错误码体系对齐项目错误码规范：S001-S009（Simple）/ E010-E018（Intermediate 模式专属）/ E001-E302（通用网络/配置错误） |

**GlossaryDiagram**（`lib/features/help/presentation/widgets/glossary_diagram.dart`）

用于「术语表」页顶部主视觉，3 组术语分类卡片纵向排列。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角，纵向 3 个 _GroupCard（sSm 间距） |
| 分组卡片 | _GroupCard：surface 背景 + rMd 圆角 + divider 边框，Row + 36×36 rSm 色彩 12% alpha 容器 + 20px 图标 + Expanded 内容列 |
| 内容列 | bodySm w700 ink 色 title + caption 11px w600 色彩色（count · countDesc）+ surfaceVariant rXs 徽章（10px muted examples） |
| 色彩区分 | API/LLM 术语用 primary + cloud_outlined；记忆/检索术语用 accent + psychology_outlined；项目特定术语用 success + apps_outlined |
| 文案来源 | i18n key `help.glossary.diagram*Title` 3 个 + `apiCount/memoryCount/projectCount` 3 个 + `*CountDesc` 3 个 + `apiExamples/memoryExamples/projectExamples` 3 个（共 12 个） |
| 对齐 | 3 组术语分类对齐术语表实际组织方式：API/LLM 基础术语（API Key、Token、SSE 等）/ 记忆检索术语（Embedding、Vector、FTS5 等）/ 项目特定术语（CompactionPoint、FactualMemory、narrativeTime 等） |

**FeatureIndexDiagram**（`lib/features/help/presentation/widgets/feature_index_diagram.dart`）

用于「功能索引表」页顶部主视觉，5 大模块卡片纵向排列，按版本归属着色。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角，纵向 5 个 _ModuleCard（sXs 间距） |
| 模块卡片 | _ModuleCard：surface 背景 + rSm 圆角 + divider 边框，Row + 6×28 rXs 色彩侧边条 + Expanded title + 色彩 12% alpha rFull 胶囊（10px w700 色彩色 count）+ Flexible caption 10px muted countDesc |
| 色彩区分 | Simple 对话模式用 primary；Intermediate 故事模式用 accent；Settings 配置用 success；Data 数据维护用 warning；Help 帮助系统用 muted |
| 文案来源 | i18n key `help.featureIndex.diagram*Title` 5 个 + `simpleCount/intermediateCount/settingsCount/dataCount/helpCount` 5 个 + `*CountDesc` 5 个（共 15 个） |
| 对齐 | 5 大模块对齐项目实际 feature 划分：`features/chat`（Simple）/ `features/chat` Intermediate 控制器（Intermediate）/ `features/settings`（Settings）/ `features/chat` 数据维护动作（Data）/ `features/help`（Help） |

**VersionHistoryDiagram**（`lib/features/help/presentation/widgets/version_history_diagram.dart`）

用于「版本更新记录」页顶部主视觉，3 个版本阶段卡片纵向排列，按状态着色。

| 属性 | 规范 |
|------|------|
| 容器 | surfaceVariant 背景 + rLg 圆角，纵向 3 个 _VersionCard（sSm 间距） |
| 版本卡片 | _VersionCard：surface 背景 + rMd 圆角 + divider 边框，Row + 40×40 圆形色彩 12% alpha 容器 + 中心 14×14 圆形实色点 + Expanded 内容列 |
| 内容列 | bodySm w700 ink 色 title + RichText caption 11px（行 1：status · statusDesc w600 色彩色；行 2：schema · schemaDesc muted） |
| 状态色彩 | v0.1 已交付用 success（绿色，已完成）；v0.2 进行中用 warning（黄色，开发中）；v0.3 待启动用 muted（灰色，未开始） |
| 文案来源 | i18n key `help.versionHistory.diagram*Title` 3 个 + `v01Status/v02Status/v03Status` 3 个 + `*StatusDesc` 3 个 + `v01Schema/v02Schema/v03Schema` 3 个 + `*SchemaDesc` 3 个（共 15 个） |
| 对齐 | 3 个版本阶段对齐项目版本策略：v0.1（Simple 模式 + 基础设施，schemaVersion=15 终态）/ v0.2（Intermediate 中级模式 + DOC-11 事实层中间方案，schemaVersion=16-22 dev 阶段）/ v0.3（Advanced 高级模式 + 完整事实层 + HUD + update_world，待启动） |

> **设计原则**：4 个组件延续 §4.6.9/10/11/12 的设计策略——i18n 驱动文案、上段 surfaceVariant 主视觉。本组组件更强调"分类与状态语义"——FaqDiagram 用 primary/accent/muted 三色对应错误码体系的三种归属（Simple/Intermediate/通用）；GlossaryDiagram 用 primary/accent/success 三色对应术语的三种语义角色（API/记忆/项目）；FeatureIndexDiagram 用五色（primary/accent/success/warning/muted）对应 5 大模块的版本归属；VersionHistoryDiagram 用 success/warning/muted 三色对应 3 个版本阶段的交付状态（已交付/进行中/待启动）。所有错误码范围、术语分组、模块划分、版本状态严格对齐项目实际情况，避免 wiki 与产品不一致。

---

## 5. Simple 交互规范

### 5.1 流式输出

| 属性 | 规范 |
|------|------|
| 首 token 延迟 | < 1s |
| 输出指示器 | primary 色，打字动画 |
| 停止按钮 | error 色，与发送按钮互斥 |

### 5.2 分支交互（ForkNav）

| 属性 | 规范 |
|------|------|
| 创建分支 | 任意助手消息处 Regenerate 触发（`regenerateInNewFork`） |
| 分支导航 | "◀ 1/3 ▶"，SimpleForkNav 组件（内联文本+图标行） |
| 切换方式 | 循环切换（左右箭头，`switchFork`） |
| 持久化 | `chat_session_branches` 表（parent_user_msg_id + active_branch_index + branch_count + branch_snapshots） |
| 内存视图 | `ForkAnchor`（activeIndex + branchCount + hasForks，由 `getForkAnchors` 从表查询组装） |
| 存储模型 | 快照模型——`chat_messages` 表仅存当前活跃分支消息，非活跃分支存为 JSON 快照于 `branch_snapshots` 列 |

> **v0.1 实现演进**：Fork 机制从早期"纯内存 ForkAnchor（基于 parentUserMsgId 分组 siblingIds）"演进为"`chat_session_branches` 表持久化 + `ForkAnchor` 内存视图"，最终重构为**快照模型**（对标 ChatBox `messageForksHash`）。当前实现：
> - `chat_messages` 表仅存储当前活跃分支消息，无需按 `branch_index` 过滤
> - 非活跃分支消息以 JSON 快照存储在 `chat_session_branches.branch_snapshots` 列
> - 切换分支 = 在 DB 行与 JSON 快照间交换消息
> - `ForkAnchor` 字段精简为 `parentUserMsgId` + `activeIndex` + `branchCount`（移除 `siblingIds`）

### 5.3 编辑消息交互（editAndResend）

| 属性 | 规范 |
|------|------|
| 触发 | 用户消息上选择"编辑" |
| 行为 | 更新消息内容 → 删除该消息之后的所有消息 → 重新发送 |
| 参考 | ChatBox 的编辑逻辑 |

**MessageEditDialog 组件规范**（对标实际实现 `lib/features/chat/presentation/widgets/message_edit_dialog.dart`）：

| 属性 | 规范 |
|------|------|
| 容器 | Dialog（Material 3），rLg 圆角，surface 背景 |
| 标题 | "编辑消息"（titleLarge） |
| 输入框 | 多行 TextField，初始内容为原消息，自动聚焦，光标置末 |
| 按钮区（3 按钮） | 取消（text）/ 保存（text）/ 保存并发送（filled，primary） |
| 脏检查 | `_isDirty = _controller.text != _originalText` |
| `_canSave` | `_isDirty && _controller.text.trim().isNotEmpty` |
| PopScope 拦截 | 有未保存改动时拦截返回，弹出确认对话框（"放弃未保存的改动？"） |
| 返回值 | `MessageEditResult(messageId, content, saveAndResend: bool)`，取消时返回 null |
| 保存按钮启用条件 | `_canSave` 为 true 时启用，否则禁用 |
| 保存并发送启用条件 | `_canSave` 为 true 时启用 |
| 键盘 | 输入框获焦时弹出键盘，Dialog 内部可滚动 |

> **v0.1 新增**：旧文档无 editAndResend 功能描述。实际实现通过 `MessageEditDialog` 组件支持编辑用户消息，提供"保存"（仅保存不发送）和"保存并发送"（保存后触发重新发送）两种模式，并通过 `PopScope` 防止用户误丢弃未保存改动。

---

## 6. Simple 动效规范

### 6.1 过渡动画

| 场景 | 时长 | 曲线 |
|------|------|------|
| 页面切换 | 250ms | EaseInOut |
| BottomSheet 弹出 | 200ms | EaseOut |
| BottomSheet 收起 | 150ms | EaseIn |
| 消息气泡入场 | 150ms | EaseOut |
| 分支切换 | 200ms | FadeIn |

### 6.2 微交互

| 场景 | 效果 |
|------|------|
| 按钮按下 | 缩放 95% + 透明度 80% |
| 列表项按下 | 透明度 90% |
| 开关切换 | 滑块移动 150ms |
| 滑块拖动 | 实时反馈 |
| 侧边栏会话项生成中（BreathingDot） | opacity 0.4 ↔ 1.0 呼吸，1500ms 周期，EaseInOut，无限循环；reduced-motion（`MediaQuery.accessibleNavigationOf`）时静态 0.7 opacity 兜底 |

---

## 7. Simple 业务组件

| 组件 | 文件路径 | 说明 | 版本 |
|------|---------|------|------|
| ChatModeController | `lib/features/chat/presentation/controllers/chat_mode_controller.dart` | Simple 模式聊天控制器 | v0.1 |
| ChatModePage | `lib/features/chat/presentation/pages/chat/chat_mode_page.dart` | Simple 模式聊天页面 | v0.1 |
| SessionsPage | `lib/features/chat/presentation/pages/sessions_page.dart` | 会话列表页（已删除） | v0.1 |
| HomePage | `lib/features/chat/presentation/pages/home_page.dart` | 主界面（app 入口页面） | v0.1 |
| ModelSelectorSheet | ~~`lib/features/chat/presentation/widgets/model_selector_sheet.dart`~~ | 已废弃（2026-07-24 v1.4 删除）：双 dropdown 设计被 `DefaultModelPickerSheet` 单菜单替代 | v0.1→v1.4 |
| DefaultModelPickerSheet | `lib/features/settings/presentation/widgets/default_model_picker_sheet.dart` | 统一模型选择 BottomSheet（按供应商分组 + 可折叠 + 单菜单） | v1.4 |
| SessionSettingsSheet | `lib/features/chat/presentation/widgets/session_settings_sheet.dart` | 会话设置 BottomSheet | v0.1 |
| SimpleMarkdownBody | — | Markdown 渲染组件 | v0.1 |
| SimpleForkNav | `lib/core/theme/system/structures/classic/conversation/simple_fork_nav.dart` | 分支导航组件（"◀ 1/3 ▶" 内联） | v0.1 |
| SimpleMessageNavigation | `lib/core/theme/system/structures/classic/conversation/simple_message_navigation.dart` | 长对话快速定位浮标（4 按钮 + 分割线） | v0.1 |
| MessageEditDialog | `lib/features/chat/presentation/widgets/message_edit_dialog.dart` | 消息编辑对话框（含 PopScope 脏检查） | v0.1 |
| ForkAnchor | `lib/features/chat/domain/entities/fork_anchor.dart` | 分支锚点数据结构（chat_session_branches 表内存视图） | v0.1 |
| CompactionService | `lib/features/chat/domain/services/compaction_service.dart` | 上下文压缩服务（阈值检查 + 非流式摘要 + 压缩点落库 + 流式编排） | v0.1 |
| CompactionStreamer | `lib/features/chat/domain/services/compaction_streamer.dart` | 流式压缩器（SSE 流式 LLM 摘要请求） | v0.1 |
| CompactionFailedCard | `lib/core/theme/system/structures/classic/conversation/compaction_failed_card.dart` | 压缩失败常驻卡片（error tint + 全边框，重试/关闭） | v0.1 |
| BreathingDot | `lib/core/theme/shared/components/breathing_dot.dart` | 侧边栏会话项"生成中"呼吸点指示器（共享组件，Simple 主题色） | v0.2 |

> **v0.1 实际实现差异**：
> - 旧文档列出 `MessageBubble`/`StreamingIndicator`/`BranchIndicator`/`TokenCountChip`/`SimpleSessionCard`/`AdvancedSessionCard` 等组件，部分尚未创建独立文件
> - 新增 `SimpleMarkdownBody`/`SimpleForkNav`/`ForkAnchor`/`CompactionService` 等组件
> - 新增 `HomePage`（主界面入口），旧文档无此组件
> - 新增供应商配置组件群：`ProviderListPage`/`ProviderDetailPage`/`DefaultModelPage`/`ModelPickerDialog`/`ModelEditDialog`/`ModelCapabilityBadges`（对标 ChatBox 模型服务商设计，详见 DOC-06 设计基础第 3 节）

---

## 8. Simple 设计令牌代码实现

### 8.1 色彩令牌

```dart
// lib/core/theme/simple/simple_colors.dart
class SimpleColors {
  SimpleColors._();

  // ── Light Theme ("Daylight") ──
  static const lightBg = Color(0xFFF4F5F7);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceElevated = Color(0xFFEEF0F3);
  static const lightSurfaceVariant = Color(0xFFE7E9ED);
  static const lightInk = Color(0xFF22222E);
  static const lightMuted = Color(0xFF6E6E80);
  static const lightFaint = Color(0xFF767680);
  static const lightPrimary = Color(0xFF4338CA);
  static const lightPrimaryDim = Color(0x1F4338CA);
  static const lightAccent = Color(0xFF9E7520);
  static const lightAccentDim = Color(0x1F9E7520);
  static const lightDivider = Color(0xFFDDE0E5);
  static const lightSuccess = Color(0xFF1A8A52);
  static const lightWarning = Color(0xFFA07A20);
  static const lightError = Color(0xFFB02E2E);
  static const lightScrim = Color(0x66161616);

  // ── Dark Theme ("Twilight") ──
  static const darkBg = Color(0xFF1A1A22);
  static const darkSurface = Color(0xFF242430);
  static const darkSurfaceElevated = Color(0xFF30303C);
  static const darkSurfaceVariant = Color(0xFF292934);
  static const darkInk = Color(0xFFECECF0);
  static const darkMuted = Color(0xFF9595A2);
  static const darkFaint = Color(0xFF8A8A95);
  static const darkPrimary = Color(0xFF5C5CE8);
  static const darkPrimaryDim = Color(0x265C5CE8);
  static const darkAccent = Color(0xFFC9983A);
  static const darkAccentDim = Color(0x26C9983A);
  static const darkDivider = Color(0xFF383842);
  static const darkSuccess = Color(0xFF2EA86A);
  static const darkWarning = Color(0xFFC49A30);
  static const darkError = Color(0xFFC43838);
  static const darkScrim = Color(0xB3161616);

  // ── Semantic aliases ──
  static SimpleColorSet of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  static const SimpleColorSet light = SimpleColorSet(...);
  static const SimpleColorSet dark = SimpleColorSet(...);
}

class SimpleColorSet {
  const SimpleColorSet({
    required this.bg, required this.surface, required this.surfaceElevated,
    required this.surfaceVariant, required this.ink, required this.muted,
    required this.faint, required this.primary, required this.primaryDim,
    required this.accent, required this.accentDim, required this.divider,
    required this.success, required this.warning, required this.error,
    required this.scrim,
  });
  // ... 16 个 final Color 字段
}
```

### 8.2 字体令牌

```dart
// lib/core/theme/simple/simple_text_styles.dart
class SimpleTextStyles {
  SimpleTextStyles._();
  static const String fontFamily = 'Inter';

  static const TextStyle display = TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1.3, letterSpacing: -0.02);
  static const TextStyle title1 = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.35, letterSpacing: -0.015);
  static const TextStyle title2 = TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4, letterSpacing: -0.01);
  static const TextStyle title3 = TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.45);
  static const TextStyle body = TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 1.6);
  static const TextStyle bodySm = TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.55);
  static const TextStyle caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.5, letterSpacing: 0.02);
  static const TextStyle overline = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.4, letterSpacing: 0.06);
}
```

### 8.3 主题数据

```dart
// lib/core/theme/simple/simple_theme.dart
class SimpleTheme {
  SimpleTheme._();

  static final ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    fontFamily: SimpleTextStyles.fontFamily,
    colorScheme: const ColorScheme.light(
      primary: SimpleColors.lightPrimary,
      secondary: SimpleColors.lightAccent,
      error: SimpleColors.lightError,
    ),
    scaffoldBackgroundColor: SimpleColors.lightBg,
    // ... 完整组件主题配置
  );

  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    fontFamily: SimpleTextStyles.fontFamily,
    colorScheme: const ColorScheme.dark(
      primary: SimpleColors.darkPrimary,
      secondary: SimpleColors.darkAccent,
      error: SimpleColors.darkError,
    ),
    scaffoldBackgroundColor: SimpleColors.darkBg,
    // ... 完整组件主题配置
  );
}
```

---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从 DOC-06 拆分创建。迁移 Simple 模式专属内容：色彩系统、字体层级、页面布局、页面设计、交互规范、动效规范、业务组件、设计令牌代码。共享基础（圆角/间距/图标/通用 AppBar/设置页面/响应式/基础组件/主题架构/验收标准）保留在 DOC-06 设计基础 |
| v1.1 | 2026-07-03 | §4.1 SidebarSessionItem 新增"生成中指示器"规范（BreathingDot 呼吸点，覆盖 star/chat 图标）；§6.2 微交互新增 BreathingDot 动效条目（1500ms opacity 呼吸 + reduced-motion 兜底）；§7 业务组件表新增 BreathingDot（共享组件，Simple 主题色） |
| v1.2 | 2026-07-08 | §4.1 SidebarSessionItem 改为两行布局（Row 1 模式标签+模式色区分，Row 2 会话标题）；模式色彩：对话=primary(indigo)，故事=accent(warm amber)；Star 指示器移至右侧不再覆盖模式图标 |
| v1.3 | 2026-07-20 | 新增 §4.5 新手引导页（OnboardingPage）：6 步详细版流程（欢迎/双模式/API Key/模板/记忆/开始使用）；双入口模式（首次启动全屏覆盖 + 设置页重看）；OnboardingNotifier 状态管理（SharedPreferences key `onboarding_completed`）；视觉规范（_HeroIcon/_ModeCard/_PrimaryButton/_MemoryFlowDiagram 组件清单）；翻译键体系（onboarding 章节） |
| v1.4 | 2026-07-26 | 新增 §4.6 帮助页（HelpSettingsPage）：合并原设置主页底部「新手引导」入口卡片为统一「帮助」入口；分两个区块（新手引导 + 故事模式原理 wiki）；3 个 wiki 子页（四步流程/记忆机制/失败处理）；3 个复用组件（WikiPageScaffold/WikiSection/WikiStepCard）；§4.5 设置页入口描述更新为已迁移到帮助页；翻译键体系（help 章节） |
| v1.5 | 2026-07-26 | §4.6.4/4.6.5 四步流程页 v2 图形化重构：基于用户反馈「文字太多不直观」，将纯文字版重构为图形示意图+短句要点；新增 4 个图形组件（FlowOverviewDiagram 主流程图/RoleFlowDiagram 角色流程图/FlowStepCard 增强步骤卡/VisualFlowTimeline 视觉时间轴）；i18n 文案精简为 input/output/keyPoints 短句结构；遵循 impeccable 设计指南（拒绝大段文字堆砌） |
| v1.6 | 2026-07-27 | §4.6 重构：删除原 `HelpSettingsPage`（v1.4 的「帮助页」两区块结构承载过单一），新增 `WikiHomePage`（使用手册主目录，参考 iOS/Android 系统设置搜索样式：顶部固定搜索框 + 7 个用户视角章节 + 35 条目）；文件拆分（wiki_data/wiki_search_bar/wiki_section_view/wiki_entry_view 4 个子组件，满足 ≤500 行规则）；§4.6.4 wiki 子页从 3 个扩展为 4 个（新增 `MacroSummaryWikiPage` 宏摘要机制页）；新增 §4.6.6 `MacroSummaryOverviewDiagram` 主视觉示意图组件（i18n 驱动文案，与 §4.6.5 硬编码策略对比说明）；§4.5 设置页入口描述更新为直接跳转 `WikiHomePage`；i18n 清理废弃 key（gettingStarted/storyWiki 系列） |
| v1.7 | 2026-07-27 | §4.6.4 wiki 子页扩展至 6 个（新增 `FirstLaunchWikiPage` 第一次打开 App + `HomeOverviewWikiPage` 界面总览）；新增 §4.6.7 `FirstLaunchFlowDiagram`（3 节点流程图：启动→新手引导→主界面，节点 2 高亮 + accent 数字徽章强调"6 步"）和 §4.6.8 `HomeLayoutDiagram`（5 区域竖向布局图：标题/API Key 提示/双卡入口/最近会话/设置，`_ConditionalBlock` warning 虚线边框表达条件显示）；新增 `WikiSectionTitle` 公共章节标题组件（从 macro_summary_wiki_page 和 story_flow_wiki_page 提取私有 `_SectionTitle` 消除重复）；文案全部 i18n 驱动（10 个 firstLaunch + 10 个 homeOverview 翻译键） |
| v1.8 | 2026-07-27 | §4.6.4 wiki 子页扩展至 12 个（新增第二部分「对话模式用法」6 个子页：`SessionOperationWikiPage` 创建与切换会话 / `MessageFlowWikiPage` 发送消息与流式输出 / `MessageActionsWikiPage` 消息操作 / `MessageNavigationWikiPage` 消息导航 / `SessionSettingsWikiPage` 会话设置 / `CompactionFlowWikiPage` 上下文管理与压缩）；新增 §4.6.9 对话模式用法页示意图组件规范（6 个组件：`SessionOperationDiagram`/`MessageFlowDiagram`/`MessageActionsDiagram`/`FloatingNavDiagram`/`SessionSettingsDiagram`/`CompactionFlowDiagram`，统一「上段 surfaceVariant 主视觉 + 下段 surface 补充说明」结构，节点高亮用 primary 实色强调重点步骤）；文案全部 i18n 驱动（6 个子页共约 70 个翻译 key）；wiki_data.dart 第二部分 6 个条目 pageBuilder 从 null 接入实际页面 |
| v1.9 | 2026-07-27 | §4.6.9 对话模式用法页示意图组件图标全面修正对齐代码实现：(1) `FloatingNavDiagram` 4 个按钮图标全部修正——跳顶/跳底用 `Icons.keyboard_double_arrow_up/down`（双箭头表「跳到端点」），上一条/下一条用户消息用 `Icons.keyboard_arrow_up/down`（单箭头表「逐条翻动」），原 wiki 写反且多写了 `_outlined` 后缀。(2) `MessageActionsDiagram` 操作列表扩展至 6 项——新增「继续生成」（`Icons.arrow_downward`，仅用户消息，对标 ChatBox `continueGenerating`）；修正「重新生成」为 `Icons.refresh_rounded`（非 `refresh_outlined`），「引用」为 `Icons.format_quote`（非 `format_quote_outlined`）。(3) `SessionOperationDiagram` 修正「重命名」为 `Icons.edit_outlined`（非 `drive_file_rename_outline`），「收藏」为 `Icons.star_border`（非 `star_outline`），「复制」为 `Icons.content_copy`（非 `content_copy_outlined`）。同步重写 6 个子页 i18n 文案：以用户产品视角替代系统实现描述（删除「草稿会话机制避免数据库污染」/「三级优先级链」/「阈值公式」等内部实现细节，改为「会话是你和 AI 的一段独立对话」/「会话级配置 > 全局默认」/「对话长度接近模型上限时自动触发」等用户能理解的语言）；消息操作子页 WikiStepCard 从 5 个扩展为 6 个（补全「继续生成」操作）。 |
| v2.0 | 2026-07-27 | §4.6.4 wiki 子页扩展至 17 个（新增第三部分「故事模式用法」5 个新子页：`StoryVsChatWikiPage` 故事模式与对话模式的区别 / `FirstStoryWikiPage` 创建第一个故事 / `StoryMessageActionsWikiPage` 故事模式消息操作 / `StorySessionSettingsWikiPage` 故事会话设置 / `MemoryBrowserWikiPage` 记忆库浏览器）；新增 §4.6.10 故事模式用法页示意图组件规范（5 个组件：`StoryVsChatDiagram` 双栏对比 / `FirstStoryFlowDiagram` 3 步流程 + 嵌入模型缺失 Banner / `StoryMessageActionsDiagram` 4 操作 + Fork 窗口限制 / `StorySessionSettingsDiagram` 4 步骤模型 + 6 区段 / `MemoryBrowserDiagram` 双 Tab + 4 操作）；图标严格对齐 `intermediate_message_actions.dart` / `intermediate_session_settings_sheet.dart` / `memory_browser_page.dart` / `experience_memory_tab.dart` / `factual_memory_tab.dart` 实际代码；文案全部 i18n 驱动（5 个子页共约 80 个翻译 key）；wiki_data.dart 第三部分 7 个条目 pageBuilder 从 null 接入实际页面（3.3 复用 StoryFlowWikiPage、3.5 复用 StoryFailureWikiPage） |
| v2.1 | 2026-07-27 | §4.6.4 wiki 子页扩展至 24 个（新增第五部分「配置与个性化」7 个子页：`ApiProviderWikiPage` API 供应商管理 / `ModelStrategyWikiPage` 模型选择策略 / `PromptTemplateWikiPage` 提示词模板系统 / `StoryPromptCustomWikiPage` 故事模式提示词自定义 / `AppearanceWikiPage` 外观与主题 / `LanguageInputWikiPage` 语言与输入 / `AdvancedSettingsWikiPage` 高级设置）；新增 §4.6.11 配置与个性化页示意图组件规范（7 个组件：`ApiProviderDiagram` 7 内置模板+自定义 2 步 / `ModelStrategyDiagram` 3 层优先级+4 步骤 / `PromptTemplateDiagram` 3 类型+4 操作 / `StoryPromptCustomDiagram` 8 段+编辑器 3 区块 / `AppearanceDiagram` 3 主题+10 档字体 / `LanguageInputDiagram` 3 语言+2 快捷键 / `AdvancedSettingsDiagram` 3 区块+5 档思考预算）；配置页组件更强调"分类清晰"——上段展示主分类、下段展示子项或操作；图标严格对齐 `provider_templates.dart` / `default_reasoning_effort_section.dart` / `language_selector_section.dart` 等实际设置页代码；文案全部 i18n 驱动（7 个子页共约 90 个翻译 key）；wiki_data.dart 第五部分 7 个条目 pageBuilder 从 null 接入实际页面 |
| v2.2 | 2026-07-27 | §4.6.4 wiki 子页扩展至 28 个（新增第六部分「数据与维护」4 个子页：`DataExportWikiPage` 数据导出与导入 / `DataRecoveryWikiPage` 数据恢复与表修复 / `ClearDataWikiPage` 清除所有数据 / `DiagnosticsWikiPage` 诊断信息）；新增 §4.6.12 数据与维护页示意图组件规范（4 个组件：`DataExportDiagram` 3 类备份内容+API Key 开关+2 种导入模式 / `DataRecoveryDiagram` 孤立消息恢复 2 步+表结构修复 3 动作 / `ClearDataDiagram` 会清空 4 类表 vs 会保留 2 类配置 / `DiagnosticsDiagram` 5 区块纵向排列）；本组组件更强调"安全/危险语义对比"——error 色标注清空操作、success 色标注保留项/追加模式、warning 色标注风险提示、primary 色标注常规操作；图标严格对齐 `ExportOptionsSheet` / `ImportModeSheet` / `app_database.dart` 的 `recreateConversationTables` DROP 列表 / `diagnostics_page.dart` 的 5 个区块 / `LogLevel` 枚举 / `DebugLogField` 枚举；文案全部 i18n 驱动（4 个子页共约 70 个翻译 key）；wiki_data.dart 第六部分 4 个条目 pageBuilder 从 null 接入实际页面 |
| v2.3 | 2026-07-27 | §4.6.4 wiki 子页扩展至 32 个（新增第七部分「附录」4 个子页：`FaqWikiPage` 故障排除 FAQ / `GlossaryWikiPage` 术语表 / `FeatureIndexWikiPage` 功能索引表 / `VersionHistoryWikiPage` 版本更新记录）；新增 §4.6.13 附录页示意图组件规范（4 个组件：`FaqDiagram` 3 类错误码体系卡片按模式区分色彩 / `GlossaryDiagram` 3 组术语分类卡片纵向排列 / `FeatureIndexDiagram` 5 大模块卡片按版本归属着色 / `VersionHistoryDiagram` 3 个版本阶段卡片按状态着色）；本组组件更强调"分类与状态语义"——primary/accent/muted 三色对应错误码体系归属（Simple/Intermediate/通用）、primary/accent/success 三色对应术语语义角色（API/记忆/项目）、五色对应 5 大模块版本归属（Simple/Intermediate/Settings/Data/Help）、success/warning/muted 三色对应版本交付状态（已交付/进行中/待启动）；图标和分类严格对齐项目错误码规范（S001-S009/E010-E018/E001-E302）、术语实际分组、feature 划分、版本策略；文案全部 i18n 驱动（4 个子页共约 60 个翻译 key）；wiki_data.dart 第七部分 4 个条目 pageBuilder 从 null 接入实际页面，Wiki 主目录 7 部分建设全部完成 |
| v2.4 | 2026-07-30 | §4.2 SimpleMarkdownBody 规范全面重写：从原"支持代码块、粗体、斜体、列表等"4 行简略描述扩展为完整渲染能力清单（对标 ChatBox Markdown.tsx）。新增 3 项能力：**(1) 代码语法高亮**——`flutter_highlighting` 库 + github/github-dark 主题；独立组件 `SimpleCodeBlock` 含语言标签胶囊 + 折叠/展开（>7 行自动折叠）+ 复制按钮 + Mermaid 降级提示（语言为 `mermaid` 时显示 i18n `mermaidNotSupported` 提示条 + 完整源码，Flutter 无原生 Mermaid 实现）。**(2) LaTeX 数学公式**——`flutter_markdown_latex` 解析 + `flutter_math_fork` 渲染，行内 `$...$` 与块级 `$$...$$`，独立 `SafeLatexElementBuilder` try-catch 容错（不支持的命令降级为纯文本）。**(3) 链接点击打开外部浏览器**——`url_launcher.launchUrl` + `LaunchMode.externalApplication`，非 http(s) 链接或启动失败回退剪贴板 + SnackBar。GFM 扩展（表格/任务列表/删除线/自动链接）通过 `ExtensionSet.gitHubFlavored` 启用。i18n 新增 3 个 key：`codeExpand` / `codeCollapse` / `mermaidNotSupported`。pubspec 新增依赖：`flutter_highlighting` / `flutter_math_fork` / `flutter_markdown_latex` / `url_launcher`。AndroidManifest.xml 新增 `<queries>` 声明支持 https scheme（Android 11+ 包可见性要求）。设计动机：用户反馈"对话模式渲染能力不足，无法显示代码高亮和公式" |
