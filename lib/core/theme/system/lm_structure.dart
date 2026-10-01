import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// 布局口径（断点 + 版心）已归入 [LmLayout] 单源；此处保留导出，
/// 便于既有 `import 'lm_structure.dart'` 的调用点继续使用
/// [LmReadingConstraints]，无需逐个改导入。
export 'package:lmstory/core/theme/system/lm_layout.dart'
    show LmLayout, LmLayoutTier, LmMeasure, LmReadingConstraints;

abstract interface class LmStructure {
  String get id;
  ThemeData assemble(LmPalette palette, Brightness brightness);
  LmComponentKit buildComponents();
}
