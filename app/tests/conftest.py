import os
import sys
from pathlib import Path

# app/main.py and app/db.py aren't a package (no __init__.py, matching the
# Dockerfile's flat `COPY main.py db.py ./`) - put app/ itself on sys.path so
# `import main` / `import db` resolve the same way regardless of whether
# pytest is invoked from the repo root or from inside app/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# db.py reads these two at import time (DB_HOST = os.environ["DB_HOST"], see
# app/db.py) - they just need to exist so `import db` succeeds during test
# collection. No test ever calls the real psycopg.connect(): every test
# monkeypatches db.get_connection itself (see test_app.py).
os.environ.setdefault("DB_HOST", "test-db-host")
os.environ.setdefault("DB_NAME", "test-db")
