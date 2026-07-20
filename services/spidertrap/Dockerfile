FROM rust:1-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /build
RUN git clone --depth 1 https://github.com/acuciureanu/spidertrap-rs.git .
RUN cargo build --release

FROM alpine:3
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/target/release/spidertrap-rs /usr/local/bin/spidertrap-rs
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/spidertrap-rs"]
