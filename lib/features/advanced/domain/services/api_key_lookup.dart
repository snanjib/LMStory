/// Agent Loop 自检所需的最小取 Key 抽象。
///
/// 自检控制器（advanced presentation）此前跨特性直接 import settings
/// 的 data 层具体类 `ApiKeyDatasource`——按「Presentation → Domain ← Data」
/// 分层红线，倒置为：本域声明端口，组合根（core/di/providers.dart）以
/// settings 的 ApiKeyDatasource.read 撕脱适配注入。抽象面按自检实际
/// 消费收窄为单个 read（单成员故取函数类型别名）。
typedef ApiKeyLookup = Future<String?> Function(String presetId);
