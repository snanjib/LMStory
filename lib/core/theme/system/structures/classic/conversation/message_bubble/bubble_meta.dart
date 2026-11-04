import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/settings/domain/entities/display_preferences.dart';
import 'package:lmstory/i18n/strings.g.dart';

// =============================================================================
// Message meta info (对标 ChatBox tips 数组)
// （从 simple_message_bubble.dart 拆出，主文件装配引用）
// =============================================================================

/// 消息元数据条目（对标 ChatBox tips: { label, tooltip? }）
class _MetaTip {
  const _MetaTip(this.label, {this.tooltip});
  final String label;
  final String? tooltip;
}

/// 消息下方的元信息行（模型名·tokens·字数·延迟·时间）
///
/// 对标 ChatBox Message.tsx 的 tips 渲染逻辑：
/// - 所有元数据条目收集到 tips 数组后统一渲染
/// - 样式：11px monospace + faint 色 + `·` 分隔符
/// - 第 2 项起前缀 `· `
/// - 生成中不显示 tokens/首字延迟（对标 !msg.generating）
/// - 单位词硬编码英文（tokens/words/s）— 技术缩写跨语言可读
class BubbleMessageMeta extends StatelessWidget {
  const BubbleMessageMeta({
    required this.message,
    required this.isStreaming,
    required this.isUser,
    required this.displayPreferences,
    required this.colors,
    super.key,
    this.modelNameFallback,
  });

  final ChatMessage message;
  final bool isStreaming;
  final bool isUser;
  final DisplayPreferences displayPreferences;
  final LmPalette colors;

  /// 模型名兜底值（历史消息可能没有 modelName 字段，使用外部传入值）
  final String? modelNameFallback;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    // 生成中不显示部分元数据（对标 ChatBox !msg.generating）
    final showTokens =
        displayPreferences.showTokenUsed && !isUser && !isStreaming;
    final showWordCount = displayPreferences.showWordCount && !isStreaming;
    final showLatency =
        displayPreferences.showFirstTokenLatency && !isUser && !isStreaming;
    final showModel = displayPreferences.showModelName && !isUser;
    final showTimestamp = displayPreferences.showTimestamp;

    // 构建 tips 列表（对标 ChatBox tips 数组模式）
    final tips = <_MetaTip>[];

    // 续写合并徽标（不受显示偏好开关影响，恒显）
    if (!isUser && message.isContinued) {
      tips.add(_MetaTip(t.chat.continuedBadge));
    }

    if (showModel) {
      final modelName = message.modelName ?? modelNameFallback;
      if (modelName != null && modelName.isNotEmpty) {
        tips.add(
          _MetaTip(
            modelName,
            tooltip: t.settings.chatSettings.modelNameTooltip,
          ),
        );
      }
    }

    if (showTokens && message.tokensUsed != null) {
      tips.add(
        _MetaTip(
          '${message.tokensUsed} tokens',
          tooltip: t.settings.chatSettings.tokensUsedTooltip,
        ),
      );
    }

    if (showWordCount) {
      final content = message.content ?? '';
      final wordCount = _countWords(content);
      if (wordCount > 0) {
        tips.add(
          _MetaTip(
            '$wordCount words',
            tooltip: t.settings.chatSettings.wordCountTooltip,
          ),
        );
      }
    }

    if (showLatency && message.firstTokenLatency != null) {
      final seconds = (message.firstTokenLatency! / 1000).toStringAsFixed(1);
      tips.add(
        _MetaTip(
          '${seconds}s',
          tooltip: t.settings.chatSettings.firstTokenLatencyTooltip,
        ),
      );
    }

    if (showTimestamp) {
      tips.add(_MetaTip(_formatTimestamp(message.createdAt)));
    }

    if (tips.isEmpty) return const SizedBox.shrink();

    // 对标 ChatBox: 11px monospace + faint 色 + `·` 分隔符
    final metaStyle = LmUiTextStyles.caption.copyWith(
      color: colors.faint,
      fontFamily: 'monospace',
      fontSize: 11,
      height: 1.4,
    );

    return Padding(
      padding: const EdgeInsets.only(top: LmSpacing.s3xs),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: LmSpacing.s2xs,
        children: [
          for (var i = 0; i < tips.length; i++) ...[
            if (i > 0) Text('·', style: metaStyle) else const SizedBox.shrink(),
            Text(tips[i].label, style: metaStyle),
          ],
        ],
      ),
    );
  }

  /// 统计字数（对标 ChatBox countWord）
  ///
  /// 中文按字符数计算，英文按空格分词，两者相加。
  /// 简化实现：遍历字符串，中文字符按个计数，连续非空白非中文字符作为一个词。
  int _countWords(String text) {
    if (text.isEmpty) return 0;
    var count = 0;
    var inWord = false;
    for (final char in text.runes) {
      if (_isChinese(char)) {
        count++;
        inWord = false;
      } else if (_isWhitespace(char)) {
        inWord = false;
      } else {
        if (!inWord) {
          count++;
          inWord = true;
        }
      }
    }
    return count;
  }

  bool _isChinese(int rune) {
    // CJK Unified Ideographs 基本区
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        // CJK 扩展 A
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        // CJK 兼容表意文字
        (rune >= 0xF900 && rune <= 0xFAFF);
  }

  bool _isWhitespace(int rune) {
    return rune == 0x20 || // space
        rune == 0x0A || // newline
        rune == 0x0D || // carriage return
        rune == 0x09; // tab
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(dt.year, dt.month, dt.day);

    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';

    if (messageDate == today) {
      return timeStr;
    }

    final thisYearStart = DateTime(now.year);
    if (messageDate.isAfter(thisYearStart) ||
        messageDate.isAtSameMomentAs(thisYearStart)) {
      final month = dt.month.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      return '$month/$day $timeStr';
    }

    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year/$month/$day $timeStr';
  }
}
