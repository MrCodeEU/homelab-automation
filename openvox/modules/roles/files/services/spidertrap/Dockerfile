FROM rust:1-alpine AS builder
RUN apk add --no-cache musl-dev git
WORKDIR /build
RUN git clone --depth 1 https://github.com/acuciureanu/spidertrap-rs.git .
RUN cargo build --release

FROM alpine:3
RUN apk add --no-cache ca-certificates \
    && addgroup -S spidertrap \
    && adduser -S -G spidertrap spidertrap
COPY --from=builder /build/target/release/spidertrap-rs /usr/local/bin/spidertrap-rs
EXPOSE 8080
USER spidertrap
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/ || exit 1
ENTRYPOINT ["/usr/local/bin/spidertrap-rs"]
