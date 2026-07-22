"""FastAPI app - read-only quake endpoints for the dashboard SPA.

/health is liveness only and never touches the database - see health()
below. Every /api/* route depends on get_repo() (overridden in tests) and
any psycopg error raised while handling one is turned into a single,
uniform 503 by database_error_handler, which is what the SPA's freshness
banner watches for.
"""
from __future__ import annotations

import base64
import json
import logging
from datetime import datetime, timezone
from typing import Literal

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from src.db import get_pool
from src.repo import QuakeRepository

logger = logging.getLogger(__name__)

app = FastAPI(title="tcgl01-api")


def get_repo() -> QuakeRepository:
    return QuakeRepository(get_pool())


@app.exception_handler(psycopg.Error)
def database_error_handler(request, exc: psycopg.Error) -> JSONResponse:
    logger.exception("database error")
    return JSONResponse(status_code=503, content={"error": "database unavailable"})


def _iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _shape_quake(row: dict) -> dict:
    return {
        "id": row["event_id"],
        "time": _iso(row["occurred_at"]),
        "magnitude": row["magnitude"],
        "place": row["place"],
        "lat": row["latitude"],
        "lon": row["longitude"],
        "depth_km": row["depth_km"],
    }


def _utc(value: datetime | None) -> datetime | None:
    """Naive datetimes from the query string are taken as UTC - the same
    convention _iso applies on the way out."""
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


_CURSOR_MALFORMED = "malformed cursor: pass next_cursor back exactly as issued"


def _encode_cursor(sort: str, order: str, value: str | float, event_id: str) -> str:
    """Opaque keyset cursor: URL-safe base64 JSON of the last row's sort
    value and event_id, tagged with the sort/order it was minted under."""
    payload = {"s": sort, "o": order, "v": value, "id": event_id}
    return base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")


def _decode_cursor(cursor: str, sort: str, order: str) -> tuple[datetime | float, str]:
    """Reverse of _encode_cursor, defensive on purpose: a client-mangled
    cursor must be a 422, never a 500, and a cursor minted under a different
    sort/order is refused - resuming it would silently restart the listing
    somewhere else.
    """
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        payload = json.loads(raw)
        issued = (payload["s"], payload["o"])
        value, event_id = payload["v"], payload["id"]
        if not isinstance(event_id, str):
            raise TypeError("cursor id must be a string")
    except (ValueError, KeyError, TypeError):
        raise HTTPException(status_code=422, detail=_CURSOR_MALFORMED)

    if issued != (sort, order):
        raise HTTPException(
            status_code=422,
            detail=(
                f"cursor was issued for sort={issued[0]} order={issued[1]} "
                f"and cannot resume sort={sort} order={order}"
            ),
        )

    try:
        if sort == "time":
            return _utc(datetime.fromisoformat(value)), event_id
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("cursor value must be a number")
        return float(value), event_id
    except (ValueError, TypeError):
        raise HTTPException(status_code=422, detail=_CURSOR_MALFORMED)


@app.get("/health")
def health() -> dict:
    """Liveness probe only - deliberately never touches the database.

    The ALB target group polls this every 15s (see infra/modules/api/alb.tf).
    If it depended on Postgres, a DB blip would drain every task and take
    the whole service down instead of failing just the /api/* routes that
    actually need data.
    """
    return {"status": "ok"}


@app.get("/api/quakes/recent")
def recent(repo: QuakeRepository = Depends(get_repo)) -> dict:
    items = [_shape_quake(row) for row in repo.recent()]
    return {"items": items, "count": len(items)}


@app.get("/api/quakes/weekly-averages")
def weekly_averages(repo: QuakeRepository = Depends(get_repo)) -> dict:
    rows = repo.weekly_counts()
    daily = [{"date": row["d"].isoformat(), "count": row["count"]} for row in rows]
    total = sum(row["count"] for row in rows)
    return {"daily": daily, "average_per_day": round(total / 7.0, 2)}


@app.get("/api/quakes/top")
def top(
    days: int = Query(30, ge=1, le=90),
    limit: int = Query(5, ge=1, le=50),
    repo: QuakeRepository = Depends(get_repo),
) -> dict:
    items = [_shape_quake(row) for row in repo.top(days=days, limit=limit)]
    return {"items": items}


@app.get("/api/quakes")
def catalog(
    sort: Literal["time", "magnitude"] = Query("time"),
    order: Literal["desc", "asc"] = Query("desc"),
    min_mag: float | None = Query(None, ge=-2, le=11),
    max_mag: float | None = Query(None, ge=-2, le=11),
    start: datetime | None = Query(None),
    end: datetime | None = Query(None),
    limit: int = Query(25, ge=1, le=100),
    cursor: str | None = Query(None),
    repo: QuakeRepository = Depends(get_repo),
) -> dict:
    """Paginated historical catalog - served only from our own database.

    Per ADR 014 nothing here calls upstream: instead of hydrating gaps on
    demand, the response states what the catalog covers (all_since /
    m4_since) and the keyset cursor keeps deep pages O(page) at deep-seed
    scale, where OFFSET would degrade with depth.
    """
    after_value = after_id = None
    if cursor is not None:
        after_value, after_id = _decode_cursor(cursor, sort, order)

    # limit + 1: the spare row answers "is there another page" without a
    # count query; it is trimmed before shaping.
    rows = repo.catalog(
        sort=sort,
        order=order,
        min_mag=min_mag,
        max_mag=max_mag,
        start=_utc(start),
        end=_utc(end),
        limit=limit + 1,
        after_value=after_value,
        after_id=after_id,
    )
    has_more = len(rows) > limit
    rows = rows[:limit]

    next_cursor = None
    if has_more:
        last = rows[-1]
        value = _iso(last["occurred_at"]) if sort == "time" else last["magnitude"]
        next_cursor = _encode_cursor(sort, order, value, last["event_id"])

    coverage = repo.coverage()
    return {
        "items": [_shape_quake(row) for row in rows],
        "next_cursor": next_cursor,
        "coverage": {"all_since": _iso(coverage["all_since"]), "m4_since": _iso(coverage["m4_since"])},
    }


@app.get("/api/meta/freshness")
def freshness(repo: QuakeRepository = Depends(get_repo)) -> dict:
    row = repo.freshness()
    last_ingest = row["last_ingest"]

    if last_ingest is None:
        return {"last_ingest": None, "latest_event": None, "age_seconds": None, "stale": True}

    # Staleness tracks the ingestion pipeline's heartbeat (last row written),
    # not the most recent earthquake's own timestamp - a quiet day for global
    # seismic activity isn't an outage, a pipeline that stopped writing is.
    age_seconds = int((datetime.now(timezone.utc) - last_ingest.astimezone(timezone.utc)).total_seconds())
    return {
        "last_ingest": _iso(last_ingest),
        "latest_event": _iso(row["latest_event"]),
        "age_seconds": age_seconds,
        "stale": age_seconds > 900,
    }
