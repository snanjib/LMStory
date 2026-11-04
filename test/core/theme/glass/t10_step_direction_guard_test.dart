//  守卫 · 白玻璃台阶**方向派生**与**台阶增量 / 对比度**双表。
//
// ## 裁决原文（2026-09-22 复评）
//
// 「白玻璃阶梯引入暗向档 → 批准，但必须是**派生**不是再加一套常量」：
//   · 方向由**底面色亮度**派生，不是按 `Brightness` 硬分档；
//   · 参数单一来源在 `glass_materials.dart`；
//   · 台阶语义（hover +1 / pressed +2）必须在四组合 × 明暗下都产出可感知
//     增量，**验收线 Δ≥15**（对齐 classic 按钮已过线的水平）；
//   · 修掉日间两档同值（旧 `fill10(light) == fill16(light) == 白@50%`）；
//   · 暗向档必须验证文字对比度不低于 **4.5:1**（波尔多夜间 onPrimary 深字
//     压白尤其）。
//
// ## 本夹具锁的三条线
//
// 1. **方向派生**：`directionOf(base)` 只由 `base.computeLuminance()` 决定。
//    判据不是「断言某个组合是 lift」——那样换个配色就假绿——而是**同一张
//    配色、同一个 Brightness 下，两个不同底面必须给出不同方向**
//    （波尔多夜：bg #150C13 → lift，primary #E8DCE4 → sink）。这条一旦回退
//    成按 Brightness 分档，立刻红。
// 2. **台阶增量**：每个真实台阶面的 `静息→hover`、`静息→pressed` 的 max
//    通道差 ≥15，`hover→pressed` 的额外增量 ≥8（同款判据）。
// 3. **对比度**：暗向档（sink）三态全 ≥4.5；提亮档（lift）静息面 ≥4.5
//    （既有配色槽不达标的唯一一处写成白名单，修好即红）；hover / pressed
//    报数不设阈值——台阶必然改变面色，另行登记在「未修复清单」。
//
// ## 为什么不直接复用旧常数名
//
// 旧 `fillNight6/10/16/22` + `fillDay30/50/70` 是两套常量，方向锁死为「只叠白」。
// 现在改成 `lift1..4` / `sink1..4` 两组档位 + 一个 `directionOf` 派生方向，
// 常量总数从 7 降到 8 但**语义轴只剩一条**（档位序号 × 方向），不再是两套。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';

/// 台阶增量验收线（max 通道差）。与 classic 按钮已过线水平对齐。
const int _kStepDelta = 15;

/// 「hover → pressed 额外增量」下限（沿用  同款 Δ8 判据）。
const int _kExtraDelta = 8;

/// WCAG AA 正文对比度线。
const double _kContrast = 4.5;

const String _reportPath =
    'test_screenshots/night-2026-09-21/t10_step_direction_report.md';

/// 提亮档里**静息面本就不达标**的既有配色槽缺口（`组合/明暗 构件`）。
/// 命中即放过并在报告里标「既有」；不再命中则说明配色槽已修，必须删条目。
const Set<String> _knownLiftGaps = {
  // classic/夜 的 destructive 药丸 = error #C44830 + onPrimary #14100A（深字）。
  // 深底大红亮度高、深字压上去只有 3.91:1 —— 这是**静息面**的属性，
  // 与台阶无关（台阶不参与静息面）。配色档注释已记为「error 消费面按图标/
  // 描边使用」，属既有决策，不在  范围内改值。
  'classic/dark 药丸·destructive',
};

int _q(double v) => (v * 255).round();

String _hex(Color c) => '#${_q(c.r).toRadixString(16).padLeft(2, '0')}'
    '${_q(c.g).toRadixString(16).padLeft(2, '0')}'
    '${_q(c.b).toRadixString(16).padLeft(2, '0')}';

/// 两色 max 通道差（0–255）：与  `maxChange` 同口径。
int _delta(Color a, Color b) => math.max(
      math.max((_q(a.r) - _q(b.r)).abs(), (_q(a.g) - _q(b.g)).abs()),
      (_q(a.b) - _q(b.b)).abs(),
    );

double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 一个真实台阶面：静息 / hover / pressed 三态的合成色 + 承载的文字色。
class _FaceCase {
  const _FaceCase({
    required this.combo,
    required this.control,
    required this.stepBase,
    required this.rest,
    required this.hover,
    required this.pressed,
    required this.foreground,
  });

  final String combo;
  final String control;

  /// 派生的那一个底面（断言方向时用）。
  final Color stepBase;

  final Color rest;
  final Color hover;
  final Color pressed;

  /// 该面承载的文字色（对比度核算用）。
  final Color foreground;

  String get id => '$combo $control';

  int get hoverDelta => _delta(rest, hover);
  int get pressedDelta => _delta(rest, pressed);
  int get extraDelta => _delta(hover, pressed);

  double get restContrast => _contrast(foreground, rest);
  double get hoverContrast => _contrast(foreground, hover);
  double get pressedContrast => _contrast(foreground, pressed);

  bool get isSink =>
      GlassMaterials.directionOf(stepBase) == GlassStepDirection.sink;
}

/// 造出某组合下**全部真实台阶面**（与工厂里的接线一一对应，不重算逻辑只
/// 复述表达式——工厂改了而这里没改，Δ 表会漂，正是我们要的耦合）。
List<_FaceCase> _cases(LmPalette p, String combo) {
  final bg = p.bg;

  // (1) 构件自带面的台阶：面板 / 卡片 / chip / 行 / 阅读卡 —— 压在 bg 上。
  _FaceCase surface(String name, Color base, Color fg) => _FaceCase(
        combo: combo,
        control: name,
        stepBase: base,
        rest: GlassMaterials.stepped(base, GlassMaterials.fill6(base)),
        hover: GlassMaterials.stepped(base, GlassMaterials.fill10(base)),
        pressed: GlassMaterials.stepped(base, GlassMaterials.fill16(base)),
        foreground: fg,
      );

  // (3) 药丸：静息是**裸底**（不含），hover 上 ，pressed 上 。
  _FaceCase pill(String name, Color under, Color fg) => _FaceCase(
        combo: combo,
        control: name,
        stepBase: under,
        rest: under,
        hover: GlassMaterials.stepped(under, GlassMaterials.fill10(under)),
        pressed: GlassMaterials.stepped(under, GlassMaterials.fill16(under)),
        foreground: fg,
      );

  // (4) secondary：面色本身是「 压在场地上的半透明合成」，必须先合成为
  //     不透明色再判方向（半透明台阶的 rgb 恒为 0 或 255，直接判会错）。
  final under = GlassMaterials.fill10(bg);
  final secondaryBase = GlassMaterials.stepped(bg, under);

  return <_FaceCase>[
    // (1) 构件自带面 —— 压在 bg 上。
    surface('面板/卡片/chip/行', bg, p.muted),
    // (2) 输入框：压在 surfaceVariant 上（工厂里唯一不用 bg 的台阶面）。
    surface('输入框', p.surfaceVariant, p.ink),
    pill('药丸·primary', p.primary, p.onPrimary),
    pill('药丸·destructive', p.error, p.onPrimary),
    pill('药丸·ghost', bg, p.ink),
    _FaceCase(
      combo: combo,
      control: '药丸·secondary',
      stepBase: secondaryBase,
      rest: secondaryBase,
      hover: Color.alphaBlend(
        Color.alphaBlend(GlassMaterials.fill10(secondaryBase), under),
        bg,
      ),
      pressed: Color.alphaBlend(
        Color.alphaBlend(GlassMaterials.fill16(secondaryBase), under),
        bg,
      ),
      foreground: p.ink,
    ),
  ];
}

void main() {
  const families = <String, LmPaletteFamily>{
    'classic': ClassicPaletteFamily(),
    'bordeaux': BordeauxPaletteFamily(),
  };

  // ── 契约①：方向由底面亮度派生，不是按 Brightness 分档 ──────────────
  testWidgets('方向派生：同一配色同 brightness 下两个底面给出不同方向', (tester) async {
    // 波尔多夜：整档是 dark，但 primary 是纯白 —— 若方向按 Brightness 分档，
    // 这里必然退化成 lift（旧实现的病根：白叠白 Δ0）。
    const night = BordeauxPaletteValues.night;
    expect(
      GlassMaterials.directionOf(night.bg),
      GlassStepDirection.lift,
      reason: '波尔多夜 bg #150C13 是深底 → 必须提亮',
    );
    expect(
      GlassMaterials.directionOf(night.primary),
      GlassStepDirection.sink,
      reason: '波尔多夜浅色 primary 虽在 dark 档 → 也必须压暗（派生，非分档）',
    );

    // 反向：波尔多日整档是 light，而 primary #8C2440 是深底 → 必须提亮。
    expect(
      GlassMaterials.directionOf(BordeauxPaletteValues.day.primary),
      GlassStepDirection.lift,
      reason: '波尔多日 primary #8C2440 虽在 light 档 → 必须提亮（派生，非分档）',
    );

    // 全量一致性：任意底面，方向 ⇔ 亮度阈值。
    for (final entry in families.entries) {
      for (final brightness in Brightness.values) {
        final p = entry.value.of(brightness);
        for (final base in <Color>[
          p.bg,
          p.surface,
          p.surfaceVariant,
          p.primary,
          p.error,
          p.accent,
        ]) {
          expect(
            GlassMaterials.directionOf(base),
            base.computeLuminance() >= GlassMaterials.stepFlipLuminance
                ? GlassStepDirection.sink
                : GlassStepDirection.lift,
            reason: '${entry.key}/${brightness.name} ${_hex(base)} 方向未由亮度派生',
          );
        }
      }
    }
  });

  // ── 契约②：四档互不相同（修掉旧 fill10(light)==fill16(light)）────────
  testWidgets('台阶四档互不相同（日间不再塌档）', (tester) async {
    for (final entry in families.entries) {
      for (final brightness in Brightness.values) {
        final p = entry.value.of(brightness);
        for (final base in <Color>[
          p.bg,
          p.surfaceVariant,
          p.primary,
          p.error,
        ]) {
          final tiers = <Color>[
            GlassMaterials.fill6(base),
            GlassMaterials.fill10(base),
            GlassMaterials.fill16(base),
            GlassMaterials.fill22(base),
          ];
          final seen = <int>{};
          for (final t in tiers) {
            seen.add(t.toARGB32());
          }
          expect(
            seen.length,
            4,
            reason: '${entry.key}/${brightness.name} 底面 ${_hex(base)} 的四个台阶'
                ' 出现同值（旧病：日间 fill10==fill16）→ hover/pressed 塌成一档',
          );
        }
      }
    }
  });

  // ── 契约③/④：增量表与对比度表（四组合 × 明暗全覆盖）────────────────
  testWidgets('台阶增量表 Δ≥15 与对比度合规表（四组合 × 明暗）', (tester) async {
    final rows = <_FaceCase>[];
    for (final entry in families.entries) {
      for (final brightness in Brightness.values) {
        final combo =
            '${entry.key}/${brightness == Brightness.light ? 'light' : 'dark'}';
        rows.addAll(_cases(entry.value.of(brightness), combo));
      }
    }

    Directory('test_screenshots/night-2026-09-21').createSync(recursive: true);
    File(_reportPath).writeAsStringSync(_render(rows));

    // (a) 增量线：hover / pressed 相对静息 ≥15，pressed 相对 hover 额外 ≥8。
    final weak = <String>[];
    for (final r in rows) {
      if (r.hoverDelta < _kStepDelta) {
        weak.add('${r.id} hover Δ${r.hoverDelta} < $_kStepDelta '
            '（${_hex(r.rest)} → ${_hex(r.hover)}）');
      }
      if (r.pressedDelta < _kStepDelta) {
        weak.add('${r.id} pressed Δ${r.pressedDelta} < $_kStepDelta '
            '（${_hex(r.rest)} → ${_hex(r.pressed)}）');
      }
      if (r.extraDelta < _kExtraDelta) {
        weak.add('${r.id} 按压相对悬停额外增量 Δ${r.extraDelta} < $_kExtraDelta '
            '（${_hex(r.hover)} → ${_hex(r.pressed)}）');
      }
    }
    expect(weak, isEmpty, reason: '台阶增量不达标：\n  - ${weak.join('\n  - ')}');

    // (b) 对比度：暗向档三态全 ≥4.5（裁决点名项）；提亮档静息面 ≥4.5。
    final lowContrast = <String>[];
    for (final r in rows) {
      if (r.isSink) {
        for (final pair in <(String, double)>[
          ('静息', r.restContrast),
          ('悬停', r.hoverContrast),
          ('按压', r.pressedContrast),
        ]) {
          if (pair.$2 < _kContrast) {
            lowContrast.add(
              '【暗向】${r.id} ${pair.$1} ${pair.$2.toStringAsFixed(2)} '
              '< $_kContrast（${_hex(r.foreground)} on 面）',
            );
          }
        }
      } else if (r.restContrast < _kContrast &&
          !_knownLiftGaps.contains(r.id)) {
        lowContrast.add(
          '【提亮】${r.id} 静息 ${r.restContrast.toStringAsFixed(2)} '
          '< $_kContrast（${_hex(r.foreground)} on ${_hex(r.rest)}）',
        );
      }
    }
    expect(
      lowContrast,
      isEmpty,
      reason: '文字对比度不达标：\n  - ${lowContrast.join('\n  - ')}',
    );

    // 白名单自清理。
    final stale = _knownLiftGaps
        .where(
          (id) => !rows.any((r) => r.id == id && r.restContrast < _kContrast),
        )
        .toList();
    expect(stale, isEmpty, reason: '以下既有缺口已达标，请从 _knownLiftGaps 删除：$stale');
  });
}

String _render(List<_FaceCase> rows) {
  final buf = StringBuffer()
    ..writeln('# T10-2 · 白玻璃台阶方向 / 增量 / 对比度报告')
    ..writeln()
    ..writeln('夹具：`test/core/theme/glass/t10_step_direction_guard_test.dart`')
    ..writeln()
    ..writeln('## 口径')
    ..writeln()
    ..writeln('- **方向**：`GlassMaterials.directionOf(base)`，'
        ' `base.computeLuminance() ≥ ${GlassMaterials.stepFlipLuminance}` → 压暗（叠黑），否则提亮（叠白）。')
    ..writeln('- **Δ**：两态 max 通道差（0–255），与 T08 `maxChange` 同口径。')
    ..writeln('- **验收线**：`静息→悬停` 与 `静息→按压` Δ≥$_kStepDelta；'
        ' `悬停→按压` 额外增量 Δ≥$_kExtraDelta。')
    ..writeln('- **对比度**：WCAG 相对亮度；暗向档三态断言 ≥$_kContrast，'
        ' 提亮档静息面断言 ≥$_kContrast（hover/pressed 报数、另登记）。')
    ..writeln()
    ..writeln('## 台阶增量表')
    ..writeln()
    ..writeln('| 组合/明暗 | 台阶面 | 方向 | 静息面 | 悬停面 | 按压面 '
        '| hover Δ | pressed Δ | 额外 Δ |')
    ..writeln('|---|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    buf.writeln(
      '| ${r.combo} | ${r.control} | ${r.isSink ? 'sink 压暗' : 'lift 提亮'} '
      '| ${_hex(r.rest)} | ${_hex(r.hover)} | ${_hex(r.pressed)} '
      '| ${r.hoverDelta} | ${r.pressedDelta} | ${r.extraDelta} |',
    );
  }

  buf
    ..writeln()
    ..writeln('## 对比度合规表（该台阶面承载的文字色）')
    ..writeln()
    ..writeln('| 组合/明暗 | 台阶面 | 方向 | 文字色 | 静息 | 悬停 | 按压 | 判定 |')
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    final String verdict;
    if (r.isSink) {
      verdict = (r.restContrast >= _kContrast &&
              r.hoverContrast >= _kContrast &&
              r.pressedContrast >= _kContrast)
          ? '✅ 三态全 ≥$_kContrast'
          : '❌ 有态 <$_kContrast';
    } else {
      verdict = r.restContrast >= _kContrast
          ? '✅ 静息 ≥$_kContrast（hover/pressed 报数）'
          : (_knownLiftGaps.contains(r.id)
              ? '⚠️ 既有配色槽缺口（白名单）'
              : '❌ 静息 <$_kContrast');
    }
    buf.writeln(
      '| ${r.combo} | ${r.control} | ${r.isSink ? 'sink' : 'lift'} '
      '| ${_hex(r.foreground)} | ${r.restContrast.toStringAsFixed(2)} '
      '| ${r.hoverContrast.toStringAsFixed(2)} '
      '| ${r.pressedContrast.toStringAsFixed(2)} | $verdict |',
    );
  }
  return buf.toString();
}
