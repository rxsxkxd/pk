# Container image of the stub for running in a VPC (ECS Fargate, arm64): the local server (local.mjs) as is.
# No dependencies, so nothing is installed at build or run time. See ../DESIGN.md 付録 B.
FROM public.ecr.aws/docker/library/node:24-alpine
WORKDIR /app
COPY analyzer.mjs index.mjs local.mjs ./
USER node
EXPOSE 8090
ENV PORT=8090
CMD ["node", "local.mjs"]
