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
      DNS_ENABLED: "true"
      DNS_DROP_PRIVATE: "false" # 私有地址(局域网)是否入DNS记录表。true表示扔掉不入库
      DNS_INTERFACE: eth1
      DNS_DB_PATH: /data/pmacct.db #DNS主库
      #DNS_REPLICAS: /data/pmacct.db #DNS复制库
      DNS_FLUSH_SECONDS: "60"      # ← 你要的"每分钟一次"
      DNS_MAX_BUFFER: "5000"
      DNS_RETENTION_DAYS: "30"
      ETL_ENABLED: "true"
      FLOW_ETL_INTERVAL: "900"          # 运行周期 15 分钟
      FLOW_ETL_BUCKET_MINUTES: "15"     # 统计桶粒度 15 分钟
      FLOW_ETL_LAG_MINUTES: "2"
    volumes:
      - ./pmacctd.conf:/etc/pmacct/pmacctd.conf:ro
      - ./pmacct_data:/data
    restart: unless-stopped

