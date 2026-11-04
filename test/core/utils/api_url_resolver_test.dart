import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';

/// ApiUrlResolver 单元测试
///
/// 对标 ChatBox 的 `llm_utils.test.ts`（src/shared/utils/llm_utils.test.ts），
/// 验证 baseUrl 规范化逻辑与 ChatBox 行为一致。
///
/// 核心设计（对标 ChatBox normalizeOpenAIApiHostAndPath）：
/// - 版本号属于 baseUrl，不属于 path
/// - path 只含端点后缀（/chat/completions、/models、/embeddings），不含 /v1
/// - baseUrl 无版本号时自动补 /v1；已有版本号（/v1、/v3、/v4）则保留
void main() {
  group('基础场景 - baseUrl 不含版本号，自动补 /v1', () {
    test('OpenAI 默认 baseUrl + /chat/completions', () {
      expect(
        ApiUrlResolver.resolve('https://api.openai.com', '/chat/completions'),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('DeepSeek 默认 baseUrl + /models', () {
      expect(
        ApiUrlResolver.resolve('https://api.deepseek.com', '/models'),
        'https://api.deepseek.com/v1/models',
      );
    });

    test('NVIDIA NIM baseUrl + /embeddings', () {
      expect(
        ApiUrlResolver.resolve(
          'https://integrate.api.nvidia.com',
          '/embeddings',
        ),
        'https://integrate.api.nvidia.com/v1/embeddings',
      );
    });
  });

  group('baseUrl 含版本号前缀（保留版本号，不补 /v1）', () {
    test('OpenRouter baseUrl /api/v1 + /chat/completions', () {
      expect(
        ApiUrlResolver.resolve(
          'https://openrouter.ai/api/v1',
          '/chat/completions',
        ),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('OpenRouter baseUrl /api/v1 + /models', () {
      expect(
        ApiUrlResolver.resolve('https://openrouter.ai/api/v1', '/models'),
        'https://openrouter.ai/api/v1/models',
      );
    });

    test('用户填 https://api.openai.com/v1 + /chat/completions', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/v1',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });
  });

  group('baseUrl 已含完整端点路径（剥离端点后缀，保留版本号）', () {
    test('baseUrl = .../v1/chat/completions + /chat/completions', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/v1/chat/completions',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('baseUrl = .../v1/chat/completions + /models（端点不同也能正确派生）', () {
      // 关键场景：用户填了 chat 完整 URL，list models 调用应该派生出正确的 URL
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/v1/chat/completions',
          '/models',
        ),
        'https://api.openai.com/v1/models',
      );
    });

    test('baseUrl = .../v1/chat/completions + /embeddings', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/v1/chat/completions',
          '/embeddings',
        ),
        'https://api.openai.com/v1/embeddings',
      );
    });
  });

  group('v3 版本号 - 保留用户填的版本号', () {
    test('baseUrl = .../v3/chat/completions + /chat/completions（保留 /v3）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.example.com/v3/chat/completions',
          '/chat/completions',
        ),
        'https://api.example.com/v3/chat/completions',
      );
    });

    test('baseUrl = .../v3/chat/completions + /models（保留 /v3，派生 models）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.example.com/v3/chat/completions',
          '/models',
        ),
        'https://api.example.com/v3/models',
      );
    });

    test('baseUrl = .../v3 + /chat/completions（保留 /v3）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.example.com/v3',
          '/chat/completions',
        ),
        'https://api.example.com/v3/chat/completions',
      );
    });

    test('baseUrl = .../v3 + /models（保留 /v3）', () {
      expect(
        ApiUrlResolver.resolve('https://api.example.com/v3', '/models'),
        'https://api.example.com/v3/models',
      );
    });
  });

  group('v4 版本号 - 与 v3 同等处理', () {
    test('baseUrl = .../v4 + /chat/completions（保留 /v4）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.example.com/v4',
          '/chat/completions',
        ),
        'https://api.example.com/v4/chat/completions',
      );
    });

    test('baseUrl = .../v4 + /models（保留 /v4）', () {
      expect(
        ApiUrlResolver.resolve('https://api.example.com/v4', '/models'),
        'https://api.example.com/v4/models',
      );
    });

    test('baseUrl = .../v4/chat/completions + /chat/completions', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.example.com/v4/chat/completions',
          '/chat/completions',
        ),
        'https://api.example.com/v4/chat/completions',
      );
    });
  });

  group('火山引擎真实场景', () {
    // 用户反馈：https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions
    // 火山引擎方舟的 coding 端点，实际版本号是 /v3
    test('火山引擎 coding v3 + /chat/completions（保留 /api/coding/v3）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
          '/chat/completions',
        ),
        'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
      );
    });

    test('火山引擎 coding v3 + /models（派生 models 端点）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
          '/models',
        ),
        'https://ark.cn-beijing.volces.com/api/coding/v3/models',
      );
    });

    test('火山引擎 coding v3 + /embeddings（派生 embeddings 端点）', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
          '/embeddings',
        ),
        'https://ark.cn-beijing.volces.com/api/coding/v3/embeddings',
      );
    });

    test('火山引擎 v3（无端点后缀）+ /chat/completions', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/v3',
          '/chat/completions',
        ),
        'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
      );
    });

    test('火山引擎 v3（无端点后缀）+ /models', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/v3',
          '/models',
        ),
        'https://ark.cn-beijing.volces.com/api/v3/models',
      );
    });
  });

  group('自动补 https:// 协议头', () {
    test('用户填 api.openai.com（不带协议）-> 自动补 https://', () {
      expect(
        ApiUrlResolver.resolve('api.openai.com', '/chat/completions'),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('用户填 my-proxy.com/v1 -> 自动补 https://', () {
      expect(
        ApiUrlResolver.resolve('my-proxy.com/v1', '/chat/completions'),
        'https://my-proxy.com/v1/chat/completions',
      );
    });

    test('用户填 http://localhost:8080（http 协议保留）', () {
      expect(
        ApiUrlResolver.resolve('http://localhost:8080', '/chat/completions'),
        'http://localhost:8080/v1/chat/completions',
      );
    });
  });

  group('末尾斜杠处理', () {
    test('baseUrl 末尾带 / 会被自动去掉', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('baseUrl 末尾带多个 / 会被全部去掉', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com//',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('baseUrl 末尾带 / + 版本号场景', () {
      expect(
        ApiUrlResolver.resolve(
          'https://openrouter.ai/api/v1/',
          '/models',
        ),
        'https://openrouter.ai/api/v1/models',
      );
    });

    test('火山引擎 URL 末尾带 / 也能正确处理', () {
      expect(
        ApiUrlResolver.resolve(
          'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions/',
          '/chat/completions',
        ),
        'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
      );
    });
  });

  group('空格处理', () {
    test('baseUrl 前后有空格会被 trim', () {
      expect(
        ApiUrlResolver.resolve(
          '  https://api.openai.com  ',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });
  });

  group('raw 模式 - 手动输入完整 URL', () {
    test('raw + 完整 URL -> 原样返回', () {
      expect(
        ApiUrlResolver.resolve(
          'raw:https://api.example.com/v3/chat/completions',
          '/chat/completions',
        ),
        'https://api.example.com/v3/chat/completions',
      );
    });

    test('raw + 完整 URL + 调用 models -> 原样返回（可能 404，由用户负责）', () {
      expect(
        ApiUrlResolver.resolve(
          'raw:https://api.example.com/v3/chat/completions',
          '/models',
        ),
        'https://api.example.com/v3/chat/completions',
      );
    });

    test('raw + 非标准端点 -> 原样返回', () {
      expect(
        ApiUrlResolver.resolve(
          'raw:https://api.example.com/v4/chat/completion',
          '/chat/completions',
        ),
        'https://api.example.com/v4/chat/completion',
      );
    });
  });

  group('isRawMode / displayName 辅助方法', () {
    test('isRawMode - raw 前缀', () {
      expect(ApiUrlResolver.isRawMode('raw:https://api.example.com'), isTrue);
    });

    test('isRawMode - 非 raw 前缀', () {
      expect(ApiUrlResolver.isRawMode('https://api.example.com'), isFalse);
    });

    test('displayName - raw 前缀被去掉', () {
      expect(
        ApiUrlResolver.displayName('raw:https://api.example.com'),
        'https://api.example.com',
      );
    });

    test('displayName - 非 raw 前缀原样返回', () {
      expect(
        ApiUrlResolver.displayName('https://api.example.com'),
        'https://api.example.com',
      );
    });
  });

  group('ChatBox 测试用例对标（src/shared/utils/llm_utils.test.ts）', () {
    test('ChatBox: apiHost=https://api.openai.com -> 自动补 /v1', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('ChatBox: apiHost=.../v1/chat/completions -> 拆分端点', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.openai.com/v1/chat/completions',
          '/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('ChatBox: apiHost=https://openrouter.ai/api/v1 -> 保留', () {
      expect(
        ApiUrlResolver.resolve(
          'https://openrouter.ai/api/v1',
          '/chat/completions',
        ),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('ChatBox: apiHost=.../v1/chat/completions/ -> 去末尾斜杠', () {
      expect(
        ApiUrlResolver.resolve(
          'https://openrouter.ai/api/v1/chat/completions/',
          '/chat/completions',
        ),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('ChatBox: apiHost=my-proxy.com -> 自动补 https:// + /v1', () {
      expect(
        ApiUrlResolver.resolve('my-proxy.com', '/chat/completions'),
        'https://my-proxy.com/v1/chat/completions',
      );
    });

    test('ChatBox: apiHost=http://my-proxy.com -> 保留 http:// + 补 /v1', () {
      expect(
        ApiUrlResolver.resolve('http://my-proxy.com', '/chat/completions'),
        'http://my-proxy.com/v1/chat/completions',
      );
    });
  });

  group('Anthropic 全端点粘贴', () {
    test('baseUrl 含 /v1/messages 时剥离后不重复', () {
      expect(
        ApiUrlResolver.resolve(
          'https://api.anthropic.com/v1/messages',
          '/messages',
        ),
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('无版本号的 /messages 不误剥离，raw 模式原样使用', () {
      expect(
        ApiUrlResolver.resolve(
          'raw:https://proxy.example.com/messages',
          '/messages',
        ),
        'https://proxy.example.com/messages',
      );
    });
  });
}
