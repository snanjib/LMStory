import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart'
    show apiPresetRepositoryProvider, settingsRepositoryProvider;
import 'package:lmstory/core/di/providers.dart' as di
    show templateRepositoryProvider;
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/shared/streaming_markdown_blocks.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../test_helpers/stub_failure_log_repository.dart';

///  流式渲染性能专项：量化基线基准（2026-09-04 建档）
///
/// 三个场景测「一次合帧 delta 后的 pump 墙钟耗时」（build+layout+paint，
/// tester 环境为 JIT+asserts，绝对值偏大；用途是同机前后对比与规模缩放
/// 观测，不是真机帧率的绝对度量）：
///
/// 1. SimpleMarkdownBody：流式气泡正文从 2k→16k 字增长时的重解析成本
///    （三模式共用的 O(全文) 重解析点，chat 流式气泡直接命中）。
/// 2. ChatModePage：N 条消息会话 + 长文流式输出的整链路单 delta 帧耗时
///   （含整页重建 + 滚动跟随 + markdown 重解析）。
/// 3. DirectorChatBody：R 轮历史 + live 时间线流式增量的单 delta 帧耗时
///    （_buildRows 全量构造 + 装配器现算 + 稿件卡全文重解析）。
///
/// 结果经 print 输出（`flutter test test/perf/ -r expanded`），不设硬阈值
/// 断言（CI 机器差异会抖动）；用例只 sanity 断言测量非零。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('markdown 重解析成本（SimpleMarkdownBody，全文变长）', () {
    for (final targetChars in [2000, 4000, 8000, 16000]) {
      testWidgets('$targetChars字正文：每次增量后的 pump 耗时', (tester) async {
        final doc = _markdownDoc(targetChars);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: _GrowingMarkdownHost(initial: doc.substring(0, 500)),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // 以「行边界」粒度增长（至少 +40 字，取下一个换行边界）：任意
        // 中途切分会触发 flutter_markdown 对未闭合块的 _inlines.isEmpty
        // 断言（设计文档 §一.3 已记录），异常刷屏掩盖测量；行边界粒度
        // 保证每步都是完整块结构，成本口径仍是「全量重解析」。
        final boundaries = <int>[
          for (var i = 0; i < doc.length; i++)
            if (doc.codeUnitAt(i) == 0x0A) i + 1,
        ];
        final times = <double>[];
        var pos = 500;
        var bi = 0;
        while (bi < boundaries.length && boundaries[bi] <= pos) {
          bi++;
        }
        while (pos < targetChars && bi < boundaries.length) {
          var next = boundaries[bi];
          while (bi + 1 < boundaries.length && next - pos < 40) {
            bi++;
            next = boundaries[bi];
          }
          bi++;
          pos = next;
          tester
              .state<_GrowingMarkdownHostState>(
                find.byType(_GrowingMarkdownHost),
              )
              .grow(doc.substring(0, pos));
          final sw = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 32));
          times.add(sw.elapsedMicroseconds / 1000);
        }
        _report('markdown[$targetChars]', times);
        expect(times, isNotEmpty);
      });
    }
  });

  group('冻结前缀流式壳（StreamingMarkdownBody 流式路径）', () {
    for (final targetChars in [4000, 16000]) {
      testWidgets('$targetChars 字流式增长：单帧耗时与长度脱敏', (tester) async {
        final doc = _markdownDoc(targetChars);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: _GrowingStreamingMarkdownHost(
                    initial: doc.substring(0, 500),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final times = <double>[];
        var pos = 500;
        while (pos < targetChars) {
          final next = (pos + 80).clamp(0, doc.length);
          tester
              .state<_GrowingStreamingMarkdownHostState>(
                find.byType(_GrowingStreamingMarkdownHost),
              )
              .grow(doc.substring(0, next));
          pos = next;
          final sw = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 32));
          times.add(sw.elapsedMicroseconds / 1000);
        }
        _report('streamingMarkdown[$targetChars]', times);
        expect(times, isNotEmpty);
      });
    }
  });

  group('纯文本快速路径（T8：无空行中文散文流式，2026-09-10 建档）', () {
    testWidgets('16k 无空行散文追加 100 次：快速路径单帧远低于全文重解析基线', (tester) async {
      final doc = _plainProseDoc(16000);
      // sanity：文档必须命中快速路径前置条件（无空行一整块 + 判纯）
      expect(looksLikePlainText(doc), isTrue);
      expect(markdownBlockStarts(doc), hasLength(1));

      // 基线：同数据同节奏，每帧全文 MarkdownBody 重解析（前的
      // 单块流式路径——切块冻结对无空行散文失效）
      final baseline = await _measurePlainProse(tester, doc, fastPath: false);
      // 快速路径：单块纯文本尾段 Text 直渲（跳过 Markdown 解析）
      final fast = await _measurePlainProse(tester, doc, fastPath: true);

      _report('plainProse baseline[16k, 100 steps]', baseline);
      _report('plainProse fastpath[16k, 100 steps]', fast);

      // 阈值依据（2026-09-10 本机实测，同 testWidgets 内先后测量；
      //  淡入当日复核修订）：
      //   -  建档日：基线（全文 MarkdownBody 重解析）warm 中位
      //     ≈ 48-60ms；快速路径（Text 直渲）≈ 21-25ms；裸 Text 地板
      //     ≈ 27-30ms——Markdown 解析增量（基线的 ~55%）被消除，原
      //     1/5 阈值在「分母含共享地板」下不可达，取 1/2。
      //   -  复核日（机器更快）：基线 warm 中位 ≈ 20.2ms，无淡入
      //     快速路径 ≈ 8.6ms（2.3 倍）；淡入占位盒（预算 12 盒）单位
      //     成本实测 ≈0.11ms/盒，快速路径含淡入 ≈ 9.5-10ms 量级，
      //     1/2 阈值（<10.1ms）余量不足 5%，机器抖动即误红。
      //   - 改取 0.75：两代机型下快速路径均以 ≥40% 余量显著低于基线
      //     （淡入有界开销 ≤ ~1.3ms 不改变量级），语义仍为「显著低于
      //     全文重解析」；由  全量回归时复测记录。
      expect(
        _warmMedian(fast),
        lessThan(_warmMedian(baseline) * 0.75),
        reason: '快速路径单帧墙钟须显著低于全文重解析基线'
            '（含淡入占位盒的有界开销）',
      );
    });
  });

  group('超长单段冻结窗口（2026-10-05 建档）', () {
    testWidgets('16k/32k/64k 恒定到达率追加：单帧成本与长度脱敏', (tester) async {
      final doc16 = _plainProseDoc(16000);
      final doc32 = _plainProseDoc(32000);
      final doc64 = _plainProseDoc(64000);
      // sanity：全部命中快速路径 + 冻结前置（无空行一整块 + 判纯 + 多行）
      for (final doc in [doc16, doc32, doc64]) {
        expect(looksLikePlainText(doc), isTrue);
        expect(markdownBlockStarts(doc), hasLength(1));
      }

      // 口径：**固定步长**（160 码元/32ms，≈真实到达率量级）。活窗内容
      // = 淡入留存窗 × 到达率——与全文长度无关；若按比例步长（100 步
      // 吃完全文），活窗随总长线性膨胀，量的是到达率不是长度。
      final t16 = await _measurePlainProseFixedStep(tester, doc16, 160);
      final t32 = await _measurePlainProseFixedStep(tester, doc32, 160);
      final t64 = await _measurePlainProseFixedStep(tester, doc64, 160);
      _report('plainProse frozen-fixedstep[16k]', t16);
      _report('plainProse frozen-fixedstep[32k]', t32);
      _report('plainProse frozen-fixedstep[64k]', t64);

      // 冻结窗口的长度脱敏断言：64k 单帧中位 < 16k 的 2 倍。冻结在位时
      // 两者同量级（活窗排版 O(留存窗×到达率) + O(n) 残余仅为若干次
      // memcmp/trim 常数遍扫描）；冻结失效（回归）时 O(n) 全文排版令
      // 64k ≈ 4×16k（比例步长基线口径 16k≈12.6ms → 64k≈50ms），必红。
      // 同 testWidgets 内先后测量，机器抖动 ±10-20% 不影响判定。
      expect(
        _warmMedian(t64),
        lessThan(_warmMedian(t16) * 2),
        reason: '冻结窗口下超长单段单帧成本须与全文长度脱敏'
            '（16k/64k 同量级；4× 线性放大 = 冻结失效）',
      );
    });
  });

  group('ChatModePage 整链路单 delta 帧耗时', () {
    for (final messageCount in [100, 300]) {
      testWidgets('$messageCount 条消息 + 8k 字流式正文', (tester) async {
        final session = ChatSession(
          sessionId: 'perf-session',
          title: '性能基准',
          mode: 'chat',
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: 0,
          presetId: 'p1',
          modelId: 'm1',
        );
        final repo = _SeededChatRepository(messageCount);
        final llmService = _ScriptedLlmService();
        final events = StreamController<LlmStreamEvent>();
        llmService.stream = events.stream;
        addTearDown(() => unawaited(events.close()));

        final container = ProviderContainer(
          overrides: [
            chatModeControllerProvider(session).overrideWith((ref) {
              return ChatModeController(
                chatRepository: repo,
                presetRepository: _NoopPresetRepository(),
                settingsRepository: _FakeSettingsRepository(),
                compactionService: _compactionService(),
                llmService: llmService,
                logger: const Logger('test'),
                failureLogRepository: const StubFailureLogRepository(),
                session: session,
                // 基准口径：delta 即时落地（合帧粒度由本测试的喂入节奏控制）
                streamDeltaCoalesceInterval: Duration.zero,
              );
            }),
            settingsRepositoryProvider.overrideWithValue(
              _FakeSettingsRepository(),
            ),
            apiPresetRepositoryProvider.overrideWithValue(
              _NoopPresetRepository(),
            ),
            di.templateRepositoryProvider.overrideWithValue(
              _NoopTemplateRepository(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: SizedBox(
                  width: 800,
                  height: 600,
                  child: ExcludeSemantics(
                    child: ChatModePage(session: session),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        unawaited(
          container
              .read(chatModeControllerProvider(session).notifier)
              .sendMessage('继续'),
        );
        await tester.pump(const Duration(milliseconds: 400));

        // 喂 8k 字流式正文（~80 字/帧合帧粒度），测每帧 pump 墙钟
        final doc = _markdownDoc(8000);
        final times = <double>[];
        var sent = 0;
        while (sent < doc.length) {
          final end = (sent + 80).clamp(0, doc.length);
          events.add(LlmTextDelta(doc.substring(sent, end)));
          sent = end;
          final sw = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 32));
          times.add(sw.elapsedMicroseconds / 1000);
        }
        _report('chatPage[$messageCount msgs, 0→8k]', times);
        expect(times, isNotEmpty);

        events.add(const LlmStreamDone());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 3));
      });
    }
  });

  group('DirectorChatBody 单 delta 帧耗时', () {
    for (final rounds in [10, 30]) {
      testWidgets('$rounds 轮历史 + live 流式增量', (tester) async {
        var state = _directorState(rounds);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: _DirectorBodyHost(
                    state: state,
                    onState: (s) => state = s,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // live 正文增量（每帧 ~60 字追加进末块，对齐 AgentLiveTranscript.appendText）
        final doc = _markdownDoc(6000);
        final times = <double>[];
        var sent = 0;
        while (sent < doc.length) {
          final end = (sent + 60).clamp(0, doc.length);
          tester
              .state<_DirectorBodyHostState>(find.byType(_DirectorBodyHost))
              .update(
                (s) => s.copyWith(
                  liveBlocks: AgentLiveTranscript.appendText(
                    s.liveBlocks,
                    1,
                    doc.substring(sent, end),
                    source: AgentTextSource.finishRoundProse,
                  ),
                ),
              );
          sent = end;
          final sw = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 32));
          times.add(sw.elapsedMicroseconds / 1000);
        }
        _report('director[$rounds rounds, 0→6k]', times);
        expect(times, isNotEmpty);
      });
    }
  });
}

void _report(String label, List<double> timesMs) {
  final sorted = [...timesMs]..sort();
  double pct(double p) =>
      sorted[(sorted.length * p).clamp(0, sorted.length - 1).floor()];
  // 忽略前 10% 冷启动（首帧布局/字体加载等一次性成本）
  final warmCut = (timesMs.length * 0.1).floor();
  final warm = sorted.sublist(warmCut);
  final median = warm[warm.length ~/ 2];

  //  复评：max 是**全样本**口径，永远被单帧离群占据。为了把「离群」定位到
  // 「进程预热前几帧」还是「随机 GC」，这里同时报出**离群帧在原始顺序中的角标**，
  // 以及超出 100ms 的帧集合与其中有多少落在预热窗口内。
  var maxIdx = 0;
  for (var i = 1; i < timesMs.length; i++) {
    if (timesMs[i] > timesMs[maxIdx]) maxIdx = i;
  }
  final over = <int>[
    for (var i = 0; i < timesMs.length; i++)
      if (timesMs[i] >= 100) i,
  ];
  final overWarm = over.where((i) => i < warmCut).length;
  final first3 = timesMs.take(3).map((t) => t.toStringAsFixed(1)).join('/');

  debugPrint(
    '[perf] $label: n=${timesMs.length} '
    'median=${median.toStringAsFixed(1)}ms '
    'p90=${pct(0.9).toStringAsFixed(1)}ms '
    'max=${sorted.last.toStringAsFixed(1)}ms '
    '(max@idx=$maxIdx, warmCut=$warmCut, first3=$first3, '
    '≥100ms=${over.length} 帧${over.isEmpty ? '' : ' $over'}, '
    '其中预热窗内=$overWarm)',
  );
}

/// 去掉前 10% 冷启动样本后的中位（与 [_report] 同口径）
double _warmMedian(List<double> timesMs) {
  final sorted = [...timesMs]..sort();
  final warm = sorted.sublist((sorted.length * 0.1).floor());
  return warm[warm.length ~/ 2];
}

///  纯文本散文流式测量：从 500 字起，把 doc 分 100 步追加，测每步
/// pump（32ms 合帧）墙钟。fastPath=false 为全文重解析基线，true 为
/// 纯文本快速路径。
Future<List<double>> _measurePlainProse(
  WidgetTester tester,
  String doc, {
  required bool fastPath,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: fastPath
                ? _GrowingPlainTextHost(initial: doc.substring(0, 500))
                : _GrowingMarkdownHost(initial: doc.substring(0, 500)),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));

  final times = <double>[];
  final step = (doc.length - 500 + 99) ~/ 100;
  var pos = 500;
  while (pos < doc.length) {
    final next = (pos + step).clamp(0, doc.length);
    if (fastPath) {
      tester
          .state<_GrowingPlainTextHostState>(find.byType(_GrowingPlainTextHost))
          .grow(doc.substring(0, next));
    } else {
      tester
          .state<_GrowingMarkdownHostState>(find.byType(_GrowingMarkdownHost))
          .grow(doc.substring(0, next));
    }
    pos = next;
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 32));
    times.add(sw.elapsedMicroseconds / 1000);
  }
  return times;
}

/// 冻结窗口脱敏口径：从 500 字起按**固定步长**（恒定到达率）追加到
/// doc.length，测每步 pump（32ms 合帧）墙钟。与 [_measurePlainProse] 的
/// 「100 步吃完全文」比例步长不同——后者步长随总长放大，活窗（淡入
/// 留存窗 × 到达率）随之线性膨胀，无法隔离「长度」变量。
Future<List<double>> _measurePlainProseFixedStep(
  WidgetTester tester,
  String doc,
  int stepChars,
) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: _GrowingPlainTextHost(initial: doc.substring(0, 500)),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));

  final times = <double>[];
  var pos = 500;
  while (pos < doc.length) {
    final next = (pos + stepChars).clamp(0, doc.length);
    tester
        .state<_GrowingPlainTextHostState>(find.byType(_GrowingPlainTextHost))
        .grow(doc.substring(0, next));
    pos = next;
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 32));
    times.add(sw.elapsedMicroseconds / 1000);
  }
  return times;
}

/// 生成指定字数的无空行中文散文（纯文本——无任何 Markdown 特征字符，
/// 段内换行保留）。行首恒为中文字符（不触发列表/缩进判定）。
String _plainProseDoc(int targetChars) {
  final buf = StringBuffer();
  var i = 0;
  while (buf.length < targetChars) {
    buf
      ..write('夜色沉下去的时候，走廊尽头的灯还亮着。')
      ..write('她数着台阶下楼，第三级永远比其余的响，第 $i 次也是。')
      ..write('\n')
      ..write('对话在两个方向之间摇摆，一边是试探，一边是坦白。')
      ..write('角色们各自握着真相的一角，谁也不肯先摊牌。$i')
      ..write('\n');
    i++;
  }
  return buf.toString().substring(0, targetChars);
}

/// 生成指定字数的中文 Markdown 文档（标题/段落交错）
String _markdownDoc(int targetChars) {
  final buf = StringBuffer();
  var i = 0;
  while (buf.length < targetChars) {
    buf
      ..writeln('## 第$i节 场景推进')
      ..writeln()
      ..writeln('夜色沉下去的时候，走廊尽头的灯还亮着。${_para(i)}')
      ..writeln()
      // 注意：不用列表/引用/粗体/代码围栏——特定块序列组合（含自定义
      // pre builder 时）会触发 flutter_markdown 0.7 builder 的
      // _inlines.isEmpty 断言（库级缺陷，debug/test 模式限定；发现记录
      // 见设计文档 §一.3），异常刷屏会掩盖测量。基准只保留标题/段落。
      ..writeln('关键线索 $i：她把钥匙留在了门垫下。人物动机：他不相信任何人，但需要帮手。场景细节：雨声盖过了电话铃声。')
      ..writeln()
      ..writeln('他数着台阶下楼，第三级永远比其余的响。$_para(i + 2)')
      ..writeln();
    i++;
  }
  return buf.toString();
}

String _para(int i) =>
    '对话在两个方向之间摇摆，一边是试探，一边是坦白。第 $i 次转折出现在所有人都以为尘埃落定的时候——门被推开，带进来的不止是冷风。角色们各自握着真相的一角，谁也不肯先摊牌。';

// ── markdown 隔离场景宿主 ─────────────────────────────────────────────

class _GrowingMarkdownHost extends StatefulWidget {
  const _GrowingMarkdownHost({required this.initial});
  final String initial;
  @override
  State<_GrowingMarkdownHost> createState() => _GrowingMarkdownHostState();
}

class _GrowingMarkdownHostState extends State<_GrowingMarkdownHost> {
  late String text = widget.initial;
  void grow(String next) => setState(() => text = next);
  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(child: SimpleMarkdownBody(data: text));
}

/// 流式路径走冻结前缀壳（与 chat 气泡的接线同构）
class _GrowingStreamingMarkdownHost extends StatefulWidget {
  const _GrowingStreamingMarkdownHost({required this.initial});
  final String initial;
  @override
  State<_GrowingStreamingMarkdownHost> createState() =>
      _GrowingStreamingMarkdownHostState();
}

class _GrowingStreamingMarkdownHostState
    extends State<_GrowingStreamingMarkdownHost> {
  late String text = widget.initial;
  void grow(String next) => setState(() => text = next);
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: StreamingMarkdownBody(
          data: text,
          blockGap: 4,
          blockBuilder: (segment) => SimpleMarkdownBody(data: segment),
        ),
      );
}

/// 纯文本快速路径宿主（与 chat 流式气泡的接线同构——plainTextStyle
/// 传与 styleSheet.p 同源的段落样式）
class _GrowingPlainTextHost extends StatefulWidget {
  const _GrowingPlainTextHost({required this.initial});
  final String initial;
  @override
  State<_GrowingPlainTextHost> createState() => _GrowingPlainTextHostState();
}

class _GrowingPlainTextHostState extends State<_GrowingPlainTextHost> {
  late String text = widget.initial;
  void grow(String next) => setState(() => text = next);
  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return SingleChildScrollView(
      child: StreamingMarkdownBody(
        data: text,
        blockGap: SimpleSpacing.s2xs,
        plainTextStyle: SimpleMarkdownBody.paragraphStyle(colors: colors),
        blockBuilder: (segment) => SimpleMarkdownBody(data: segment),
      ),
    );
  }
}

// ── 导演场景宿主 ─────────────────────────────────────────────────────

class _DirectorBodyHost extends StatefulWidget {
  const _DirectorBodyHost({required this.state, required this.onState});
  final AdvancedChatState state;
  final void Function(AdvancedChatState) onState;
  @override
  State<_DirectorBodyHost> createState() => _DirectorBodyHostState();
}

class _DirectorBodyHostState extends State<_DirectorBodyHost> {
  late AdvancedChatState state = widget.state;
  void update(AdvancedChatState Function(AdvancedChatState) f) =>
      setState(() => state = f(state));
  @override
  Widget build(BuildContext context) {
    widget.onState(state);
    return DirectorChatBody(
      state: state,
      onCopy: (_) {},
      onRegenerate: (_) {},
      onEdit: (_) {},
      onDeleteRound: (_) {},
    );
  }
}

AdvancedChatState _directorState(int rounds) {
  final session = ChatSession(
    sessionId: 'perf-director',
    title: '导演基准',
    mode: 'advanced',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 0,
  );
  final messages = <ChatMessage>[];
  final artifacts = <int, StoryRoundArtifacts>{};
  for (var r = 1; r <= rounds; r++) {
    messages
      ..add(
        ChatMessage(
          messageId: 'u$r',
          sessionId: session.sessionId,
          role: 'user',
          content: '推进第 $r 幕：$_para(r)',
          createdAt: DateTime(2026, 1, 1, 1, r),
        ),
      )
      ..add(
        ChatMessage(
          messageId: 'a$r',
          sessionId: session.sessionId,
          role: 'assistant',
          content: '第 $r 幕正文：${_para(r)}$_para(r + 1)}',
          createdAt: DateTime(2026, 1, 1, 1, r, 30),
        ),
      );
    artifacts[r] = StoryRoundArtifacts(
      sessionId: session.sessionId,
      turnNumber: r,
      createdAt: DateTime(2026, 1, 1, 1, r),
      agentTimeline: [
        AgentTimelineBlock(
          kind: AgentTimelineKind.thinking,
          stepIndex: 0,
          text: '思考本轮走向：${_para(r)}',
        ),
        const AgentTimelineBlock(
          kind: AgentTimelineKind.narration,
          stepIndex: 1,
          text: '播报：翻阅设定与近几轮伏笔。',
        ),
        const AgentTimelineBlock(
          kind: AgentTimelineKind.thinking,
          stepIndex: 2,
          text: '续写正文段落。',
        ),
      ],
    );
  }
  return AdvancedChatState(
    phase: IntermediatePhase.generating,
    messages: messages,
    retryCounts: const {},
    session: session,
    artifactsByTurnNumber: artifacts,
    pendingUserMessage: ChatMessage(
      messageId: 'pending',
      sessionId: session.sessionId,
      role: 'user',
      content: '继续推进剧情',
      createdAt: DateTime(2026, 1, 2),
    ),
    liveBlocks: const [
      AgentLiveBlock(
        kind: AgentLiveBlockKind.thinking,
        stepIndex: 0,
        text: '先想想。',
      ),
    ],
  );
}

// ── chat 页面桩（照抄 chat_mode_page_scroll_test 的桩家族） ─────────

CompactionService _compactionService() => CompactionService(
      chatRepository: _SeededChatRepository(0),
      tokenCounter: TokenCounter(),
      settingsRepository: _FakeSettingsRepository(),
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: _NoopLlmService()),
      llmService: _NoopLlmService(),
    );

class _SeededChatRepository implements ChatRepository {
  _SeededChatRepository(int rounds) {
    for (var i = 0; i < rounds; i++) {
      messages
        ..add(
          ChatMessage(
            messageId: 'u$i',
            sessionId: 'perf-session',
            role: 'user',
            content: '用户消息 $i：$_para(i)',
            createdAt: DateTime(2026, 1, 1, 1, i),
          ),
        )
        ..add(
          ChatMessage(
            messageId: 'a$i',
            sessionId: 'perf-session',
            role: 'assistant',
            content: '助手回复 $i：${_para(i)}${_para(i + 1)}',
            createdAt: DateTime(2026, 1, 1, 1, i, 30),
          ),
        );
    }
  }

  final List<ChatMessage> messages = [];
  final List<ChatMessage> addMessageCalls = [];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      List.of(messages);

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addMessageCalls.add(message);
    messages.add(message);
    return message;
  }

  @override
  Future<ChatSession> createSession({
    required String title,
    String? sessionId,
    String mode = 'chat',
    String? modelId,
    String? presetId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> getSession(String sessionId) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> deleteAllSessions() async {}

  @override
  Future<void> recreateConversationTables() async {}

  @override
  Future<void> deleteMessage(String messageId) async {
    messages.removeWhere((m) => m.messageId == messageId);
  }

  @override
  Future<void> updateMessageContent(String messageId, String content) async {
    final i = messages.indexWhere((m) => m.messageId == messageId);
    if (i >= 0) messages[i] = messages[i].copyWith(content: content);
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async => [];

  @override
  Future<void> updateMessageTokensUsed(
    String messageId,
    int? tokensUsed,
  ) async {}

  @override
  Future<int> updateMessageError(String messageId, String? error) async => 0;

  @override
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(
    String sessionId,
  ) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) => stream!;

  @override
  Future<LlmResponse> chat(LlmRequest request) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: 'test',
        broadcastChat: BroadcastChatConfig(
          presetId: 'preset-test',
          modelId: 'model-test',
          autoCompaction: false,
        ),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  Future<void> clearAllUserOverrides() async {}

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {}

  @override
  Future<int> getUserOverrideCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepository implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopPresetRepository implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test Provider',
        baseUrl: 'https://api.test.com/v1',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<List<ApiPreset>> getAllPresets() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
