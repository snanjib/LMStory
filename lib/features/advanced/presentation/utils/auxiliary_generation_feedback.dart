import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart'
    show DirectorTitleUpdateResult;
import 'package:lmstory/features/story_runtime/domain/entities/auxiliary_generation_failure.dart';
import 'package:lmstory/i18n/strings.g.dart';

String directorAuxiliaryFailureText(
  Translations t,
  AuxiliaryGenerationFailure failure,
) {
  final messages = t.advanced.auxiliaryFailure;
  final parameter = failure.parameter;
  final reason = switch (failure.kind) {
    AuxiliaryGenerationFailureKind.noConversation => messages.noConversation,
    AuxiliaryGenerationFailureKind.modelOrKeyUnavailable =>
      messages.modelOrKeyUnavailable,
    AuxiliaryGenerationFailureKind.timeout => messages.timeout,
    AuxiliaryGenerationFailureKind.network => messages.network,
    AuxiliaryGenerationFailureKind.auth => messages.auth,
    AuxiliaryGenerationFailureKind.rateLimit => messages.rateLimit,
    AuxiliaryGenerationFailureKind.requestRejected => parameter == null
        ? messages.requestRejected
        : messages.unsupportedParameter(parameter: parameter),
    AuxiliaryGenerationFailureKind.contextOverflow => messages.contextOverflow,
    AuxiliaryGenerationFailureKind.server => messages.server,
    AuxiliaryGenerationFailureKind.emptyOutput => messages.emptyOutput,
    AuxiliaryGenerationFailureKind.invalidCandidates =>
      messages.invalidCandidates,
    AuxiliaryGenerationFailureKind.titleChanged => messages.titleChanged,
    AuxiliaryGenerationFailureKind.saveFailed => messages.saveFailed,
    AuxiliaryGenerationFailureKind.unknown => messages.unknown,
  };
  final status = failure.httpStatus;
  return status == null
      ? reason
      : messages.withHttpStatus(reason: reason, status: status);
}

String? directorTitleUpdateText(
  Translations t,
  DirectorTitleUpdateResult result,
) {
  if (result.updated) return t.advanced.settings.titleUpdated;
  final failure = result.failure;
  if (failure == null) return null;
  return t.advanced.auxiliaryFailure.titleFailed(
    reason: directorAuxiliaryFailureText(t, failure),
  );
}
