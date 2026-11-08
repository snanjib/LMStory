import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// r3 退出/恢复场景共用的真实页面脚手架（MyApp+MainLayout+真实遮罩）。
///
/// 隔离纪律（勿合并回单文件多 testWidgets）：locale 变更会打到上一
/// 测试拆树后 defunct 的 slang TranslationProvider（setState-after-
/// dispose），并连带打断次轮首帧的 postFrame 链使 MainLayout 启动门
/// 被跳过；rootBundle 亦有跨测试残留。故本目录每个场景文件只持一个
/// testWidgets（flutter test 每文件独立 isolate，互不可见）。
class DemoExitHarness {
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'demo_exit_resume',
  );
  late final File demoFile = File('${tmpDir.path}/demo.db');
  late final AppDatabase realDb = AppDatabase.forTesting(NativeDatabase.memory());
  late final Preferences realPrefs = Preferences();

  Future<void> setUp() async {
    await LocaleSettings.setLocaleRaw('zh');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_completed': false,
    });
  }

  Future<void> tearDown() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  }

  Widget host(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MyApp(),
    );
  }

  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  DemoRuntime buildRuntime() {
    return DemoRuntime(
      realDatabase: realDb,
      preferences: realPrefs,
      secureStorage: SecureStorage(),
      stateStore: DemoStateStore(directory: tmpDir),
      databaseOpener: () async =>
          AppDatabase.forTesting(NativeDatabase(demoFile)),
    );
  }

  ProviderContainer buildContainer(DemoRuntime runtime) {
    final rootContainer = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(realDb),
        preferencesProvider.overrideWithValue(realPrefs),
        secureStorageProvider.overrideWithValue(SecureStorage()),
        demoRuntimeProvider.overrideWith((ref) => runtime),
      ],
    );
    return rootContainer;
  }

  /// 挂载 Demo 作用域（接受邀请，到向导首页步）。
  Future<DemoRuntime> mountDemo(WidgetTester tester) async {
    final runtime = buildRuntime();
    final rootContainer = buildContainer(runtime);
    addTearDown(rootContainer.dispose);
    await tester.pumpWidget(host(rootContainer));
    // 等待启动检查门完成 load（文件 I/O 在 fake async 下需真实时间片）
    var loaded = false;
    for (var i = 0; i < 160 && !loaded; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      loaded = runtime.loaded;
    }
    expect(loaded, isTrue, reason: '运行状态加载完成');
    // 等待邀请弹窗（门控通过后首帧渲染）
    var inviteShown = false;
    for (var i = 0; i < 80 && !inviteShown; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      inviteShown = find.text('立即体验').evaluate().isNotEmpty;
    }
    expect(inviteShown, isTrue, reason: '邀请弹窗出现');

    await tester.tap(find.text('立即体验'), warnIfMissed: false);
    await settle(tester);
    expect(runtime.scopeActive, isTrue, reason: '前置：Demo 作用域已挂载');
    return runtime;
  }

  /// 清理：退出作用域 + 拆树 + 推过 20s 备份延迟时钟（消除 pending timer）。
  Future<void> teardownScope(WidgetTester tester, DemoRuntime runtime) async {
    await runtime.exitKeepData();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
  }
}
