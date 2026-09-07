"""
Minimal FastAPI service demonstrating the mounted-secret DB credential
pattern end to end: liveness/readiness probes, a static landing page, and
a JSON endpoint that reads and writes a single row to prove real
connectivity.
"""

import logging
from pathlib import Path

from fastapi import FastAPI, Response, status
from fastapi.responses import FileResponse
from prometheus_fastapi_instrumentator import Instrumentator

import db

logger = logging.getLogger("uvicorn.error")

app = FastAPI()
Instrumentator().instrument(app).expose(app)

# site/index.html is a sibling of this file in the container (Dockerfile
# COPYs site/ alongside main.py into /app), but a sibling of app/ itself in
# a local checkout - check both rather than hardcode one.
_SITE_INDEX = next(
    (
        path
        for path in (
            Path(__file__).resolve().parent / "site" / "index.html",
            Path(__file__).resolve().parent.parent / "site" / "index.html",
        )
        if path.is_file()
    ),
    None,
)
if _SITE_INDEX is None:
    raise RuntimeError("site/index.html not found next to app/ or inside it")


def _ensure_schema(conn: "db.psycopg.Connection") -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS visits (
                id BIGINT PRIMARY KEY,
                count BIGINT NOT NULL
            )
            """
        )
        cur.execute(
            "INSERT INTO visits (id, count) VALUES (1, 0) "
            "ON CONFLICT (id) DO NOTHING"
        )
    conn.commit()


@app.on_event("startup")
def _startup() -> None:
    # Best-effort only - must never raise. An uncaught exception in an ASGI
    # lifespan startup handler is fatal to uvicorn: the whole process dies,
    # not just this one operation. A readiness probe that then hits a
    # dying/dead process gets a bare connection reset (EOF), not an HTTP
    # response - which is indistinguishable from a hung server and, unlike
    # a clean 503, actively misleads whoever's debugging it.
    #
    # This DB call can transiently fail here for two reasons: RDS not yet
    # reachable, or the mounted DB credential files not yet populated
    # because ExternalSecret's sync to the mounted Secret races pod
    # startup. Both are transient and both resolve within seconds, so
    # rather than treat either as fatal, schema setup is retried on every
    # /readyz call too (below) and self-heals once the dependency is
    # actually ready, with no pod restart needed.
    try:
        with db.get_connection() as conn:
            _ensure_schema(conn)
    except Exception:
        logger.exception("schema setup failed at startup - will retry on next /readyz")


@app.get("/healthz")
def healthz() -> dict:
    # Liveness: process only, no DB check. A DB blip should stop traffic
    # (readyz), not restart a pod that's otherwise fine.
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    try:
        with db.get_connection() as conn:
            _ensure_schema(conn)
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return {"status": "ready"}
    except Exception:  # readiness must report, never raise
        logger.exception("readiness check failed")
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not ready"}


def _increment_and_get_visits() -> int:
    """Backs /api/stats only - the landing page is static, see site/index.html."""
    with db.get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE visits SET count = count + 1 WHERE id = 1 RETURNING count"
            )
            (count,) = cur.fetchone()
        conn.commit()
    return count


@app.get("/api/stats")
def stats() -> dict:
    # Original payload shape, unchanged - this is what CI's smoke test
    # asserts against. Deliberately no try/except here: a DB failure on
    # this endpoint should surface as a real error, not be swallowed.
    return {"message": "Hello from eks-platform", "visits": _increment_and_get_visits()}


@app.get("/")
def index() -> FileResponse:
    # Static resume page, not DB-backed - see site/index.html, the single
    # source shared verbatim with the S3+CloudFront surface.
    return FileResponse(_SITE_INDEX, media_type="text/html")
