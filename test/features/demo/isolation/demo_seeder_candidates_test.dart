import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_seeder.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';

/// 播种器候选清单回归：
/// - 传候选列表 → 对话模型清单=候选虚拟 id 与展示名（演示命名空间）；
/// - 空表回退 → 旧单模型行为不变（兼容路径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DemoSecureStorage secure;
  late DemoPreferences prefs;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secure = DemoSecureStorage();
    prefs = DemoPreferences();
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<Map<String, dynamic>>> seededModels() async {
    final rows =
        await db.customSelect('SELECT cached_models FROM api_presets').get();
    final raw = rows.single.read<String>('cached_models');
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  test('候选列表进播种：五个对话模型 + 一个嵌入模型，展示名按候选', () async {
    final candidates = <DemoCandidate>[
      const DemoCandidate(
        id: 'glm-5.3',
        sourceModelId: 'glm-5.3',
        virtualModelId: 'demo-narrator-glm',
        locale: 'zh-CN',
        assetPath: 'a.json',
        isDefault: true,
        displayNameZh: '仿真 · GLM-5.3',
        displayNameEn: 'Sim · GLM-5.3',
      ),
      const DemoCandidate(
        id: 'kimi-k3.1-pro',
        sourceModelId: 'kimi-k3.1-pro',
        virtualModelId: 'demo-narrator-kimi-k3.1-pro',
        locale: 'zh-CN',
        assetPath: 'b.json',
        isDefault: false,
        displayNameZh: '仿真 · Kimi-K3.1-Pro',
        displayNameEn: 'Sim · Kimi-K3.1-Pro',
      ),
    ];
    await seedDemoEnvironment(
      db,
      secure,
      prefs,
      localeTag: 'zh-CN',
      candidates: candidates,
    );

    final models = await seededModels();
    final chat =
        models.where((m) => (m['type'] as String?) != 'embedding').toList();
    final embedding =
        models.where((m) => (m['type'] as String?) == 'embedding').toList();
    expect(chat, hasLength(2));
    expect(embedding, hasLength(1));
    expect(
      chat.map((m) => m['modelId']),
      containsAll(<String>[
        'demo-narrator-glm',
        'demo-narrator-kimi-k3.1-pro',
      ]),
    );
    // 中文 locale 用中文展示名
    expect(
      chat.firstWhere(
        (m) => m['modelId'] == 'demo-narrator-kimi-k3.1-pro',
      )['displayName'],
      '仿真 · Kimi-K3.1-Pro',
    );
  });

  test('空候选表回退旧单模型（兼容路径行为不变）', () async {
    await seedDemoEnvironment(db, secure, prefs, localeTag: 'zh-CN');
    final models = await seededModels();
    final chat =
        models.where((m) => (m['type'] as String?) != 'embedding').toList();
    expect(chat, hasLength(1));
    expect(chat.single['modelId'], DemoSeedIds.chatModelId);
  });
}
