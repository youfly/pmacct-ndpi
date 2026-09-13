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
    make install && \
    ldconfig

# 【自检+自愈 1】打印真实安装布局；缺 libndpi.so 链接名就手动补；库文件彻底不在则硬失败并打印真实位置
RUN echo '=== /usr/local/lib layout after nDPI install:'; ls -lR /usr/local/lib | head -60; \
    for d in /usr/local/lib /usr/local/lib/x86_64-linux-gnu /usr/local/lib/aarch64-linux-gnu; do \
      [ -d "$d" ] || continue; \
      real=$(ls "$d"/libndpi.so.* 2>/dev/null | grep -v '\.so$' | head -n1); \
      if [ -n "$real" ] && [ ! -e "$d/libndpi.so" ]; then \
        ln -s "$(basename "$real")" "$d/libndpi.so"; \
        echo "🔧 created missing linker symlink: $d/libndpi.so -> $(basename "$real")"; \
      fi; \
    done; \
    { test -e /usr/local/lib/libndpi.so || \
      test -e /usr/local/lib/x86_64-linux-gnu/libndpi.so || \
      test -e /usr/local/lib/aarch64-linux-gnu/libndpi.so || \
      { echo '❌ libndpi not installed at all! Real locations:'; find / -name 'libndpi*' 2>/dev/null; exit 1; }; }

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV CFLAGS="-I/usr/local/include"
# 【加固】链接时同时搜索所有候选库目录（ld 对不存在的 -L 目录静默忽略，无副作用）
ENV LDFLAGS="-L/usr/local/lib -L/usr/local/lib/x86_64-linux-gnu -L/usr/local/lib/aarch64-linux-gnu"

RUN git clone --depth 1 https://github.com/pmacct/pmacct.git /tmp/pmacct && \
    cd /tmp/pmacct && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --libdir=/usr/local/lib \
                --enable-ndpi --enable-sqlite3 --enable-json --enable-jansson \
                --enable-nflog --with-ndpi=/usr/local && \
    make -j2 && \
    make install

# 清理静态库，控制镜像体积
RUN rm -f /usr/local/lib/*.la /usr/local/lib/*.a


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

# 整目录拷贝（含可能存在的多架构子目录），不用通配符，杜绝静默空拷
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/sbin/ /usr/local/sbin/

COPY cleanup.sh /cleanup.sh
COPY entrypoint.sh /entrypoint.sh

# 【自检 2】把实际存在的库目录注册进 ld.so，刷新缓存后强制校验
RUN chmod +x /cleanup.sh /entrypoint.sh && \
    { for d in /usr/local/lib /usr/local/lib/x86_64-linux-gnu /usr/local/lib/aarch64-linux-gnu; do \
        [ -d "$d" ] && echo "$d"; \
      done; } > /etc/ld.so.conf.d/pmacct.conf && \
    ldconfig && \
    ldconfig -p | grep -q libndpi && \
    ! ldd /usr/local/sbin/pmacctd | grep -q "not found"

# 双保险搜索路径
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:/usr/local/lib/aarch64-linux-gnu

RUN mkdir -p /etc/pmacct /data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pmacctd", "-f", "/etc/pmacct/pmacctd.conf"]
