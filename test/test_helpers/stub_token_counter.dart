import 'package:lmstory/core/utils/token_counter.dart';

/// Keeps token-dependent tests deterministic without starting a BPE worker.
class StubTokenCounter extends TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length;

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((text) => text.length).toList();
}
