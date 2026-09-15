#!/bin/bash
DB=${DNS_DB_PATH:-/data/pmacct.db}
FLUSH_SECONDS=${DNS_FLUSH_SECONDS:-60}
MAX_BUFFER=${DNS_MAX_BUFFER:-5000}
ERRLOG=/tmp/dns-ingest.err 

declare -A BUF_HITS BUF_FIRST BUF_LAST
LAST_FLUSH_S=$SECONDS

# 核心处理函数：解析单行（已合并）并放入 Buffer
process_packet() {
    local line="$1"
    line=${line//\\/}
    local payload=${line#*dns }
    local flags="${payload%% *}"
    [[ "$flags" == *"qr"* ]] || return 0
    
    local ts_date ts_time
    read -r _ ts_date ts_time _ <<< "$line"
    local ts="${ts_date} ${ts_time:0:8}"
    
    local token domain ip key
    for token in $payload; do
        if [[ "$token" == *",IN,A,"* ]]; then
            domain="${token%%,IN,A,*}"; ip="${token##*,}"; domain="${domain%.}"
        elif [[ "$token" == *",IN,AAAA,"* ]]; then
            domain="${token%%,IN,AAAA,*}"; ip="${token##*,}"; domain="${domain%.}"
        else
            continue
        fi
        [ -n "$domain" ] && [ -n "$ip" ] || continue
        [[ "$ip" =~ [^0-9a-fA-F.:] ]] && continue
        
        key="${domain}|${ip}"
        if [ -n "${BUF_HITS[$key]:-}" ]; then
            BUF_HITS[$key]=$((BUF_HITS[$key]+1))
            [[ "$ts" < "${BUF_FIRST[$key]}" ]] && BUF_FIRST[$key]=$ts
            [[ "$ts" > "${BUF_LAST[$key]}" ]] && BUF_LAST[$key]=$ts
        else
            BUF_HITS[$key]=1; BUF_FIRST[$key]=$ts; BUF_LAST[$key]=$ts
        fi
    done
}

flush() {
    [ ${#BUF_HITS[@]} -eq 0 ] && return 0
    local sql="PRAGMA busy_timeout=10000; BEGIN;" key domain ip
    for key in "${!BUF_HITS[@]}"; do
        domain=${key%%|*}; ip=${key#*|}
        domain=${domain//\'/\'\'}
        sql+=" INSERT INTO dns_map(domain,ip,first_seen,last_seen,hits)
               VALUES('${domain}','${ip}','${BUF_FIRST[$key]}','${BUF_LAST[$key]}',${BUF_HITS[$key]})
               ON CONFLICT(domain,ip) DO UPDATE SET
                 last_seen=excluded.last_seen, hits=hits+excluded.hits;"
    done
    sql+=" COMMIT;"
    if ! sqlite3 "$DB" "$sql" 2>>"$ERRLOG"; then
        echo "❌ $(date) FLUSH FAILED" >>"$ERRLOG"
    fi
    BUF_HITS=(); BUF_FIRST=(); BUF_LAST=()
    LAST_FLUSH_S=$SECONDS
}
trap 'flush' EXIT TERM INT

current_packet=""
while true; do
    IFS= read -r -t "$FLUSH_SECONDS" line
    rc=$?
    
    if [ $rc -eq 0 ]; then
        # 遇到新包的开头 [ ，处理上一个包
        if [[ "$line" == \[* ]]; then
            [ -n "$current_packet" ] && process_packet "$current_packet"
            current_packet="$line"
        else
            # 续行，拼接（去掉前导空格）
            stripped="${line#"${line%%[![:space:]]*}"}"
            current_packet="$current_packet $stripped"
        fi
        
        # 检查是否需要 flush
        if [ $((SECONDS - LAST_FLUSH_S)) -ge "$FLUSH_SECONDS" ] || \
           [ ${#BUF_HITS[@]} -ge "$MAX_BUFFER" ]; then
            flush
        fi
    elif [ $rc -gt 128 ]; then
        # 超时触发
        [ -n "$current_packet" ] && { process_packet "$current_packet"; current_packet=""; }
        flush
    else
        # EOF 退出
        [ -n "$current_packet" ] && process_packet "$current_packet"
        flush
        exit 0
    fi
done
