#!/bin/bash
# entrypoint.sh — pmacct-ndpi 镜像入口
# 职责: (可选)被动DNS采集链 → 后台清理 → 移交主进程(pmacctd)
# DNS 总开关: DNS_ENABLED (默认 true; 想"不配置就完全不动 DNS"改为 false)

DNS_ENABLED="${DNS_ENABLED:-false}"
DNS_IF="${DNS_INTERFACE:-eth1}"
DNS_DB="${DNS_DB_PATH:-/data/pmacct.db}"
DNS_REPLICAS="${DNS_REPLICAS:-}"
DNS_FLUSH="${DNS_FLUSH_SECONDS:-60}"
DNS_REPL_INT="${DNS_REPLICA_INTERVAL:-60}"

# ---------- DNS 1/3: 主库+所有副本 幂等应用表结构(每库仅一次) ----------
dns_init_schema() {
    local db
    for db in $(echo "${DNS_DB},${DNS_REPLICAS}" | tr ',' ' '); do
        if [ -f "$db" ]; then
            sqlite3 "$db" < /etc/pmacct/dns_schema.sql \
                && echo "📋 dns_map schema applied: $db" \
                || echo "⚠️ dns_map schema failed: $db"
        else
            echo "⚠️ dns schema skipped (file missing): $db"
        fi
    done
}

# ---------- DNS 2/3: 采集→聚合→批量写主库(带重启守护) ----------
dns_start_pipeline() {
    (
        while true; do
            dnscap -i "$DNS_IF" -d 2>/dev/null | /usr/local/bin/dns-ingest.sh
            echo "⚠️ dns pipeline exited, restart in 3s" >&2
            sleep 3
        done
    ) &
    echo "🕵️ dnscap started on $DNS_IF (batch=${DNS_FLUSH}s)."
}

# ---------- DNS 3/3: 副本库每分钟从主库幂等拉取(覆写式, 不双计) ----------
dns_start_replicator() {
    local db
    (
        while true; do
            for db in $(echo "$DNS_REPLICAS" | tr ',' ' '); do
                [ -f "$db" ] || continue
                sqlite3 "$db" "PRAGMA busy_timeout=8000;
                  ATTACH '${DNS_DB}' AS p;
                  INSERT INTO main.dns_map(domain,ip,first_seen,last_seen,hits)
                  SELECT domain,ip,first_seen,last_seen,hits FROM p.dns_map
                   WHERE last_seen >= datetime('now','-10 minutes','localtime')
                  ON CONFLICT(domain,ip) DO UPDATE SET
                    first_seen=excluded.first_seen,
                    last_seen=excluded.last_seen,
                    hits=excluded.hits;" 2>>/var/log/dns-sync.err \
                    || echo "⚠️ dns replica sync failed: $db" >&2
            done
            sleep "$DNS_REPL_INT"
        done
    ) &
    echo "🔄 dns replicator started: ${DNS_DB} -> ${DNS_REPLICAS} (every ${DNS_REPL_INT}s)."
}

# ---------- DNS 总闸门: 关闭时一切 DNS 逻辑零痕迹 ----------
if [ "$DNS_ENABLED" = "true" ]; then
    dns_init_schema
    dns_start_pipeline
    [ -n "$DNS_REPLICAS" ] && dns_start_replicator
else
    echo "ℹ️ DNS_ENABLED!=true, 跳过全部 DNS 逻辑 (schema/pipeline/replicas)."
fi

# ---------- 后台清理(保留策略, 与 DNS 无关, 常驻) ----------
/cleanup.sh &

# ---------- 移交主进程(exec 保证信号传递, docker stop 正常停止 pmacctd) ----------
exec "$@"
