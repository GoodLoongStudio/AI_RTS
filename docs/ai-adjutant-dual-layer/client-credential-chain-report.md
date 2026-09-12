# 客户端副官凭证链修复报告

日期：2026-09-08。执行：CodeBuddy（GLM-5.3-Flash）。
真实模型请求：0 次；Hermes takeover：0 次；指挥类游戏命令（move/attack/gather/produce/build）：0 次；现网 /home/ubuntu/AI_RTS 与 24571 对局：零修改。

## 1. 旧 token 来源与删除位置（不输出 token 值）

旧管理 token 曾硬编码于客户端 source/ui/AdjutantButton.gd 第 10 行（const TOKEN 常量，随游戏仓库公开，这正是服务端轮换并整改鉴权的原因）。本次删除位置：AdjutantButton.gd 删除 const TOKEN 常量；takeover/stop、ping 连通测试、tail 轮询三处请求全部改用运行时加载的 _token 变量。全仓库扫描（git ls-files 全部 tracked 文件，二进制除外）：旧 token 字符串 0 出现（测试 test_retired_token_absent_from_tracked_files 断言，防回归）。场景/资源/普通配置从未写入（本次与历史均无）；.godot 导入缓存不涉及。

## 2. 新凭证流（时序与权限边界）

运行时按优先级：1) 环境变量 AI_ADJUTANT_TOKEN（本地开发/专用环境，最高优先级）；2) 受保护用户配置 user://adjutant_credentials.cfg（[adjutant] token=...，玩家本机单用户信任级别等价于游戏存档）；3) 均未配置则为未配置状态（按钮/面板中文提示，不发请求，绝不回退任何默认值）。

时序：用户点击 → 懒加载凭证（_ensure_credential）→ 未配置则中文提示并中止 → 带凭证 POST /adjutant/control → 服务端 /control 统一鉴权（hmac.compare_digest，token 文件 /home/ubuntu/ai-adjutant/config/adjutant_token，600 ubuntu）→ 200 正常 / 403 进入认证失败状态。

权限边界：token 只驻客户端内存，不写日志、面板、场景、Git、普通配置；服务端 token 文件仅 ubuntu 可读（600）。服务端 403 时客户端置 _auth_blocked：停止 tail 自动轮询（重试风暴路径被移除），接管按钮等待用户显式再次点击（点击时重新加载凭证并复位标志），不自动重试。

## 3. 认证失败时的用户行为

未配置：连通测试显示「✗ 副官凭证未配置」，面板显示设置指引（环境变量名/配置文件路径）；点击接管不发请求。403：连通测试显示「✗ 认证失败（403）：凭证无效或未配置」；面板同口径文案；tail 自动轮询停止（不重试风暴）；用户配置或更新凭证后再次点击即可恢复。其他 HTTP 错误：保留状态码的可读提示。

## 4. 测试命令与真实结果

- Godot headless 凭证冒烟（新增 tests/automated/AdjutantCredentialSmokeTest.tscn）：godot --headless --path G:\AIRTS\AI_RTS res://tests/automated/AdjutantCredentialSmokeTest.tscn → exit 0，11 项断言全过（0 failures）：源码无旧 token、缺凭证空串、环境变量最高优先、用户配置次之、环境变量优先于配置、空白环境变量视为未设置、403 文案明确、清理无残留。
- 规则导出冒烟回归：AdjutantRulesExportSmokeTest → exit 0，0 failure(s)（确认 AdjutantButton.gd 改动不影响工程加载）。
- Python 全量：python -m unittest discover -s tests → Ran 115 tests, OK（原 113 + 新增 2：仓库级旧 token 扫描 + 凭证来源支持断言；首个失败为断言前缀误报 const TOKEN_ENV_VAR 命中 const TOKEN 检查，修正断言后通过，已留档）。
- python -m py_compile（新增/修改 py）：exit 0。
- git diff --check：exit 0（仅 CRLF 转 LF 提示，无错误）。

## 5. 本轮修改文件

source/ui/AdjutantButton.gd（凭证链改造：删硬编码、运行时加载、403 状态机、中文提示、tail 防重试风暴）；source/adjutant_coordinator/tests/test_client_credential_source.py（新增 2 项仓库级静态测试）；tests/automated/AdjutantCredentialSmokeTest.gd 与 .tscn（新增 11 项断言）；docs/ai-adjutant-dual-layer/hermes-runtime-validation-report.md（边界说法阶段限定修订节）；本报告。

## 6. 剩余阻塞与用户行动项

1. 新 token 不入库：用户需在本机设置环境变量 AI_ADJUTANT_TOKEN，或在用户目录 adjutant_credentials.cfg 写入 token 值（服务器 /home/ubuntu/ai-adjutant/config/adjutant_token 由用户自行读取，本轮不代读不代传）。
2. 客户端重新发布：客户端构建已不含任何凭证可直接发布；已装机的玩家需按文档完成一次凭证配置。
3. dashboard 弱口令、SSH 口令、stepfun key 轮换：仍需用户在供应商后台或设置页完成（上轮遗留，不变）。
