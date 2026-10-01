/// Agent 瀑布钩子类型（dsh waterfall 语义的 Dart 表达）
///
/// 每个钩子收到当前值 [value] 与下游 continuation [next]：
/// - 调用 `await next()` 让下游先决策，再对结果加工（后置加工）
/// - 不调用 [next] 直接返回，短路整条链（前置否决）
///
/// 监听器顺序由注册顺序决定；对"单调 guard"类语义（只能收紧不能放宽），
/// 使用专用 guard 列表（见 AgentToolPipeline），不走本瀑布。
typedef AgentWaterfallHook<T> = Future<T> Function(
  T value,
  Future<T> Function() next,
);

/// 运行瀑布链：hooks 依次获得决策权，[leaf] 为链尾默认实现
///
/// 等价于 `hooks[0](seed, () => hooks[1](seed, () => ... leaf()))`；
/// 任一钩子短路（不调用 next）则其返回值成为整条链的结果。
Future<T> runAgentWaterfall<T>(
  List<AgentWaterfallHook<T>> hooks,
  T seed,
  Future<T> Function() leaf,
) {
  Future<T> chain(int index) {
    if (index >= hooks.length) return leaf();
    return hooks[index](seed, () => chain(index + 1));
  }

  return chain(0);
}
