import 'dart:convert';
import 'dart:io';

import 'package:lmstory/features/demo/data/demo_database.dart';

/// 演示运行阶段（契约 §4.1）
enum DemoPhase {
  /// 从未启动（或已彻底放弃）
  idle,

  /// 首问已发出（accepted/declined 由 inviteStatus 区分）
  invited,

  /// 演示进行中（stepId=最后检查点）
  running,

  /// 交接已触发未确认完成（重启自动幂等重跑）
  handoverPending,

  /// 交接完成（会话已入正式库）
  handoverDone,

  /// 用户显式放弃（数据已清）
  abandoned,
}

enum DemoInviteStatus { pending, accepted, declined, notApplicable }

/// 演示运行状态（`<docs>/lmstory_demo/state.json`）
class DemoState {
  const DemoState({
    this.version = 1,
    this.inviteStatus = DemoInviteStatus.pending,
    this.phase = DemoPhase.idle,
    this.runId,
    this.sessionId,
    this.stepId,
    this.seedPresetId,
    this.localeTag = 'zh-CN',
    this.packContentVersion,
    this.formatVersion,
    this.replayProfileId,
    this.capabilitiesHash,
    this.candidateId,
    this.virtualModelId,
    this.packSha256,
    this.updatedAt,
  });

  factory DemoState.fromJson(Map<String, dynamic> json) {
    DemoInviteStatus parseInvite(String? v) => DemoInviteStatus.values
        .firstWhere((e) => e.name == v, orElse: () => DemoInviteStatus.pending);
    DemoPhase parsePhase(String? v) => DemoPhase.values
        .firstWhere((e) => e.name == v, orElse: () => DemoPhase.idle);
    return DemoState(
      version: json['version'] as int? ?? 1,
      inviteStatus: parseInvite(json['inviteStatus'] as String?),
      phase: parsePhase(json['phase'] as String?),
      runId: json['runId'] as String?,
      sessionId: json['sessionId'] as String?,
      stepId: json['stepId'] as String?,
      seedPresetId: json['seedPresetId'] as String?,
      localeTag: json['localeTag'] as String? ?? 'zh-CN',
      packContentVersion: json['packContentVersion'] as String?,
      formatVersion: json['formatVersion'] as int?,
      replayProfileId: json['replayProfileId'] as String?,
      capabilitiesHash: json['capabilitiesHash'] as String?,
      candidateId: json['candidateId'] as String?,
      virtualModelId: json['virtualModelId'] as String?,
      packSha256: json['packSha256'] as String?,
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
    );
  }

  final int version;
  final DemoInviteStatus inviteStatus;
  final DemoPhase phase;
  final String? runId;

  /// 演示库中本 run 物化的会话 id（未物化为 null）
  final String? sessionId;

  /// 最后检查点步骤（DemoStepId.name；null=尚未进入流程）
  final String? stepId;

  /// 本 run 的虚拟供应商 id（恢复路径重注入内存密钥用，不清库）
  final String? seedPresetId;
  final String localeTag;
  final String? packContentVersion;
  final int? formatVersion;
  final String? replayProfileId;
  final String? capabilitiesHash;

  /// 本 run 绑定的候选目录 id（glm-5.3 / deepseek-v4.1-flash / ...）；
  /// 旧单包状态无此字段，恢复时按可证明的默认包身份映射回默认候选
  final String? candidateId;

  /// 本 run 绑定的演示命名空间虚拟模型 id（demo-narrator-*）
  final String? virtualModelId;

  /// 本 run 数据包字节 SHA-256（与候选目录对账，防资产漂移后静默换包）
  final String? packSha256;
  final DateTime? updatedAt;

  DemoState copyWith({
    DemoInviteStatus? inviteStatus,
    DemoPhase? phase,
    String? runId,
    String? sessionId,
    bool clearSessionId = false,
    String? stepId,
    String? seedPresetId,
    String? localeTag,
    String? packContentVersion,
    int? formatVersion,
    String? replayProfileId,
    String? capabilitiesHash,
    String? candidateId,
    String? virtualModelId,
    String? packSha256,
  }) {
    return DemoState(
      version: version,
      inviteStatus: inviteStatus ?? this.inviteStatus,
      phase: phase ?? this.phase,
      runId: runId ?? this.runId,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      stepId: stepId ?? this.stepId,
      seedPresetId: seedPresetId ?? this.seedPresetId,
      localeTag: localeTag ?? this.localeTag,
      packContentVersion: packContentVersion ?? this.packContentVersion,
      formatVersion: formatVersion ?? this.formatVersion,
      replayProfileId: replayProfileId ?? this.replayProfileId,
      capabilitiesHash: capabilitiesHash ?? this.capabilitiesHash,
      candidateId: candidateId ?? this.candidateId,
      virtualModelId: virtualModelId ?? this.virtualModelId,
      packSha256: packSha256 ?? this.packSha256,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'inviteStatus': inviteStatus.name,
        'phase': phase.name,
        if (runId != null) 'runId': runId,
        if (sessionId != null) 'sessionId': sessionId,
        if (stepId != null) 'stepId': stepId,
        if (seedPresetId != null) 'seedPresetId': seedPresetId,
        'localeTag': localeTag,
        if (packContentVersion != null)
          'packContentVersion': packContentVersion,
        if (formatVersion != null) 'formatVersion': formatVersion,
        if (replayProfileId != null) 'replayProfileId': replayProfileId,
        if (capabilitiesHash != null) 'capabilitiesHash': capabilitiesHash,
        if (candidateId != null) 'candidateId': candidateId,
        if (virtualModelId != null) 'virtualModelId': virtualModelId,
        if (packSha256 != null) 'packSha256': packSha256,
        'updatedAt': updatedAt?.toIso8601String(),
      };
}

/// 演示状态文件读写：tmp+rename 原子写；损坏文件按 idle 处理并备份。
class DemoStateStore {
  DemoStateStore({Directory? directory}) : _directory = directory;

  Directory? _directory;
  static const String fileName = 'state.json';

  Future<Directory> _dir() async => _directory ??= await demoDataDirectory();

  Future<File> _file() async => File(
        '${(await _dir()).path}/$fileName',
      );

  Future<DemoState> load() async {
    final file = await _file();
    if (!file.existsSync()) return const DemoState();
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('root not object');
      }
      return DemoState.fromJson(decoded);
    } catch (e) {
      // 损坏：备份 .corrupt 后按全新状态处理（演示数据可重建，
      // 不阻塞应用启动）
      try {
        file.copySync('${file.path}.corrupt');
        file.deleteSync();
      } catch (_) {}
      return const DemoState();
    }
  }

  Future<void> save(DemoState state) async {
    final dir = await _dir();
    final file = File('${dir.path}/$fileName');
    File('${dir.path}/$fileName.tmp')
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
        flush: true,
      )
      ..renameSync(file.path);
  }

  /// 清除状态文件（放弃演示数据时与库文件一并清理）
  Future<void> delete() async {
    final file = await _file();
    for (final path in [
      file.path,
      '${file.path}.tmp',
      '${file.path}.corrupt',
    ]) {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    }
  }
}
