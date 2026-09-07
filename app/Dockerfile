# syntax=docker/dockerfile:1
#
# Build context is the repo root, not app/ - see .github/workflows/deploy.yml
# ("docker build -f app/Dockerfile ."). site/index.html (the shared landing
# page, also served verbatim by S3+CloudFront) lives outside app/, as a
# sibling directory, so it's only reachable from a repo-root context.

# Pinned by digest, not just tag, so a rebuild can't silently pick up a
# new base image. Re-resolve with:
#   docker buildx imagetools inspect python:3.12-slim
# and update both stages together if bumped.
FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217 AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217

# Fixed numeric UID, matching charts/app's securityContext.runAsUser - never
# rely on an image-default user that could change between base image
# rebuilds.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /install /usr/local
WORKDIR /app
COPY app/main.py app/db.py ./
COPY site/ ./site/

USER 10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

EXPOSE 8080

# Shell form so $PORT expands. readOnlyRootFilesystem (set in the Helm
# chart's securityContext) means nothing here writes to disk regardless.
CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port \"${PORT}\""]
