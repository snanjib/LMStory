import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

///  守卫①：动效单源（`lib/core/theme/system/lm_motion.dart`）。
///
/// 三条不变量：
/// 1. **无散落字面量**：`lib/` 全域不得再出现 `Duration(milliseconds: <数字>)`、
///    `Curves.<名>`、`Cubic(<数字>…)`；唯一豁免通道是在该语句**上方一行**写
///    `// lm-motion-exempt: <理由>`（非过渡动效时长：网络超时 / 去抖 / 流式
///    引擎节奏），且理由不得为空。
/// 2. **数值锚定**：语义槽收编时是等值替换（Classic 零视觉零行为变化），
///    改值必须显式改这里的锚 —— 防止「顺手调一下」悄悄改掉经典手感。
/// 3. **禁 bounce / elastic / back**（Apple 原则）：曲线槽不得带回弹，
///    采样全程不得越出 [0,1] 太多。
void main() {
  // ── 1. 无散落字面量 ─────────────────────────────────────────────
  final leakPattern = RegExp(
    r'Duration\(\s*milliseconds:\s*\d'
    r'|Curves\.[A-Za-z]+(?!\w)'
    r'|Cubic\(\s*-?\d',
  );
  const exemptMarker = 'lm-motion-exempt:';

  test('lib/ 全域无散落的时长/曲线字面量（豁免标注除外）', () {
    final offenders = <String>[];
    var exemptCount = 0;

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      if (rel.endsWith('/lm_motion.dart')) continue;
      final src = entity.readAsStringSync();

      for (final match in leakPattern.allMatches(src)) {
        if (_inLineComment(src, match.start)) continue; // 注释里提到的字面量不算散落
        final statement = _statementSpan(src, match.start, match.end);
        if (statement.contains(exemptMarker) ||
            _previousLine(src, match.start).contains(exemptMarker)) {
          exemptCount++;
          continue;
        }
        offenders.add(
          '$rel:${_lineOf(src, match.start)} → ${_snippet(match.group(0)!)}',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '发现散落的动效字面量（应改为 LmMotion 语义槽；确属非过渡动效的 '
          '时长请在语句上方一行标注 `// $exemptMarker <理由>`）：\n'
          '${offenders.join('\n')}',
    );
    expect(
      exemptCount,
      greaterThan(0),
      reason: '豁免扫描未生效（若字面量已全部收编，应删掉本条断言并同步注释）',
    );
  });

  test('每条豁免标注都必须写明理由（不得空标注）', () {
    final lazy = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!line.contains(exemptMarker)) continue;
        if (line.trimLeft().startsWith('///')) continue; // 文档里提到标记的说明行
        final reason = line.split(exemptMarker).last.trim();
        if (reason.length < 6) lazy.add('$rel:${i + 1}');
      }
    }
    expect(lazy, isEmpty, reason: '缺理由的豁免标注：${lazy.join(', ')}');
  });

  // ── 2. 数值锚定 ────────────────────────────────────────────────
  test('时长语义槽数值锚定（收编 = 等值替换，改值须显式改锚）', () {
    final anchors = <String, Duration>{
      'instant': LmMotion.instant,
      'micro': LmMotion.micro,
      'fast': LmMotion.fast,
      'base': LmMotion.base,
      'slow': LmMotion.slow,
      'emphasis': LmMotion.emphasis,
      'enter': LmMotion.enter,
      'transition': LmMotion.transition,
      'unfold': LmMotion.unfold,
      'fold': LmMotion.fold,
      'step': LmMotion.step,
      'sweep': LmMotion.sweep,
      'blink': LmMotion.blink,
      'pulse': LmMotion.pulse,
      'pulseSoft': LmMotion.pulseSoft,
      'loop': LmMotion.loop,
      'breathe': LmMotion.breathe,
    };
    const expected = <String, int>{
      'instant': 0,
      'micro': 120,
      'fast': 150,
      'base': 200,
      'slow': 250,
      'emphasis': 300,
      'enter': 400,
      'transition': 500,
      'unfold': 160,
      'fold': 180,
      'step': 220,
      'sweep': 240,
      'blink': 540,
      'pulse': 800,
      'pulseSoft': 900,
      'loop': 1200,
      'breathe': 1500,
    };
    for (final entry in anchors.entries) {
      expect(
        entry.value.inMilliseconds,
        expected[entry.key],
        reason: '槽 ${entry.key} 数值被动过——T06 收编是等值替换，'
            ' 改值须单独 commit 并出前后对比',
      );
    }
  });

  test('语义别名与刻度恒等（press/hover/focus/exit）', () {
    expect(LmMotion.press, LmMotion.fast);
    expect(LmMotion.hover, LmMotion.fast);
    expect(LmMotion.focus, LmMotion.micro);
    expect(LmMotion.exit, LmMotion.slow);
  });

  // ── 3. 禁 bounce ───────────────────────────────────────────────
  test('曲线槽禁 bounce / elastic / back，且不越界', () {
    final slots = <String, Curve>{
      'easeStandard': LmMotion.easeStandard,
      'easeBoth': LmMotion.easeBoth,
      'easeEmphasis': LmMotion.easeEmphasis,
      'easeSnap': LmMotion.easeSnap,
      'easeColor': LmMotion.easeColor,
      'easeRecede': LmMotion.easeRecede,
      'linear': LmMotion.linear,
    };
    final banned = <Curve>[
      Curves.bounceIn,
      Curves.bounceOut,
      Curves.bounceInOut,
      Curves.elasticIn,
      Curves.elasticOut,
      Curves.elasticInOut,
      Curves.easeInBack,
      Curves.easeOutBack,
      Curves.easeInOutBack,
    ];
    for (final entry in slots.entries) {
      expect(
        banned,
        isNot(contains(entry.value)),
        reason: '${entry.key} 是回弹曲线（Apple 原则：无弹跳无弹性）',
      );
      expect(entry.value.transform(0), closeTo(0, 1e-6));
      expect(entry.value.transform(1), closeTo(1, 1e-6));
      for (var t = 0.0; t <= 1.0001; t += 0.02) {
        final v = entry.value.transform(t.clamp(0, 1));
        expect(
          v,
          inInclusiveRange(-0.02, 1.02),
          reason: '${entry.key} 在 t=$t 处越界（v=$v）——过冲即回弹',
        );
      }
    }
  });
}

/// 取命中点所在的逻辑语句跨度（以 `;` / `{` / `}` 分句），用于判定豁免标注。
String _statementSpan(String src, int start, int end) {
  final candidates = <int>[
    src.lastIndexOf(';', start),
    src.lastIndexOf('{', start),
    src.lastIndexOf('}', start),
  ];
  final from = candidates.reduce((a, b) => a > b ? a : b) + 1;
  final to = src.indexOf(';', end);
  return src.substring(from, to == -1 ? src.length : to + 1);
}

/// 命中点的上一行（构造器初始化列表等跨行语句里标注更贴近字面量）。
String _previousLine(String src, int offset) {
  final lineStart = src.lastIndexOf('\n', offset);
  if (lineStart <= 0) return '';
  final prevStart = src.lastIndexOf('\n', lineStart - 1) + 1;
  return src.substring(prevStart, lineStart);
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

/// 命中点是否落在该行的 `//` 注释之后（注释里的字面量不是散落用量）。
bool _inLineComment(String src, int offset) {
  final lineStart = src.lastIndexOf('\n', offset) + 1;
  final before = src.substring(lineStart, offset);
  return before.contains('//');
}

String _snippet(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
