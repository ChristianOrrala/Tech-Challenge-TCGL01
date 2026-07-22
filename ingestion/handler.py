"""USGS earthquake ingestion - scheduled Lambda entrypoint.

Runs on a 5-minute EventBridge schedule (infra/modules/ingestion). On an
empty table it backfills BACKFILL_DAYS in day-sized chunks; otherwise it
re-fetches the trailing 2 hours - upsert() is keyed on event_id, so the
overlap just re-applies USGS revisions instead of duplicating rows.

Module-level imports are stdlib only: psycopg is vendored into
ingestion/build/ by `make package-ingestion` and boto3 ships with the
Lambda runtime, but neither is installed in the local test venv, so both
are imported lazily inside the functions that use them - transform() and
window_chunks() have to stay importable (and testable) without either.
"""
from __future__ import annotations

import json
import logging
import os
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS earthquakes (
    event_id text PRIMARY KEY,
    occurred_at timestamptz NOT NULL,
    magnitude double precision,
    place text,
    latitude double precision,
    longitude double precision,
    depth_km double precision,
    updated_at timestamptz,
    ingested_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_eq_time ON earthquakes (occurred_at);
CREATE INDEX IF NOT EXISTS idx_eq_mag_time ON earthquakes (magnitude DESC, occurred_at);
"""

_UPSERT_SQL = """
INSERT INTO earthquakes
    (event_id, occurred_at, magnitude, place, latitude, longitude, depth_km, updated_at)
VALUES
    (%(event_id)s, %(occurred_at)s, %(magnitude)s, %(place)s,
     %(latitude)s, %(longitude)s, %(depth_km)s, %(updated_at)s)
ON CONFLICT (event_id) DO UPDATE SET
    occurred_at = EXCLUDED.occurred_at,
    magnitude   = EXCLUDED.magnitude,
    place       = EXCLUDED.place,
    latitude    = EXCLUDED.latitude,
    longitude   = EXCLUDED.longitude,
    depth_km    = EXCLUDED.depth_km,
    updated_at  = EXCLUDED.updated_at,
    -- An update is still a pipeline write. API freshness is
    -- MAX(ingested_at), so it must advance on every successful cycle,
    -- not only when the feed publishes a brand-new event id - otherwise
    -- a quiet quarter-hour of global seismicity reads as an outage and
    -- fails the canary through the freshness endpoint's 503.
    ingested_at = now()
"""


# --- pure transform logic (unit-tested, no network/DB) ---------------------
def _epoch_ms_to_utc(ms: float) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)


def transform(feature: dict) -> dict | None:
    """Map one USGS GeoJSON feature to an earthquakes row, or None to skip.

    USGS occasionally ships a feature missing id or time; both are
    required (id is the primary key, time anchors the row), so such
    features are defensively dropped rather than failing the whole batch.
    """
    event_id = feature.get("id")
    props = feature.get("properties") or {}
    time_ms = props.get("time")
    if event_id is None or time_ms is None:
        return None

    updated_ms = props.get("updated")
    mag = props.get("mag")
    lon, lat, depth = feature["geometry"]["coordinates"]

    return {
        "event_id": event_id,
        "occurred_at": _epoch_ms_to_utc(time_ms),
        "magnitude": float(mag) if mag is not None else None,
        "place": props.get("place"),
        "longitude": lon,
        "latitude": lat,
        "depth_km": depth,
        "updated_at": _epoch_ms_to_utc(updated_ms) if updated_ms is not None else None,
    }


def window_chunks(start: datetime, end: datetime, days: int = 1):
    """Yield (chunk_start, chunk_end) day-sized slices covering [start, end).

    The final slice is partial when the range isn't an exact multiple of
    `days`. Yields nothing when start >= end.
    """
    step = timedelta(days=days)
    cursor = start
    while cursor < end:
        chunk_end = min(cursor + step, end)
        yield cursor, chunk_end
        cursor = chunk_end


def _transform_all(features: list[dict]) -> list[dict]:
    return [row for f in features if (row := transform(f)) is not None]


# --- USGS fetch (network, no DB) --------------------------------------------
def fetch_window(start: datetime, end: datetime) -> list[dict]:
    """GET one [start, end) window from the USGS feed; return its features."""
    params = {
        "format": "geojson",
        "starttime": start.isoformat(),
        "endtime": end.isoformat(),
        "limit": 20000,
        "orderby": "time",
    }
    url = f"{os.environ['USGS_BASE']}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as resp:  # raises on HTTP errors
        payload = json.load(resp)
    return payload.get("features", [])


# --- database (lazy psycopg import) -----------------------------------------
def _get_credentials() -> dict:
    # Lazy: boto3 ships with the Lambda runtime, not the local test venv.
    import boto3

    client = boto3.client("secretsmanager")
    secret = client.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
    return json.loads(secret["SecretString"])


def _connect():
    # Lazy: psycopg is vendored into ingestion/build/ by packaging, not
    # installed in the local test venv - pure-logic tests must not need it.
    import psycopg

    creds = _get_credentials()
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=creds["username"],
        password=creds["password"],
        autocommit=False,
    )


def ensure_schema(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(_SCHEMA_SQL)


def upsert(conn, rows: list[dict]) -> int:
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(_UPSERT_SQL, rows)
    return len(rows)


def _put_metric_data(metric_data: list[dict]) -> None:
    # Lazy: boto3 ships with the Lambda runtime, not the local test venv.
    import boto3

    client = boto3.client("cloudwatch")
    client.put_metric_data(Namespace=os.environ["METRIC_NAMESPACE"], MetricData=metric_data)


# --- entrypoint --------------------------------------------------------------
def lambda_handler(event, context):
    conn = None
    try:
        conn = _connect()
        ensure_schema(conn)

        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM earthquakes")
            existing = cur.fetchone()[0]

        now = datetime.now(timezone.utc)

        if existing == 0:
            mode = "backfill"
            start = now - timedelta(days=int(os.environ["BACKFILL_DAYS"]))
            upserted = 0
            for chunk_start, chunk_end in window_chunks(start, now):
                upserted += upsert(conn, _transform_all(fetch_window(chunk_start, chunk_end)))
        else:
            mode = "incremental"
            # 2h lookback re-covers the previous cycle on purpose - upsert
            # is idempotent on event_id, and USGS revises recent events
            # (magnitude, place) within their first hours.
            rows = _transform_all(fetch_window(now - timedelta(hours=2), now))
            upserted = upsert(conn, rows)

        conn.commit()

        _put_metric_data([
            {"MetricName": "EventsUpserted", "Value": float(upserted), "Unit": "Count"},
            # Always 0.0 on success - age of THIS ingest at publish time, not
            # a live gauge. The freshness alarm's real trigger is this metric
            # going missing for two silent 5-min cycles; >900s just guards
            # residual clock/publish weirdness on top of that.
            {"MetricName": "IngestionFreshnessSeconds", "Value": 0.0, "Unit": "Seconds"},
            {"MetricName": "IngestionSuccess", "Value": 1.0, "Unit": "Count"},
        ])
        return {"status": "ok", "mode": mode, "upserted": upserted}

    except Exception:
        logger.exception("ingestion run failed")
        try:
            _put_metric_data([{"MetricName": "IngestionSuccess", "Value": 0.0, "Unit": "Count"}])
        except Exception:
            logger.exception("failed to publish failure metric")
        raise  # Lambda error -> AWS/Lambda Errors metric -> ingestion-failures alarm

    finally:
        if conn is not None:
            conn.close()
