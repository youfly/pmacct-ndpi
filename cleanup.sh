#!/bin/bash
# ==========================================
# SQLite 数据清理脚本
# 环境变量统一 CLEANUP_ 前缀
# ==========================================
CLEANUP_DAYS=${CLEANUP_DAYS:-7}                          # 数据保留天数
CLEANUP_DB_PATHS=${CLEANUP_DB_PATHS:-/data/pmacct.db}    # 目标库列表，逗号分隔支持多库
CLEANUP_TIMESTAMP_COLUMN=${CLEANUP_TIMESTAMP_COLUMN:-stamp_inserted}  # 时间字段名
CLEANUP_INTERVAL_SECONDS=${CLEANUP_INTERVAL_SECONDS:-3600}            # 清理周期（秒）
CLEANUP_TABLE_FILTER=${CLEANUP_TABLE_FILTER:-}           # 表名过滤正则，空=全部表

echo "🗑️ days=${CLEANUP_DAYS} column=${CLEANUP_TIMESTAMP_COLUMN} dbs=${CLEANUP_DB_PATHS} filter=${CLEANUP_TABLE_FILTER}"
sleep 15

while true; do
  # 与容器同时区的时间字符串 cutoff，匹配 pmacct 的 DATETIME 文本格式
  CUTOFF=$(date -d "-${CLEANUP_DAYS} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
           date -v-${CLEANUP_DAYS}d '+%Y-%m-%d %H:%M:%S')

  IFS=',' read -ra DBS <<< "$CLEANUP_DB_PATHS"
  for DB in "${DBS[@]}"; do
    DB=$(echo "$DB" | tr -d ' ')
    [ -f "$DB" ] || { echo "⚠️ $(date): $DB 不存在，跳过"; continue; }

    TABLES=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null)
    N=0
    for T in $TABLES; do
      [ -n "$CLEANUP_TABLE_FILTER" ] && ! echo "$T" | grep -qE "$CLEANUP_TABLE_FILTER" && continue
      if sqlite3 "$DB" "PRAGMA table_info($T);" 2>/dev/null | grep -q "$CLEANUP_TIMESTAMP_COLUMN"; then
        sqlite3 "$DB" "PRAGMA busy_timeout=5000; DELETE FROM $T WHERE $CLEANUP_TIMESTAMP_COLUMN < '$CUTOFF';"
        N=$((N+1))
      fi
    done
    echo "✅ $(date): $DB 清理 $N 张表 (cutoff=$CUTOFF)"
  done
  sleep "$CLEANUP_INTERVAL_SECONDS"
done
