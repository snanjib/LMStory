import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/failure_classifier.dart';

enum AuxiliaryGenerationFailureKind {
  noConversation,
  modelOrKeyUnavailable,
  timeout,
  network,
  auth,
  rateLimit,
  requestRejected,
  contextOverflow,
  server,
  emptyOutput,
  invalidCandidates,
  titleChanged,
  saveFailed,
  unknown,
}

typedef AuxiliaryGenerationResult<T> = ({
  T? value,
  AuxiliaryGenerationFailure? failure
});

/// Metadata that is safe to show or log for background model requests.
class AuxiliaryGenerationFailure {
  const AuxiliaryGenerationFailure(this.kind)
      : httpStatus = null,
        parameter = null;

  const AuxiliaryGenerationFailure._(
    this.kind,
    this.httpStatus,
    this.parameter,
  );

  factory AuxiliaryGenerationFailure.fromException(Object error) {
    final classified = const StoryFailureClassifier().classifyError(error);
    final status = classified.httpStatus;
    final kind = switch (classified.category) {
      ErrorCategory.timeout => AuxiliaryGenerationFailureKind.timeout,
      ErrorCategory.network => AuxiliaryGenerationFailureKind.network,
      ErrorCategory.auth => AuxiliaryGenerationFailureKind.auth,
      ErrorCategory.rateLimit => AuxiliaryGenerationFailureKind.rateLimit,
      ErrorCategory.request => AuxiliaryGenerationFailureKind.requestRejected,
      ErrorCategory.contextOverflow =>
        AuxiliaryGenerationFailureKind.contextOverflow,
      ErrorCategory.server
          when status != null && status >= 400 && status < 500 =>
        AuxiliaryGenerationFailureKind.requestRejected,
      ErrorCategory.server => AuxiliaryGenerationFailureKind.server,
      _ => AuxiliaryGenerationFailureKind.unknown,
    };
    final parameter = kind == AuxiliaryGenerationFailureKind.requestRejected &&
            error is AppHttpException
        ? _rejectedParameter(error)
        : null;
    return AuxiliaryGenerationFailure._(kind, status, parameter);
  }

  final AuxiliaryGenerationFailureKind kind;
  final int? httpStatus;
  final String? parameter;

  String get diagnostic => [
        'reason=${kind.name}',
        if (httpStatus case final status?) 'httpStatus=$status',
        if (parameter case final field?) 'parameter=$field',
      ].join(', ');

  static const _knownParameters = 'temperature|top_p|presence_penalty|'
      'frequency_penalty|reasoning_effort|max_tokens|max_completion_tokens|'
      'response_format';
  static final _unsupportedParameter = RegExp(
    '''\\b($_knownParameters)\\b["'`]?(?: is)? (?:not supported|unsupported)\\b'''
    r'''|\b(?:unsupported|unknown|unrecognized) parameter\s*:?\s*["'`]?'''
    '''\\b($_knownParameters)\\b''',
    caseSensitive: false,
  );

  static String? _rejectedParameter(AppHttpException error) {
    final message = '${error.message}\n${error.responseBody ?? ''}';
    final match = _unsupportedParameter.firstMatch(message);
    return (match?.group(1) ?? match?.group(2))?.toLowerCase();
  }
}
