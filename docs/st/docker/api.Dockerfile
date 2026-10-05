# API container for E2E (E2E.md 2.3): the deployment package runs on the Lambda base image (Runtime
# Interface Emulator), behind apigw-local (the API Gateway role). Pick the implementation with the build
# target: api-go or api-node.

# --- Go: the deployment bootstrap (same flags as go/Makefile) and the gateway ---
FROM golang:1.27.1 AS go-build
WORKDIR /src/go
COPY go/go.mod go/go.sum ./
RUN go mod download
COPY go/ ./
RUN CGO_ENABLED=0 go build -tags lambda.norpc -trimpath -ldflags='-s -w' -o /out/bootstrap ./cmd/ticketqr \
 && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/apigw-local ./cmd/apigw-local

# --- Node: the deployment bundle (same esbuild command as node/package.json, without the zip) ---
FROM node:24 AS node-build
WORKDIR /src/node
COPY node/package.json node/package-lock.json ./
RUN npm ci
COPY node/ ./
RUN npx esbuild src/ticketqr.ts --bundle --platform=node --target=node24 --format=esm --minify \
      '--external:@aws-sdk/*' --outfile=/out/index.mjs

FROM public.ecr.aws/lambda/provided:al2023 AS api-go
COPY --from=go-build /out/bootstrap /var/runtime/bootstrap
COPY --from=go-build /out/apigw-local /usr/local/bin/apigw-local
COPY docker/api-entrypoint.sh /api-entrypoint.sh
ENTRYPOINT ["/api-entrypoint.sh"]
CMD ["bootstrap"]

FROM public.ecr.aws/lambda/nodejs:24 AS api-node
COPY --from=node-build /out/index.mjs /var/task/index.mjs
COPY --from=go-build /out/apigw-local /usr/local/bin/apigw-local
COPY docker/api-entrypoint.sh /api-entrypoint.sh
ENTRYPOINT ["/api-entrypoint.sh"]
CMD ["index.handler"]
