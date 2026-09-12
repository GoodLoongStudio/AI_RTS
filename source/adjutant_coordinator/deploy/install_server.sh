#!/usr/bin/env bash
# AI 副官（LangGraph）服务器安装脚本：独立目录 + 独立虚拟环境。
#
# 边界（方案 §12）：
# - 只创建 /opt/airts-agent（不碰 /home/ubuntu/AI_RTS、不碰线上 Hermes daemon、不改任何服务）；
# - API Key 只写 /opt/airts-agent/.env（chmod 600），从 ~/.hermes/.env 复制，不回显明文；
# - 幂等：重复执行只做增量（已存在的 venv 不重建）。
#
# 用法（在服务器上）：
#   bash install_server.sh                     # 安装/升级 Python 环境
#   bash install_server.sh --sync-hermes-env   # 额外从 ~/.hermes/.env 提取模型配置
set -euo pipefail

APP_DIR="/opt/airts-agent"
APP_HOME="${APP_DIR}/app"
VENV_DIR="${APP_DIR}/.venv"
ENV_FILE="${APP_DIR}/.env"
HERMES_ENV="${HOME}/.hermes/.env"
REQ_FILE="${APP_HOME}/adjutant_coordinator/requirements-graph.txt"

echo "== [1/6] 目录 =="
if [ ! -d "${APP_DIR}" ]; then
  sudo mkdir -p "${APP_DIR}"
fi
sudo mkdir -p "${APP_HOME}" "${APP_DIR}/state" "${APP_DIR}/logs" "${APP_DIR}/backups"
sudo chown -R "${USER}:${USER}" "${APP_DIR}"
chmod 755 "${APP_DIR}"

echo "== [2/6] 系统 venv 能力 =="
if ! /usr/bin/python3 -c "import ensurepip" >/dev/null 2>&1; then
  echo ">> 安装 python3-venv（系统包）"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-venv >/dev/null
fi

echo "== [3/6] 虚拟环境 =="
if [ ! -x "${VENV_DIR}/bin/python" ]; then
  /usr/bin/python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/python" -m pip install --upgrade pip -q

echo "== [4/6] 依赖安装（requirements-graph.txt） =="
if [ -f "${REQ_FILE}" ]; then
  "${VENV_DIR}/bin/python" -m pip install -q -r "${REQ_FILE}"
else
  echo "!! 未找到 ${REQ_FILE}（先同步代码）" >&2
fi

echo "== [5/6] 模型配置（密钥不落日志） =="
if [ "${1:-}" = "--sync-hermes-env" ]; then
  if [ ! -f "${HERMES_ENV}" ]; then
    echo "!! 未找到 ${HERMES_ENV}" >&2
  else
    umask 077
    STEPFUN_KEY="$(grep -E '^STEPFUN_API_KEY=' "${HERMES_ENV}" | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
    STEPFUN_BASE="$(grep -E '^STEPFUN_BASE_URL=' "${HERMES_ENV}" | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
    DEFAULT_MODEL="$(grep -E '^model:|default:' -A2 "${HOME}/.hermes/config.yaml" 2>/dev/null \
      | grep -E '^\s+default:' | head -1 | awk '{print $2}')"
    : "${DEFAULT_MODEL:=step-3.7-flash}"
    {
      echo "# 自动生成（来源 ~/.hermes/.env 与 ~/.hermes/config.yaml）；请勿提交版本库"
      echo "LLM_BASE_URL=${STEPFUN_BASE:-https://api.stepfun.com/step_plan/v1}"
      echo "LLM_API_KEY=${STEPFUN_KEY}"
      echo "HERMES_MODEL=${DEFAULT_MODEL}"
      echo "STRATEGY_MODEL=${DEFAULT_MODEL}"
      echo "TACTICS_MODEL=${DEFAULT_MODEL}"
      echo "LLM_TIMEOUT_SECONDS=60"
    } > "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    echo ">> 已写 ${ENV_FILE}（mode 600；base_url 与模型名可 cat，密钥不打印）"
    echo ">> base_url/模型："
    grep -vE '^LLM_API_KEY=' "${ENV_FILE}" | sed 's/^/   /'
  fi
fi

echo "== [6/6] 版本自检 =="
"${VENV_DIR}/bin/python" - <<'PY'
import importlib.metadata as m
for name in ("langgraph", "langgraph-checkpoint", "pydantic", "pydantic-ai", "httpx", "aiosqlite"):
    try:
        print("  %-22s %s" % (name, m.version(name)))
    except Exception:
        print("  %-22s MISSING" % name)
PY
echo "== 安装完成：${APP_DIR} =="
