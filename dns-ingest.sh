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

while true; do
    IFS= read -r -t "$FLUSH_SECONDS" line
    rc=$?
    if [ $rc -eq 0 ]; then
        # 1. 提取 flags (dns 后面的第一个词，如 QUERY,NOERROR,52550,qr|rd|ra)
        payload=${line#*dns }
        flags="${payload%% *}"
        
        # 2. 只处理响应包 (包含 qr 标志)
        [[ "$flags" == *"qr"* ]] || continue
        
        # 3. 提取时间 (YYYY-MM-DD HH:MM:SS)，直接存入 SQLite DATETIME 列
        ts=$(echo "$line" | awk '{print $2" "substr($3,1,8)}')
        
        # 4. 遍历包内的词，精准匹配 A 和 AAAA 答案记录
        for token in $payload; do
            if [[ "$token" == *",IN,A,"* ]]; then
                domain="${token%%,IN,A,*}"
                ip="${token##*,}"
                domain="${domain%.}"  # 去掉根域名的尾点
            elif [[ "$token" == *",IN,AAAA,"* ]]; then
                domain="${token%%,IN,AAAA,*}"
                ip="${token##*,}"
                domain="${domain%.}"
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
        [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ] && flush
    elif [ $rc -gt 128 ]; then
        flush # 满 60 秒触发
    else
        flush; echo "stdin EOF, exit" >>"$ERRLOG"; exit 0
    fi
done
