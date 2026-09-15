#!/bin/bash
DB=${DNS_DB_PATH:-/data/pmacct.db}
FLUSH_SECONDS=${DNS_FLUSH_SECONDS:-60}
MAX_BUFFER=${DNS_MAX_BUFFER:-5000}
# 改到 /tmp 避免 /var/log 权限问题
ERRLOG=/tmp/dns-ingest.err 

declare -A BUF_HITS BUF_FIRST BUF_LAST

flush() {
    [ ${#BUF_HITS[@]} -eq 0 ] && return 0
    
    local sql="PRAGMA busy_timeout=10000; BEGIN;" key domain ip
    for key in "${!BUF_HITS[@]}"; do
        domain=${key%%|*}; ip=${key#*|}
        # 严格过滤：如果 IP 里还有奇怪的字符（比如反斜杠），直接丢弃
        if [[ "$ip" =~ [^0-9a-fA-F.:] ]]; then
            echo "⚠️ Dirty IP skipped: $ip" >>"$ERRLOG"
            continue
        fi
        domain=${domain//\'/\'\'}
        sql+=" INSERT INTO dns_map(domain,ip,first_seen,last_seen,hits)
               VALUES('${domain}','${ip}','${BUF_FIRST[$key]}','${BUF_LAST[$key]}',${BUF_HITS[$key]})
               ON CONFLICT(domain,ip) DO UPDATE SET
                 last_seen=excluded.last_seen, hits=hits+excluded.hits;"
    done
    sql+=" COMMIT;"
    
    # 执行 SQL，如果失败，把错误和当时的 SQL 片段打印出来！
    if ! sqlite3 "$DB" "$sql" 2>>"$ERRLOG"; then
        echo "❌ $(date) FLUSH FAILED! See SQL snippet:" >>"$ERRLOG"
        echo "${sql:0:200}..." >>"$ERRLOG"
        # 失败也清空 buffer，防止死循环堆积
        BUF_HITS=(); BUF_FIRST=(); BUF_LAST=()
    else
        BUF_HITS=(); BUF_FIRST=(); BUF_LAST=()
    fi
}
trap 'flush' EXIT TERM INT

LAST_FLUSH_S=$SECONDS

while true; do
    IFS= read -r -t "$FLUSH_SECONDS" line
    rc=$?
    if [ $rc -eq 0 ]; then
        # 【修复1】：暴力清除行内所有的反斜杠 \ ，防止续行符污染 Token
        line=${line//\\/}

        payload=${line#*dns }
        flags="${payload%% *}"
        [[ "$flags" == *"qr"* ]] || continue
        
        # 【修复2】：纯 Bash 提取时间，避免 echo/awk 吞字符
        read -r _ ts_date ts_time _ <<< "$line"
        ts="${ts_date} ${ts_time:0:8}"
        
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
        
        if [ $((SECONDS - LAST_FLUSH_S)) -ge "$FLUSH_SECONDS" ] || \
           [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ]; then
            flush
            LAST_FLUSH_S=$SECONDS
        fi
    elif [ $rc -gt 128 ]; then
        flush; LAST_FLUSH_S=$SECONDS
    else
        flush; echo "stdin EOF, exit" >>"$ERRLOG"; exit 0
    fi
done
