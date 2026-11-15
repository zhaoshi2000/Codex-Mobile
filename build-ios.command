#!/bin/bash
cd "$(dirname "$0")"
./build-ios.sh
RESULT=$?
echo
echo "构建脚本退出码：$RESULT"
read -r -p "按回车关闭窗口..." _
exit "$RESULT"
