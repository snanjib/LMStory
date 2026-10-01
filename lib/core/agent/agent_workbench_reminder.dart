// 轮尾合成消息的通用标记与服从强化句（agent 循环契约的一部分）。
// 历史位置：advanced/domain/services/agent_system_prompt.dart（下沉时随
// agent_runner 的使用一并迁入 core，advanced 侧 re-export 保持原引用不变）。

/// 服从强化句（尾部指令保缓存：位置无关的最高优先级声明）
///
/// 追加到轮尾强指令（节奏指令/执笔提醒/maxSteps 通牒）的措辞强化：
/// 语义只依赖「本条 + 本次回复」，无论消息落在尾部 recency 位，还是被
/// 协议实现上提进顶层 system 块（Anthropic/Gemini 对 system 的合并行为），
/// 效力一致。措辞守 §3 硬约束：零题材词、零否定句式。
const String kPriorityObedienceClause = '本条为最高优先级即时指令，须在本次回复中立即执行。';

/// harness 生成的轮尾内容统一用 role=user 合成消息承载，内容以此标记
/// 包裹——从根上绕开 Anthropic 适配器把 system 抽到顶层 system 字段导致
/// 轮尾内容失去 recency 位的问题（R6），不修改适配器本体。
///
/// 标记同时向模型声明"这是工作台提醒，不是导演发言"。
const String kWorkbenchReminderOpen = '〈workbench-reminder〉';
const String kWorkbenchReminderClose = '〈/workbench-reminder〉';

/// 把一段 harness 提示文案包成 workbench-reminder 形态
String wrapWorkbenchReminder(String content) =>
    '$kWorkbenchReminderOpen$content$kWorkbenchReminderClose';
