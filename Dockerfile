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

# 编译 nDPI：--libdir 强制钉死库安装位置
RUN (git clone --depth 1 --branch 4.14-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.12-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.10-stable https://github.com/ntop/nDPI.git /tmp/nDPI) && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib && \
    make -j2 && \
    make install && \
    ldconfig

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV CFLAGS="-I/usr/local/include"
ENV LDFLAGS="-L/usr/local/lib"

# 编译 pmacct：同样钉死 libdir
RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib \
                --enable-ndpi --enable-sqlite3 --enable-json --enable-jansson \
                --enable-nflog --with-ndpi=/usr/local && \
    make -j2 && \
    make install

# 【自检 1】builder 阶段：清理静态库后确认 libndpi 在 /usr/local/lib；
# 若不在，打印它真实所在位置（find 输出会进 Actions 日志）然后失败
RUN rm -f /usr/local/lib/*.la /usr/local/lib/*.a && \
    { ls /usr/local/lib | grep -q libndpi || \
      { echo '❌ libndpi NOT in /usr/local/lib! Actual locations:'; \
        find / -name 'libndpi*' 2>/dev/null; exit 1; }; }


# ==========================================
# 阶段 2: 极简运行环境 (Runtime)
# ==========================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcap0.8 libsqlite3-0 libjansson4 zlib1g \
    libmnl0 libnuma1 libnetfilter-log1 \
    sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 【关键】整目录 COPY，不用通配符：源目录缺失会硬报错，绝不静默跳过
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/sbin/ /usr/local/sbin/

COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh

# 【自检 2】runtime 阶段：缓存必须注册 libndpi，且 pmacctd 依赖必须齐全
RUN chmod +x /cleanup.sh /entrypoint.sh && ldconfig && \
    ldconfig -p | grep -q libndpi && \
    ! ldd /usr/local/sbin/pmacctd | grep -q "not found"

ENV LD_LIBRARY_PATH=/usr/local/lib

RUN mkdir -p /etc/pmacct /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
