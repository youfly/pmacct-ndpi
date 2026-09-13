# pmacct-ndpi

```yaml
version: '3.8'

services:
  pmacct:
    image: ghcr.io/youfly/pmacct-ndpi-docker:latest
    container_name: pmacct-dpi
    network_mode: "host"
    cap_add:
      - NET_RAW
      - NET_ADMIN
    environment:
      # 数据保留天数
      - SQLITE_RETENTION_DAYS=7
      # 清理检查间隔（秒）
      - CLEANUP_INTERVAL_SECONDS=3600
      # 数据库路径
      - SQLITE_DB_PATH=/data/pmacct.db
      # 时间戳字段名
      - SQLITE_TIMESTAMP_COLUMN=stamp_start
      # 【可选】表名过滤（不配置则清理所有表）
      # - SQLITE_TABLE_FILTER=traffic|dpi
    volumes:
      - ./pmacctd.conf:/etc/pmacct/pmacctd.conf:ro
      - ./pmacct_data:/data
    restart: unless-stopped

