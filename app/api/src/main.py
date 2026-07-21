"""FastAPI app - read-only quake endpoints for the dashboard SPA.

/health is liveness only and never touches the database - see health()
below. Every /api/* route depends on get_repo() (overridden in tests) and
any psycopg error raised while handling one is turned into a single,
uniform 503 by database_error_handler, which is what the SPA's freshness
banner watches for.
"""
from __future__ import annotations

from datetime import datetime, timezone

import psycopg
from fastapi import Depends, FastAPI, Query
from fastapi.responses import JSONResponse

from src.db import get_pool
from src.repo import QuakeRepository

app = FastAPI(title="tcgl01-api")


def get_repo() -> QuakeRepository:
    return QuakeRepository(get_pool())


@app.exception_handler(psycopg.Error)
def database_error_handler(request, exc: psycopg.Error) -> JSONResponse:
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
