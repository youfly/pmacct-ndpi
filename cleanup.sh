#!/bin/bash
RETENTION_DAYS=${SQLITE_RETENTION_DAYS:-7}
DB_PATHS=${SQLITE_DB_PATH:-/data/pmacct.db}        # 支持逗号分隔多库
TIMESTAMP_COLUMN=${SQLITE_TIMESTAMP_COLUMN:-stamp_inserted}
CHECK_INTERVAL=${CLEANUP_INTERVAL_SECONDS:-3600}
TABLE_FILTER=${SQLITE_TABLE_FILTER:-}

echo "🗑️ retention=${RETENTION_DAYS}d column=$TIMESTAMP_COLUMN dbs=$DB_PATHS table_filter=$TABLE_FILTER"
sleep 15

while true; do
  # 用与容器同时区的"时间字符串"做 cutoff，匹配 pmacct 的 DATETIME 文本格式
  CUTOFF=$(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
           date -v-${RETENTION_DAYS}d '+%Y-%m-%d %H:%M:%S')
  IFS=',' read -ra DBS <<< "$DB_PATHS"
  for DB in "${DBS[@]}"; do
    DB=$(echo "$DB" | tr -d ' ')
    [ -f "$DB" ] || { echo "⚠️ $(date): $DB 不存在，跳过"; continue; }
    TABLES=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null)
    N=0
    for T in $TABLES; do
      [ -n "$TABLE_FILTER" ] && ! echo "$T" | grep -qE "$TABLE_FILTER" && continue
      if sqlite3 "$DB" "PRAGMA table_info($T);" 2>/dev/null | grep -q "$TIMESTAMP_COLUMN"; then
        sqlite3 "$DB" "PRAGMA busy_timeout=5000; DELETE FROM $T WHERE $TIMESTAMP_COLUMN < '$CUTOFF';"
        N=$((N+1))
      fi
    done
    echo "✅ $(date): $DB 清理 $N 张表 (cutoff=$CUTOFF)"
  done
  sleep "$CHECK_INTERVAL"
done
