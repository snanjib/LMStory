/// 续写接写合并
///
/// 「继续生成」的 API 上下文构造：半截 assistant 内容 + 续写指令合并为
/// 单条 user 消息（指令为前缀），替换上下文末尾的半截 assistant 条目——
/// 模型看到的是「请接着这段写」的单条指令，而非 [用户, 半截回复] 后另起
/// 一条（后者模型常重新开场、口吻重复）。生成完成后新内容由控制器追加进
/// 被续写消息（单气泡 + 「已中断·续写」徽标）。
library;

/// 续写指令（进 API 上下文的模型可见文案）
const String kContinueWritingDirective = '下面是上一条被中断的回复。请从中断处继续写完：直接输出后续内容，'
    '不要重复已有文字，不要重新开场，不要解释。';

/// 把上下文末尾的半截 assistant 条目替换为单条 user 消息
/// （[kContinueWritingDirective] 前缀 + 半截内容）。
///
/// 规则：
/// - 末条为 assistant（含 [halfContent] 的原文）→ 原位替换；
/// - 截断把半截条目裁掉（末条非 assistant）→ 追加在末尾，半截内容仍
///   随指令进上下文（丢上下文好过丢半截正文）；
/// - [halfContent] 为空 → 原样返回（无半截可接，调用方不应到达此处）。
///
/// 角色说明：合并条目为 user 角色，与锚点用户消息可能相邻成对——
/// OpenAI 兼容/Gemini 原生接受连续同角色；Anthropic 现行 Messages API
/// 亦接受（按连续 turn 合并语义）。若未来某适配器严格交替校验， fallback
/// 是把指令并入锚点 user 消息尾部（本函数唯一改动点）。
List<Map<String, dynamic>> mergeContinueContext(
  List<Map<String, dynamic>> context, {
  required String halfContent,
  String directive = kContinueWritingDirective,
}) {
  if (halfContent.isEmpty) return context;
  final merged = <String, dynamic>{
    'role': 'user',
    'content': '$directive\n\n$halfContent',
  };
  if (context.isNotEmpty && context.last['role'] == 'assistant') {
    return [...context.sublist(0, context.length - 1), merged];
  }
  return [...context, merged];
}
