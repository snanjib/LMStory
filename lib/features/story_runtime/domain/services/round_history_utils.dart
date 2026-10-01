import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';

/// 剔除 history 末尾与 [userInput] 内容相同的持久化 user 消息。
///
/// 不变量：进入 RoundContext 的 history 不得包含本轮用户输入——本轮输入仅由
/// RoundContext.userInput 承载，各阶段组装器会在末尾统一追加一次。正常发送
/// 时 user 消息到 persisting 阶段才落库，history 天然不含本轮输入；但"重新
/// 生成"刻意保留 user_N 在数据库中（Fork 语义），重载 history 后该不变
/// 量被打破，若不剔除，同一条用户消息会进 LLM 上下文两次。
///
/// 仅剔除末尾连续匹配项（理论上至多一条），其余位置的同文消息一律不动——
/// 用户故意重复发送同样内容是合法剧情输入，不在此处去重。
List<ChatMessage> stripTrailingDuplicateUserInput(
  List<ChatMessage> history,
  String userInput,
) {
  var end = history.length;
  while (end > 0) {
    final last = history[end - 1];
    if (last.role != 'user' || last.content != userInput) break;
    end--;
  }
  if (end == history.length) return history;
  return history.sublist(0, end);
}

/// 删轮/编辑重发后回滚叙事时间的
/// 唯一取值口径。
///
/// `experiences.last` 不可靠：getAllExperiences 按 turnNumber 排序，同轮
/// 并列（手动压缩插入的同轮 macro、同轮多条 micro）次序不定，且无
/// narrativeTime 的行会把会话时间清空（世界状态条时间消失，下一轮
/// persist 后才自愈）。两模式控制器统一倒序找最后一条 narrativeTime
/// 非空的记忆；全空时返回 null（回退到初始时间）。
String? latestNarrativeTimeOf(List<ExperientialMemory> experiences) {
  for (final experience in experiences.reversed) {
    final time = experience.narrativeTime;
    if (time != null && time.isNotEmpty) return time;
  }
  return null;
}

// ──  turn 单一事实源：会话级轮次号公式统一工具 ─────────────────────────
//
//  轮次号推导曾有四套公式并存（count 系 / index 奇偶系 /
// length 系），压缩边界落在 user 消息时互相分裂，导致孤儿 assistant、
// 同事务双轮号、记忆撞号、过程小窗查不到等连锁缺陷。
//
// 本组函数是公式侧的唯一实现：所有「从可见消息列表推导轮次号」的调用点
// （UI 三处 + 控制器）一律引用此处，不得再地推导算。权威来源仍是
// `chat_sessions.next_turn` 计数器（见 [resolveTurnNumber]），公式仅在
// 计数器未物化（NULL，存量会话）时惰性回退。

/// 统计消息列表中的真实对话消息数（user/assistant，排除摘要卡等 system 消息）
///
/// turnNumber 推导必须基于真实对话消息而非列表长度——压缩后可见列表
/// 头部会多出一条 system 角色的摘要卡，直接 length ~/ 2 会把它算进配对。
int countDialogueMessages(Iterable<ChatMessage> messages) {
  return messages
      .where((m) => m.role == 'user' || m.role == 'assistant')
      .length;
}

/// 已完成的对话轮数（压缩基数 + 可见真实对话轮数）
///
/// 「第 X–Y 轮」标注、Fork 窗口、artifacts 键查找等已完成轮视角统一走本式。
int completedTurnCount({
  required int compactedTurnBase,
  required Iterable<ChatMessage> messages,
}) {
  return compactedTurnBase + countDialogueMessages(messages) ~/ 2;
}

/// 公式推导的下一轮轮次号（已完成轮数 + 1）
///
/// 仅用于 [resolveTurnNumber] 的惰性回退与计数器物化前的兜底，
/// 不要直接在业务代码中调用（一律经 [resolveTurnNumber]）。
int formulaNextTurnNumber({
  required int compactedTurnBase,
  required Iterable<ChatMessage> messages,
}) {
  return completedTurnCount(
        compactedTurnBase: compactedTurnBase,
        messages: messages,
      ) +
      1;
}

/// 轮次号单一事实源解析：`chat_sessions.next_turn` 计数器优先，NULL 回退公式
///
/// 存量会话（schema < 47 物化前）nextTurn 为 null，按公式惰性兼容；
/// 首次轮次写入后计数器即物化，公式与计数器在干净状态下恒等。
int resolveTurnNumber({
  required int? nextTurn,
  required int compactedTurnBase,
  required Iterable<ChatMessage> messages,
}) {
  return nextTurn ??
      formulaNextTurnNumber(
        compactedTurnBase: compactedTurnBase,
        messages: messages,
      );
}

/// 消息所在轮次号（role 感知配对推导，替代 index 奇偶公式）
///
/// 旧 index 奇偶系（`(i+1)~/2` / `(i+2)~/2`）在列表头部出现孤儿 assistant
/// 或摘要卡错位时分裂；本实现按「消息前方的真实对话消息数」配对：
/// - assistant 消息：完成第 `base + (前方对话数 + 1) ~/ 2` 轮
/// - user 消息：开启第 `base + 前方对话数 ~/ 2 + 1` 轮
///
/// 消息不在列表中返回 null。
int? turnNumberForMessage({
  required ChatMessage message,
  required List<ChatMessage> messages,
  required int compactedTurnBase,
}) {
  final index = messages.indexWhere((m) => m.messageId == message.messageId);
  if (index < 0) return null;
  final dialogueBefore = countDialogueMessages(messages.take(index));
  return message.role == 'assistant'
      ? compactedTurnBase + (dialogueBefore + 1) ~/ 2
      : compactedTurnBase + dialogueBefore ~/ 2 + 1;
}
