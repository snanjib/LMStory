import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 提示词预览用的固定模拟输入（预览功能，随界面语言双语）。
///
/// 预览页面用这套固定示例数据模拟一次「第三轮」故事对话，让用户直观看到
/// 当前提示词配置下，六步生成中各 LLM 请求实际发给 LLM 的完整 messages。
/// zh 为古堡探险剧情，en 为原创剧情 The Drowned Bell（内容各自原创，
/// 不互为翻译）；结构性说明与 token 预算口径见原设计（见 git 历史）。
class IntermediatePreviewMockData {
  IntermediatePreviewMockData._();

  /// 模拟的当前用户输入
  static String get userInput =>
      t.settings.intermediate.preview.sample.userInput;

  /// 模拟的历史对话（2 轮 = 4 条消息，第一、二轮）
  static List<ChatMessage> get history => [
        ChatMessage(
          messageId: 'mock-user-1',
          sessionId: 'mock-session',
          role: 'user',
          content: t.settings.intermediate.preview.sample.history1User,
          createdAt: DateTime(2026, 7, 9, 10),
        ),
        ChatMessage(
          messageId: 'mock-assistant-1',
          sessionId: 'mock-session',
          role: 'assistant',
          content: t.settings.intermediate.preview.sample.history1Assistant,
          createdAt: DateTime(2026, 7, 9, 10, 1),
        ),
        ChatMessage(
          messageId: 'mock-user-2',
          sessionId: 'mock-session',
          role: 'user',
          content: t.settings.intermediate.preview.sample.history2User,
          createdAt: DateTime(2026, 7, 9, 10, 5),
        ),
        ChatMessage(
          messageId: 'mock-assistant-2',
          sessionId: 'mock-session',
          role: 'assistant',
          content: t.settings.intermediate.preview.sample.history2Assistant,
          createdAt: DateTime(2026, 7, 9, 10, 6),
        ),
      ];

  /// 模拟的生成内容
  static String get generated =>
      t.settings.intermediate.preview.sample.generated;

  /// 模拟的压缩摘要（预览需呈现压缩过的会话中实际存在的第 2 条
  /// system 摘要消息，保证「预览即所得」）
  static String get compactionSummary =>
      t.settings.intermediate.preview.sample.compactionSummary;

  /// 模拟的回复正文（reviewing 融合检索记忆后的最终回复）
  static String get reply => t.settings.intermediate.preview.sample.reply;

  /// 模拟的检索记忆（2 条，来自第一、二轮的事件摘要）
  static List<ScoredMemory> get retrievedMemories => [
        ScoredMemory(
          memory: ExperientialMemory(
            memoryId: 'mock-mem-1',
            sessionId: 'mock-session',
            summary: t.settings.intermediate.preview.sample.mem1Summary,
            importance: 3,
            tags: t.settings.intermediate.preview.sample.mem1Tags,
            turnNumber: 1,
            createdAt: DateTime(2026, 7, 9, 10, 1),
          ),
          fts5Score: 0.72,
          vectorScore: 0.68,
          temporalScore: 0,
          finalScore: 0.70,
        ),
        ScoredMemory(
          memory: ExperientialMemory(
            memoryId: 'mock-mem-2',
            sessionId: 'mock-session',
            summary: t.settings.intermediate.preview.sample.mem2Summary,
            importance: 4,
            tags: t.settings.intermediate.preview.sample.mem2Tags,
            turnNumber: 2,
            createdAt: DateTime(2026, 7, 9, 10, 6),
          ),
          fts5Score: 0.81,
          vectorScore: 0.75,
          temporalScore: 0,
          finalScore: 0.78,
        ),
      ];

  /// 模拟的当前轮次序号（已有 2 轮，当前为第 3 轮）
  static const int currentTurnNumber = 3;

  /// 模拟的上下文窗口（取常见模型值，足够容纳模拟数据不触发缩减）
  static const int contextWindow = 32768;
}
