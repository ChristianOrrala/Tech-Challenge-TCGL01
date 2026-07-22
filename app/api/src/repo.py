"""QuakeRepository - the only module that speaks SQL.

Every method opens a pooled connection, runs one query, and returns plain
dicts (row_factory=dict_row) keyed by column name. main.py shapes those
dicts into the API's JSON contract; it never sees a cursor.
"""
from __future__ import annotations

from datetime import datetime

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

# GET /api/quakes building blocks. sort and order arrive already validated
# by the endpoint's Literal params, and even then they are only ever used
# as keys into these mappings - user input never reaches the SQL text,
# every value travels as a bind parameter.
_CATALOG_SORT_COLUMN = {"time": "occurred_at", "magnitude": "magnitude"}
_CATALOG_DIRECTION = {"asc": ("ASC", ">"), "desc": ("DESC", "<")}

# Two scalar subqueries instead of one FILTER aggregate: each keeps its own
# index path (min/max lookup on idx_eq_time, index-only range on
# idx_eq_mag_time), so coverage stays cheap at deep-seed scale.
# all_since marks where ALL-magnitude coverage starts, approximated by the
# earliest sub-M4 (or unmeasured) row: the deep seed backfills M >= 4.0
# only, so a plain MIN(occurred_at) would follow the seed back a decade
# and overclaim coverage for small events the catalog does not hold there.
_COVERAGE_SQL = """
    SELECT
        (SELECT min(occurred_at) FROM earthquakes
          WHERE magnitude < 4.0 OR magnitude IS NULL) AS all_since,
        (SELECT min(occurred_at) FROM earthquakes WHERE magnitude >= 4.0) AS m4_since
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

    def catalog(
        self,
        *,
        sort: str,
        order: str,
        min_mag: float | None,
        max_mag: float | None,
        start: datetime | None,
        end: datetime | None,
        limit: int,
        after_value: datetime | float | None,
        after_id: str | None,
    ) -> list[dict]:
        column = _CATALOG_SORT_COLUMN[sort]
        direction, comparator = _CATALOG_DIRECTION[order]

        where = []
        params: dict = {"limit": limit}
        if sort == "magnitude":
            # A keyset over a nullable column has undefined placement, and a
            # magnitude-ordered catalog listing unmeasured events is
            # meaningless - NULL magnitudes are only reachable under sort=time.
            where.append("magnitude IS NOT NULL")
        if min_mag is not None:
            where.append("magnitude >= %(min_mag)s")
            params["min_mag"] = min_mag
        if max_mag is not None:
            where.append("magnitude <= %(max_mag)s")
            params["max_mag"] = max_mag
        if start is not None:
            where.append("occurred_at >= %(start)s")
            params["start"] = start
        if end is not None:
            where.append("occurred_at <= %(end)s")
            params["end"] = end
        if after_id is not None:
            # Row comparison resumes exactly after the cursor row: event_id
            # breaks ties, so a page boundary inside a group of equal sort
            # values neither repeats nor skips rows - and unlike OFFSET it
            # stays O(page) and stable while the ingest keeps inserting.
            where.append(f"({column}, event_id) {comparator} (%(after_value)s, %(after_id)s)")
            params["after_value"] = after_value
            params["after_id"] = after_id

        where_sql = ("WHERE " + " AND ".join(where)) if where else ""
        sql = f"""
            SELECT {_RECENT_COLUMNS}
            FROM earthquakes
            {where_sql}
            ORDER BY {column} {direction}, event_id {direction}
            LIMIT %(limit)s
        """
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(sql, params)
                return cur.fetchall()

    def coverage(self) -> dict:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_COVERAGE_SQL)
                return cur.fetchone()

    def freshness(self) -> dict:
        with self._pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(_FRESHNESS_SQL)
                return cur.fetchone()
