FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

COPY ziti-mesh-exporter /usr/local/bin/ziti-mesh-exporter

# The identity file is 2171:2171 0600 (scripts/ziti-enroll-proxy.sh).
USER 2171:2171

HEALTHCHECK --interval=30s --timeout=5s CMD ["/usr/local/bin/ziti-mesh-exporter", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/ziti-mesh-exporter"]
