"""
No real Postgres in CI - every test that touches a DB-backed route
monkeypatches db.get_connection with a fake instead. main.py calls
db.get_connection() through the `db` module object (not a `from db import
get_connection`), so patching the attribute on the imported db module is
visible from inside main.py's route handlers too.

The TestClient below is built without the `with` context-manager form, so
main.py's ASGI lifespan (and therefore its own startup-time db.get_connection
call) never runs - each test controls exactly one call to db.get_connection,
with nothing from app startup mixed in.
"""

from unittest.mock import MagicMock

from fastapi.testclient import TestClient

import db
import main

client = TestClient(main.app)


class FakeCursor:
    def __init__(self, fetchone_return=None):
        self._fetchone_return = fetchone_return

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False

    def execute(self, *args, **kwargs):
        pass

    def fetchone(self):
        return self._fetchone_return


class FakeConnection:
    """Stands in for psycopg.Connection: supports `with db.get_connection()
    as conn:`, `with conn.cursor() as cur:`, and .commit() - the exact shape
    _ensure_schema/_increment_and_get_visits/readyz use in main.py."""

    def __init__(self, fetchone_return=None):
        self._fetchone_return = fetchone_return

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False

    def cursor(self):
        return FakeCursor(self._fetchone_return)

    def commit(self):
        pass


def _raise_unreachable():
    raise RuntimeError("db unreachable")


def test_healthz_ok_and_never_touches_db(monkeypatch):
    mock_get_connection = MagicMock()
    monkeypatch.setattr(db, "get_connection", mock_get_connection)

    response = client.get("/healthz")

    assert response.status_code == 200
    mock_get_connection.assert_not_called()


def test_readyz_ok_when_db_reachable(monkeypatch):
    monkeypatch.setattr(db, "get_connection", lambda: FakeConnection(fetchone_return=(1,)))

    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_503_when_db_unreachable(monkeypatch):
    # Bug B regression: an unreachable DB must produce a clean 503, not an
    # uncaught exception that crashes the worker.
    monkeypatch.setattr(db, "get_connection", _raise_unreachable)

    response = client.get("/readyz")

    assert response.status_code == 503
    assert response.json() == {"status": "not ready"}


def test_stats_returns_message_and_int_visits(monkeypatch):
    monkeypatch.setattr(db, "get_connection", lambda: FakeConnection(fetchone_return=(7,)))

    response = client.get("/api/stats")

    assert response.status_code == 200
    body = response.json()
    assert body["message"] == "Hello from eks-platform"
    assert isinstance(body["visits"], int)


def test_index_renders_page(monkeypatch):
    monkeypatch.setattr(db, "get_connection", lambda: FakeConnection(fetchone_return=(3,)))

    response = client.get("/")

    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "Chethan" in response.text


def test_index_degrades_counter_when_db_unreachable(monkeypatch):
    # Bug B regression, other half: the landing page is a demo surface, not
    # the readiness check - a DB blip degrades the counter, it does not 500.
    monkeypatch.setattr(db, "get_connection", _raise_unreachable)

    response = client.get("/")

    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_metrics_exposed():
    response = client.get("/metrics")

    assert response.status_code == 200
    assert "python_info" in response.text
