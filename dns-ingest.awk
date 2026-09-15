BEGIN {
  DB    = (ENVIRON["DNS_DB_PATH"] != "" ? ENVIRON["DNS_DB_PATH"] : "/data/pmacct.db")
  FLUSH = (ENVIRON["DNS_FLUSH_SECONDS"]+0 > 0 ? ENVIRON["DNS_FLUSH_SECONDS"]+0 : 60)
  MAXB  = (ENVIRON["DNS_MAX_BUFFER"]+0 > 0 ? ENVIRON["DNS_MAX_BUFFER"]+0 : 5000)
  CMD   = "sqlite3 " DB
  last  = systime()
}
function flush(   key, sql, n, K) {
  n = 0; sql = "PRAGMA busy_timeout=10000; BEGIN;"
  for (key in HITS) {
    split(key, K, "|")
    dom = K[1]; gsub(/'/, "''", dom)
    sql = sql " INSERT INTO dns_map(domain,ip,first_seen,last_seen,hits) VALUES('" dom "','" K[2] "','" FIRST[key] "','" LAST[key] "'," HITS[key] ") ON CONFLICT(domain,ip) DO UPDATE SET last_seen=excluded.last_seen, hits=hits+excluded.hits;"
    n++
  }
  last = systime()
  if (n == 0) return
  print sql " COMMIT;" | CMD
  close(CMD)                      # close 即提交并结束该 sqlite3 进程: 每分钟仅 1 次 fork
  delete HITS; delete FIRST; delete LAST
}
function proc(line,   i, payload, flags, ts, nT, T, j, tok, dom, ip, key) {
  gsub(/\\/, "", line)
  i = index(line, "dns ")
  if (i == 0) return
  payload = substr(line, i + 4)
  flags = payload; sub(/ .*/, "", flags)
  if (flags !~ /qr/) return
  nT = split(line, T, " "); ts = T[2] " " substr(T[3], 1, 8)
  nT = split(payload, T, " ")
  for (j = 1; j <= nT; j++) {
    tok = T[j]
    if      (tok ~ /,IN,A,/)    { dom = tok; sub(/,IN,A,.*/, "", dom);    ip = tok; sub(/.*,/, "", ip) }
    else if (tok ~ /,IN,AAAA,/) { dom = tok; sub(/,IN,AAAA,.*/, "", dom); ip = tok; sub(/.*,/, "", ip) }
    else continue
    if (dom == "" || ip == "" || ip ~ /[^0-9a-fA-F.:]/) continue
    sub(/\.$/, "", dom)
    key = dom "|" ip
    if (key in HITS) { HITS[key]++; if (ts < FIRST[key]) FIRST[key] = ts; if (ts > LAST[key]) LAST[key] = ts }
    else { HITS[key] = 1; FIRST[key] = ts; LAST[key] = ts }
  }
}
/^\[/ { if (buf != "") proc(buf); buf = $0; if (systime() - last >= FLUSH || length(HITS) >= MAXB) flush(); next }
      { sub(/^[ \t]+/, ""); buf = buf " " $0; next }
END   { if (buf != "") proc(buf); flush() }
