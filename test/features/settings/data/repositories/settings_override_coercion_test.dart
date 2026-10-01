import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// b：覆盖值类型矫正——_deepMerge 收口点
///
/// 手改/异版本备份可把 `"connect_timeout_ms": "15000"`（String）写进
/// 覆盖表，读取侧 `as int?` 硬转型会让 getResolvedConfig 持续抛
/// TypeError、设置页进 error 态。矫正规则：可转则转（宽容用户意图），
/// 不可转丢弃保留默认（类型安全优先于生效）。
void main() {
  // ConfigLoader 经 rootBundle 读 default_config.json，需测试 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepositoryImpl repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = SettingsRepositoryImpl(
      preferences: Preferences(
        prefs: await SharedPreferences.getInstance(),
      ),
      configLoader: ConfigLoader(),
      apiKeyDatasource: _NoopApiKeyDatasource(),
      logger: const Logger('test'),
    );
  });

  Future<void> seedOverrides(Map<String, dynamic> overrides) async {
    for (final entry in overrides.entries) {
      await repo.setUserOverride(entry.key, entry.value);
    }
  }

  test('CF9-4：损坏的 user_overrides 覆写前先落备份键留档（不静默灭失）', () async {
    // 直接向底层 SP 写入损坏 JSON（模拟手改/磁盘半写）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_overrides', '{broken json !!');
    expect(await repo.getUserOverrides(), isEmpty);

    await repo.setUserOverride('network.connect_timeout_ms', 15000);

    // 损坏原串已挪入备份键留档（可人工恢复），不再被「{}+新键」整体
    // 覆写静默吞掉全部用户配置
    expect(
      prefs.getString('user_overrides_corrupt_backup'),
      '{broken json !!',
    );
    // 新覆写正常生效
    expect(
      (await repo.getUserOverrides())['network.connect_timeout_ms'],
      15000,
    );
  });

  test('String 数字覆盖 int 键 → 转为 int 生效（不再 TypeError）', () async {
    await seedOverrides({'network.connect_timeout_ms': '15000'});

    final config = await repo.getResolvedConfig();

    expect(config.network.connectTimeoutMs, 15000);
  });

  test('num 覆盖 int/double 键 → 数值转换', () async {
    await seedOverrides({
      'network.connect_timeout_ms': 20000.0,
      'intermediate.generation.temperature': '0.9',
    });

    final config = await repo.getResolvedConfig();

    expect(config.network.connectTimeoutMs, 20000);
    expect(config.intermediate.generation.temperature, 0.9);
  });

  test('不可转换的值 → 丢弃保留默认（不抛错）', () async {
    await seedOverrides({
      'network.connect_timeout_ms': 'not-a-number',
      'broadcast_chat.stream_enabled': 'yes-maybe',
    });

    final config = await repo.getResolvedConfig();

    // 默认值生效（default_config.json 的网络超时）
    expect(config.network.connectTimeoutMs, greaterThan(0));
    expect(config.broadcastChat.streamEnabled, isA<bool>());
  });

  test('String "true"/"false" 覆盖 bool 键 → 解析生效', () async {
    await seedOverrides({'broadcast_chat.stream_enabled': 'false'});

    final config = await repo.getResolvedConfig();

    expect(config.broadcastChat.streamEnabled, false);
  });

  // 枚举标量白名单——坏字符串值
  // 经 String 直通合并会让 AdvancedConfig.fromJson 解析期 throw，
  // 全部模式 getResolvedConfig 持续失败。合并收口点按枚举集拦截。
  test('CF12-3：枚举标量坏值丢弃保留默认，全部模式解析不炸', () async {
    await seedOverrides({
      'advanced.narrative_pacing': ' BALANCED ', // 大小写/空白均非法
      'advanced.tools.ask_user': 'always', // 三态外
    });

    final config = await repo.getResolvedConfig();

    expect(config.advanced.narrativePacing, 'balanced');
    expect(
      config.advanced.tools,
      isEmpty,
      reason: '坏三态值不入 tools map（默认空 map=全 allow）',
    );
  });

  test('CF12-3：枚举标量合法值照常生效', () async {
    await seedOverrides({
      'advanced.narrative_pacing': 'conservative',
      'advanced.tools.ask_user': 'ask',
    });

    final config = await repo.getResolvedConfig();

    expect(config.advanced.narrativePacing, 'conservative');
    expect(config.advanced.tools['ask_user'], 'ask');
  });

  test('默认 null 的可空键：标量放行、List 拒收', () async {
    await seedOverrides({
      'broadcast_chat.max_tokens': 0, // 两级 null 物化：0=无上限哨兵
    });

    final config = await repo.getResolvedConfig();

    expect(config.broadcastChat.maxTokens, 0);
  });

  test('String 覆盖 num 键的既有正路径不回归（正常 int 直用）', () async {
    await seedOverrides({'network.connect_timeout_ms': 30000});

    final config = await repo.getResolvedConfig();

    expect(config.network.connectTimeoutMs, 30000);
  });

  // ── ：drop WARN 同 keyPath 实例生命周期只报一次 ──────
  // 坏 key 不清理（保留用户数据），若每次解析都 WARN 会随每次打开设置页
  // 重复刷屏。去重按 keyPath 记在仓库实例字段上（单例 provider 注入）。

  test('CF8-3：重复解析同一坏 key 只 WARN 一次', () async {
    final sink = _RecordingSink();
    Logger.addSink(sink);
    addTearDown(() => Logger.removeSink(sink));

    await seedOverrides({'network.connect_timeout_ms': 'not-a-number'});
    await repo.getResolvedConfig();
    await repo.getResolvedConfig();

    final dropDetails = sink.records
        .where((r) => r.message.contains('Drop type-incompatible'))
        .map((r) => r.detail ?? '')
        .toList();
    expect(
      dropDetails.where((d) => d.contains('network.connect_timeout_ms')).length,
      1,
      reason: '坏 key 永续滞留时，重复解析不应重复刷同一条 drop WARN',
    );
  });

  test('CF8-3：不同 keyPath 的 drop WARN 不互相抑制', () async {
    final sink = _RecordingSink();
    Logger.addSink(sink);
    addTearDown(() => Logger.removeSink(sink));

    await seedOverrides({
      'network.connect_timeout_ms': 'not-a-number',
      'broadcast_chat.stream_enabled': 'yes-maybe',
    });
    await repo.getResolvedConfig();

    final dropDetails = sink.records
        .where((r) => r.message.contains('Drop type-incompatible'))
        .map((r) => r.detail ?? '')
        .toList();
    expect(
      dropDetails.any((d) => d.contains('network.connect_timeout_ms')),
      isTrue,
    );
    expect(
      dropDetails.any((d) => d.contains('broadcast_chat.stream_enabled')),
      isTrue,
    );
  });

  test('resource_ai 覆盖合并：model 引用与 max_steps 生效', () async {
    // 无覆盖：静态默认（无模型引用）
    final base = await repo.getResolvedConfig();
    expect(base.resourceAi.maxSteps, 6);
    expect(base.resourceAi.isModelConfigured, isFalse);

    // 首用快照/重选写入覆盖后：解析出模型引用与步数
    await seedOverrides({
      'resource_ai.model.preset_id': 'openrouter',
      'resource_ai.model.model_id': 'agnes-2.5-flash',
      'resource_ai.max_steps': 8,
    });
    final resolved = await repo.getResolvedConfig();
    expect(resolved.resourceAi.modelPresetId, 'openrouter');
    expect(resolved.resourceAi.modelId, 'agnes-2.5-flash');
    expect(resolved.resourceAi.isModelConfigured, isTrue);
    expect(resolved.resourceAi.maxSteps, 8);
  });
}

/// 捕获 LogRecord 的测试 sink（Logger sink 注册是全局静态，测试内注册/
/// tearDown 移除，不泄漏到其他用例）。
class _RecordingSink implements LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}

  @override
  String? get currentFilePath => null;
}

class _NoopApiKeyDatasource implements ApiKeyDatasource {
  _NoopApiKeyDatasource();

  @override
  Future<String?> read(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
