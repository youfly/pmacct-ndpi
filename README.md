# pmacct-ndpi

version: '3.8'

services:
  pmacct:
    image: ghcr.io/你的用户名/pmacct-ndpi-docker:latest
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

  grafana:
    image: grafana/grafana:10.4.0
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_INSTALL_PLUGINS=frser-sqlite-datasource
      - GF_SECURITY_ADMIN_PASSWORD=admin123
    volumes:
      - grafana_data:/var/lib/grafana
      - ./pmacct_data/pmacct.db:/var/lib/grafana/pmacct.db:ro
    restart: unless-stopped
    depends_on:
      - pmacct

volumes:
  grafana_data:
