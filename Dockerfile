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

# 编译 nDPI (锁定稳定分支)
RUN (git clone --depth 1 --branch 4.14-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.12-stable https://github.com/ntop/nDPI.git /tmp/nDPI || \
     git clone --depth 1 --branch 4.10-stable https://github.com/ntop/nDPI.git /tmp/nDPI) && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    # 【核心修改】：强制指定库文件安装到 /usr/local/lib 根目录，消灭多架构子目录
    ./configure --prefix=/usr/local --libdir=/usr/local/lib && \
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
    # 【核心修改】：同样强制指定库目录
    ./configure --prefix=/usr/local --libdir=/usr/local/lib \
                --enable-ndpi --enable-sqlite3 --enable-json --enable-jansson \
                --enable-nflog --with-ndpi=/usr/local && \
    make -j2 && \
    make install


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

# 现在 /usr/local/lib/ 下绝对有 libndpi.so.4，直接整目录拷贝
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/sbin/ /usr/local/sbin/

COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh

# 刷新缓存并执行强制自检（缺库直接让构建失败）
RUN chmod +x /cleanup.sh /entrypoint.sh && ldconfig && \
    ldconfig -p | grep -q libndpi && \
    ! ldd /usr/local/sbin/pmacctd | grep -q "not found"

ENV LD_LIBRARY_PATH=/usr/local/lib

RUN mkdir -p /etc/pmacct /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
