import 'dart:convert';

import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

///  跨轮工作痕迹（长会话退化治理设计 §3-S1，对 R1）。
///
/// 根因：persist 只落 1 条 user + 1 条 assistant 正文，下一轮 surface 重建
/// 只有这两类消息——模型看到的 in-context 示范永远是"输入→成品"，会话
/// 越长"直写"先验越强。本模块在装配期从 [StoryRoundArtifacts] 合成一行
/// 轮工作痕迹（round-work trace），插在对应 assistant 正文之后，恢复
/// "这是一个会查会记的 agent"的历史示范。
///
/// 硬约束：零 schema 改动、不落 chat_messages、不进压缩输入（trace 由
/// 装配期即时合成，压缩读库内历史，天然不参与摘要）；冻结前缀与缓存
/// 断点不受影响（trace 全在历史区）；老会话/失败轮无 artifacts 按缺失
/// 跳过，不伪造。
///
///  跨轮缓存止血：trace 保留边界锚定压缩纪元起点
/// （compactedTurnBase+1），不再按 `lastTurn-8+1` 滑窗截断。滑窗每轮
/// 删一条窗口外 trace，插入序列在滑动边界处每轮变位，跨轮缓存前缀
/// 每轮断裂；锚定后压缩纪元内 trace 区为纯追加（一旦出现的 trace
/// 字节恒定，直到压缩整体重建），跨轮可缓存前缀覆盖压缩点之后的全部
/// 历史。代价：纪元内 trace 随轮数线性累积（每条约一行，全部落在
/// 缓存命中区），压缩边界即自然回收点。

/// 检索类工具（trace 中聚合为「查记忆×N」）
const Set<String> _retrievalTools = {
  'search_story',
  'read_story',
  'query_facts',
  'read_compact_summary',
};

/// 从单轮 artifacts 合成一行 trace（无可用痕迹时返回 null）
///
/// 无工具轮诚实标注「本轮无工具调用，直写正文」——不美化、不伪造；
/// finish_round 是交付动作不算工作工具。
String? roundWorkTraceFor(StoryRoundArtifacts artifact) {
  final workSteps = artifact.agentSteps
      .where(
        (s) =>
            s.toolName != 'finish_round' &&
            s.toolName != 'system' &&
            !s.isRunning,
      )
      .toList();

  final segments = <String>[];

  final retrievalCount = workSteps
      .where((s) => _retrievalTools.contains(s.toolName) && s.isSuccess)
      .length;
  if (retrievalCount > 0) segments.add('查记忆×$retrievalCount');

  if (artifact.factsChanges.isNotEmpty) {
    segments.add('事实+${artifact.factsChanges.length}');
  }

  final eventCount = workSteps
      .where((s) => s.toolName == 'record_event_memory' && s.isSuccess)
      .length;
  if (eventCount > 0) segments.add('记事件×$eventCount');

  final skillNames = <String>[];
  for (final s in workSteps) {
    if (s.toolName != 'read_skill' || !s.isSuccess) continue;
    final name = _skillNameFromArgsPreview(s.argsPreview);
    if (name != null && !skillNames.contains(name)) skillNames.add(name);
  }
  if (skillNames.isNotEmpty) segments.add('读技能:${skillNames.join('、')}');

  if (workSteps.any(
    (s) => s.toolName == 'update_story_anchor' && s.isSuccess,
  )) {
    segments.add('锚点更新');
  }

  final mergeCount = workSteps
      .where((s) => s.toolName == 'merge_entities' && s.isSuccess)
      .length;
  if (mergeCount > 0) segments.add('归并×$mergeCount');

  final spawnCount =
      workSteps.where((s) => s.toolName == 'spawn' && s.isSuccess).length;
  if (spawnCount > 0) segments.add('派子代理×$spawnCount');

  // 标签统一用 workbench-reminder 包裹（与  轮尾自立纪律一致，
  // 声明「工作台提醒，非导演发言」；round-work 内层标签保留供模型定位轮号）
  if (segments.isEmpty) {
    if (workSteps.isEmpty) {
      return wrapWorkbenchReminder(
        '〈round-work n=${artifact.turnNumber}〉本轮无工具调用，直写正文〈/round-work〉',
      );
    }
    // 有工具调用但全部失败/未归类：如实记调用数，不判"无工具"
    return wrapWorkbenchReminder(
      '〈round-work n=${artifact.turnNumber}〉工具调用'
      '${workSteps.length} 次（未见成效）〈/round-work〉',
    );
  }
  return wrapWorkbenchReminder(
    '〈round-work n=${artifact.turnNumber}〉'
    '${segments.join(' · ')}〈/round-work〉',
  );
}

/// read_skill 步骤的技能名提取（argsPreview 是参数 JSON 串）
String? _skillNameFromArgsPreview(String argsPreview) {
  if (argsPreview.isEmpty) return null;
  try {
    final decoded = jsonDecode(argsPreview);
    if (decoded is Map<String, dynamic>) {
      final name = decoded['name'];
      if (name is String && name.isNotEmpty) return name;
    }
  } on FormatException {
    // 旧数据/截断预览：跳过该名字
  }
  return null;
}

/// 历史映射（user/assistant/system）+ 压缩纪元内各轮的 round-work trace
/// 插入（折叠锚点：保留边界 = compactedTurnBase+1，纪元内纯追加）。
///
/// 轮号口径：非摘要 user 消息按序递增（第 k 个 = 绝对轮号
/// [compactedTurnBase] + k，与 compactedTurnBaseFor 同基）；trace 跟在
/// 所属轮的 assistant 正文之后（连续 user 消息对 OpenAI 兼容端无影响，
/// Anthropic 端服务端自动合并同角色 turn——见 anthropic_messages_test）。
List<AgentMessage> mapHistoryWithWorkTraces({
  required List<ChatMessage> history,
  required Map<int, StoryRoundArtifacts> artifacts,
  required int compactedTurnBase,
}) {
  var turn = compactedTurnBase;
  final result = <AgentMessage>[];
  for (final m in history) {
    switch (m.role) {
      case 'user':
        result.add(AgentMessage.user(m.content ?? ''));
        if (!m.isSummary) turn++;
      case 'assistant':
        result.add(AgentMessage.assistant(text: m.content ?? ''));
        final artifact = artifacts[turn];
        if (!m.isSummary && artifact != null) {
          final trace = roundWorkTraceFor(artifact);
          if (trace != null) result.add(AgentMessage.user(trace));
        }
      default:
        result.add(AgentMessage.system(m.content ?? ''));
    }
  }
  return result;
}

// ====================  风格漂移监测（对"模型不知道自己忘了 skill"）====================

/// 漂移判定窗口：读最近 5 轮 artifacts
const int kStyleDriftWindow = 5;

/// 触发阈值：窗口内 ≥2 轮 styleLintHits 非零
const int kStyleDriftMinRounds = 2;

/// 去AI味技能名（抑制判定的 read_skill 目标）
const String kDeaiFlavorSkill = 'deai-flavor';

///  风格漂移判定：harness 用确定性信号检测文风劣化并明确告知。
///
/// 窗口内 ≥2 轮 styleLintHits 非零、且这些轮里没有读过 deai-flavor →
/// 返回一条一次性告知文案（当轮生效，由调用方以 user+workbench-reminder
/// 注入尾部；持续劣化则持续触发——"记住"由 harness 负责，不由模型负责）。
/// 旧数据 styleLintHits=null 不参与统计（不触发也不阻断）。null = 不触发。
String? styleDriftReminderFor(Map<int, StoryRoundArtifacts> artifacts) {
  if (artifacts.isEmpty) return null;
  final recentTurns = artifacts.keys.toList()..sort();
  final windowStart =
      (recentTurns.length - kStyleDriftWindow).clamp(0, recentTurns.length);
  final window = [
    for (final turn in recentTurns.skip(windowStart)) artifacts[turn]!,
  ];

  final hitRounds = window
      .where((a) => (a.agentWorkSummary?.styleLintHits ?? 0) > 0)
      .toList();
  if (hitRounds.length < kStyleDriftMinRounds) return null;

  // 窗口内已重读过规范 → 模型已被告知，本轮不再重复注入
  final hasDeaiRead = window.any(
    (a) => a.agentSteps.any(
      (s) =>
          s.toolName == 'read_skill' &&
          s.isSuccess &&
          _skillNameFromArgsPreview(s.argsPreview) == kDeaiFlavorSkill,
    ),
  );
  if (hasDeaiRead) return null;

  final totalHits = hitRounds.fold<int>(
    0,
    (sum, a) => sum + a.agentWorkSummary!.styleLintHits!,
  );
  return '近几轮正文多次命中写作规范红线（共 $totalHits 处）。动笔前先用 '
      'read_skill 读取 $kDeaiFlavorSkill，按其逐条自查。';
}

// ====================  零工具轮计数（升级闸门数据口径）====================

/// 从最近轮往前统计"连续零记忆轮"数（计数口径；阈值常量
/// kZeroToolEscalateAfter 定义于 agent_session_tools.dart，FinishRoundTool
/// 消费本函数产出的 streak）。
///
/// 一轮计入 = agentSteps 非空且不含 update_facts / record_event_memory
/// 调用（调用即清零，与工具成败无关）；agentSteps 为空的旧轮按"已用
/// 记忆"处理（fail-open，不因数据缺失误升级）。设计原文的
/// "eventSummary == null" 子句在 artifacts 层不可区分兜底合成与模型
/// 手记（collectRound 恒回填），并入工具调用口径实现。
int zeroMemoryRoundStreak(Map<int, StoryRoundArtifacts> artifacts) {
  if (artifacts.isEmpty) return 0;
  final turns = artifacts.keys.toList()..sort();
  var streak = 0;
  for (var i = turns.length - 1; i >= 0; i--) {
    final artifact = artifacts[turns[i]]!;
    // 旧数据（无 agentSteps 留痕）：不计入，终止统计
    if (artifact.agentSteps.isEmpty) break;
    final usedMemory = artifact.agentSteps.any(
      (s) =>
          s.toolName == 'update_facts' || s.toolName == 'record_event_memory',
    );
    if (usedMemory) break;
    streak++;
  }
  return streak;
}
