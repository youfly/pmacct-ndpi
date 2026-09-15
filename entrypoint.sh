#!/bin/bash
# 启动dns解析记录保存
if [ "${DNS_ENABLED:-true}" = "true" ]; then
    DNS_IF=${DNS_INTERFACE:-eth1}
    sqlite3 "${DNS_DB_PATH:-/data/pmacct.db}" < /etc/pmacct/dns_schema.sql \
        && echo "📋 dns_map schema applied."
    ( while true; do
          passivedns -i "$DNS_IF" 2>/dev/null | /usr/local/bin/dns-ingest.sh
          echo "⚠️ dns pipeline exited, restart in 3s" >&2; sleep 3
      done ) &
    echo "🕵️ passivedns started on $DNS_IF (batch=${DNS_FLUSH_SECONDS:-60}s)."
fi

# 启动后台清理脚本
/cleanup.sh &

# 启动 pmacctd (使用 exec 确保信号传递，让 docker stop 能正常停止容器)
exec "$@"
