"""Connection pool, built lazily from environment on first use.

The pool is never constructed at import time. The container has to start
and answer /health even if the database is mid-failover or briefly
unreachable, so nothing here runs until a request actually needs a
connection - see repo.py / main.get_repo.
"""
from __future__ import annotations

import json
import os

from psycopg_pool import ConnectionPool

_pool: ConnectionPool | None = None


def _conninfo() -> str:
    creds = json.loads(os.environ["DB_CREDS"])
    return (
        f"host={os.environ['DB_HOST']} "
        f"port={os.environ['DB_PORT']} "
        f"dbname={os.environ['DB_NAME']} "
        f"user={creds['username']} "
        f"password={creds['password']}"
    )


def get_pool() -> ConnectionPool:
    """Return the process-wide pool, creating it on first call."""
    global _pool
    if _pool is None:
        # open=True is explicit to avoid psycopg_pool's implicit-open
        # deprecation warning; the pool still fills its connections in a
        # background worker rather than blocking here.
        _pool = ConnectionPool(conninfo=_conninfo(), open=True)
    return _pool
