"""
Minimal FastAPI service demonstrating the mounted-secret DB credential
pattern end to end: liveness/readiness probes plus one endpoint that reads
and writes a single row to prove real connectivity.
"""

import logging

from fastapi import FastAPI, Response, status

import db

logger = logging.getLogger("uvicorn.error")

app = FastAPI()


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
    # This DB call is exactly as likely to transiently fail here as the one
    # in readyz() below (RDS not reachable yet, or the mounted credential
    # files not fully populated yet during an ExternalSecret sync race -
    # both observed for real: see CHALLENGES.md). readyz() already handles
    # that failure correctly (503, not a crash) - so schema setup is
    # retried there too on every call, and self-heals the moment the DB
    # actually becomes reachable, with no pod restart needed.
    try:
        with db.get_connection() as conn:
            _ensure_schema(conn)
    except Exception:
        logger.exception("schema setup failed at startup - will retry on next /readyz")


@app.get("/healthz")
def healthz() -> dict:
    # Liveness: process only, no DB check - CLAUDE.md §11. A DB blip
    # should stop traffic (readyz), not restart a pod that's otherwise fine.
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


@app.get("/")
def index() -> dict:
    with db.get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE visits SET count = count + 1 WHERE id = 1 RETURNING count"
            )
            (count,) = cur.fetchone()
        conn.commit()
    return {"message": "Hello from eks-platform", "visits": count}
