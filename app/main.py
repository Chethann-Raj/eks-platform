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


@app.on_event("startup")
def _ensure_schema() -> None:
    with db.get_connection() as conn:
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


@app.get("/healthz")
def healthz() -> dict:
    # Liveness: process only, no DB check - CLAUDE.md §11. A DB blip
    # should stop traffic (readyz), not restart a pod that's otherwise fine.
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    try:
        with db.get_connection() as conn:
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
