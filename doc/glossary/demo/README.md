# 演示引导（Demo）术语

| 术语 | 含义 |
|---|---|
| 演示作用域 | 独立无父 Riverpod 容器（`ProviderContainer` 无 parent），经 `UncontrolledProviderScope` 包住 MaterialApp；除桥对象外与正式作用域零共享 |
| 桥（DemoBridge） | 根/Demo 两作用域间唯一通信对象集（Spotlight 注册表、输入锁、教程控制器、网络守卫、回放句柄与回调位） |
| 虚拟供应商 | 演示库内预置的假供应商（`demo.invalid` 端点+占位 Key+chat/embedding 双模型），满足真实向导已配置分支门控 |
| 数据包（DemoPack） | 版本化本地回放资产 `assets/demo/first_launch/<locale>.json`；manifest 指纹（工具集/模板/提示词哈希）与源码对账，不符即隐藏入口 |
| 回放匹配键 | （`LlmRequest.purpose` × 回合 × purpose 内步序）；done 完成才消耗，取消/异常不消耗可安全重试；未匹配本地失败绝不联网 |
| 网络守卫 | Guarded Dio/HTTP 客户端：任何远程调用企图先计数再就地失败；`attemptCount==0` 是「零远程调用」证据（不依赖断网） |
| 会话交接 | demo 库→正式库的 11 表单事务搬运：清虚拟引用/剥演示向量/FTS 同事务重建；幂等=同 ID IGNORE+会话行存在即已导入 |
| 输入锁 | `DirectorInputLock` 通用能力：固定文本只读、草稿恢复/落库/插入五防线全跳过、仅用户亲自点击发送启动 |
| Spotlight 目标 | 真实 widget 以语义 id 注册全局 Rect 的定位机制（`SpotlightTarget`）；遮罩挖孔命中穿透，无固定坐标 |
| 恢复矩阵 | 演示中断重启后的步骤重导规则：向导未完成→homeWizardEntry；回合未提交→sessionInput；已提交→settingsIntro（不再生成一轮） |
| 候选目录 | `assets/demo/first_launch/catalog.json`：「候选 id→包路径/来源模型/字节指纹/展示文案」唯一映射点；向导选项、播种清单、恢复对账一律从目录推导 |
| 仿真候选（多仿真模型） | 一份已验收的离线回放数据包 + 展示元数据；虚拟模型 id 在 `demo-narrator-*` 命名空间内，仅存在于演示库，交接时清理 |
| 英文离线故事样例 | 英文界面内置的一轮完整故事。数据包标记 `kind=sample`，正文和回放事件源于本地创作，经演示包校验、演示库和向导播放 |
| 选择协调点 | Demo 内部把「向导模型步点击」翻译成一致绑定的单一入口：换包+画像+持久身份可等待完成，失败保持上一选择；首轮发送后锁定 |
