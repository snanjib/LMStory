# 首次启动演示数据包

本目录是首次启动 Demo 引导的版本化回放资产。每个 locale 一个自包含包文件：

```
assets/demo/first_launch/zh-CN.json                       （默认候选 glm-5.3）
assets/demo/first_launch/zh-CN/<model>.json               （多仿真候选包）
assets/demo/first_launch/catalog.json                     （候选目录）
assets/demo/first_launch/en-US-sample.json                （英文离线故事样例）
```

## 多仿真候选（2026-11-07 起）

首轮开始前，用户可在真实导演向导的模型步从五个仿真候选中选择体验对象。
候选目录 `catalog.json` 是「候选 id → 包路径 / 来源模型 / 字节指纹 / 展示
文案」的**唯一映射点**；向导选项、播种模型清单、恢复身份对账一律从目录
推导，禁止在页面内另写模型名→包路径映射。

| 候选 id | 来源模型 | 虚拟模型 id | 回放画像 | 包 |
|---|---|---|---|---|
| `glm-5.3`（默认） | glm-5.3 | `demo-narrator-glm` | zhipu | `zh-CN.json` |
| `deepseek-v4.1-flash` | deepseek-v4.1-flash | `demo-narrator-deepseek-v4.1-flash` | deepseek | `zh-CN/deepseek-v4.1-flash.json` |
| `glm-5.3-flash` | glm-5.3-flash | `demo-narrator-glm-5.3-flash` | zhipu | `zh-CN/glm-5.3-flash.json` |
| `kimi-k3.1-pro` | kimi-k3.1-pro | `demo-narrator-kimi-k3.1-pro` | conservativeRelay | `zh-CN/kimi-k3.1-pro.json` |
| `mimo-v2.6-flash` | mimo-v2.6-flash | `demo-narrator-mimo-v2.6-flash` | conservativeRelay | `zh-CN/mimo-v2.6-flash.json` |
| `en-us-story-sample` | 本地创作样例 | `demo-narrator-en-sample` | conservativeRelay | `en-US-sample.json` |

- 五个简中候选使用 `formatVersion=2`、`kind=official` 并共享同一固定
  首问（promptHash `070bde0187451cff`）。
- 候选包字节 SHA-256 登记在 `catalog.json` 的 `packSha256`，加载器逐字节
  对账，资产漂移按候选局部不可用处理。
- 候选数据形态各异（实体 4/3/0/1/3；DeepSeek 与 MiMo 未触发嵌入，零
  embed 行合法），记忆库引导按真实沉淀定向，不为零实体候选造实体。
- 虚拟模型 id 全部在 `demo-narrator-*` 命名空间内，仅存在于演示库虚拟
  供应商缓存清单；交接时按列全量清理，不代表真实供应商配置。
- 英文入口有一个 `kind=sample` 包。向导显示 English story sample。目录按语言筛选，英文选择该语言下唯一的样例。

## 加入一个新候选（流程）

1. 用采集工具线（`tool/demo/capture/`）产出 `candidate-1/pack.json` 并
   完成验收（expectations 语义证据齐备、凭据扫描零命中）。
2. 包文件放 `assets/demo/first_launch/<locale>/<model>.json`，字节不动。
3. 在 `catalog.json` 增补条目：稳定候选 id、来源模型 id、虚拟模型 id
   （`demo-narrator-*`）、locale、assetPath、packSha256（
   `shasum -a 256`）、展示文案；`isDefault` 恒仅一个。
4. `pubspec.yaml` 声明新子目录（Flutter 目录资产不递归）。
5. 验证：

```bash
cd <仓库根>
dart run tool/demo/verify_pack.dart assets/demo/first_launch/<locale>/<model>.json
flutter test test/features/demo/pack/          # 目录/指纹/manifest 对账
flutter test test/features/demo/replay/five_pack_full_round_test.dart
```

## 当前状态

**`zh-CN.json` 为默认正式演示包（`manifest.kind == "official"`，
`formatVersion == 2`）**：由文本模型 `glm-5.3` 与嵌入模型
`nvidia/nemotron-3.5-embed-8b` 真实轮次采集物化并完成无凭据脱敏清洗，
绑定 `zhipu` 流式工具调用回放画像（`streamingToolCallsReliable=true`,
`requiresToolStreamFlag=true`）。
**`zh-CN/` 四份多模型候选包**来自 2026-11-06/07 多模型补充采集批次
（已验收 candidate-1），回放画像与来源模型真实对账。
`en-US-sample.json` 是本地创作的英文开场及合成回放。它记录一条经历并提交一轮完整英文正文，使用与简中相同的模板指纹和工具集校验。数据包没有向量素材。

## 格式与校验

格式契约（manifest 字段、事件序列化、匹配键、规范化规则、兼容性）见
仓库内《首次启动Demo：接口与验收契约》设计文档 §7（产品仓库过程目录）。

替换/新增包后必须全部通过：

```bash
cd <仓库根>   # 主检出或实施 worktree
dart run tool/demo/verify_pack.dart assets/demo/first_launch/<locale>.json
flutter test test/features/demo/pack/
```

- CLI 校验结构/密钥扫描/promptHash（纯 Dart）；
- flutter test 校验 toolFingerprint、builtin 模板 content 哈希对当前
  源码的对账（采集后源码演进会使旧包自然失效——需按当前源码重采，
  不是把哈希改对了事）。

## 采集侧指纹获取

采集准备阶段需要当前源码的工具指纹时，运行：

```bash
flutter test test/features/demo/pack/ --name "manifest 哈希对账当前源码"
```

失败信息中会打印 `actual=<指纹>`；或在测试环境调用
`computeDemoToolFingerprint()`（`lib/features/demo/data/demo_tool_fingerprint.dart`）。

## 禁止入库

API Key、鉴权头、endpoint 私密参数、真实用户数据、采集原始日志、
未经审核的模型思考全文。`DemoPack.parse` 的密钥扫描与 CLI 会拒绝
含凭据样式的包。

## 播放与版本维护

真实采集耗时仅用于追溯，不用于回放调度。文本模型请求固定等待 750ms；流式文本按 240 个 Unicode 码点/秒、思考过程按 480 码点/秒（~40ms 批次调度）播放。非流式工具结果整体交付，标题和嵌入不额外叠加等待。节奏由运行时独立配置，跨相邻同类 delta 累计分片，不同供应商分片颗粒度不改变播放速度。

每次大版本重新录制并验收；小版本检查兼容性，工具、模板、能力画像或业务语义改变时提前重录。产品版本、contentVersion 与 formatVersion 分开维护，不能仅改版本号或哈希复用不兼容内容。正式包替换后重新执行完整页面回归及双端断网/恢复矩阵。
