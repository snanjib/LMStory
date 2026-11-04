# 贡献指南

感谢你对 LMStory 项目的兴趣！本文档描述了如何参与项目贡献。

## 行为准则

参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。请保持尊重和友善。

## 报告 Bug

1. 在 [Issues](https://github.com/snanjib/LMStory/issues) 中搜索是否已有相同问题
2. 如果没有，使用 Bug Report 模板创建新 Issue
3. 提供尽可能详细的信息：操作系统、App 版本、复现步骤、预期行为、实际行为

## 提交功能建议

1. 在 [Issues](https://github.com/snanjib/LMStory/issues) 中搜索是否已有类似建议
2. 使用 Feature Request 模板创建新 Issue
3. 描述功能用途、解决的问题和建议的实现方式

## 开发环境搭建

### 前置要求

- Flutter >= 3.19.0
- Dart >= 3.3.0
- Android Studio / VS Code（推荐安装 Flutter 插件）

### 步骤

```bash
# 克隆仓库
git clone https://github.com/snanjib/LMStory.git
cd LMStory

# 安装依赖
dart pub get

# 代码生成（drift / riverpod / json_serializable）
dart run build_runner build --delete-conflicting-outputs

# 国际化代码生成（修改翻译文件后执行）
dart run slang

# 运行 App
flutter run
```

## 开发流程

### 分支策略

本仓库以**当前迭代的主版本分支作为主干**（不设 `main`/`master`，当前主干为 `v0.4.0`，即仓库默认分支）。版本发布以打在主干上的 tag 为准（如 `v0.4.1`）；开启新的主版本迭代时，主干会切换到新的版本分支（如 `v0.5.0`）。

- `v0.4.0`：当前主干分支（默认分支）
- `feat/<功能名>`：新功能开发
- `fix/<问题描述>`：Bug 修复
- `docs/<内容>`：文档更新
- `refactor/<模块>`：代码重构

### Commit 规范

使用 Conventional Commits 格式：

```
feat: 添加 XX 功能
fix: 修复 XX 问题
docs: 更新 XX 文档
refactor: 重构 XX 模块
test: 添加 XX 测试
chore: 更新依赖/配置
```

### 代码规范

- 遵循 `very_good_analysis` lint 规则
- 提交前运行 `flutter analyze`；不得新增 error/warning，并处理与本次变更相关的 lint
- 运行 `dart format lib/ test/` 格式化代码与测试
- 文件命名 `snake_case`，类名 `PascalCase`
- 禁止使用 `!` 空断言，使用 `??` 或 `if (x != null)` 替代
- 所有用户可见文本使用 slang 国际化系统，禁止硬编码

### 测试要求

- 新功能需附带测试
- 提交前运行 `flutter test`，确保全部通过
- 测试文件放在 `test/` 目录，与 `lib/` 结构对应

### Pull Request 流程

1. 从主干分支 `v0.4.0` 创建功能分支
2. 编写代码并确保通过 `flutter analyze` 和 `flutter test`
3. 如果修改了 drift 表 / riverpod provider / json model，重新运行 `build_runner`
4. 如果修改了翻译文件，运行 `dart run slang`
5. 更新相关设计文档（如有需要）
6. 创建 PR，描述变更内容、变更类型和测试方式
7. 等待 CI 检查通过和代码审查

## 架构约束

本项目采用 Clean Architecture（4 层），贡献代码需遵守以下不变量：

- **Domain 层纯净**：不依赖 Flutter，不依赖 Data 层
- **单向依赖目标**：Presentation -> Domain <- Data；新增代码不得扩大现有 Core 到 feature/domain 的历史性反向引用
- **接口隔离**：Repository 仅含数据存取，业务逻辑在 UseCase/Service/Controller
- **配置驱动**：共享默认参数集中在 `assets/configs/default_config.json`；会话覆盖、兼容字段和平台差异由代码负责解析

详细架构说明见 `doc/design/` 目录下的设计文档。

## 文档更新

代码修改完成后，必须同步检查相关设计文档、术语字典和应用内 Wiki。出现不一致时以当前可执行代码和数据库 Schema 为准，再用日期更近的设计决策补充意图；旧计划和报告只代表历史快照。完整规则见 `doc/README.md`。

## 设计文档体系

| 文档 | 内容 |
|------|------|
| `doc/design/01` | 项目概要设计（当前实现概要） |
| `doc/design/02` | 系统/Web 演进稿（Schema 与模块图需用代码校验） |
| `doc/design/03` | 子系统演进稿；03A 为 Agent Loop 历史方向稿（已被实现超越） |
| `doc/design/04` | 详细设计演进稿；04A 为历史占位稿（导演模式实际设计在 v0.3.0/ 目录） |
| `doc/design/05` | 历史接口快照；当前签名以源码为准 |
| `doc/design/06` | UI 设计规范 |
| `doc/design/06A` | Simple 模式视觉规范 |
| `doc/design/06B` | Intermediate 模式视觉规范（导演模式共享现行全局外观体系） |
| `doc/design/07` | 国际化设计 |
| `doc/design/08` | Intermediate 模式设计 |
| `doc/design/09` | Intermediate 模式详细设计 |
| `doc/design/10` | 多粒度记忆与双摘要设计 |
| `doc/design/11` | 当前事实层三表与 FactsDelta |
| `doc/design/12` | 供应商模板与多协议（4 类已实现协议） |
| `doc/design/13` | 当前故事上下文与压缩/宏摘要分工 |
| `doc/design/14` | 设置交互优化设计 |
| `doc/design/15` | 世界书与角色卡设计（已实施，`lib/features/resource_library/`） |
| `doc/design/v0.3.0/` | 导演模式（Agent Loop）现行设计与实施记录（现行设计与实施记录，以目录为准） |
| `doc/product/00_项目定位.md` | 项目定位（对外表述以此为准） |
