import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_navigation.dart';

/// The narrative palette is supplied by the surrounding theme.
class IntermediateMessageNavigation extends SimpleMessageNavigation {
  const IntermediateMessageNavigation({
    required super.onJumpToTop,
    required super.onPrevUserMessage,
    required super.onNextUserMessage,
    required super.onJumpToBottom,
    required super.visible,
    super.compact,
    super.onAccessibilityFocus,
    super.key,
  });
}
