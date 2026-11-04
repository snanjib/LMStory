import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/lm_interactive_motion.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

class ContinuingStoryCard extends StatelessWidget {
  const ContinuingStoryCard({
    required this.session,
    required this.onTap,
    this.compact = false,
    super.key,
  });

  final ChatSession session;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final preview = session.lastMessagePreview?.trim();
    return LmArrival(
      delay: LmMotion.micro,
      child: LmInteractiveMotion(
        child: context.lmUi.entryCard(
          context,
          onTap: onTap,
          fallbackColor: colors.surface,
          child: Padding(
            padding: const EdgeInsets.all(LmSpacing.sXs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.chat.home.continueStory,
                        style: LmNarrativeTextStyles.label.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ),
                    Text(
                      session.mode == ChatMode.advanced
                          ? t.chat.sidebar.modeDirector
                          : t.chat.sidebar.modeStory,
                      style: LmNarrativeTextStyles.caption.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    if (compact) ...[
                      const SizedBox(width: LmSpacing.sXs),
                      Icon(
                        Icons.arrow_forward,
                        color: colors.primary,
                        size: 18,
                      ),
                    ],
                  ],
                ),
                SizedBox(height: compact ? LmSpacing.sXs : LmSpacing.sMd),
                Text(
                  session.title,
                  style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
                    fontSize: compact ? 24 : 36,
                    color: colors.ink,
                  ),
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!compact && preview != null && preview.isNotEmpty) ...[
                  const SizedBox(height: LmSpacing.sSm),
                  Text(
                    preview,
                    style: LmNarrativeTextStyles.narrativeBody.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (!compact) ...[
                  const SizedBox(height: LmSpacing.sLg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.chat.home.resumeStory,
                          style: LmNarrativeTextStyles.label.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward,
                        color: colors.primary,
                        size: 20,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
