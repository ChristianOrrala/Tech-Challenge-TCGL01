"""QuakeRepository - the only module that speaks SQL.

Every method opens a pooled connection, runs one query, and returns plain
dicts (row_factory=dict_row) keyed by column name. main.py shapes those
dicts into the API's JSON contract; it never sees a cursor.
"""
from __future__ import annotations

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

_RECENT_COLUMNS = "event_id, occurred_at, magnitude, place, latitude, longitude, depth_km"

_RECENT_SQL = f"""
    SELECT {_RECENT_COLUMNS}
    FROM earthquakes
    WHERE magnitude > 4.0 AND occurred_at >= now() - interval '24 hours'
    ORDER BY occurred_at DESC
"""

_WEEKLY_SQL = """
    SELECT date_trunc('day', occurred_at)::date AS d, count(*) AS count
    FROM earthquakes
    WHERE occurred_at >= now() - interval '7 days'
    GROUP BY 1
    ORDER BY 1
"""

_TOP_SQL = f"""
    SELECT {_RECENT_COLUMNS}
    FROM earthquakes
    WHERE occurred_at >= now() - make_interval(days => %(days)s)
    ORDER BY magnitude DESC NULLS LAST
    LIMIT %(limit)s
"""

_FRESHNESS_SQL = """
    SELECT max(ingested_at) AS last_ingest, max(occurred_at) AS latest_event
    FROM earthquakes
"""


class QuakeRepository:
    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool

    def recent(self) -> list[dict]:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_RECENT_SQL)
                return cur.fetchall()

    def weekly_counts(self) -> list[dict]:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_WEEKLY_SQL)
                return cur.fetchall()

    def top(self, days: int, limit: int) -> list[dict]:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_TOP_SQL, {"days": days, "limit": limit})
                return cur.fetchall()

    def freshness(self) -> dict:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_FRESHNESS_SQL)
                return cur.fetchone()
