# Container image of the stub for running in a VPC (ECS Fargate, arm64): the local server (local.py) as is.
# Standard library only, so nothing is installed. See ../DESIGN.md 付録 B.
FROM public.ecr.aws/docker/library/python:3.13-slim
WORKDIR /app
COPY analyzer.py index.py local.py ./
RUN useradd --system --no-create-home stub
USER stub
ENV PORT=8090 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8090
CMD ["python", "local.py"]
