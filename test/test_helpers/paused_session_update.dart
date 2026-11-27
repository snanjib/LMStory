import 'dart:async';

import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';

class PausedSessionUpdate extends ChatRepositoryImpl {
  PausedSessionUpdate({required super.database});

  final entered = Completer<ChatSession>();
  final resume = Completer<void>();
  final written = Completer<void>();

  @override
  Future<ChatSession> updateSession(ChatSession session) async {
    if (entered.isCompleted) return super.updateSession(session);
    entered.complete(session);
    await resume.future;
    try {
      return await super.updateSession(session);
    } finally {
      written.complete();
    }
  }
}
