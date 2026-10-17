# RSI Round <NN>：<方向>

## Controller：方向与假设

- 当前 champion：
- 本轮唯一方向：
- 可证伪假设：
- 预期可观察结果：
- 反向闸门：
- 本轮预算/停止条件：
- 关联 checklist：

## Explorer：回放证据

- 基线启动时间：
- 启动方式/实例登记：
- 确定性步骤：
- 正向结果：
- 反向结果：
- 状态/日志路径：
- 截图路径、mtime、肉眼观察：
- 是否复现：`yes` / `no` / `blocked`
- 补丁后新开无头真实 Match：命令/场景/PID/实例：
- 真实实体、命令、位移/到达、伤害或产出、physics ticks：
- 模拟秒/墙钟秒、退出码、错误摘要、`cleanup_ok`：
- `headless_match.json` 路径及产物 mtime：

## Editor：改动意图

- 修改文件：
- 每个改动对应的假设：
- 保留的不变量：
- 预期不会改变的行为：

## Verifier：重放与回归

- 是否从同一基线重放：
- 目标断言：
- 相关套件、rc、marker、forbidden output：
- 独立探针/新会话：
- 新截图已打开：
- 旧证据污染检查：
- 旧功能轨迹是否在同一候选后重放：
- 结论：`promote` / `reject` / `needs-review` / `blocked`

## Global Monitor：检查点决策

- candidate ref/tree hash：
- hard gates：
- quality vector before → candidate：
- champion 是否更新：
- 连续未提升轮数：
- 下一阶段方向或停止原因：
