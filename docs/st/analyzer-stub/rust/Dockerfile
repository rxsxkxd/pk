# Container image of the stub for running in a VPC (ECS Fargate, arm64): the local server
# (examples/local.rs). Built on Amazon Linux 2023 and run on its minimal image, so the glibc matches.
# See ../DESIGN.md 付録 B.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS build
RUN dnf install -y gcc gcc-c++ cmake make perl && dnf clean all
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
WORKDIR /src
COPY . .
RUN cargo build --release --example local

FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
COPY --from=build /src/target/release/examples/local /usr/local/bin/analyzer-stub
USER 65534
ENV PORT=8090
EXPOSE 8090
CMD ["/usr/local/bin/analyzer-stub"]
