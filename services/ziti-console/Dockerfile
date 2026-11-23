FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

COPY ziti-console-proxy /usr/local/bin/ziti-console-proxy

# The controller's uid: the overlay root CA it reads is 2171:2171 0600.
USER 2171:2171

HEALTHCHECK --interval=30s --timeout=5s CMD ["/usr/local/bin/ziti-console-proxy", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/ziti-console-proxy"]
