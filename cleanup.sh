#!/bin/bash

# ==========================================
# 环境变量配置（可在 docker-compose 中覆盖）
# ==========================================
RETENTION_DAYS=${SQLITE_RETENTION_DAYS:-7}              
DB_PATH=${SQLITE_DB_PATH:-/data/pmacct.db}              
TIMESTAMP_COLUMN=${SQLITE_TIMESTAMP_COLUMN:-stamp_start} 
CHECK_INTERVAL=${CLEANUP_INTERVAL_SECONDS:-3600}        

# 【核心修改】默认不过滤，为空则清理所有表
TABLE_FILTER=${SQLITE_TABLE_FILTER:-""}

echo "🗑️ SQLite 数据保留策略已启用"
echo "📊 数据库: $DB_PATH"
echo "⏱️  保留天数: $RETENTION_DAYS | 时间戳字段: $TIMESTAMP_COLUMN"

# 打印过滤状态
if [ -z "$TABLE_FILTER" ]; then
    echo "🔍 表名过滤: 未启用 (将清理所有包含时间戳字段的表)"
else
    echo "🔍 表名过滤: 仅清理包含 [$TABLE_FILTER] 的表"
fi

# 等待 pmacct 初始化数据库
sleep 15

while true; do
    # 【必须】每次循环重新计算过期时间戳
    EXPIRED_TIMESTAMP=$(date -d "-${RETENTION_DAYS} days" +%s 2>/dev/null || date -v-${RETENTION_DAYS}d +%s)
    
    # 获取所有用户表
    TABLES=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null)
    
    if [ -z "$TABLES" ]; then
        echo "⚠️ $(date): 数据库为空或不存在，跳过清理"
        sleep $CHECK_INTERVAL
        continue
    fi

    CLEANED_COUNT=0
    
    for TABLE in $TABLES; do
        # 【核心逻辑】仅当 TABLE_FILTER 不为空时，才执行过滤检查
        if [ -n "$TABLE_FILTER" ]; then
            if ! echo "$TABLE" | grep -qE "$TABLE_FILTER"; then
                # 如果不符合过滤规则，静默跳过（避免日志刷屏）
                continue
            fi
        fi
        
        # 检查时间戳字段是否存在
        COLUMN_EXISTS=$(sqlite3 "$DB_PATH" "PRAGMA table_info($TABLE);" 2>/dev/null | grep -c "$TIMESTAMP_COLUMN")
        
        if [ "$COLUMN_EXISTS" -gt 0 ]; then
            sqlite3 "$DB_PATH" "PRAGMA busy_timeout = 5000; DELETE FROM $TABLE WHERE $TIMESTAMP_COLUMN < $EXPIRED_TIMESTAMP;"
            echo "✅ $(date): 表 [$TABLE] 清理完成"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
    done
    
    echo "🏁 $(date): 本轮清理结束，共处理 $CLEANED_COUNT 张表"
    sleep $CHECK_INTERVAL
done
