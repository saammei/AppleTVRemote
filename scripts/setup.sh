#!/bin/bash
# 安装 AppleTVRemote 后端运行环境（pyatv）到用户目录，供应用直接使用。
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/AppleTVRemote"
VENV="$APP_SUPPORT/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$APP_SUPPORT"

if [ ! -x "$VENV/bin/python3" ]; then
    echo "创建 Python 虚拟环境: $VENV"
    python3 -m venv "$VENV"
fi

echo "安装/更新依赖（pyatv）…"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install -r "$PROJECT_DIR/requirements.txt"

echo
echo "完成！后端 Python 位于: $VENV/bin/python3"
echo "现在可以启动 AppleTVRemote 应用了。"
