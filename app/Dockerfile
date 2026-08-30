# syntax=docker/dockerfile:1

# Pinned by digest, not just tag - CLAUDE.md §11. Re-resolve with:
#   docker buildx imagetools inspect python:3.12-slim
# and update both stages together if bumped.
FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217 AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217

# Fixed numeric UID, matching charts/app's securityContext.runAsUser - never
# rely on an image-default user that could change between base image
# rebuilds.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /install /usr/local
WORKDIR /app
COPY main.py db.py ./

USER 10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

EXPOSE 8080

# Shell form so $PORT expands. readOnlyRootFilesystem (set in the Helm
# chart's securityContext) means nothing here writes to disk regardless.
CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port \"${PORT}\""]
