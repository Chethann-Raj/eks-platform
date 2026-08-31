"""
Minimal FastAPI service demonstrating the mounted-secret DB credential
pattern end to end: liveness/readiness probes, a server-rendered landing
page, and a JSON endpoint - both reading and writing the same single row
to prove real connectivity.
"""

import logging

from fastapi import FastAPI, Response, status
from fastapi.responses import HTMLResponse
from prometheus_fastapi_instrumentator import Instrumentator

import db

logger = logging.getLogger("uvicorn.error")

app = FastAPI()
Instrumentator().instrument(app).expose(app)


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


def _increment_and_get_visits() -> int:
    """The one code path to the counter - shared by / and /api/stats."""
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


def _render_page(visits_display: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<title>Chethan R - DevOps / SRE</title>
<style>
  :root {{
    --bg: #0b0e11;
    --fg: #e6e9ec;
    --muted: #8b95a1;
    --accent: #4fd1a5;
    --border: #1e2328;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
      Helvetica, Arial, sans-serif;
    line-height: 1.65;
    display: flex;
    justify-content: center;
    padding: 3rem 1.25rem;
  }}
  main {{ max-width: 700px; width: 100%; }}
  h1 {{ margin: 0 0 0.15rem; font-size: 2rem; }}
  .headline {{ color: var(--accent); margin: 0 0 1rem; font-size: 1.05rem; }}
  .bio {{
    color: var(--muted);
    margin: 0 0 1.75rem;
    max-width: 60ch;
    text-wrap: pretty;
  }}
  section {{
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1.25rem 1.5rem;
    margin-bottom: 1.5rem;
  }}
  section h2 {{
    margin: 0 0 0.75rem;
    font-size: 0.85rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
  }}
  ul {{ margin: 0; padding-left: 1.15rem; }}
  li {{ margin-bottom: 0.5rem; }}
  li:last-child {{ margin-bottom: 0; }}
  .counter {{
    display: flex;
    align-items: baseline;
    gap: 0.6rem;
  }}
  .counter .n {{ font-size: 2rem; color: var(--accent); font-weight: 600; }}
  .counter .label {{ color: var(--muted); font-size: 0.9rem; }}
  a {{ color: var(--accent); }}
  footer {{ color: var(--muted); font-size: 0.85rem; margin-top: 1.5rem; }}
</style>
</head>
<body>
<main>
  <h1>Chethan R</h1>
  <p class="headline">DevOps / Site Reliability Engineer &middot; Bangalore</p>
  <p class="bio">
    ~3 years of DevOps / SRE experience, including in PCI DSS-regulated
    payments. AWS Solutions Architect Associate.
  </p>

  <section>
    <h2>This page is the demo</h2>
    <ul>
      <li>VPC, EKS cluster, and RDS Postgres provisioned from Terraform</li>
      <li>GitHub Actions deploys via OIDC - no long-lived AWS keys in CI</li>
      <li>AWS Load Balancer Controller + ExternalDNS + ACM route and secure this exact page</li>
      <li>External Secrets Operator pulls the RDS password live from AWS Secrets Manager</li>
      <li>Postgres runs in a private subnet, reachable only from inside the cluster</li>
    </ul>
  </section>

  <div class="counter">
    <span class="n">{visits_display}</span>
    <span class="label">visits - a real Postgres read-write on every load, not a static number</span>
  </div>

  <footer>
    <a href="https://github.com/Chethann-Raj/eks-platform">github.com/Chethann-Raj/eks-platform</a>
    <br>
    Served from EKS in ap-south-1.
  </footer>
</main>
</body>
</html>"""


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    try:
        visits_display = str(_increment_and_get_visits())
    except Exception:
        # The landing page is a demo surface, not the readiness check - a
        # DB blip should degrade the counter, not the page. /readyz is
        # what actually gates traffic on DB health.
        logger.exception("visit counter unavailable for landing page")
        visits_display = "—"
    return HTMLResponse(_render_page(visits_display))
