# ==========================================
# 阶段 1: 编译环境 (Builder)
# ==========================================
FROM debian:bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential git autoconf automake libtool pkg-config \
    libpcap-dev libsqlite3-dev libjansson-dev zlib1g-dev \
    libmnl-dev libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

# 【核心修复】：锁定 nDPI 稳定分支，绝不使用默认 dev 分支
# 按 4.14 -> 4.12 -> 4.10 顺序回退，保证总能拿到一个 API 冻结的稳定版
RUN (git clone --depth 1 --branch 4.14-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.12-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.10-stable https://github.com/ntop/nDPI.git /tmp/nDPI) && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    ./configure && \
    make -j2 && \
    make install && \
    ldconfig

# 编译 pmacct
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV CFLAGS="-I/usr/local/include"
ENV LDFLAGS="-L/usr/local/lib"

RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure --enable-ndpi --enable-sqlite3 --enable-json --enable-jansson --with-ndpi=/usr/local --prefix=/usr/local && \
    make -j2 && \
    make install


# ==========================================
# 阶段 2: 极简运行环境 (Runtime)
# ==========================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcap0.8 libsqlite3-0 libjansson4 zlib1g \
    libmnl0 libnuma1 \
    sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/sbin/pmacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/nfacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/sfacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/uacctd /usr/local/sbin/
COPY --from=builder /usr/local/lib/libndpi.so* /usr/local/lib/
COPY --from=builder /usr/local/lib/libpmacct.so* /usr/local/lib/

COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /cleanup.sh /entrypoint.sh && ldconfig

RUN mkdir -p /etc/pmacct /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
