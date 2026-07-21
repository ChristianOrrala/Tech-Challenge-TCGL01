"""Endpoint contract tests - shape and status codes only.

Every test injects a FakeRepo through the get_repo dependency override, so
none of these touch a real database. SQL correctness (filtering, sort
order, date math) is exercised against the real RDS instance by the Task
14 post-deploy smoke test - these tests only prove the HTTP layer passes
repo output through and shapes it correctly, validates query params, and
turns repo failures into the contracted 503.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient

from src.main import app, get_repo


class FakeRepo:
    """Plain stand-in for QuakeRepository - canned rows, no SQL, no DB.

    Every method that takes arguments records them in a *_calls list so
    tests can assert what the endpoint passed through, without needing a
    mock framework.
    """

    def __init__(self, *, recent=None, weekly=None, top=None, freshness=None, error=None):
        self._recent = recent if recent is not None else []
        self._weekly = weekly if weekly is not None else []
        self._top = top if top is not None else []
        self._freshness = freshness if freshness is not None else {"last_ingest": None, "latest_event": None}
        self._error = error
        self.recent_calls = []
        self.top_calls = []

    def recent(self):
        self.recent_calls.append(())
        if self._error:
            raise self._error
        return self._recent

    def weekly_counts(self):
        if self._error:
            raise self._error
        return self._weekly

    def top(self, days, limit):
        self.top_calls.append({"days": days, "limit": limit})
        if self._error:
            raise self._error
        return self._top

    def freshness(self):
        if self._error:
            raise self._error
        return self._freshness


class ExplodingRepo:
    """Repo whose every method fails the test if called at all."""

    def _boom(self, *args, **kwargs):
        raise AssertionError("repo must not be touched")

    recent = _boom
    weekly_counts = _boom
    top = _boom
    freshness = _boom


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def override(repo):
    app.dependency_overrides[get_repo] = lambda: repo


# --- /health --------------------------------------------------------------


def test_health_ok_and_no_repo_touched(client):
    override(ExplodingRepo())

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# --- /api/quakes/recent -----------------------------------------------------


def test_recent_shapes_and_orders_and_calls_repo_with_no_args(client):
    # Already filtered (mag > 4.0) and ordered newest-first, as the real SQL
    # would return - the endpoint's job is to pass this through, not refilter.
    newer = {
        "event_id": "us1000abcd",
        "occurred_at": datetime(2026, 7, 20, 10, 0, 0, tzinfo=timezone.utc),
        "magnitude": 5.4,
        "place": "10km SE of Somewhere",
        "latitude": 12.34,
        "longitude": 56.78,
        "depth_km": 10.5,
    }
    older = {
        "event_id": "us1000abce",
        "occurred_at": datetime(2026, 7, 20, 8, 0, 0, tzinfo=timezone.utc),
        "magnitude": 4.2,
        "place": "20km NW of Elsewhere",
        "latitude": -12.34,
        "longitude": -56.78,
        "depth_km": 33.0,
    }
    fake = FakeRepo(recent=[newer, older])
    override(fake)

    response = client.get("/api/quakes/recent")

    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 2
    assert body["items"] == [
        {
            "id": "us1000abcd",
            "time": "2026-07-20T10:00:00+00:00",
            "magnitude": 5.4,
            "place": "10km SE of Somewhere",
            "lat": 12.34,
            "lon": 56.78,
            "depth_km": 10.5,
        },
        {
            "id": "us1000abce",
            "time": "2026-07-20T08:00:00+00:00",
            "magnitude": 4.2,
            "place": "20km NW of Elsewhere",
            "lat": -12.34,
            "lon": -56.78,
            "depth_km": 33.0,
        },
    ]
    # No filter/date-range args cross the HTTP boundary - that's all SQL.
    assert fake.recent_calls == [()]


# --- /api/quakes/weekly-averages --------------------------------------------


def test_weekly_returns_seven_buckets_and_correct_average(client):
    counts = [3, 5, 2, 4, 6, 1, 2]  # sum 23 -> 23/7.0 = 3.2857... -> 3.29
    daily_rows = [
        {"d": datetime(2026, 7, 14 + i, tzinfo=timezone.utc).date(), "count": c}
        for i, c in enumerate(counts)
    ]
    fake = FakeRepo(weekly=daily_rows)
    override(fake)

    response = client.get("/api/quakes/weekly-averages")

    assert response.status_code == 200
    body = response.json()
    assert len(body["daily"]) == 7
    assert body["daily"][0] == {"date": "2026-07-14", "count": 3}
    assert body["daily"][6] == {"date": "2026-07-20", "count": 2}
    assert body["average_per_day"] == 3.29


# --- /api/quakes/top ---------------------------------------------------------


def test_top_passes_default_days_and_limit_to_repo(client):
    fake = FakeRepo(top=[])
    override(fake)

    response = client.get("/api/quakes/top")

    assert response.status_code == 200
    assert fake.top_calls == [{"days": 30, "limit": 5}]


def test_top_passes_explicit_days_and_limit_to_repo(client):
    row = {
        "event_id": "us1000abcf",
        "occurred_at": datetime(2026, 7, 19, 3, 0, 0, tzinfo=timezone.utc),
        "magnitude": 6.1,
        "place": "5km N of Nowhere",
        "latitude": 1.0,
        "longitude": 2.0,
        "depth_km": 15.0,
    }
    fake = FakeRepo(top=[row])
    override(fake)

    response = client.get("/api/quakes/top", params={"days": 10, "limit": 3})

    assert response.status_code == 200
    assert fake.top_calls == [{"days": 10, "limit": 3}]
    assert response.json()["items"] == [
        {
            "id": "us1000abcf",
            "time": "2026-07-19T03:00:00+00:00",
            "magnitude": 6.1,
            "place": "5km N of Nowhere",
            "lat": 1.0,
            "lon": 2.0,
            "depth_km": 15.0,
        }
    ]


@pytest.mark.parametrize("params", [{"days": 0}, {"days": 91}, {"limit": 0}, {"limit": 51}])
def test_top_rejects_out_of_range_params(client, params):
    fake = FakeRepo(top=[])
    override(fake)

    response = client.get("/api/quakes/top", params=params)

    assert response.status_code == 422
    assert fake.top_calls == []  # validation failed before the repo was ever reached


# --- /api/meta/freshness -----------------------------------------------------


def test_freshness_not_stale_at_100_seconds(client):
    now = datetime.now(timezone.utc)
    last_ingest = now - timedelta(seconds=100)
    fake = FakeRepo(freshness={"last_ingest": last_ingest, "latest_event": last_ingest})
    override(fake)

    response = client.get("/api/meta/freshness")

    assert response.status_code == 200
    body = response.json()
    assert body["stale"] is False
    assert abs(body["age_seconds"] - 100) <= 2
    assert body["last_ingest"] is not None
    assert body["latest_event"] is not None


def test_freshness_stale_at_1000_seconds(client):
    now = datetime.now(timezone.utc)
    last_ingest = now - timedelta(seconds=1000)
    fake = FakeRepo(freshness={"last_ingest": last_ingest, "latest_event": last_ingest})
    override(fake)

    response = client.get("/api/meta/freshness")

    assert response.status_code == 200
    body = response.json()
    assert body["stale"] is True
    assert abs(body["age_seconds"] - 1000) <= 2


def test_freshness_empty_table_returns_nulls_and_stale(client):
    fake = FakeRepo(freshness={"last_ingest": None, "latest_event": None})
    override(fake)

    response = client.get("/api/meta/freshness")

    assert response.status_code == 200
    assert response.json() == {
        "last_ingest": None,
        "latest_event": None,
        "age_seconds": None,
        "stale": True,
    }


# --- database error handling -------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        "/api/quakes/recent",
        "/api/quakes/weekly-averages",
        "/api/quakes/top",
        "/api/meta/freshness",
    ],
)
def test_database_error_returns_503_with_exact_body(client, path):
    fake = FakeRepo(error=psycopg.OperationalError("connection refused"))
    override(fake)

    response = client.get(path)

    assert response.status_code == 503
    assert response.json() == {"error": "database unavailable"}
