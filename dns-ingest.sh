#!/bin/bash
# dns-ingest.sh v3 — stdin 读 dnscap -d 文本输出；内存聚合，每 DNS_FLUSH_SECONDS 秒单事务批量 upsert
DB=${DNS_DB_PATH:-/data/pmacct.db}
FLUSH_SECONDS=${DNS_FLUSH_SECONDS:-60}
MAX_BUFFER=${DNS_MAX_BUFFER:-5000}
ERRLOG=/var/log/dns-ingest.err

declare -A BUF_HITS BUF_FIRST BUF_LAST

flush() {
    [ ${#BUF_HITS[@]} -eq 0 ] && return 0
    local sql="PRAGMA busy_timeout=10000; BEGIN;" key domain ip
    for key in "${!BUF_HITS[@]}"; do
        domain=${key%%|*}; ip=${key#*|}
        domain=${domain//\'/\'\'}; ip=${ip//\'/\'\'}
        sql+=" INSERT INTO dns_map(domain,ip,first_seen,last_seen,hits)
               VALUES('${domain}','${ip}','${BUF_FIRST[$key]}','${BUF_LAST[$key]}',${BUF_HITS[$key]})
               ON CONFLICT(domain,ip) DO UPDATE SET
                 last_seen=excluded.last_seen, hits=hits+excluded.hits;"
    done
    sql+=" COMMIT;"
    if sqlite3 "$DB" "$sql" 2>>"$ERRLOG"; then
        BUF_HITS=(); BUF_FIRST=(); BUF_LAST=()
    else
        echo "⚠️ $(date) flush failed, buffer kept for retry" >>"$ERRLOG"
        return 1
    fi
}
trap 'flush' EXIT TERM INT

while true; do
    read -r -t "$FLUSH_SECONDS" -a T          # 按词切进数组 T
    rc=$?
    if [ $rc -eq 0 ]; then
        # 字段位: T[1]=日期 T[2]=时间 T[6]=QUERY/RESPONSE T[8]=qname; 若你的版本探针显示偏移, 只改这几处下标
        [ "${T[6]:-}" = "RESPONSE" ] || continue
        ts="${T[1]} ${T[2]%%.*}"              # 去微秒 → 'YYYY-MM-DD HH:MM:SS'(字典序=时间序)
        dom="${T[8]%.}"                       # 去尾点
        [ -n "$dom" ] || continue
        for ((i=9; i<${#T[@]}; i++)); do
            tok=${T[i]}
            if [[ $tok =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || \
               [[ $tok == *:* && $tok =~ ^[0-9a-fA-F:]+$ ]]; then
                key="${dom}|${tok}"
                if [ -n "${BUF_HITS[$key]:-}" ]; then
                    BUF_HITS[$key]=$((BUF_HITS[$key]+1))
                    [[ "$ts" < "${BUF_FIRST[$key]}" ]] && BUF_FIRST[$key]=$ts
                    [[ "$ts" > "${BUF_LAST[$key]}" ]] && BUF_LAST[$key]=$ts
                else
                    BUF_HITS[$key]=1; BUF_FIRST[$key]=$ts; BUF_LAST[$key]=$ts
                fi
            fi
        done
        [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ] && flush
    elif [ $rc -gt 128 ]; then
        flush                                # 满一分钟
    else
        flush; echo "stdin EOF, exit (supervisor restarts)" >>"$ERRLOG"; exit 0
    fi
done
