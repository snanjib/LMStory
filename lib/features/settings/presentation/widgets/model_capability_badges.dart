import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型能力图标组
///
/// 对标 ChatBox ModelList 中的能力图标展示。紧凑横向排列，每个图标带 Tooltip。
/// 用于模型选择弹窗、供应商详情页模型项、默认模型选择页。
class ModelCapabilityBadges extends StatelessWidget {
  const ModelCapabilityBadges({
    required this.capabilities,
    this.size = 14,
    super.key,
  });

  final List<ModelCapability> capabilities;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (capabilities.isEmpty) return const SizedBox.shrink();
    final colors = context.lm.palette;
    // Tooltip 文案入 slang——此前硬编码英文
    //（Vision/Reasoning/Tool use/Web search），与 zh-CN 全中文 UI 不符
    //（中文门禁只拦中文字面量，英文漏网）。
    final t = Translations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: capabilities.map((c) => _badge(colors, c, t)).toList(),
    );
  }

  Widget _badge(
    LmPalette colors,
    ModelCapability cap,
    Translations t,
  ) {
    final spec = _spec(cap, t);
    return Padding(
      padding: const EdgeInsets.only(right: SimpleSpacing.s2xs),
      child: Tooltip(
        message: spec.label,
        child: Icon(spec.icon, size: size, color: spec.color(colors)),
      ),
    );
  }

  _CapabilitySpec _spec(ModelCapability cap, Translations t) {
    final labels = t.settings.modelCapabilities;
    switch (cap) {
      case ModelCapability.vision:
        return _CapabilitySpec(
          icon: Icons.visibility_outlined,
          color: (c) => c.primary,
          label: labels.vision,
        );
      case ModelCapability.reasoning:
        return _CapabilitySpec(
          icon: Icons.lightbulb_outline,
          color: (c) => c.warning,
          label: labels.reasoning,
        );
      case ModelCapability.toolUse:
        return _CapabilitySpec(
          icon: Icons.build_outlined,
          color: (c) => c.success,
          label: labels.toolUse,
        );
      case ModelCapability.webSearch:
        return _CapabilitySpec(
          icon: Icons.travel_explore_outlined,
          color: (c) => c.accent,
          label: labels.webSearch,
        );
    }
  }
}

class _CapabilitySpec {
  const _CapabilitySpec({
    required this.icon,
    required this.color,
    required this.label,
  });
  final IconData icon;
  final Color Function(LmPalette) color;
  final String label;
}
