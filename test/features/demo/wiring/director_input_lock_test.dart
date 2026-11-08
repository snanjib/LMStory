import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_input_lock.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
import 'package:lmstory/i18n/strings.g.dart';

Widget inputApp({bool locked = false}) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: IntermediateChatInput(
            phase: IntermediatePhase.idle,
            onSend: (_) {},
            onCancel: () {},
            isDirector: true,
            locked: locked,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locked=true：输入只读（编辑/粘贴/输入法组合全禁）', (tester) async {
    await tester.pumpWidget(inputApp(locked: true));

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).readOnly,
      isTrue,
      reason: '锁定时编辑/粘贴/输入法组合全部禁用',
    );
  });

  testWidgets('locked=false（默认）：可编辑——正式会话零影响', (tester) async {
    await tester.pumpWidget(inputApp());

    final field = find.byType(TextField);
    expect(
      tester.widget<TextField>(field).readOnly,
      isFalse,
      reason: '默认无锁',
    );
  });

  test('锁控制器：lockTo/release 语义', () {
    final controller = DirectorInputLockController();
    expect(controller.value, isNull);

    controller.lockTo('（固定提示词）');
    expect(controller.value?.fixedText, '（固定提示词）');

    controller.release();
    expect(controller.value, isNull);
  });

  testWidgets('provider 注入链路：Demo 容器 override 后宿主可解析', (tester) async {
    final controller = DirectorInputLockController(
      const DirectorInputLock(fixedText: '（固定）'),
    );
    late DirectorInputLockController resolved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [directorInputLockProvider.overrideWithValue(controller)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              resolved = ref.watch(directorInputLockProvider);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(resolved, same(controller));
    expect(resolved.value?.fixedText, '（固定）');
  });
}
