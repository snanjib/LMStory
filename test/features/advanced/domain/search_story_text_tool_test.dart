import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/search_story_text_tool.dart';

class _Reader implements AgentStoryReader {
  List<AgentStoryRound> rounds = [];
  bool fail = false;
  int loads = 0;

  @override
  Future<List<AgentStoryRound>> readAllRounds() async {
    loads++;
    if (fail) throw StateError('storage unavailable');
    return rounds;
  }

  @override
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  }) async =>
      rounds
          .where(
            (r) => r.turnNumber >= fromTurn && r.turnNumber < fromTurn + count,
          )
          .toList();

  @override
  Future<int> totalRounds() async => rounds.length;
}

AgentStoryRound round(
  int turn, {
  String? user,
  String? text,
  String? reply,
  String? summary,
}) =>
    AgentStoryRound(
      turnNumber: turn,
      createdAt: DateTime(2026),
      userText: user,
      narrativeText: text,
      replyText: reply,
      eventSummaryText: summary,
    );

void main() {
  late _Reader reader;
  late AgentRoundDraft draft;
  late SearchStoryTextTool tool;
  late AgentToolInvocation invocation;
  setUp(() {
    reader = _Reader();
    draft = AgentRoundDraft(turnNumber: 180);
    tool = SearchStoryTextTool(reader: reader, draft: draft);
    invocation = AgentToolInvocation(
      callId: 'text',
      toolName: tool.name,
      stepIndex: 0,
      cancellation: AgentCancellationToken(),
    );
  });
  Future<AgentToolResult> search(
    String query, {
    int limit = 8,
    int offset = 0,
  }) =>
      tool.invoke(
        invocation,
        {'query': query, 'limit': limit, 'offset': offset},
      );

  test('早期原文细节不依赖摘要或后续人物相关记忆', () async {
    reader.rounds = [
      round(32, text: '成员甲的交接凭证是银色方片', summary: '成员甲完成交接'),
      for (var i = 33; i < 180; i++) round(i, text: '成员甲继续行动', summary: '重大事件'),
    ];
    final result = await search('银色方片');
    expect(result.isError, isFalse);
    expect(validateToolOutputSchema(result), isEmpty);
    expect(result.output, contains('[第32轮]'));
    expect(result.output, contains('银色方片'));
    expect(result.metadata?['total'], 1);
    expect(reader.loads, 1);
    expect(draft.calledTools, contains('search_story_text'));
    final original = await reader.readRounds(fromTurn: 32, count: 1);
    expect(original.single.narrativeText, contains('银色方片'));
  });

  test('多词轮内AND可跨来源匹配并忽略大小写', () async {
    reader.rounds = [
      round(2, user: 'ALPHA', text: '短词 Beta'),
      round(1, text: 'alpha'),
      round(3, reply: 'beta'),
    ];
    final result = await search('  alpha   BETA  ');
    expect(result.metadata?['total'], 1);
    expect(result.output, contains('用户输入'));
    expect(result.output, contains('正文'));
  });

  test('短词和特殊字符按字面匹配', () async {
    reader.rounds = [round(1, text: '甲乙 [a.*] %_'), round(2, text: 'axxx')];
    expect((await search('甲乙')).metadata?['total'], 1);
    expect((await search('[a.*] %_')).metadata?['total'], 1);
  });

  test('按轮次升序分页且返回下一页偏移', () async {
    reader.rounds = [
      round(3, text: '词'),
      round(1, text: '词'),
      round(2, text: '词'),
    ];
    final first = await search('词', limit: 2);
    expect(
      first.output.indexOf('[第1轮]'),
      lessThan(first.output.indexOf('[第2轮]')),
    );
    expect(first.metadata?['total'], 3);
    expect(first.metadata?['nextOffset'], 2);
    final last = await search('词', limit: 2, offset: 2);
    expect(last.output, contains('[第3轮]'));
    expect(last.metadata?['nextOffset'], isNull);
    expect((await search('词', offset: 10)).metadata?['hitCount'], 0);
  });

  test('不搜摘要与当前未提交轮次并去重正文回复', () async {
    reader.rounds = [
      round(1, text: '唯一正文', reply: '唯一正文', summary: '隐藏摘要'),
      round(180, text: '未提交'),
    ];
    expect((await search('隐藏摘要')).metadata?['total'], 0);
    expect((await search('未提交')).metadata?['total'], 0);
    final result = await search('唯一正文');
    expect('唯一正文'.allMatches(result.output).length, 1);
    expect(result.metadata?['total'], 1);
  });

  test('命中片段围绕关键词且单来源不超过160字符', () async {
    reader.rounds = [round(1, text: '${'前' * 300}KEY${'后' * 300}')];
    final result = await search('key');
    final snippet = result.output.split('正文：').last.split('\n').first;
    expect(snippet, contains('KEY'));
    expect(snippet.runes.length, lessThanOrEqualTo(160));
  });

  test('重新读取最新原文而不缓存结果', () async {
    reader.rounds = [round(1, text: '旧词')];
    expect((await search('旧词')).metadata?['total'], 1);
    reader.rounds = [round(1, text: '新词')];
    expect((await search('旧词')).metadata?['total'], 0);
    expect((await search('新词')).metadata?['total'], 1);
    expect(reader.loads, 3);
  });

  test('工具取消不伪装成读取失败', () async {
    invocation.cancellation.cancel();
    await expectLater(search('词'), throwsA(isA<AgentCancelledException>()));
    expect(reader.loads, 0);
  });

  test('参数错误不读库，读取异常与无命中区分', () async {
    for (final args in <Map<String, dynamic>>[
      {},
      {'query': '  '},
      {'query': 123},
      {'query': '词', 'limit': 21},
      {'query': '词', 'offset': -1},
      {'query': '词', 'limit': 'bad'},
    ]) {
      expect((await tool.invoke(invocation, args)).isError, isTrue);
    }
    expect(reader.loads, 0);
    expect((await search('词')).isError, isFalse);
    reader.fail = true;
    final failed = await search('词');
    expect(failed.isError, isTrue);
    expect(failed.output, isNot(contains('未命中')));
  });
}
