import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// 提示词预览用的固定模拟输入（预览功能）。
///
/// 预览页面用这套固定示例数据模拟一次「第三轮」故事对话，让用户直观看到
/// 当前提示词配置下，四步生成中四个 LLM 请求实际发给 LLM 的完整 messages。
///
/// 四步流程对应数据：
/// - generating：[userInput] + [history] → 生成内容
/// - extracting：[userInput] + [history] → 关键词
/// - reviewing：[generated] + [retrievedMemories] + [history] + [userInput] → 回复
/// - summarizing：[reply] → 事件摘要
///
/// 设计原则：
/// - **固定不变**：每次预览用相同输入，便于对比调整提示词前后的差异。
/// - **真实感**：内容为连贯的奇幻冒险剧情，长度接近实际使用，能体现
///   history 拼接、生成内容注入、记忆注入的真实效果。
/// - **2 轮历史**：currentTurnNumber=3，含 2 轮（4 条）历史消息，能展示
///   token 预算缩减但不触发（contextWindow=32768 足够容纳）。
class IntermediatePreviewMockData {
  IntermediatePreviewMockData._();

  /// 模拟的当前用户输入
  static const String userInput =
      '我推开密室尽头的石门，一阵腐朽的冷风扑面而来。火把的光芒里，墙上挂着一幅褪色的画像——画中人的眼睛似乎正盯着我。';

  /// 模拟的历史对话（2 轮 = 4 条消息，第一、二轮）
  ///
  /// 内容连贯，体现故事进展：抵达古堡 → 遇到守门人 → 进入密室。
  static List<ChatMessage> get history => [
        ChatMessage(
          messageId: 'mock-user-1',
          sessionId: 'mock-session',
          role: 'user',
          content: '我是一名流浪的考古学者，在山间迷路三天后，终于看见了一座被藤蔓吞噬的古堡。我推开了生锈的铁门。',
          createdAt: DateTime(2026, 7, 9, 10),
        ),
        ChatMessage(
          messageId: 'mock-assistant-1',
          sessionId: 'mock-session',
          role: 'assistant',
          content:
              '铁门发出刺耳的呻吟，惊起梁上数只乌鸦。门厅高大而幽暗，尘埃在斜射的光柱中翻飞。正前方一座断裂的石阶通向黑暗，两侧走廊尽头各有一盏熄灭的壁灯。空气中弥漫着陈年霉味，还夹杂着一丝若有若无的甜香——像是很久以前焚过的熏香，至今未散。',
          createdAt: DateTime(2026, 7, 9, 10, 1),
        ),
        ChatMessage(
          messageId: 'mock-user-2',
          sessionId: 'mock-session',
          role: 'user',
          content: '我点燃壁灯，沿着右侧走廊深入。走廊尽头是一扇雕花橡木门，门后传来低沉的吟唱声。',
          createdAt: DateTime(2026, 7, 9, 10, 5),
        ),
        ChatMessage(
          messageId: 'mock-assistant-2',
          sessionId: 'mock-session',
          role: 'assistant',
          content:
              '壁灯的火苗在你经过时诡异地摇曳，仿佛被某种看不见的气流扰动。走廊墙壁上绘着斑驳的壁画：一群身着长袍的人围成圆圈，中央是一口盛满液体的石盆。吟唱声愈发清晰，是古语，每一个音节都像是在叩击你的颅骨。橡木门虚掩着，门缝透出幽蓝色的微光。',
          createdAt: DateTime(2026, 7, 9, 10, 6),
        ),
      ];

  /// 模拟的生成内容
  static const String generated =
      '石门在身后沉重地合拢。密室不大，四壁刻满了与走廊壁画相同的符文。正中央的祭坛上摆放着一具水晶棺椁，棺中躺着画中那位女子——面容栩栩如生，仿佛只是沉睡。墙上的画像与棺中人别无二致，唯有画中人的眼睛是睁开的，正随着你的移动缓缓转动。空气中的甜香浓烈到了令人眩晕的程度。';

  /// 模拟的压缩摘要（修复 2026-08-23：预览需呈现压缩过的会话中
  /// 实际存在的第 2 条 system 摘要消息，否则"预览即所得"名不副实）
  static const String compactionSummary = '【前情摘要】你在暴雨夜进入古堡，在门厅壁画上认出长袍人围圈祭祀的场景，'
      '并在二楼书房找到记事本残页，得知堡中女主人与某种古老仪式有关。'
      '你循着甜香与符文指引来到地下走廊，推开尽头刻有双环纹章的石门。';

  /// 模拟的回复正文
  ///
  /// reviewing 步骤在生成内容基础上融合检索记忆后的最终回复。
  /// summarizing 步骤以此作为输入生成事件摘要。
  static const String reply =
      '石门在身后沉重地合拢，符文在火光中微微闪烁。密室中央的水晶棺椁中躺着画中那位女子——面容栩栩如生。墙上的画像与棺中人别无二致，唯有画中人的眼睛是睁开的，随着你的移动缓缓转动。你想起壁画上围圈的长袍人与石盆，意识到这甜香或许与某种古老的祭祀有关。棺椁旁的符文似乎在引导你触碰什么，但画中人的目光让你脊背发凉——她在等待你的选择。';

  /// 模拟的检索记忆（2 条，来自第一、二轮的事件摘要）
  static List<ScoredMemory> get retrievedMemories => [
        ScoredMemory(
          memory: ExperientialMemory(
            memoryId: 'mock-mem-1',
            sessionId: 'mock-session',
            summary: '主角抵达被藤蔓吞噬的古堡，推开生锈铁门进入幽暗门厅，闻到陈年霉味与残留熏香。',
            importance: 3,
            tags: const ['古堡', '抵达', '门厅'],
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
            summary: '主角沿右侧走廊深入，见到壁画（长袍人围圈、石盆）与雕花橡木门，门后传来古语吟唱与幽蓝微光。',
            importance: 4,
            tags: const ['壁画', '吟唱', '橡木门', '古语'],
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
