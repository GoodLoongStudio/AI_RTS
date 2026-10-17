# 直接试玩：按用户指令停止

日期：2026-10-10。工程：`G:/AIRTS/AI_RTS`。

用户最新决定：完整游戏体验由用户自行测试，Agent 只在小功能修改后做相应验证。已停止本轮，不再补测。不把部分过程报为完整验收。

## 实际改动

- 新建本轮计划、历史执行合同、隔离测试驱动和证据。没有修改游戏代码、场景、配表、玩家设置或旧报告，没有更新打包成品。
- 执行 `dotnet build OpenRTS.sln --no-restore --nologo -v minimal`，rc=0，0错误/0警告；更新的编译产物属于本地构建，不是产品源码补丁。第一次构建输出保存因目录缺失失败，创建本轮日志目录后重跑并保留成功日志。
- Git根和三个文档目标checker rc=0。共享树956条既有状态，不reset/clean/stage/commit。

## 停止前有限过程

三个工具资格尝试分别遇到隔离桌面枚举失败、枚举失败和本轮驱动路径分隔符比较错误，分别保留独立目录，未覆盖历史产物。第四实例使用引擎只读原生窗口句柄，在独立Windows桌面运行，不切换用户桌面。

第四实例PID51948、驱动PID49840。发生最小化后只做一次对已核验归属窗口的非激活恢复和NOACTIVATE设置，记录在本轮目录；未使用系统输入、真实光标移动或前台切换。隔离桌面不能证明所有输入不受系统鼠标影响，不能标全面非干扰通过。

有限状态证明正常菜单进入单人练习局（只有Player_0）、无人机点选成功、发送右键移动后位置变化。曾调用已有拖拽和持续按键接口；未完成它们的资格判定。合成鼠标移动位置与读取的viewport鼠标位置不一致是工具限制线索，不能由此判实际玩家操作故障。建造、采矿、生产、战斗、正常退局重开均未完成。

实际打开了菜单、配置、出生和建造尝试截图，曾有恢复后的旧画面，不能把即时捕获当已刷新。录像没有按关键区间完成动态回看，因此本报告不做录像支持的玩法通过判断、不推断性能或产品根因。

## 收尾证据

最后实例在停止请求之前已退出；[exit_observation.json](G:/AIRTS/AI_RTS/agent/runs/20261010-195500-codex-playtest-04/exit_observation.json) 显示 `pre_cleanup_game_rc=0`、`stop_requested=false`，退出原因未核实。控制器停止请求连接被拒，不能报该请求成功。

[cleanup.json](G:/AIRTS/AI_RTS/agent/runs/20261010-195500-codex-playtest-04/cleanup.json) 显示游戏rc=0、cleanup_ok=true；录制子进程rc分别2、0、2，失败或中断录像不算合格证据。前两个失败启动的rc=1发生在工具清理后，不算产品自退证据。

停止后只读检查：本轮11个驱动/游戏/录制PID全部不存在；列明的7个控制端口无TCP监听；最后实例目录无登记文件，命令rc=0。未结束用户或其他会话的实例。

## 证据入口

- [构建日志](G:/AIRTS/AI_RTS/agent/runs/20261010-194610-codex-playtest-01/logs/build.log)
- [启动失败1](G:/AIRTS/AI_RTS/agent/runs/20261010-194610-codex-playtest-01/driver_failure.json)
- [启动失败2](G:/AIRTS/AI_RTS/agent/runs/20261010-195100-codex-playtest-02/driver_failure.json)
- [启动失败3](G:/AIRTS/AI_RTS/agent/runs/20261010-195300-codex-playtest-03/driver_failure.json)
- [第四实例身份](G:/AIRTS/AI_RTS/agent/runs/20261010-195500-codex-playtest-04/identity.json)
- [第四实例动作/状态/截图/录像](G:/AIRTS/AI_RTS/agent/runs/20261010-195500-codex-playtest-04/)

本轮状态：**stopped-by-user / partial，非完整验收。** 无产品candidate/champion晋级。后续按用户分工，在获授权的小功能修改后做范围明确的解析/编译和对应行为验证，不自行恢复本轮完整试玩。
