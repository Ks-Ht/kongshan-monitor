# ---- 构建阶段 ----
FROM rust:1-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# sqlx 编译期查询校验需要一个 schema 库
RUN sh scripts/dev-db.sh && cargo build --release -p outpost-server

# ---- 运行阶段 ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates openssl curl gosu \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin outpost \
    && mkdir -p /etc/outpost/pki /var/lib/outpost/dist
COPY --from=builder /src/target/release/outpost-server /usr/local/bin/outpost-server
COPY deploy/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENV OUTPOST_CONFIG=/etc/outpost/config.toml
EXPOSE 25510
VOLUME ["/etc/outpost", "/var/lib/outpost"]
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
