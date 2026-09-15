# ==========================================
# 阶段 1: 编译环境 (Builder)
# ==========================================
FROM debian:bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential git autoconf automake libtool pkg-config \
    libpcap-dev libsqlite3-dev libjansson-dev zlib1g-dev \
    libmnl-dev libnuma-dev libnetfilter-log-dev \
    && rm -rf /var/lib/apt/lists/*

RUN (git clone --depth 1 --branch 4.14-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.12-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.10-stable https://github.com/ntop/nDPI.git /tmp/nDPI) && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib && \
    make -j2 && \
    make install

# 【根因修复】nDPI 的 Makefile 会拼接 $(prefix)+$(libdir)，产生 /usr/local/usr/local/lib 双层目录；
# 这里统一归一化回 /usr/local/lib，并修正 .pc 路径、补齐链接名、硬校验
RUN set -e; \
    if [ -d /usr/local/usr/local/lib ]; then \
      echo '🔧 nDPI doubled-prefix install detected, normalizing...'; \
      mkdir -p /usr/local/lib; \
      cp -a /usr/local/usr/local/lib/. /usr/local/lib/; \
      rm -rf /usr/local/usr; \
    fi; \
    sed -i 's|/usr/local/usr/local/lib|/usr/local/lib|g' /usr/local/lib/pkgconfig/libndpi.pc 2>/dev/null || true; \
    real=$(ls /usr/local/lib/libndpi.so.* 2>/dev/null | grep -v '\.so$' | head -n1); \
    if [ -n "$real" ] && [ ! -e /usr/local/lib/libndpi.so ]; then \
      ln -s "$(basename "$real")" /usr/local/lib/libndpi.so; \
      echo "🔧 created linker symlink libndpi.so -> $(basename "$real")"; \
    fi; \
    ldconfig; \
    echo '=== Final /usr/local/lib:'; ls -l /usr/local/lib; \
    test -e /usr/local/lib/libndpi.so || { echo '❌ libndpi.so still missing!'; exit 1; }

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV CFLAGS="-I/usr/local/include"
ENV LDFLAGS="-L/usr/local/lib"

RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib \
                --enable-ndpi --enable-sqlite3 --enable-json --enable-jansson \
                --enable-nflog --with-ndpi=/usr/local && \
    make -j2 && \
    make install

RUN rm -f /usr/local/lib/*.la /usr/local/lib/*.a


# ==========================================
# 阶段 2: 极简运行环境 (Runtime)
# ==========================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
# 在 apt-get install 列表中加入 expect
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcap0.8 libsqlite3-0 libjansson4 zlib1g \
    libmnl0 libnuma1 libnetfilter-log1 \
    sqlite3 ca-certificates dnscap \
    bash mawk procps expect \
    && rm -rf /var/lib/apt/lists/*

# 整目录拷贝（不用通配符，杜绝静默空拷）
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/sbin/ /usr/local/sbin/

COPY dns-ingest.sh /usr/local/bin/dns-ingest.sh
COPY dns-ingest.awk /usr/local/bin/dns-ingest.awk
COPY dns_schema.sql /etc/pmacct/dns_schema.sql
COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh

# 注册库目录 + 强制自检：缓存必须有 libndpi，pmacctd 依赖必须齐全
RUN chmod +x /cleanup.sh /entrypoint.sh /usr/local/bin/dns-ingest.sh && \
    echo '/usr/local/lib' > /etc/ld.so.conf.d/pmacct.conf && \
    ldconfig && \
    ldconfig -p | grep -q libndpi && \
    ! ldd /usr/local/sbin/pmacctd | grep -q "not found"

ENV LD_LIBRARY_PATH=/usr/local/lib

RUN mkdir -p /etc/pmacct /etc/pmacct/etl /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
