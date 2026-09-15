CREATE TABLE IF NOT EXISTS dns_map (
  domain TEXT NOT NULL, ip TEXT NOT NULL,
  first_seen DATETIME NOT NULL, last_seen DATETIME NOT NULL,
  hits INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (domain, ip));
CREATE INDEX IF NOT EXISTS idx_dns_ip ON dns_map(ip);
CREATE INDEX IF NOT EXISTS idx_dns_lastseen ON dns_map(last_seen);
