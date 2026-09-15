#!/bin/bash
# dns-ingest.sh v2 — 从 stdin 读 passivedns 竖线分隔输出；
# 内存聚合，每 DNS_FLUSH_SECONDS(默认60) 秒以单事务批量 upsert 进 dns_map。
DB=${DNS_DB_PATH:-/data/pmacct.db}
FLUSH_SECONDS=${DNS_FLUSH_SECONDS:-60}
MAX_BUFFER=${DNS_MAX_BUFFER:-5000}          # 缓冲条目上限，防内存膨胀
ERRLOG=/var/log/dns-ingest.err

declare -A BUF_HITS BUF_FIRST BUF_LAST

flush() {
    [ ${#BUF_HITS[@]} -eq 0 ] && return 0
    local sql="PRAGMA busy_timeout=10000; BEGIN;" key domain ip
    for key in "${!BUF_HITS[@]}"; do
        domain=${key%%|*}; ip=${key#*|}
        domain=${domain//\'/\'\'}; ip=${ip//\'/\'\'}
        sql+=" INSERT INTO dns_map(domain,ip,first_seen,last_seen,hits)
               VALUES('${domain}','${ip}',
                      datetime(${BUF_FIRST[$key]},'unixepoch','localtime'),
                      datetime(${BUF_LAST[$key]},'unixepoch','localtime'),
                      ${BUF_HITS[$key]})
               ON CONFLICT(domain,ip) DO UPDATE SET
                 last_seen=excluded.last_seen, hits=hits+excluded.hits;"
    done
    sql+=" COMMIT;"
    if sqlite3 "$DB" "$sql" 2>>"$ERRLOG"; then
        BUF_HITS=(); BUF_FIRST=(); BUF_LAST=()      # 事务原子: 成功才清缓冲
    else
        echo "⚠️ $(date) flush failed, buffer kept for retry" >>"$ERRLOG"
        return 1                                     # 原子性保证重试不双计
    fi
}
trap 'flush' EXIT TERM INT                           # 容器停止前把残余写掉

while true; do
    IFS='|' read -r -t "$FLUSH_SECONDS" ts client domain type answer ttl cnt
    rc=$?
    if [ $rc -eq 0 ]; then
        case "$type" in A|AAAA) ;; *) continue ;; esac
        [ -n "$domain" ] && [ -n "$answer" ] || continue
        ts=${ts%%.*}                                 # 去掉小数秒
        key="${domain}|${answer}"
        if [ -n "${BUF_HITS[$key]:-}" ]; then
            BUF_HITS[$key]=$((BUF_HITS[$key]+1))
            [ "$ts" -lt "${BUF_FIRST[$key]}" ] && BUF_FIRST[$key]=$ts
            [ "$ts" -gt "${BUF_LAST[$key]}" ] && BUF_LAST[$key]=$ts
        else
            BUF_HITS[$key]=1; BUF_FIRST[$key]=$ts; BUF_LAST[$key]=$ts
        fi
        [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ] && flush   # 尺寸保险丝
    elif [ $rc -gt 128 ]; then
        flush                                        # read 超时=满一分钟
    else
        flush; echo "stdin EOF, exit (supervisor restarts)" >>"$ERRLOG"; exit 0
    fi
done
