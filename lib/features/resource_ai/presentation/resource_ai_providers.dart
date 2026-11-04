/// resource_ai 页面装配 providers（controller 工厂可被测试覆写）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_json_builder.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';

/// controller 异步工厂（session 需先载入 skill 注册表）。
typedef ResourceAiControllerBuilder = Future<ResourceAiController> Function({
  required DraftKind kind,
  String? targetCardId,
  String? targetBookId,
  String? targetSummary,
  String? originalRawJson,
});

final resourceAiControllerBuilderProvider =
    Provider<ResourceAiControllerBuilder>((ref) {
  return ({
    required kind,
    targetCardId,
    targetBookId,
    targetSummary,
    originalRawJson,
  }) async {
    final session = await ref.read(resourceAiSessionProvider.future);
    final config = await ref.read(resourceAiConfigProvider.future);
    // 经 DI 取网关实现（core/agent 只留抽象）
    final runner = AgentRunner(
      gateway: ref.watch(agentLlmGatewayProvider),
    );
    return ResourceAiController(
      runner: runner,
      session: session,
      saveService: ResourceAiSaveService(
        repository: ref.read(resourceLibraryRepositoryProvider),
      ),
      resolveNaming: (presetId, modelId) => ref
          .read(configurationResolverProvider)
          .resolvePresetModelNamingConfig(
            presetId,
            modelId,
          ),
      config: config,
      kind: kind,
      initialDraft: _initialDraft(
        kind,
        originalRawJson,
        targetSummary,
      ),
      targetCardId: targetCardId,
      targetBookId: targetBookId,
      targetSummary: targetSummary,
      originalRawJson: originalRawJson,
    );
  };
});

/// 编辑模式预填：原文 JSON → 草稿（条目 id=原书 uid，extensions 整包带回）。
DraftState? _initialDraft(
  DraftKind kind,
  String? originalRawJson,
  String? targetSummary,
) {
  if (originalRawJson == null || targetSummary == null) return null;
  final dynamic decoded;
  try {
    decoded = jsonDecode(originalRawJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final raw = Map<String, dynamic>.from(decoded);
  return kind == DraftKind.characterCard
      ? DraftState.empty(kind).withCard(cardDraftFromJson(raw))
      : DraftState.empty(kind).withBook(worldbookDraftFromJson(raw));
}
