# AI 建卡工具设计

> 状态：**已实施（2026-09-11 交付 16 任务；2026-09-12 产品级完善见 §十三）**。
> 本文档是 `resource_ai` 功能的设计真源；实施时的偏差须回写本文档。
> 业界调研结论见附录 A（调研修订已并入正文）。

## 一、背景与目标

资源库（`lib/features/resource_library/`）现状：只有导入（PNG 卡 / JSON 卡 / 世界书
JSON）与删除，没有任何创建、编辑、导出能力。数据层为 SillyTavern 原始 JSON 无损存储（`character_cards` /
`worldbooks` 两表的 `rawJson` 列，schema v50）。

本功能在资源库旁提供一个**完全独立的 AI 建卡工具**：用户与 agent 对话，agent 以
草稿方式增量产出 SillyTavern 兼容的角色卡或世界书，用户确认后落库。同时填平两个
缺口：从零建卡（新建模式）与对话式修改已有卡（编辑模式）。

### 成功标准

1. 从一句话起点出发，≤5 轮对话产出一张可用角色卡。
2. 生成的卡/书 JSON 能被资源库现有 parser（`CharacterCardParser` /
   `WorldbookParser`）无损 round-trip。
3. 导入到 SillyTavern 后合法可用；世界书条目策略字段（position/depth/order 等）
   在 rawJson 中完整保留。

## 二、需求决议（2026-09-10）

| # | 决议 | 内容 |
|---|---|---|
| D1 | 交互模式 | 混合式：用户自由输入（一句话/粘贴材料），agent 边聊边提炼，缺口追问 |
| D2 | 落地方式 | 草稿确认制：对话内实时草稿预览，用户点「保存」才写入资源库 |
| D3 | 产品形态 | 完全独立工具，不属于 chat/intermediate/advanced 任何模式，从资源库进入 |
| D4 | 产出范围 | 一次对话一个产出：一张角色卡**或**一本世界书；对话绑定一个目标（新建=空，编辑=已有卡/书） |
| D5 | 会话生命周期 | 点开→定稿落库；无对话列表、无持久化；退出有确认拦截，杀进程即丢 |
| D6 | 编辑保存语义 | 另存为默认 + 可选覆盖原条目（覆盖前二次确认） |
| D7 | 世界书策略 | rawJson 存完整 ST 策略字段（导出不丢）；LMStory 自身注入仍只消费简化三语义（constant/enabled/vectorized），不改注入链路 |
| D8 | 运行时架构 | agent 循环契约从 advanced 下沉到 `core/agent/`，advanced 与 resource_ai 为平等消费者（§四） |
| D9 | 联网搜索 | v1 不做，预留 `web_search` 工具命名位；材料导入（粘贴/附件/资源库引用）v1 提供 |
| D10 | 提示词与 skill | 专属系统提示词 + 内置 skill 写作规范资产，为本功能的质量核心（§六） |
| D11 | 前端纪律与可读性 | presentation 设计与实现必须走 impeccable 技能；对话界面简洁、草稿双入口随时可看、草稿结构化渲染——禁止把 rawJson 原文展示给用户（§3.2） |
| D12 | 配置极简 | 用户面唯一配置=模型选择，选完即开始干活；其余为内部默认不暴露 UI（§八） |

## 三、产品形态与交互

### 3.1 入口

- 资源库页新增两个入口：「AI 建角色卡」「AI 建世界书」（新建模式）。
- 列表项操作菜单新增「AI 编辑」（编辑模式），携带该卡/书作为对话目标。

### 3.2 页面结构（`ResourceAiPage`）

**前端纪律（D11，用户明确要求）**：本功能 presentation 层的设计与实现必须走
impeccable 技能。本文档只约束信息架构与体验底线，视觉与交互细节由
impeccable 流程产出。

**三条体验铁律**：

1. **对话界面简洁**：消息流只保留 agent 文本与轻量过程行，无多余装饰。
2. **成果随时可浏览**：草稿入口至少两条——悬浮草稿状态条 + AppBar 溢出菜单
   「查看草稿」；预览页与对话页来回无摩擦。
3. **草稿适合人类阅读**：结构化渲染——角色卡=分字段区块（字段名 + 排版后
   文本），世界书=词条卡片（标题/关键词/内容/常驻·触发标记）；**禁止把
   rawJson 原文直接展示给用户**，JSON 只存在于存储层。

```
AppBar：标题（AI 建卡 / 目标卡名） · ⚙ 模型 · ⋮（查看草稿等） · 关闭
主体：对话流（agent 文本消息 + 轻量过程行，如「更新草稿：性格」）
悬浮：草稿状态条（「草稿 · 卡片 · 8 字段」），点开进入草稿预览页
底部：输入栏（文本框 + 附件按钮：导入 txt/md/json 参考资料）
```

- **草稿预览页**：竖屏全屏（宽屏/横屏右栏常驻）。卡片=分字段区块；世界书=
  词条卡片列表（标题/关键词/内容/触发标记）。「保存」按钮在预览页；编辑+
  覆盖走二次确认弹窗。
- **退出拦截**：已有对话或非空草稿时 `PopScope` 弹「退出将丢弃本次对话」确认；
  空白初始态不拦。
- **参考资料**：附件文件内容在会话内注入为材料消息（10MB 上限沿用
  `ResourceImportService.maxImportBytes` 口径）；粘贴文本天然支持。

## 四、架构：agent 循环下沉 + 新 feature

### 4.1 下沉（D8）：`lib/core/agent/`

从 `lib/features/advanced/` 平移以下**纯 Dart 契约与循环本体**（advanced 改
import，行为零变化，测试随迁）：

| 现路径（advanced/domain/…） | 内容 |
|---|---|
| `services/agent_runner.dart` | `AgentRunner` + `AgentTurnSpec`（步数/预算/doom-loop/abort 占位补全） |
| `services/agent_tool.dart` | `AgentTool` / `AgentToolPermission` / `AgentToolResult` / `agentToolToDefinition` / 输出预算截断 |
| `services/agent_tool_pipeline.dart` | pre-execute 管线（resource_ai 不用审批面，仅类型依赖） |
| `services/agent_waterfall.dart` | 瀑布回退 |
| `services/doom_loop_detector.dart` | doom-loop 检测 |
| `services/agent_llm_gateway.dart` | LLM 网关抽象 |
| `data/llm_service_agent_gateway.dart` | 网关实现随迁（构造仅依赖 `LlmService`；抽象下沉后实现留在 advanced 会造成 core↔feature 反向依赖，resource_ai 也无法 import advanced） |
| `services/agent_skill_registry.dart` | SKILL.md 解析 + 目录层 + 常驻层机制 |
| `entities/agent_budget.dart` | 预算实体 |
| `entities/agent_cancellation.dart` | 取消令牌 |
| `entities/agent_events.dart` | 事件类型与 sink 契约 |
| `entities/agent_message.dart` | agent 消息实体 |

- `agent_runner.dart` 对 `services/agent_system_prompt.dart` 存在一处 import；
  实施时评估：若仅为类型引用则随迁该类型，**提示词 builder 本体留在 advanced**。
- 留在 advanced 不动：12 个业务工具（`agent_session_tools.dart`）、系统提示词
  构建（`agent_system_prompt.dart` / `director_core_blocks.dart`）、事件持久化
  sink 与恢复（`agent_durable_event_sink.dart` / `agent_log_recovery.dart`）、
  HITL 审批、子代理、UI 侧 event bus / coalescer / timeline 装配。

### 4.2 新 feature：`lib/features/resource_ai/`

```
domain/
  entities/draft_entities.dart        卡片草稿/世界书草稿/草稿变更 的值对象
  services/resource_ai_prompts.dart   系统提示词构建（冻结前缀）
  services/resource_ai_tools.dart     update_draft / finalize_draft / read_skill
  services/draft_json_builder.dart    草稿 → ST rawJson（新建全量 / 编辑 patch）
data/
  resource_ai_save_service.dart       保存三路径（新建/另存/覆盖；覆盖依赖
                                      repository 新增的 update 方法，2026-09-11
                                      核对：现有 repository 仅 create/delete）
  resource_ai_skill_loader.dart       assets/skills 加载（复用 core 的 registry）
presentation/
  pages/resource_ai_page.dart         对话页
  pages/draft_preview_page.dart       草稿预览 + 保存
  controllers/resource_ai_controller.dart
```

**依赖规则**：resource_ai → `core`（agent 循环、LLM）+ resource_library 的
repository 接口。不依赖 advanced / story_runtime / chat / memory。

## 五、agent 工具集（v1 共 3 个）

| 工具 | 枚举标注 | 作用 |
|---|---|---|
| `update_draft` | write | 增量修改草稿（见下） |
| `finalize_draft` | write | agent 声明草稿成形；UI 高亮保存入口。**非终止**，对话可继续改 |
| `read_skill` | readOnly | 按需读写作规范 skill（复用 core 下沉后的机制） |

枚举标注是 `AgentToolPermission` 的工具元数据（下沉契约必填）。

### update_draft 参数草案

按会话类型（卡/书）只暴露对应 action（description 内写明当前模式可用 action）：

```
action: set_card_field   field, value          // 卡：name/description/personality/
                                               // scenario/first_mes/mes_example/
                                               // creator_notes 单字段写入
action: set_card_tags    tags: string[]
action: set_book_meta    name, description     // 书：书名与简介（worldbooks.name 列）
action: add_book_entry   entry{keys, secondary_keys, comment, content,
                               constant, selective, insertion_order, enabled,
                               position, extensions 子集}   // id 由端内分配
action: update_book_entry  id, patch
action: remove_book_entry  id
```

**不设 `ask_user` 工具**：这里是连续对话，agent 用文本追问即可（导演模式需要它
是轮次制产物）。**不接权限三态**：草稿工具不落库，唯一落库动作是用户点保存，
无 deny/ask 面。

## 六、提示词与 skill 资产（质量核心）

### 6.1 系统提示词（`resource_ai_prompts.dart`）

冻结前缀分区（保多轮缓存命中）：① 编辑专家定位 ② 工作法（先探需求再动笔、
主动暴露草稿缺口、改卡小步修改尊重原文）③ 工具规范（何时 update_draft、
何时 finalize）④ skill 目录层。语言跟随用户输入。

工作法采用**软阶段推进**（借鉴业界最接近的先例 CharCardStudio 的分阶段
方法论，但不做工具硬门控）：概念定位 → 字段骨架（description 先行）→
示例对话与开场 → 缺口收尾（finalize 前主动盘点还缺什么）。

### 6.2 内置 skill（`assets/skills/` 新增三目录）

| 目录 | 内容大纲 |
|---|---|
| `card-crafting` | 角色卡写作规范：V2 各字段的写法标准（description 分段结构、personality 锚点写法、first_mes 开场、mes_example 对话示例质量标准、tags 规范） |
| `worldbook-crafting` | 世界书条目写作规范：关键词选取原则（命中率 vs 误触）、内容密度、constant/选择性触发搭配、insertion_order 与 position 惯例 |
| `card-editing` | 改卡工作法：先读全卡再动手、差异最小化、保持原作声线、向用户确认破坏性改动 |

写作规范的内容基准（附录 A 调研所得）：Kingbri chara guide（description 的
Ali:Chat/段落结构）、World Info Encyclopedia（条目拆分粒度与递归）、
ST 官方 Character Design / World Info（条目内容「自足、独立成文」黄金法则：
只有 content 会进上下文）。

两条硬规范写进 skill 与 builder：**宏 `{{char}}`/`{{user}}` 原样存储、渲染期
才替换**；**`match_whole_words` 对中文等无空格语言必须默认关**。

v1 全部**按需 read_skill**，不启用 `alwaysInject`/resident 常驻层（若实测模型
忘读规范再开启，机制已在 core registry 中现成）。

## 七、数据流与正确性

### 7.1 会话初始化

- 新建：空草稿；模式（卡/书）由入口决定。
- 编辑：加载目标 `rawJson` → **原文留底（内存）** + 原始 JSON 紧凑序列化直接
  注入为首条材料消息（卡/书通常数 KB，不另做摘要）。

### 7.2 每轮

用户消息 → `AgentRunner.runTurn`（**纯内存 event sink，不落 `agent_events` 表**）
→ 模型（专属提示词 + 工具）→ `update_draft` 参数流式 delta 可驱动草稿实时渲染
→ 草稿状态更新（controller 持有，唯一状态源）→ 预览刷新。

草稿变更**只在工具 invoke 成功后应用**；失败/被中断的调用不产生变更
（AgentRunner 的 abort 占位补全保证消息序列合法）。

### 7.3 保存

| 场景 | 行为 |
|---|---|
| 新建 | 草稿 → 全新 V2 spec rawJson → repository 新增 |
| 编辑+另存（默认） | 同新建；与原条目互不影响 |
| 编辑+覆盖 | **patch 留底 rawJson**：只改 draft 覆盖的字段/词条，未知字段原样保留 → 二次确认弹窗 → repository 更新（现有仓库无 update 方法，实施新增 `updateCharacterCard`/`updateWorldbook`，保持 id 不变，避免弄断已应用到会话的引用） |

两个正确性约定：

1. **编辑走 patch 不重建**：保住导入卡中 v1 不生成的字段（如 `extensions`、
   内嵌书条目的深度策略），禁止「归一化→再序列化」的有损回写。
2. **round-trip 合法性**：`draft_json_builder` 的产物必须能被
   `CharacterCardParser` / `WorldbookParser` 解析回等价草稿（做成单测）。

世界书条目字段全集以 SillyTavern 源码
`src/endpoints/characters.js → convertWorldInfoToCharacterBook` 为准：顶层
`id/keys/secondary_keys/comment/content/constant/selective/insertion_order/
enabled/position/use_regex` + `extensions{position, depth, probability,
useProbability, scan_depth, case_sensitive, match_whole_words, vectorized,
sticky, cooldown, delay, …}`。v1 agent 可写子集=keys/secondary_keys/comment/
content/constant/selective/insertion_order/enabled/position + extensions{depth,
probability, useProbability, scan_depth, case_sensitive, match_whole_words,
vectorized}；其余字段编辑场景原样保留、新建场景取 ST 默认值。

### 7.4 角色卡字段范围（v1）与 builder 兼容性规则

生成 V2 spec（`spec: chara_card_v2`）。agent 可写：`name / description /
personality / scenario / first_mes / mes_example / creator_notes / tags`。
**不生成**：内嵌 `character_book`（单一产出原则，D4）、`alternate_greetings`、
`system_prompt`、`post_history_instructions`；编辑场景这些字段原样保留。

builder 兼容性规则（调研修订，详见附录 A）：

1. V2 必填面：`spec: 'chara_card_v2'`、`spec_version: '2.0'`、
   `data.extensions: {}`（可为空对象但必须存在）。
2. V1 兼容镜像：`name/description/personality` 等同步一份到顶层
   （V1-only 消费者可读）。
3. 世界书书级字段：`name/description/scan_depth/token_budget/
   recursive_scanning` 取 ST 默认值；`token_budget` 不自行计算（声明值随
   tokenizer 漂移，仅作导入兼容）。
4. 宏 `{{char}}/{{user}}` 原样存储，渲染期才替换。

## 八、配置

**极简原则（D12）：用户面唯一配置=模型选择，选完即开始干活。**

| 键 | 默认 | 用户面 |
|---|---|---|
| `resource_ai.model` | 首次使用时快照全局默认模型 | **唯一暴露项**：首次进入若未选过模型，内联呈现模型选择（预选快照值，可直接点「开始」）；AppBar ⚙ 即模型重选入口，无独立设置页 |
| `resource_ai.max_steps` | 6 | 不暴露 UI（内部默认；键存 default_config 备将来调参） |

遵守 snapshot-first 铁律（禁「跟随全局」动态引用）：`model` 的默认值是进入时
的一次性快照，之后不随全局漂移；重置=重新快照当前全局默认。

## 九、错误处理与中断

| 场景 | 处理 |
|---|---|
| 网络/流错误 | 对话内错误横幅 + 重试；已到达文本与草稿保留；自动重试 1 次后转手动 |
| 用户取消 | 发送中可取消（`AgentCancellationToken` 桥接网络层，机制现成） |
| 工具参数非法 | 错误信封回模型自纠（AgentRunner 现成机制） |
| 保存失败 | repository 事务性保证不留半条；提示错误，对话与草稿保留 |
| 进程被杀 | 按设计即丢（D5），无恢复路径 |

## 十、测试

1. **下沉重构**：advanced 全量测试仅 import 改动即绿；core/agent 新位置测试随迁。
2. **工具单测**：update_draft 各 action、非法参数回错误信封、finalize 语义、
   卡/书模式下 action 可用性约束。
3. **draft_json_builder 单测**：新建产物 round-trip（自家 parser 解回等价草稿）；
   编辑 patch 保未知字段（构造含 extensions/深度策略的原卡，patch 后仍在）。
   结构校验器可参考移植 SillyTavern `src/validator/TavernCardValidator.js`
   （169 行，V1/V2 结构校验）。
4. **Widget 测试**：草稿实时刷新、保存流（另存/覆盖/二次确认）、退出拦截、
   附件材料注入。
5. **提示词构建**：冻结前缀稳定性快照测试。

## 十一、文档面（实施时核对）

feature index、capability list、version milestone、CHANGELOG、glossary（新增
「AI 建卡」词条）。

## 十二、非目标（v1 明确不做）

- 联网搜索（仅预留 `web_search` 工具命名位，D9）。
- 对话持久化、多草稿会话、对话列表（D5）。
- 角色卡内嵌世界书生成（D4）。
- 资源库通用编辑表单 UI、导出能力、CHARX 格式（仍是独立缺口，不在本次范围）。
- 世界书注入链路改造（LMStory 自身仍只消费简化三语义，D7）。

## 附录 A：业界调研结论（2026-09-10）

调研要点与对本设计的
影响：

**没有直接可引入的现成 Dart 包**（pub.dev 无 character card / sillytavern 包），
但有四类可搬资产：

1. **最接近的先例**：ST 扩展 CharCardStudio——分阶段 agentic 对话 + 常驻草稿
   侧栏 + 阶段门控。本设计采纳其阶段方法论为软工作法（§6.1），不采纳硬门控
   （与本功能混合式定位冲突）。
2. **spec 与字段语义**：V2 spec（malfoyslastname/character-card-spec-v2）为
   生成格式权威；世界书条目完整策略字段以 ST
   `convertWorldInfoToCharacterBook()` 映射表为准（§7.3 已对齐）；新增
   `set_book_meta` action 与 builder 兼容性规则（§7.4）均为调研修订。
3. **可移植代码**：SillyTavern `TavernCardValidator.js`（结构校验，§十）、
   `matchKeys()` 关键词匹配（注入端将来增强时的移植蓝本）。
4. **skill 写作基准**：Kingbri chara guide、World Info Encyclopedia、ST 官方
   Character Design / World Info 四份指南作为三个内置 skill 的内容基准（§6.2）。

**本设计与调研建议「最小完备集」的已知差距**（均为 D4/D7 的 v1 取舍，
留后续迭代）：不生成内嵌 `character_book`；条目 extensions 只写常用子集
（position 顶层仅 before_char/after_char，atDepth 等经编辑场景 patch 保留）；
不做逐字段 diff 高亮与条目 token 占用展示（草稿预览 v1 为只读整稿）。

**关键坑已吸收进正文**：PNG 双 chunk/ccv3 优先（现有导入已兼容）、
`match_whole_words` 中文默认关、宏渲染期替换、`data.extensions` 必填、
`token_budget` 不自算。

---

## 实施记录（2026-09-11 回写）

状态：**已实施（2026-09-11，feat/resource-ai 分支）**。

实施偏差（与原设计差异）：

1. **read_skill 工具**：原设计复用 advanced 侧 ReadSkillTool；实际其依赖
   advanced 专属 AgentToolDeps，core 无共享实现 → resource_ai 自建
   ResourceAiReadSkillTool（仅注入 skillNames+loadSkillBody 回调）。
2. **repository**：按计划新增 updateCharacterCard/updateWorldbook
   （覆盖保存不生成新 uuid）。
3. **ConfigurationResolver**：新增公开方法 resolvePresetModelNamingConfig
   （通用 preset+model 解析，非 resource_ai 专属私有逻辑）。
4. **编辑模式预填**：原设计仅提「原文注入首条材料消息」；实施补齐
   rawJson→草稿转换器（cardDraftFromJson/worldbookDraftFromJson，
   条目 id=原书 uid、extensions 整包带回），预览页初始即有内容。
5. **宽屏右栏常驻草稿**：v1 以悬浮状态条+AppBar 双入口替代右栏
   （impeccable product 口径：先标准模式，复杂度后置）。

## 十三、2026-09-12 产品级完善（用户真机反馈驱动）

真机试用反馈三缺口：看不出在用什么模型、写卡过程不渲染 Markdown、没有
「完成」机制（无法预览当前卡、无法落库收尾）。本节按反馈补全，**与上文
冲突处以本节为准**。

### 13.1 会话设置面板（覆盖 §3.2 的「⚙ 模型 + ⋮ 查看草稿」双入口方案与 §八「用户面唯一配置=模型」）

- 入口：AppBar `settings_outlined`（进入会话后可见；idle 门与 saved 终态
  隐藏），全高 modal bottom sheet `ResourceAiSessionSettingsSheet`
  （监听 controller，轮内改稿即时反映到预览）。
- 分区：**模型**（显示名解析自 settings presets，嵌套
  `DefaultModelPickerSheet`，选中即持久化 override、下一轮生效）/
  **生成参数**（温度 0–2 滑条 + 单轮最大步数 2–12 滑条，释放才提交）/
  **草稿预览**（内嵌 `DraftPreviewContent` 实时渲染）/ 底部**完成创建**。
- 配置键：`resource_ai.model.*` / `resource_ai.temperature`（首会话内存
  快照 broadcast 值，触碰即持久化；重置=快照当前全局值）/
  `resource_ai.max_steps`（重置=6）。仍守 snapshot-first 铁律。
- **首用模型门修复**：选中即经 `controller.updateModel` 持久化（原实现
  只写局部 widget 变量，选择从不生效且门永远出不去——死路缺陷，本次修复）。

### 13.2 对话可读性

- assistant 消息 `SimpleMarkdownBody` 渲染（GFM/LaTeX/代码块，user 气泡
  保持纯文本，与 chat 模式口径一致）。
- **过程线**（§3.2 铁律 1 的「轻量过程行」落地）：工具改稿经
  `summarizeDraftChanges` 差分（`draft_change_summary.dart` 纯函数）产出
  role=tool 消息实时插入消息流；本地化文案（「更新了性格」「添加词条
  『xx』」等）与预览字段标签同源（`draft_change_labels.dart`）。
- 生成中提示行（`generatingHint`）；消息列表底部自动跟随（视口在底部
  120px 容差内时新消息自动滚底，用户上翻查看历史不打扰）。

### 13.3 完成创建流（落地铁律 2/3 与 D2，形态变更）

- 预览并入会话设置面板（用户明确要求「在会话级设置里实时预览」）；
  独立 `DraftPreviewPage` 删除——它建成时即是零入口孤儿页，实施记录 5
  所述「悬浮状态条+AppBar 双入口」实际未实现，一并作废。
- 完成入口×2：面板底部按钮 + 输入栏上方**定稿横幅**（`finalized=true`
  时「草稿已定稿 · 完成创建」，agent finalize_draft 工具的直接 UI 反馈）。
- 确认对话框：新建=「将保存『name』到资源库并结束本次写卡」；编辑=
  另存为新资源 or 完成并更新原资源（空名预览兜底「未命名角色卡/世界书」）。
- 成功：saved 终态 → toast「已保存到资源库」→ **会话自动退出**
  （popUntil 清面板再退页，`canPop` 对 saved 放行）；资源库页三个建卡
  入口 await 返回后刷新列表，落库资源立即可见、可在故事/导演模式应用。
- **保存失败不进 fatal**：`save()` 返回结构化错误，现场保留回 ready，
  snackbar 提示可重试（fatal 的「重发上一条」语义对保存失败不适配）。

### 13.4 错误结构化与门禁修复

- fatal/保存失败产出 `ResourceAiError`（kind: modelUnavailable/
  turnIncomplete/saveFailed + detail 技术细节），页面按 kind 映射 slang
  文案（控制器不再持有用户可见中文串）。
- 模型注入信封（编辑目标原文/参考材料/目标摘要）下沉 domain 组装
  （`resource_ai_prompts.dart` / `target_summary.dart`）——修复上一交付
  遗留的中文门禁 8 处违规，门禁零白名单新增转绿。
