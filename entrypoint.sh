#!/bin/bash

# 启动后台清理脚本
/cleanup.sh &

# 启动 pmacctd (使用 exec 确保信号传递，让 docker stop 能正常停止容器)
exec "$@"
