# S3-compatible storage for E2E (E2E.md 2.2): Garage. The official image only holds the static binary, so
# it is copied into Alpine to run the setup script.
FROM dxflrs/garage:v2.4.1 AS garage

FROM alpine:3.22
COPY --from=garage /garage /usr/local/bin/garage
COPY web/docker/storage/garage.toml /etc/garage.toml
COPY web/docker/storage/init.sh /init.sh
ENTRYPOINT ["/init.sh"]
