# ==========================================
# 阶段 1: 胖构建环境 (Builder) - 仅用于编译
# ==========================================
FROM debian:bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 安装编译工具链和开发库 (去掉了 libjemalloc-dev 以减少跨平台编译问题)
RUN apt-get update && apt-get install -y \
    build-essential git autoconf automake libtool pkg-config \
    libpcap-dev libsqlite3-dev libjson-c-dev libmnl-dev libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

# 编译 nDPI (限制并发数为 2，防止 QEMU OOM)
RUN git clone --depth 1 https://github.com/ntop/nDPI.git /tmp/nDPI && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    ./configure && \
    make -j2 && \
    make install && \
    ldconfig

# 编译 pmacct (限制并发数为 2)
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV CFLAGS="-I/usr/local/include"
ENV LDFLAGS="-L/usr/local/lib"

RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure --enable-ndpi --enable-sqlite3 --enable-json --prefix=/usr/local && \
    make -j2 && \
    make install


# ==========================================
# 阶段 2: 极简运行环境 (Runtime) - 最终镜像
# ==========================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# 安装运行时依赖 + sqlite3 客户端 (去掉了 libjemalloc2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcap0.8 libsqlite3-0 libjson-c5 libmnl0 libnuma1 \
    sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 复制编译好的二进制文件和库
COPY --from=builder /usr/local/sbin/pmacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/nfacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/sfacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/uacctd /usr/local/sbin/
COPY --from=builder /usr/local/lib/libndpi.so* /usr/local/lib/
COPY --from=builder /usr/local/lib/libpmacct.so* /usr/local/lib/

# 复制清理脚本和入口脚本
COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /cleanup.sh /entrypoint.sh && ldconfig

# 准备目录
RUN mkdir -p /etc/pmacct /data

# 设置入口点
ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
