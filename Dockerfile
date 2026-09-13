# ==========================================
# 阶段 1: 编译环境 (Builder)
# ==========================================
FROM ubuntu:22.04 AS builder

# 安装编译依赖
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libpcap-dev \
    libsqlite3-dev \
    libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

# 1. 从源码编译 nDPI (确保最新版，支持更多 App 识别)
RUN git clone --depth 1 https://github.com/ntop/nDPI.git /tmp/nDPI && \
    cd /tmp/nDPI && \
    ./autogen.sh && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# 2. 从源码编译 pmacct 并启用 nDPI 和 SQLite
RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure \
        --enable-ndpi \
        --enable-sqlite3 \
        --enable-jemalloc \
        --prefix=/usr/local && \
    make -j$(nproc) && \
    make install

# ==========================================
# 阶段 2: 运行环境 (Runtime)
# ==========================================
FROM ubuntu:22.04

# 仅安装运行时依赖
RUN apt-get update && apt-get install -y \
    libpcap0.8 \
    libsqlite3-0 \
    libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

# 从编译阶段复制二进制文件和动态库
COPY --from=builder /usr/local/sbin/pmacctd /usr/local/sbin/
COPY --from=builder /usr/local/sbin/nfacctd /usr/local/sbin/
COPY --from=builder /usr/local/lib/libndpi.so* /usr/local/lib/

# 刷新动态库缓存
RUN ldconfig

# 创建配置和数据目录
RUN mkdir -p /etc/pmacct /data

# 默认启动命令（可被 docker-compose 覆盖）
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
