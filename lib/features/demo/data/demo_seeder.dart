import 'package:drift/drift.dart' show Variable;
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';

/// 演示环境种子结果
class DemoSeedResult {
  const DemoSeedResult({required this.presetId});

  /// 本次播种创建的虚拟供应商 id（每次播种新建；会话引用它，
  /// 交接时按会话实际引用清除，不依赖固定常量）
  final String presetId;
}

/// 演示环境完整初始化（全新 run 专用）：**清空演示库**后布置虚拟
/// 供应商、占位 Key、内置模板与确定性业务配置。
///
/// 只允许在「首次进入 / 显式重新开始」路径调用——恢复（继续体验）
/// 必须走 [attachDemoEnvironment]，否则会删除用户上一轮的会话成果。
///
/// 虚拟供应商画像（契约 §5.6）：
/// - baseUrl=不可解析保留域；protocol=openaiCompatible；
/// - cachedModels 预置 chat+embedding 两模型——向导已配置分支零 Key
///   输入、零模型拉取、零连接测试即通过真实门控；
/// - 占位 Key 写入内存 SecureStorage——配置解析「跨 preset 借 Key」
///   只能在演示内存内打转。
Future<DemoSeedResult> seedDemoEnvironment(
  AppDatabase db,
  DemoSecureStorage secure,
  DemoPreferences prefs, {
  required String localeTag,
  List<DemoCandidate> candidates = const <DemoCandidate>[],
}) async {
  // 1. 清旧（全新 run 语义；演示库内全部数据皆为演示产物）
  await wipeDemoDatabase(db);
  await secure.deleteAll();

  // 2. 内置模板（builtin-isekai-narrator 就位）
  await TemplateRepositoryImpl(db).ensureBuiltInTemplates();

  // 3. 虚拟供应商
  final isEn = localeTag.toLowerCase().startsWith('en');
  // dioClient/adapterFactory 仅被 fetchModels 等网络路径消费，种子
  // 只做本地建行/更新缓存列表——传未被使用的实例即可（不发请求）。
  final repo = ApiPresetRepositoryImpl(
    database: db,
    apiKeyDatasource: ApiKeyDatasource(secureStorage: secure),
    dioClient: DioClient(),
    adapterFactory: LlmAdapterFactory(),
  );
  final preset = await repo.createPreset(
    name: isEn ? 'Demo models (local replay)' : '演示模型（本地回放）',
    baseUrl: DemoSeedIds.invalidBaseUrl,
  );
  // 对话模型清单 = 候选目录（当前 locale 可用项）；空表回退旧单模型，
  // 保证无目录兜底路径的既有行为不变。全部虚拟 id 都在
  // demo-narrator-* 命名空间内，交接按会话实际引用统一清理。
  final chatModels = candidates.isEmpty
      ? <ModelInfo>[
          ModelInfo(
            modelId: DemoSeedIds.chatModelId,
            displayName: isEn ? 'Demo narrator (local)' : '演示叙事模型（本地）',
            contextWindow: 128000,
          ),
        ]
      : <ModelInfo>[
          for (final c in candidates)
            ModelInfo(
              modelId: c.virtualModelId,
              displayName: c.displayNameFor(localeTag),
              contextWindow: 128000,
            ),
        ];
  await repo.updateModelList(preset.presetId, [
    ...chatModels,
    ModelInfo(
      modelId: DemoSeedIds.embeddingModelId,
      displayName: isEn ? 'Demo embedding (local)' : '演示嵌入模型（本地）',
      type: ModelType.embedding,
    ),
  ]);

  // 4. 占位 Key（内存；键名与 ApiKeyDatasource 同源 api_key_ 前缀）
  await secure.write(
    'api_key_${preset.presetId}',
    DemoSeedIds.placeholderApiKey,
  );

  // 5. 确定性业务配置（含导演入口强制可见——仅内存，不动真实开关）
  await applyDeterministicBusinessConfig(prefs);

  return DemoSeedResult(presetId: preset.presetId);
}

/// 演示环境附着（恢复/继续体验专用）：**不清库**——保留上一轮的
/// 会话、正文、实体、事件与回合状态；只做三件事：
/// 1. 重注入内存占位 Key（secure.deleteAll 只清演示内存 map）；
/// 2. 确保内置模板在位（幂等 upsert，不动数据行）；
/// 3. 业务配置确定性覆写（同全新 run，防真实配置穿透改变流程）。
Future<void> attachDemoEnvironment(
  AppDatabase db,
  DemoSecureStorage secure,
  DemoPreferences prefs, {
  required String localeTag,
  String? presetId,
}) async {
  await secure.deleteAll();
  await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
  final resolved = presetId ?? await findDemoPresetId(db);
  if (resolved != null) {
    await secure.write('api_key_$resolved', DemoSeedIds.placeholderApiKey);
  }
  await applyDeterministicBusinessConfig(prefs);
}

/// 在演示库中定位虚拟供应商 id（恢复路径状态文件缺 seedPresetId 时的
/// 兜底：按缓存模型清单中的演示命名空间模型识别——全部候选虚拟 id
/// 共享 demo-narrator- 前缀，不依赖单一旧常量）
Future<String?> findDemoPresetId(AppDatabase db) async {
  final rows = await db.customSelect(
    'SELECT preset_id FROM api_presets WHERE cached_models LIKE ? LIMIT 1',
    variables: [Variable.withString('%$demoVirtualModelNamespace%')],
  ).get();
  return rows.isEmpty ? null : rows.first.read<String>('preset_id');
}

/// 演示环境确定性业务配置（契约 §5）。
///
/// `user_overrides` 是**单键 JSON**，承载真实用户全部业务覆盖（全局
/// 模型、嵌入、工具权限、预算、提示词等）——逐点分键 remove 无法触及
/// JSON 内部。演示环境将该键整体覆写为空表：解析配置回落 default_
/// config.json 纯默认，回放流程因此确定；真实用户的该键**零修改**
/// （写只进演示 overlay）。外观、语言等独立偏好键不在 user_overrides
/// 内，读穿透继续共享。
///
/// 演示内后续写入（向导嵌入步/GM 键等）经 SettingsRepository 的
/// getUserOverrides→合并→setString 链路落在演示 overlay 上，自洽。
Future<void> applyDeterministicBusinessConfig(DemoPreferences prefs) async {
  await prefs.setString(SettingsRepositoryImpl.userOverridesPrefKey, '{}');
  await prefs.setBool(AdvancedModeFlagNotifier.prefKey, true);
}

/// 清空演示库全部会话与供应商数据（全新 run 语义专用）
Future<void> wipeDemoDatabase(AppDatabase db) async {
  await db.customStatement(
    'DELETE FROM chat_messages; DELETE FROM chat_sessions; '
    'DELETE FROM chat_session_branches; DELETE FROM compaction_points; '
    'DELETE FROM experiential_memories; DELETE FROM memories_fts; '
    'DELETE FROM factual_entities; DELETE FROM factual_attributes; '
    'DELETE FROM factual_memory_history; DELETE FROM factual_fts; '
    'DELETE FROM intermediate_round_artifacts; DELETE FROM message_variants; '
    'DELETE FROM agent_events; DELETE FROM failure_logs; '
    'DELETE FROM api_presets;',
  );
}
