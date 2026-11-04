import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';

///  守卫（大屏口径 + 焦点环对比度见 t07_focus_contrast_report_test.dart）。
///
/// 三条不变量：
///
/// 1. **断点/版心单源**：数值锚定 + `tierOf` / `usesMeasure` 边界精确
///    （版心**必须**从 1280 才启用——<1280 是历史已验证区间，任何提前收敛
///    都会改动既有观感）。
/// 2. **断点数字不外泄**：`lib/` 内除 `lm_layout.dart` 之外，不得再出现
///    「与 600 / 1280 / 1920 做比较」的散落判据。
/// 3. **布局类宽度字面量白名单化**：`lib/` 内的数值 `maxWidth` / `maxHeight`
///    必须落在一份**闭合白名单**里（全部是内容固有尺寸），
///    新文件或新数值即失败，逼作者显式登记理由。
///
/// 另附 [LmMeasure] 的阈值**行为**断言（<1280 逐像素原样、≥1280 钳制居中）——
/// 这是「经典零视觉变化」这条红线在组件层的可执行证据。
void main() {
  // ── 1. 数值锚定 ─────────────────────────────────────────────────
  test('大屏断点与版心数值锚定（改值必须显式改锚）', () {
    expect(LmLayout.compactMax, 600);
    expect(LmLayout.mediumMax, 1280);
    expect(LmLayout.wideMax, 1920);

    // 720 → 800（宽窗口留白观感，见 lm_layout 头注释）
    expect(LmLayout.readingMeasure, 800);
    expect(LmLayout.formMeasure, 880);
    expect(LmLayout.listMeasure, 1120);

    // 流式版心占比：版心 = max(槽值, 窗口 × 0.85)，两侧各留 7.5% 安全边距
    expect(LmLayout.measureFraction, 0.85);

    expect(LmLayout.dialogMaxWidth, 560);
    expect(LmLayout.dialogNarrowWidth, 480);
    expect(LmLayout.sheetMaxWidth, 640);
    expect(LmLayout.panelWidth, 560);
    expect(LmLayout.panelNarrowWidth, 440);
    expect(LmLayout.sidebarWidth, 240);

    // 阅读列旧名（lm_structure 的导出）必须仍与新版心同值。
    expect(LmReadingConstraints.width, LmLayout.readingMeasure);
  });

  test('tierOf / usesMeasure 边界精确（版心自 1280 启用）', () {
    expect(LmLayout.tierOf(0), LmLayoutTier.compact);
    expect(LmLayout.tierOf(599), LmLayoutTier.compact);
    expect(LmLayout.tierOf(600), LmLayoutTier.medium);
    expect(LmLayout.tierOf(1279), LmLayoutTier.medium);
    expect(LmLayout.tierOf(1280), LmLayoutTier.wide);
    expect(LmLayout.tierOf(1919), LmLayoutTier.wide);
    expect(LmLayout.tierOf(1920), LmLayoutTier.ultra);
    expect(LmLayout.tierOf(2560), LmLayoutTier.ultra);

    expect(LmLayout.usesMeasure(1279), isFalse);
    expect(LmLayout.usesMeasure(1280), isTrue);
  });

  test('流式版心：槽值保底、随窗口按占比放大、无固定上限', () {
    // 窗口 × 占比 ≤ 槽值：保底生效（窄窗不产生比基线更窄的回退）
    expect(LmLayout.measureOf(700, 800), 800);
    expect(LmLayout.measureOf(1000, 880), 880);
    // 窗口 × 占比 > 槽值：流式放大（85%）
    expect(LmLayout.measureOf(1280, 800), closeTo(1088, 0.01));
    expect(LmLayout.measureOf(1920, 800), closeTo(1632, 0.01));
    expect(LmLayout.measureOf(2560, 800), closeTo(2176, 0.01));
    expect(LmLayout.measureOf(2560, 1120), closeTo(2176, 0.01));
    // 无上限：单调不减
    expect(
      LmLayout.measureOf(3840, 800),
      greaterThan(LmLayout.measureOf(2560, 800)),
    );
  });

  test('capped 模式：版心恒为槽基线（用户可选的固定上限行为）', () {
    expect(LmLayout.measureOf(2560, 800, mode: LmContentWidthMode.capped), 800);
    expect(
      LmLayout.measureOf(1920, 880, mode: LmContentWidthMode.capped),
      880,
    );
    // 缺省模式为流式（消费面无 scope 时同）
    expect(LmLayout.measureOf(2560, 800), closeTo(2176, 0.01));
  });

  testWidgets('LmContentWidthScope：capped 下 LmMeasure 与阅读列不随窗口放大',
      (tester) async {
    const key = ValueKey('t07-mode-probe');

    Future<double> probe(double surfaceWidth) async {
      await tester.binding.setSurfaceSize(Size(surfaceWidth, 600));
      await tester.pumpWidget(
        MaterialApp(
          home: LmContentWidthScope(
            mode: LmContentWidthMode.capped,
            child: MediaQuery(
              data: MediaQueryData(size: Size(surfaceWidth, 600)),
              child: const Center(
                child: LmMeasure(
                  maxWidth: 600,
                  child: SizedBox(
                    key: key,
                    width: 3000,
                    height: 20,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(key)).width;
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));

    // capped：2560 窗口下仍钳在保底 600，不流式放大
    expect(await probe(2560), 600);
  });

  // ── 2. 断点数字不外泄 ───────────────────────────────────────────
  test('断点数值 600/1280/1920 的比较判据只允许出现在 lm_layout.dart', () {
    final pattern = RegExp(r'(?:[<>]=?|==)\s*(?:600|1280|1920)\b'
        r'|(?:600|1280|1920)\b\s*(?:[<>]=?|==)');
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      if (rel.endsWith('/lm_layout.dart')) continue;
      if (rel.endsWith('.g.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in pattern.allMatches(src)) {
        if (_inLineComment(src, m.start)) continue;
        offenders
            .add('$rel:${_lineOf(src, m.start)} → ${_snippet(m.group(0)!)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '发现散落的断点判据（应改用 LmLayout.tierOf / usesMeasure）：\n'
          '${offenders.join('\n')}',
    );
  });

  // ── 3. LmMeasure 阈值行为（经典零视觉变化在组件层的证据）──────────
  testWidgets('LmMeasure：<1280 原样透传、≥1280 钳制到流式版心并居中', (tester) async {
    const key = ValueKey('t07-measure-probe');
    const measure = 600.0;

    // 子件宽度按档位给：须 < 窗口宽（窗口不干涉）且与该档流式版心错开，
    // 才能分辨"没钳/钳了"。
    Future<double> probe(double surfaceWidth, double childWidth) async {
      // 两条通道：setSurfaceSize 决定**真实几何**，显式 MediaQuery 决定
      // LmMeasure 读到的**窗口宽度**（测试绑定下 setSurfaceSize 不会改写
      // MediaQuery.sizeOf，两者必须同时给才能既量准又判准）。
      await tester.binding.setSurfaceSize(Size(surfaceWidth, 600));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(surfaceWidth, 600)),
            child: Center(
              child: LmMeasure(
                maxWidth: measure,
                child: SizedBox(
                  key: key,
                  width: childWidth,
                  height: 20,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(key)).width;
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));

    // < 1280：LmMeasure 透传——子件（1100 < 窗口）拿原宽，不被钳到保底。
    expect(await probe(1279, 1100), 1100, reason: '1279 下不得收敛（历史区间零变化）');
    expect(await probe(1100, 1100), 1100, reason: '1100 下不得收敛');

    // ≥ 1280：钳制到流式版心（max(保底, 窗口×85%)）并水平居中。
    expect(
      await probe(1280, 3000),
      closeTo(LmLayout.measureOf(1280, measure), 0.5),
    );
    expect(
      await probe(2560, 3000),
      closeTo(LmLayout.measureOf(2560, measure), 0.5),
    );

    final center = tester.getCenter(find.byKey(key));
    expect(center.dx, closeTo(2560 / 2, 0.5), reason: '版心须水平居中');
  });

  // ── 4. 布局类宽度字面量白名单（闭合）────────────────────────────
  test('lib/ 的数值 maxWidth/maxHeight 字面量落在闭合白名单内', () {
    final pattern = RegExp(r'max(?:Width|Height):\s*(\d+)');
    final found = <String, Set<int>>{};

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      if (rel.endsWith('/lm_layout.dart') || rel.endsWith('.g.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in pattern.allMatches(src)) {
        if (_inLineComment(src, m.start)) continue;
        (found[rel] ??= <int>{}).add(int.parse(m.group(1)!));
      }
    }

    // 新增文件 / 新增数值即失败。
    final offenders = <String>[];
    for (final entry in found.entries) {
      final allowed = _widthWhitelist[entry.key];
      if (allowed == null) {
        offenders.add('未登记文件 ${entry.key} → ${entry.value.toList()..sort()}');
        continue;
      }
      final extra = entry.value.difference(allowed);
      if (extra.isNotEmpty) {
        offenders.add('${entry.key} 出现未登记数值 ${extra.toList()..sort()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '布局类宽度字面量必须是 LmLayout 语义槽；确属内容固有尺寸的请登记到 '
          '_widthWhitelist（附理由）：\n${offenders.join('\n')}',
    );

    // 白名单不得留陈旧条目（文件已改回 token 却还挂在表里）。
    final stale = _widthWhitelist.keys
        .where((k) => !found.containsKey(k))
        .toList()
      ..sort();
    expect(stale, isEmpty, reason: '白名单陈旧条目（该文件已无数值字面量）：$stale');
  });
}

/// 数值 `maxWidth` / `maxHeight` 字面量的**闭合白名单**。
///
/// 键 = `lib/` 相对路径；值 = 该文件允许出现的数值集合。
///
/// 收录理由：**全部是内容固有尺寸**（缩略图 / 卡片 / 弹窗与浮层的高度上限），
/// **不是**版心、面板或浮层的**布局宽度**——后者一律走 [LmLayout] 语义槽
/// （见  收编：classic/glass 的 dialog·sheet 宽、侧栏宽、设置域与
/// 资源库/帮助/看板/模板页版心、AI 面板宽）。
///
/// 任何**新文件**或**新数值**都会让守卫失败——这是刻意的：
/// 逼作者回答「这到底是版心还是内容尺寸」。
const _widthWhitelist = <String, Set<int>>{
  // 折叠卡正文预览的最大高度（行数上限的物理表现）。
  'lib/core/theme/system/structures/classic/conversation/message_bubble/bubble_compaction_card.dart':
      {80},
  // 气泡内图片缩略图的固有尺寸（240×180 主图 / 160 小图）。
  'lib/core/theme/system/structures/classic/conversation/message_bubble/bubble_image_gallery.dart':
      {240, 180, 160},
  // 思考卡正文预览的最大高度。
  'lib/core/theme/system/structures/classic/conversation/message_bubble/bubble_thinking_card.dart':
      {220},
  // HITL 审批横幅「变更明细」折叠区的最大高度（明细可达 30+ 行，
  // 限高滚动防挤占正文区——内容固有尺寸，2026-10-15 批 C）。
  'lib/features/advanced/presentation/widgets/director_hitl_banner.dart': {220},
  // 1920 是 image_picker 的**降采样上限**（非布局）；100/180 是附件缩略图
  // 与附件条目的固有尺寸；200/120 是输入框折叠前的最大高度。
  'lib/features/chat/presentation/widgets/chat_mode_input_area.dart': {
    1920,
    200,
    120,
    100,
    180,
  },
  // 建议回复浮层的最大高度。
  'lib/core/theme/system/structures/classic/narrative/suggest_reply_overlay.dart':
      {280},
  // 导演模式气泡内嵌件的最大宽度（内容件固有）。
  'lib/features/advanced/presentation/pages/director_chat_body.dart': {280},
  // 失败历史列表的最大高度。
  'lib/features/diagnostics/presentation/widgets/failure_history_widget.dart': {
    160,
  },
  // 故事模式气泡内嵌件的最大宽度（内容件固有）。
  'lib/features/intermediate/presentation/pages/intermediate_chat_body.dart': {
    300,
  },
  // 模型选择弹窗的列表最大高度（内容区高度，非弹窗宽度）。
  'lib/features/settings/presentation/widgets/model_picker_dialog.dart': {600},
  // 失败条内容的最大高度。
  'lib/features/story_runtime/presentation/widgets/failure_bar.dart': {120},
  // 故事模式输入框折叠前的最大高度。
  'lib/features/story_runtime/presentation/widgets/intermediate_chat_input.dart':
      {200},
};

/// 命中点是否落在该行的 `//` 注释之后（注释里提到的数值不算散落用量）。
bool _inLineComment(String src, int offset) {
  final lineStart = src.lastIndexOf('\n', offset) + 1;
  return src.substring(lineStart, offset).contains('//');
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

String _snippet(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
