#!/bin/bash
# 精简内嵌 Python 运行时:删除打包后不需要的组件,减小 DMG 体积。
# 用法: trim_python.sh <python-dir>
set -euo pipefail

PY_DIR="${1:?用法: trim_python.sh <python-dir>}"
LIB="$PY_DIR/lib/python3.12"
SP="$LIB/site-packages"

echo "== 删除 pip 及打包工具(仅安装依赖时需要)"
rm -rf "$SP"/pip "$SP"/pip-*.dist-info \
       "$SP"/setuptools "$SP"/setuptools-*.dist-info \
       "$SP"/wheel "$SP"/wheel-*.dist-info \
       "$SP"/distutils-precedence.pth

echo "== 删除运行用不到的标准库模块"
rm -rf \
  "$LIB"/idlelib \
  "$LIB"/tkinter \
  "$LIB"/turtledemo \
  "$LIB"/lib2to3 \
  "$LIB"/ensurepip \
  "$LIB"/venv \
  "$LIB"/unittest \
  "$LIB"/pydoc_data \
  "$LIB"/wsgiref \
  "$LIB"/xmlrpc \
  "$LIB"/curses \
  "$LIB"/dbm
rm -f "$LIB"/turtle.py "$LIB"/pydoc.py "$LIB"/doctest.py "$LIB"/cgi.py "$LIB"/cgitb.py

echo "== 删除 tcl/tk(仅 tkinter 使用)"
rm -rf "$PY_DIR/lib"/tcl9 "$PY_DIR/lib"/tcl9.0 "$PY_DIR/lib"/tk9.0 \
       "$PY_DIR/lib"/itcl* "$PY_DIR/lib"/thread* \
       "$PY_DIR"/lib/libtcl* "$PY_DIR"/lib/libtk*

echo "== 删除无用的 bin 脚本(保留 python 本体)"
rm -f "$PY_DIR/bin"/idle* "$PY_DIR/bin"/pydoc* "$PY_DIR/bin"/2to3* \
       "$PY_DIR/bin"/pip* "$PY_DIR/bin"/python*-config \
       "$PY_DIR/bin"/atvlog "$PY_DIR/bin"/atvproxy "$PY_DIR/bin"/atvremote \
       "$PY_DIR/bin"/atvscript "$PY_DIR/bin"/cffi-gen-src "$PY_DIR/bin"/idna \
       "$PY_DIR/bin"/miniaudio-documentation "$PY_DIR/bin"/normalizer \
       "$PY_DIR/bin"/srptools "$PY_DIR/bin"/tabulate

echo "== cryptography 瘦身(universal2 → arm64)"
for so in $(find "$SP/cryptography" -name "*.so" -type f); do
  if lipo -info "$so" 2>/dev/null | grep -qE "arm64.*x86_64|x86_64.*arm64"; then
    lipo -thin arm64 "$so" -output "$so.thin"
    mv "$so.thin" "$so"
  fi
done

echo "== 清理字节码缓存(运行时会按需重新生成)"
find "$LIB" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

echo "== 完成,当前大小:"
du -sh "$PY_DIR"
