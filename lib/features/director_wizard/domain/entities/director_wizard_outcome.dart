import 'package:flutter/foundation.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';

/// 导演向导完成产物：三步收集完毕后随 pop 交付给接线方（MainLayout）。
///
/// 只携带「本会话需要的配置」——全局默认（broadcast_chat 两键、
/// advanced.phase_models.generating_*、嵌入两键）的写入在向导页内
/// 按分支完成，不经过本产物（写入时序见完成事务）。
@immutable
class DirectorWizardOutcome {
  const DirectorWizardOutcome({
    required this.phaseModels,
    this.systemPromptOverride,
    this.characterInitPrompt,
    this.characterCardId,
  });

  /// 本会话 GM（generating）覆盖；两个分支都携带。
  final SessionPhaseModels phaseModels;

  /// 项目规则步确认产物；null = 跳过规则步，跟随全局兜底
  /// （物化语义：null 才回退全局快照，'' 会变成显式无规则）。
  final String? systemPromptOverride;

  /// 「初始化你的角色」自由描述（问卷路）：随草稿带至会话
  /// （characterInitPrompt 列），第 1 轮尾部一次性注入；null = 未启用。
  final String? characterInitPrompt;

  /// 「初始化你的角色」所选角色卡 id：草稿物化时走资料通道应用，
  /// id 留档（characterInitCardId 列）；null = 未启用。
  final String? characterCardId;
}
