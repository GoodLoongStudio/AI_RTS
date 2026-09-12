# 部署固化与安全整改报告

日期：2026-09-08。执行：CodeBuddy（GLM-5.3-Flash）。
真实模型未调用；Hermes 未接管；指挥类游戏命令未发送；现网 /home/ubuntu/AI_RTS 与 24571 对局零修改。

## 1. 本地文件改动

deploy_isolated.py / deploy_runner.py（新增，隔离部署固化）；recon_*/harden*/fix* 过程脚本（不入 git）；本报告与运行时验证报告。游戏侧代码、正式平衡数据、AdjutantButton.gd：零修改（见遗留项）。

## 2. 部署固化（可重复运行）

固定源：本地 HEAD ffa3c9b（tree d7c3fcec），tracked 1964 文件 SHA256 清单；addons/godot_ai（267 文件）为 .gitignore 排除的部署依赖，以 SHA256 清单校验的独立 tar 传输（未入库）。增量对账：首轮 332 mismatch（0.2MB 差异包），补传后复验 after_fix_bad=0、addon_bad=0；第二轮 0 missing / 0 mismatch。构建/验证链（真实 exit code）：dotnet build（0W0E）→ headless import → 规则冒烟（0 failures 断言）→ 隔离目录 Python unittest 113/113 → 启动 server(24575/24577)+client(24578) → networked=true → 初始化测试对局（改变隔离对局状态，已如实记录）→ 四步只读验证（动态断言：身份/规则版本一致、snapshot 递增、tick 不倒退、实体大于 0；status 为旧接口仅验证兼容）→ 按 PID 回收复核。两轮结果：p4_run1b ok=True、p4_run2 ok=True（证据 tmp_logs/hermes_recon/deploy_p4_run1b.json、deploy_p4_run2.json）。TCP 帧解析：4 字节小端长度前缀 + 分包循环 + EOF 与超时处理。

## 3. 安全整改（改前/改后）

daemon TOKEN：源码硬编码（已随游戏仓库公开）→ 从 /home/ubuntu/ai-adjutant/config/adjutant_token（600）读取，新值服务器 openssl 生成未输出；缺失/为空时 /control 全部 503 拒绝；比较用 hmac.compare_digest。管理路由：/control 全动作统一鉴权（takeover/stop/ping/tail 同路径）；/status 只读保留免鉴权（仅暴露 running/pid）。/adjutant/ 公网面：新增 nginx limit_req（30r/m burst=10）+ daemon 层鉴权；nginx -t successful 后 reload。泄露页面 /adjutant-test/index.html（含旧 token）已改名 .leaked_token_removed（公网 404）。dashboard：9119 由 0.0.0.0 改绑 127.0.0.1（对外仅经 80 反代，登录鉴权保留）。悬挂 pidfile：核对后改名 adjutant.pid.stale_20260908（未杀任何被复用进程）。

鉴权实测（服务器本机与公网双视角）：无 token 403；错误 token 403；有效 token ping 200（ok=true game_alive=true latency_ms=44）。注：ping 动作向现网 24571 发送一次只读 op=status 探测（daemon 固有行为，非指挥命令）。

用户访问方式（改后）：游戏内副官按钮需新 token（见遗留）；dashboard 仍经 http://101.43.121.102/ 登录使用；SSH 管理通道不变。

## 4. 回滚备份

位置：服务器 /home/ubuntu/ai-adjutant/backup_20260908/（700/600）：adjutant_daemon.py.orig（原 v1 含旧 token）、nginx_sites/（原配置）。回滚：sudo cp 备份文件回原位并重启 daemon；sudo cp -r backup/nginx_sites/* /etc/nginx/sites-enabled/ 后 nginx -t 与 reload。备份含旧 token，仅存服务器受限目录。

## 5. 现网保护确认（操作前后对照）

24571 对局进程 PID 3426382 全程存活、命令行未变；/home/ubuntu/AI_RTS HEAD 仍 ad04ddc（零改动）；隔离实例 ALL_STOPPED 零残留；无真实模型请求（ping_llm 未执行）、无 Hermes takeover、无指挥类游戏命令；鉴权测试 ping 附带一次 daemon 对现网端点的只读 op=status（固有行为，已记录）。

## 6. 首次失败与修复留档

mkdir 不递归 ENOENT → mkdir -p；全量 archive 1339.8MB 低效 → 哈希对账+差异补传（首轮 diff 0.2MB/332 文件）；Phase1 变量 NameError → 修正；status 断言误用包头字段 → 旧接口仅验证 units 大于 0；backlog 积压与 pkill 自匹配自杀 → 探测限频+按 PID 清理；sudo 密码首变体失败/解释器误写 bash → 双变体 stdin+python3 显式；nginx patch 后 leak 检查缺 import os 中断 → 拆分补跑。全部修复后回归通过，无 FLAKY。

## 7. 遗留与用户行动项

1. 游戏内副官按钮暂时不可用：token 已轮换，客户端 AdjutantButton.gd 仍内置旧值；需更新客户端 token（建议改 user:// 配置或环境变量读取，避免再次硬编码入库）后重新发布；期间 dashboard 手动管理不受影响。
2. dashboard 弱口令、SSH 口令、stepfun key 轮换：需用户在供应商后台或设置页完成（本轮不代做，不阻塞无模型验证）。
3. 服务器 /home/ubuntu/AI_RTS 工作区有他人未提交改动（demo.balance.v1.json 等）：未触碰。
4. /adjutant/ 限速为缓解措施；长期建议管理动作迁移内网或 SSH 隧道。

## 8. 边界声明

真实模型请求（含 ping_llm）：0 次。Hermes takeover：0 次。指挥类游戏命令（move/attack/gather/produce/build）：0 次。线上服务配置修改：仅 daemon 文件（patched）+ nginx（limit_req）+ dashboard 绑定参数，均有备份可回滚。凭证：未打印、未进命令行参数、未进 Git、未进报告与普通日志（服务器 token 文件 600 权限；测试时仅内存与命令内变量使用）。
