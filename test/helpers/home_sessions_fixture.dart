import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';

HomeSessions homeSessionsFixture(List<ChatSession> sessions) {
  final stories = sessions
      .where(
        (s) => s.mode == ChatMode.intermediate || s.mode == ChatMode.advanced,
      )
      .toList()
    ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
  return (recent: sessions.take(5).toList(), latestStory: stories.firstOrNull);
}
