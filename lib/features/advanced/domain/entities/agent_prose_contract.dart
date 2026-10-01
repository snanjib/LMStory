/// 导演模式正文交付契约共享常量（设计文档《导演模式正文交付契约设计》§2/§5）
///
/// [kProseThreshold] 是「够格算正文」的长度线，全链路共用一处：
/// - FinishRoundTool 长度截断守卫（finish_reason=length 且低于阈值 → 诊断信封）
/// - AgentRunner 的 hasEmittedProse 判据（≥ 阈值的长文本视为已执笔）
/// - pickReplyBlock 文本回退达标线（通道 B/C 的收割判据）
/// - AgentProseDedup 的 content 块下限（低于阈值的播报不参与去重）
const int kProseThreshold = 200;
