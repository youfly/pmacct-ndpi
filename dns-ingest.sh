#!/bin/bash
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

LAST_FLUSH_S=$SECONDS          # bash 内建秒表, 无需 date fork

while true; do
    IFS= read -r -t "$FLUSH_SECONDS" line
    rc=$?
    if [ $rc -eq 0 ]; then
        payload=${line#*dns }
        flags="${payload%% *}"
        [[ "$flags" == *"qr"* ]] || continue
        ts=$(echo "$line" | awk '{print $2" "substr($3,1,8)}')
        for token in $payload; do
            if [[ "$token" == *",IN,A,"* ]]; then
                domain="${token%%,IN,A,*}"; ip="${token##*,}"; domain="${domain%.}"
            elif [[ "$token" == *",IN,AAAA,"* ]]; then
                domain="${token%%,IN,AAAA,*}"; ip="${token##*,}"; domain="${domain%.}"
            else
                continue
            fi
            [ -n "$domain" ] && [ -n "$ip" ] || continue
            key="${domain}|${ip}"
            if [ -n "${BUF_HITS[$key]:-}" ]; then
                BUF_HITS[$key]=$((BUF_HITS[$key]+1))
                [[ "$ts" < "${BUF_FIRST[$key]}" ]] && BUF_FIRST[$key]=$ts
                [[ "$ts" > "${BUF_LAST[$key]}" ]] && BUF_LAST[$key]=$ts
            else
                BUF_HITS[$key]=1; BUF_FIRST[$key]=$ts; BUF_LAST[$key]=$ts
            fi
        done
        # 三重触发: 到点刷 / 满仓刷 / (空闲由 read -t 兜底)
        if [ $((SECONDS - LAST_FLUSH_S)) -ge "$FLUSH_SECONDS" ] || \
           [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ]; then
            flush
            LAST_FLUSH_S=$SECONDS
        fi
    elif [ $rc -gt 128 ]; then
        flush; LAST_FLUSH_S=$SECONDS      # 空闲超时兜底
    else
        flush; echo "stdin EOF, exit" >>"$ERRLOG"; exit 0
    fi
done
