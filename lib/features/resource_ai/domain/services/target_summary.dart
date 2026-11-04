/// AI 编辑目标的摘要（注入提示词的模型输入，非 UI 文案）。
///
/// 资源库页把编辑目标压成一句话，经对话页的 targetSummary 进入系统
/// 提示词的「编辑目标」段。中文属提示词材料而非 UI 文案，故置于
/// domain 层（presentation 中文字面量门禁不扫描此处）。纯函数、
/// 无实体依赖：只取名字与来源格式两个参数。
library;

/// 角色卡目标的摘要（sourceFormat 缺省按 json 展示）。
String cardTargetSummary(String name, String? sourceFormat) =>
    '目标卡「$name」（格式 ${sourceFormat ?? 'json'}）';

/// 世界书目标的摘要。
String bookTargetSummary(String name) => '目标书「$name」';
