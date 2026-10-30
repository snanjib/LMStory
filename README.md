<div align="center">

<img src="assets/branding/lmstory_logo_v1.png" alt="LMStory Logo" width="180" height="180">

# LMStory

**世界不是设定出来的，是经历出来的。**

一个由你推进、由 AI 回应、在经历中持续成形的互动世界。

[![CI](https://github.com/snanjib/LMStory/actions/workflows/ci.yml/badge.svg)](https://github.com/snanjib/LMStory/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.19-02569B?logo=flutter\&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Web-green)](#平台支持)

[English](README.en.md) · 简体中文

</div>

不是情感陪伴，不为创作小说，也不只是角色扮演——

**LMStory 是一个世界叙事引擎。**

你推进，AI 回应，世界生长：不必先写好角色卡、世界书或剧情大纲，从一句话开始，相遇、选择与经历就会沉淀为这个世界的知识与历史，持续影响之后的一切。

## LMStory 与你熟悉的三类产品

| 产品形态 | 核心对象 | 主要目标 |
|---|---|---|
| 情感陪伴产品 | 一个预设角色 | 与角色建立持续关系 |
| AI 酒馆 / 角色扮演前端 | 配置好的角色与世界 | 扮演预设场景 |
| 小说生成器 / 写作助手 | 大纲与章节 | 生产一份故事文本 |
| **LMStory** | **持续形成的世界** | **亲自探索并改变它** |

- **角色卡和世界书是种子，不是门票。** LMStory 兼容 SillyTavern 生态的角色卡与世界书导入（规划持续扩展兼容格式），但你可以什么都不准备，从零开始。
- **记忆不是聊天记录，而是世界的过去。** 世界不只拥有被写下的设定，也会积累亲自发生过的历史。
- **小说不是目标，而是旅程留下的纪念。** 单会话稿件已可导出 Markdown 留存；跨会话的旅程归档/编年史与分享仍在规划中——导出是纪念，不是使用目的。

## 世界如何生长

每一轮，LMStory 在你看不见的地方完成一次「世界维护」：

1. **你推进** —— 写下你的行动、对话与选择；
2. **AI 回应** —— 世界对你的行动作出回应：NPC 有记忆与立场，事件有后果；
3. **经历被沉淀** —— 本轮发生了什么、改变了哪些事实、牵动了哪些关系，被整理进世界的记忆；
4. **后续发展继承已形成的世界** —— 下一轮的回应建立在整个世界的历史之上：既成事实不被无故遗忘，设定漂移会被世界自己纠正。

这一切都在你的设备上完成（详见[数据与隐私](#数据与隐私本地优先)），由你自己接入的 AI 模型驱动（详见[快速开始](#快速开始)）。

## 当前已实现的能力

| 能力 | 状态 | 说明 |
|---|---|---|
| **对话模式** | ✅ 已实现 | 通用 AI 对话：多供应商接入、流式回复、会话分支、附件、上下文压缩 |
| **故事模式** | ✅ 已实现 | 沉浸式叙事：每轮自动沉淀经历记忆与世界事实，检索往事与设定后再生成，可选审查阶段，失败可恢复；重生成旧稿存为可切换变体、中断正文不丢失，支持稿件 Markdown 导出、会话内搜索与阅读位置记忆 |
| **导演模式** | ✅ 已实现 | 你写项目规则，AI 作为幕后「总编辑」自主检索记忆、维护设定、撰写正文；支持监督模式（逐项审批写入）、请示导演、过程分层展示、事件日志与重启恢复。设置中开启 |
| **世界书 / 角色卡（资源库）** | ✅ 已实现 | 导入 SillyTavern 兼容 PNG 角色卡（V1/V2/V3）与纯 JSON 角色卡、世界书 JSON；应用到会话作为只读「种子」设定；**AI 建卡/建书**：与 agent 对话式共创资源，草稿确认后落库 |
| **自带 Key（BYOK）** | ✅ 已实现 | 7 个内置供应商模板（OpenAI / DeepSeek / OpenRouter / Anthropic Claude / Google Gemini / NVIDIA NIM / Agnes AI），支持 OpenAI 兼容、Anthropic、Gemini 三类协议 |
| **数据导入导出** | ✅ 已实现 | 会话、记忆与配置可导出/导入，本地优先 |
| **界面语言** | ✅ 已实现 | 简体中文 / English 可切换（设置 → 语言与输入，即时生效并保留选择；跟随系统暂未开放） |

**规划中**（尚未交付，不以已实现表述）：跟随系统语言 · 旅程归档/编年史导出（单会话稿件导出已实现） · CHARX 角色卡格式 · Web 端正式发布。

## 从零开始，或带着种子进入

**从零开始**：新建故事会话，写下第一句话即可——比如「雨夜，旧宅的门被敲响第三次。」世界从你的第一句话开始成形。

**带着种子**：设置 → 角色卡/世界书，导入你已有的 SillyTavern 兼容资产，然后在故事会话设置中应用它。导入的角色与世界设定会作为只读基线参与世界运转；之后世界学到的新事实仍会正常积累，与你的种子共同生长。

想看 AI 全权执笔的另一种玩法？在设置中开启**导演模式**，写好项目规则，让 AI 总编辑替你运转世界，你负责把关与纠偏。

## 快速开始

当前处于开源准备阶段，暂无发布安装包，请从源码构建：

```bash
git clone https://github.com/snanjib/LMStory.git
cd LMStory

dart pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang        # i18n 代码生成
flutter run
```

环境要求：Flutter >= 3.19、Dart >= 3.3。首次运行后在 **设置 → 通用设置 → 供应商** 配置：选择模板（或自定义）→ 填写 `baseUrl` 与 API Key → 选择模型。

## 数据与隐私：本地优先

- 你的会话、记忆与世界事实全部存储在**设备本地数据库**中，不上传任何服务器；
- API Key 使用平台安全存储保管；LLM 请求只发往**你自己配置**的供应商；
- 应用不内置任何云端账号、遥测或广告。

## 当前开发状态与平台稳定度

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ⚠️ 开发中 | 主要目标平台；生产签名链路已接入（正式 keystore + CI 注入） |
| iOS / macOS | ✅ 已适配 | v0.4.1 完成双平台适配（拖放、关窗保护、授权记忆等），未做商店分发 |
| Windows / Linux | ⚠️ 未验证 | 平台工程已就绪，未做发布验证 |
| Web | ⚠️ 实验性 | 浏览器数据库与流式适配已完成；第三方 API 通常需部署同源代理处理 CORS |

当前版本为 0.4.1（导演模式与世界书/角色卡已交付，iOS/macOS 双平台适配完成）；发布流程与版本节奏将随开源进展逐步确定。

## Roadmap

**已实现**
- [x] 对话模式（多协议 BYOK、分支、压缩）
- [x] 故事模式（经历记忆 + 事实记忆 + 混合检索 + 失败恢复）
- [x] 导演模式（项目规则 / 监督模式 / 事件日志）
- [x] 世界书/角色卡导入与应用（SillyTavern 兼容）
- [x] iOS / macOS 双平台适配（文件拖放、关窗保护、授权记忆）
- [x] 英文界面（zh-CN / en-US 双语，切换即时生效）

**正在做**
- [ ] 内测反馈滚动修复与体验打磨
- [ ] 版本发布节奏与仓库治理（v0.4.1 起按 tag 发布）

**未来方向**（均为规划，未交付）
- [ ] 旅程归档 / 世界编年史导出（多会话级归档与分享；单会话稿件导出已实现）
- [ ] World 一级对象：一个世界容纳多条旅程与时间线
- [ ] CHARX 角色卡格式与更多生态兼容
- [ ] Web 端正式发布

## 开发、贡献与架构

本项目采用 Feature-first Clean Architecture（`Presentation -> Domain <- Data`，共享基础设施在 `Core`）：

```
Presentation -> Domain <- Data
                  ↑
                Core
```

```text
lib/
├── core/               # 基础设施（网络、存储、配置、主题）
├── features/
│   ├── chat/           # 对话模式 + 外壳路由
│   ├── intermediate/   # 故事模式（六步管线）
│   ├── advanced/       # 导演模式（Agent 内核、HITL、事件日志）
│   ├── story_runtime/  # 故事/导演共享运行时
│   ├── resource_library/ # 世界书/角色卡资源库
│   ├── memory/         # 记忆子系统
│   ├── settings/ templates/ diagnostics/ help/ onboarding/
└── i18n/               # 翻译资源（当前仅 zh-CN）
```

技术栈：Flutter / Riverpod / drift (SQLite) / dio + 自研 SSE / slang / Material 3。

- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md)
- 文档地图与裁决规则：[doc/README.md](doc/README.md)
- 项目定位：[doc/product/00_项目定位.md](doc/product/00_项目定位.md)

## 致谢

- **[ChatBox](https://github.com/chatbox-org/chatbox)** — 对话模式的产品与实现参考
- **[Inter](https://github.com/rsms/inter)** — 界面字体，随仓库分发并附 [SIL OFL 1.1](assets/fonts/Inter/OFL.txt) 许可文本

## 协议

本项目基于 [GPL-3.0](LICENSE) 协议开源。
