#!/bin/sh
# Start the gateway (API Gateway role, :3000), then the image's own entrypoint: the Runtime Interface
# Emulator (:8080) running the function.
/usr/local/bin/apigw-local &
exec /lambda-entrypoint.sh "$@"
