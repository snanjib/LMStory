import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/failure_bar.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// FailureBar Widget 测试
///
/// 验证：
/// 1. 收起态：通俗提示 + 重试/清空按钮，不显示技术详情
/// 2. 展开态：点击展开箭头后显示技术详情（错误码/HTTP状态/失败阶段/错误类型/建议操作/原始异常）
/// 3. HTTP 状态 null 时不显示 HTTP 状态行
/// 4. rawError null 时不显示原始异常区
/// 5. reduced-motion 兜底（accessibleNavigation=true 时不崩溃，详情可见）
/// 6. 重试/清空按钮回调
///
/// 权威设计：DOC-06B §6.4、 计划。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child, {bool accessibleNavigation = false}) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(accessibleNavigation: accessibleNavigation),
            child: child,
          ),
        ),
      ),
    );
  }

  FailureContext buildContext({
    ErrorCategory category = ErrorCategory.auth,
    int? httpStatus = 401,
    String? rawError = 'AppHttpException: Unauthorized',
    String? suggestionOverride,
  }) {
    return FailureContext(
      errorCode: 'E010',
      failedPhase: IntermediatePhase.generating,
      errorMessage: '生成失败',
      retryable: true,
      errorCategory: category,
      httpStatus: httpStatus,
      rawError: rawError,
      suggestionOverride: suggestionOverride,
    );
  }

  group('FailureBar 收起态', () {
    testWidgets('1. 显示通俗提示 + 重试/清空按钮，不显示技术详情', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      // 通俗提示可见
      expect(find.text('生成失败'), findsOneWidget);
      // 重试/清空按钮可见
      expect(find.text('整轮重试'), findsOneWidget);
      expect(find.text('清空本轮'), findsOneWidget);
      // 技术详情不可见（收起态）
      expect(find.text('技术详情'), findsNothing);
      expect(find.text('E010'), findsNothing);
      expect(find.text('401'), findsNothing);
    });
  });

  group('FailureBar 展开态', () {
    testWidgets('2. 点击展开箭头后显示技术详情', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      // 点击展开箭头
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // 技术详情区可见
      expect(find.text('技术详情'), findsOneWidget);
      expect(find.text('E010'), findsOneWidget);
      expect(find.text('401'), findsOneWidget);
      expect(find.text('生成回复'), findsOneWidget); // phaseLabels.generating
      expect(find.text('认证'), findsOneWidget); // categoryLabels.auth
      expect(find.text('建议操作'), findsOneWidget);
      expect(
        find.text('API Key 无效或无权限，请检查供应商配置'),
        findsOneWidget,
      ); // suggestedActions.auth
      expect(find.text('原始异常'), findsOneWidget);
      expect(find.text('AppHttpException: Unauthorized'), findsOneWidget);
    });

    testWidgets('2b. request 类别显示「请求被拒绝」与调整建议', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(
              category: ErrorCategory.request,
              httpStatus: null,
              rawError: 'Invalid JSON payload received.',
            ),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      expect(find.text('请求被拒绝'), findsOneWidget);
      expect(
        find.text('请求被模型拒绝（工具或参数不兼容），请调整模型或会话设置后重试'),
        findsOneWidget,
      );
    });

    testWidgets('3. HTTP 状态 null 时不显示 HTTP 状态行', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(httpStatus: null),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // HTTP 状态标签不显示
      expect(find.text('HTTP 状态'), findsNothing);
      // 其他详情仍显示
      expect(find.text('E010'), findsOneWidget);
      expect(find.text('认证'), findsOneWidget);
    });

    testWidgets('4. rawError null 时不显示原始异常区', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(rawError: null),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // 原始异常标签不显示
      expect(find.text('原始异常'), findsNothing);
      // 建议操作仍显示
      expect(find.text('建议操作'), findsOneWidget);
    });

    testWidgets('suggestionOverride 优先于分类通用建议', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(
              category: ErrorCategory.config,
              suggestionOverride: '导演主模型未配置：前往「设置」配置',
            ),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // 覆盖文案显示
      expect(find.text('导演主模型未配置：前往「设置」配置'), findsOneWidget);
      // 通用 config 建议不再出现
      expect(find.text('请前往设置配置 API 供应商和模型'), findsNothing);
    });

    testWidgets('4b. 点击展开箭头再次点击收起 → 技术详情隐藏', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      // 展开
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('技术详情'), findsOneWidget);

      // 再次点击收起
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('技术详情'), findsNothing);
    });
  });

  group('FailureBar reduced-motion', () {
    testWidgets('5. accessibleNavigation=true 时详情可见（瞬时切换兜底）', (tester) async {
      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(),
            onRetry: () {},
            onClear: () {},
          ),
          accessibleNavigation: true,
        ),
      );

      // 点击展开箭头
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // 技术详情可见（duration=Duration.zero 路径不崩溃）
      expect(find.text('技术详情'), findsOneWidget);
      expect(find.text('E010'), findsOneWidget);
    });
  });

  group('FailureBar 按钮回调', () {
    testWidgets('6. 点击重试/清空按钮触发回调', (tester) async {
      var retryCalled = false;
      var clearCalled = false;

      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(),
            onRetry: () => retryCalled = true,
            onClear: () => clearCalled = true,
          ),
        ),
      );

      // 点击清空按钮
      await tester.tap(find.text('清空本轮'));
      expect(clearCalled, isTrue);

      // 点击重试按钮
      await tester.tap(find.text('整轮重试'));
      expect(retryCalled, isTrue);
    });
  });

  group('FailureBar 复制报错（2026-08-17）', () {
    testWidgets('7. 一键复制完整故障报告（含原始异常全文）+ SnackBar 反馈', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<Object?, Object?>?;
            copied = args?['text'] as String? ?? args?['data'] as String?;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        wrap(
          FailureBar(
            failureContext: buildContext(
              rawError:
                  'AppHttpException: Unauthorized (api_key: sk-1234567890abc, '
                  'Authorization: Bearer sk-secrettoken999)',
            ),
            onRetry: () {},
            onClear: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      // 剪贴板内容 = 结构化故障报告（字段齐全，rawError 不截断）
      expect(copied, isNotNull);
      expect(copied, contains('[LMStory 故障报告]'));
      expect(copied, contains('错误码: E010'));
      expect(copied, contains('HTTP 状态: 401'));
      expect(copied, contains('提示信息: 生成失败'));
      expect(copied, contains('原始异常: AppHttpException: Unauthorized'));
      // 脱敏：API Key / Bearer 令牌不出现在剪贴板里
      expect(copied, contains('api_key: ***'));
      expect(copied, contains('Authorization: ***'));
      expect(copied, isNot(contains('sk-1234567890abc')));
      expect(copied, isNot(contains('sk-secrettoken999')));

      // SnackBar 反馈
      expect(find.text('已复制完整报错信息'), findsOneWidget);
    });
  });
}
