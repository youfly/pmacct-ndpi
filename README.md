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
      CLEANUP_DAYS: "7"
      CLEANUP_INTERVAL_SECONDS: "3600"
      CLEANUP_DB_PATHS: /data/pmacct.db          # 多库: /data/db_ip.db,/data/db_app.db
      CLEANUP_TIMESTAMP_COLUMN: stamp_inserted
      # 【可选】表名过滤（不配置则清理所有表）
      # - CLEANUP_TABLE_FILTER=traffic|dpi
    volumes:
      - ./pmacctd.conf:/etc/pmacct/pmacctd.conf:ro
      - ./pmacct_data:/data
    restart: unless-stopped

