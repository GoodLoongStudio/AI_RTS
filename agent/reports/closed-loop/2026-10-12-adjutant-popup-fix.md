# 副官启动弹 cmd 黑窗修复（2026-10-12）

状态：**修复完成并经探针实测验证；真实 ollama 的下一次启动端到端待 ollama 未运行时自然生效。**

## 现象

用户实机截图：启动 AI 副官后屏幕常驻一个黑窗（标题 cmd.exe，内容为 ollama serve 日志：`OLLAMA_MODELS=...\build\adjutant_runtime\models`、`Listening on 127.0.0.1:11436`）。

## 根因（三处叠加，均实测）

1. `AdjutantModelService._spawn_detached()` 经 WMI `Win32_Process.Create` 创建 `cmd.exe /c start_model_service.cmd`。**WMI 默认启动信息会为 cmd 新建一个可见控制台**；`.cmd` 里 `start "" /B ollama.exe serve` 让服务继承该控制台并把日志打在里面 → 黑窗常驻（Win11 下该控制台以 Windows Terminal 载体出现，窗口类 `CASCADIA_HOSTING_WINDOW_CLASS`，与用户截图一致）。
2. 生成的 ps1 **含中文注释**，而文件是**无 BOM UTF-8**；`powershell -File` 按 ANSI/GBK 解读 → 乱码吞掉换行 → 语法错（`} catch { }`）→ 整个 ps1 不执行（exit 1）→ 退回 `OS.create_process` 兜底。
3. 隐藏控制台（ShowWindow=0）与 WMI 直建 cmd 在 Win11 Terminal 宿主下**不可靠**：实测 cmd 进程活着却**从不执行脚本**（探针心跳不出现）——"窗口没了、服务也没起来"，不可接受。

## 改动（`source/ui/AdjutantModelService.gd`，+32/−4）

1. ps1/cmd 内容**全部纯 ASCII**（注释改英文；"无 BOM UTF-8 + PS 5.1 GBK 解读"这个坑写进代码注释）。
2. `.cmd` 不再用 `start /B`：直接 `call "<服务 exe>" serve > "<日志>" 2>&1` —— 服务输出落 `adjutant_logs/model_service.log`（不再刷屏、便于排查），路径反斜杠化。
3. 宿主改为 **wscript + VBS**：ps1 生成 `launch_model_service.vbs`（`CreateObject("WScript.Shell").Run "cmd /c ""<cmd>""", 0, False`），再用 WMI 创建 **`wscript.exe`**（GUI 子系统，**根本不分配控制台**）+ window style 0 → **无窗口且命令确实执行**。
4. 兜底路径（WMI 失败）不变（普通子进程）。

## 证据

- 验证测试 `tests/automated/AdjutantModelSpawnHiddenTest.gd/.tscn`（新增，专项；**未加入 127 套全量清单**——它写 user:// 文件且依赖 WMI，避免与并行会话互相干扰）：
  - 真实调用产品 `_spawn_detached()`，用无害探针（`probe_service.cmd`：8 秒心跳 + ping）替代 ollama；
  - 最终结果 `0 failure(s)`：pid 有效、生成的 ps1 三项静态断言（wscript 宿主 / VBS 启动器 / CreateObject）通过、**探针心跳新鲜（1 秒前）**。
- **可见控制台窗口计数**（EnumWindows 统计 `ConsoleWindowClass`/`CASCADIA_HOSTING_WINDOW_CLASS`）：探针运行期间 **delta = 0**（对照：用户报告的弹窗正是该类窗口）。
- 解析校验：`godot --headless --check-only --script res://source/ui/AdjutantModelService.gd` rc=0。
- 证据目录：`agent/runs/2026-10-12-adjutant-popup-fix/`（verify_hidden_spawn.ps1、spawn-hidden-run.log、diag_*.ps1、user_cmd_backup/）。

## 对用户现场的影响与后续

- **已弹出的那个黑窗不会被自动关闭**：请直接关掉；之后启动副官/游戏不会再有新窗口。
- 若 ollama **已在运行**（当前即如此），游戏不会再执行拉起 → 本次改动对当前对局无影响；下次 ollama 未运行时由新逻辑静默拉起。
- ollama 日志从"窗口刷屏"改为落 `%APPDATA%\Godot\app_userdata\Open RTS\adjutant_logs\model_service.log`。

## 未验证项

- **真实 ollama 走新 ps1 的端到端**：11436 已有实例（拉起会因端口冲突秒退），本轮不做；下次 ollama 未运行时自然生效（生成物由同一产品逻辑产出）。
- 用户环境"游戏控制台窗口类是否恒为 CASCADIA"未逐机核实；判据用"可见控制台窗口数不变 + 命令真的执行"。

## 回滚

- 产品文件：`git checkout -- source/ui/AdjutantModelService.gd`（本轮只动这一个产品文件；新增测试文件可单独删除）。
- 用户目录启动文件备份：`agent/runs/2026-10-12-adjutant-popup-fix/user_cmd_backup/`（已恢复到位；这两个文件每次启动都会被产品重写）。
