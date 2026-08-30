"""
Database connection helper.

Credentials (username/password) are read from files mounted from a
Kubernetes Secret - populated by an ExternalSecret from the RDS-managed
Secrets Manager secret, see charts/app/templates/externalsecret.yaml - not
environment variables. RDS rotates that password on its own schedule
(terraform/modules/rds: manage_master_user_password); an env var is read
once at process start and frozen for the container's lifetime, so it would
never see a rotated value without a pod restart. A mounted Secret file is
updated in place by kubelet when the backing Secret changes, so re-reading
it on every new connection - instead of once at import time - is what lets
a rotation take effect without restarting the app. See
terraform/modules/addons/README.md for the fuller reasoning this follows.

Connection host/port/dbname are NOT secret and come from plain environment
variables instead, set from Helm values which are themselves sourced from
Terraform's rds module outputs at deploy time.
"""

import os
from pathlib import Path

import psycopg

_CREDENTIALS_DIR = Path(os.environ.get("DB_CREDENTIALS_DIR", "/etc/secrets/db"))

DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ["DB_NAME"]


def _read_credential(filename: str) -> str:
    return (_CREDENTIALS_DIR / filename).read_text().strip()


def get_connection() -> psycopg.Connection:
    """Opens a fresh connection using whatever credentials are on disk
    right now. No long-lived pool: at this traffic scale, per-request
    connection setup is cheap enough that it isn't worth trading away
    "always uses the current password" for it.
    """
    return psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=_read_credential("username"),
        password=_read_credential("password"),
        connect_timeout=5,
    )
