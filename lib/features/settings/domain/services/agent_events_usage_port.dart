/// 导演事件日志用量读取端口
///
/// settings 域的存储统计只需「事件日志行数 + data 负载字节」这一最小
/// 能力。域层声明端口、由组合根（core/di/providers.dart）适配注入，
/// 避免 domain 直接 import 其他 feature（advanced/data）的仓库实现。
// ignore: one_member_abstracts, 单方法抽象接口为 Clean Architecture 依赖反转所需
abstract interface class AgentEventsUsagePort {
  /// 全表事件行数与 data 负载字节（批 I 膨胀可见口径）。
  Future<({int count, int bytes})> eventsUsage();
}
