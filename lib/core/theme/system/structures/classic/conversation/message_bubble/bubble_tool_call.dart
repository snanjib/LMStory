import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

// =============================================================================
// Tool call section
// （从 simple_message_bubble.dart 拆出，内容区引用）
// =============================================================================

/// Collapsible section showing tool call details.
///
/// Header: tool icon + function name + status indicator.
/// When expanded: shows arguments (formatted JSON) and result.
class BubbleToolCallSection extends StatefulWidget {
  const BubbleToolCallSection({
    required this.toolCalls,
    required this.colors,
    super.key,
  });

  final List<ToolCallData> toolCalls;
  final LmPalette colors;

  @override
  State<BubbleToolCallSection> createState() => _BubbleToolCallSectionState();
}

class _BubbleToolCallSectionState extends State<BubbleToolCallSection> {
  /// Track expanded state per tool call index
  final Set<int> _expandedIndices = {};

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: LmSpacing.sXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.toolCalls.length; i++)
            _ToolCallItem(
              toolCall: widget.toolCalls[i],
              isExpanded: _expandedIndices.contains(i),
              colors: widget.colors,
              onToggle: () => setState(() {
                if (_expandedIndices.contains(i)) {
                  _expandedIndices.remove(i);
                } else {
                  _expandedIndices.add(i);
                }
              }),
              t: t,
            ),
        ],
      ),
    );
  }
}

/// Single tool call item with collapsible details.
class _ToolCallItem extends StatelessWidget {
  const _ToolCallItem({
    required this.toolCall,
    required this.isExpanded,
    required this.colors,
    required this.onToggle,
    required this.t,
  });

  final ToolCallData toolCall;
  final bool isExpanded;
  final LmPalette colors;
  final VoidCallback onToggle;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: LmSpacing.s2xs),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: InkWell(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LmSpacing.sSm,
              vertical: LmSpacing.sXs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.build_outlined,
                      size: 14,
                      color: colors.primary,
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    Expanded(
                      child: Text(
                        toolCall.name,
                        style: LmUiTextStyles.caption.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: colors.faint,
                    ),
                  ],
                ),
                if (isExpanded) ...[
                  const SizedBox(height: LmSpacing.s2xs),
                  Divider(height: 1, color: colors.divider),
                  const SizedBox(height: LmSpacing.s2xs),
                  // Arguments
                  Text(
                    t.chat.toolCall.arguments,
                    style: LmUiTextStyles.overline.copyWith(
                      color: colors.muted,
                    ),
                  ),
                  const SizedBox(height: LmSpacing.s3xs),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(LmSpacing.sXs),
                    decoration: BoxDecoration(
                      color: colors.surfaceVariant,
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.sm),
                      ),
                    ),
                    child: Text(
                      _formatJson(toolCall.arguments),
                      style: LmUiTextStyles.bodySm.copyWith(
                        color: colors.muted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  // Result (if available)
                  if (toolCall.result != null) ...[
                    const SizedBox(height: LmSpacing.sXs),
                    Text(
                      t.chat.toolCall.result,
                      style: LmUiTextStyles.overline.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    const SizedBox(height: LmSpacing.s3xs),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(LmSpacing.sXs),
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.sm),
                        ),
                      ),
                      child: Text(
                        _formatJson(toolCall.result!),
                        style: LmUiTextStyles.bodySm.copyWith(
                          color: colors.muted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                  if (toolCall.result == null) ...[
                    const SizedBox(height: LmSpacing.sXs),
                    Text(
                      t.chat.toolCall.noResult,
                      style: LmUiTextStyles.caption.copyWith(
                        color: colors.faint,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Format a JSON string with indentation for display.
  String _formatJson(String jsonString) {
    try {
      final decoded = const JsonDecoder().convert(jsonString);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      // Not valid JSON, return as-is
      return jsonString;
    }
  }
}
