"""GET /api/quakes contract tests - pagination, cursor and coverage logic.

Same philosophy as test_endpoints.py: no real database, SQL correctness
belongs to the post-deploy smoke test. What is different here is that
keyset pagination is endpoint logic (decode the cursor, fetch one spare
row, trim, mint next_cursor), so a canned fake cannot prove the walk
invariants. KeysetFakeRepo therefore emulates the repo's SQL contract in
Python - same (sort value, event_id) ordering, same strict keyset
predicate, same NULL handling - which lets the multi-page tests assert
the one property that matters: every row exactly once, even when a page
boundary lands inside a group of tied sort values.
"""
from __future__ import annotations

import base64
import json
from datetime import datetime, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient

from src.main import app, get_repo


def _t(day: int) -> datetime:
    return datetime(2026, 7, day, 12, 0, 0, tzinfo=timezone.utc)


def _row(event_id: str, occurred_at: datetime, magnitude: float | None) -> dict:
    return {
        "event_id": event_id,
        "occurred_at": occurred_at,
        "magnitude": magnitude,
        "place": f"near {event_id}",
        "latitude": 1.0,
        "longitude": 2.0,
        "depth_km": 10.0,
    }


def _cursor(payload) -> str:
    """Build a cursor the way the API does - for hand-crafting bad ones."""
    return base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")


def _decode(cursor: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))


class FakeRepo:
    """Canned catalog rows and coverage, recording call args - no keyset logic."""

    def __init__(self, *, catalog=None, coverage=None, error=None):
        self._catalog = catalog if catalog is not None else []
        self._coverage = coverage if coverage is not None else {"all_since": None, "m4_since": None}
        self._error = error
        self.catalog_calls = []

    def catalog(self, *, sort, order, min_mag, max_mag, start, end, limit, after_value, after_id):
        self.catalog_calls.append(
            {
                "sort": sort,
                "order": order,
                "min_mag": min_mag,
                "max_mag": max_mag,
                "start": start,
                "end": end,
                "limit": limit,
                "after_value": after_value,
                "after_id": after_id,
            }
        )
        if self._error:
            raise self._error
        return self._catalog

    def coverage(self):
        if self._error:
            raise self._error
        return self._coverage


class KeysetFakeRepo:
    """Emulates QuakeRepository.catalog's SQL contract over in-memory rows.

    Kept deliberately parallel to src/repo.py: NULL magnitudes are
    unreachable under sort=magnitude and dropped by magnitude comparisons
    (SQL NULL semantics), the keyset predicate is a strict row comparison,
    and ties break on event_id.
    """

    def __init__(self, rows):
        self._rows = rows

    def catalog(self, *, sort, order, min_mag, max_mag, start, end, limit, after_value, after_id):
        rows = list(self._rows)
        if sort == "magnitude":
            rows = [r for r in rows if r["magnitude"] is not None]
        if min_mag is not None:
            rows = [r for r in rows if r["magnitude"] is not None and r["magnitude"] >= min_mag]
        if max_mag is not None:
            rows = [r for r in rows if r["magnitude"] is not None and r["magnitude"] <= max_mag]
        if start is not None:
            rows = [r for r in rows if r["occurred_at"] >= start]
        if end is not None:
            rows = [r for r in rows if r["occurred_at"] <= end]

        column = "occurred_at" if sort == "time" else "magnitude"

        def key(row):
            return (row[column], row["event_id"])

        if after_id is not None:
            after = (after_value, after_id)
            if order == "asc":
                rows = [r for r in rows if key(r) > after]
            else:
                rows = [r for r in rows if key(r) < after]
        rows.sort(key=key, reverse=(order == "desc"))
        return rows[:limit]

    def coverage(self):
        # Mirrors _COVERAGE_SQL: all_since tracks sub-M4/unmeasured rows only,
        # so an M>=4-only deep seed cannot drag it back a decade.
        sub_m4 = [r["occurred_at"] for r in self._rows if r["magnitude"] is None or r["magnitude"] < 4.0]
        m4_times = [r["occurred_at"] for r in self._rows if r["magnitude"] is not None and r["magnitude"] >= 4.0]
        return {"all_since": min(sub_m4, default=None), "m4_since": min(m4_times, default=None)}


class ExplodingRepo:
    """Repo whose every method fails the test if called at all."""

    def _boom(self, *args, **kwargs):
        raise AssertionError("repo must not be touched")

    catalog = _boom
    coverage = _boom


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def override(repo):
    app.dependency_overrides[get_repo] = lambda: repo


def _walk(client, params) -> list[list[str]]:
    """Follow next_cursor to exhaustion, returning the ids of each page."""
    pages = []
    cursor = None
    while True:
        merged = dict(params)
        if cursor is not None:
            merged["cursor"] = cursor
        response = client.get("/api/quakes", params=merged)
        assert response.status_code == 200
        body = response.json()
        pages.append([item["id"] for item in body["items"]])
        cursor = body["next_cursor"]
        if cursor is None:
            return pages
        assert len(pages) < 10  # runaway pagination = cursor bug


# Eight rows engineered so that limit=3 puts a page boundary inside a tie
# group for every (sort, order) combination: q03-q06 share occurred_at,
# q01/q02/q05 share magnitude 5.0, and q06 has no magnitude at all.
_DATASET = [
    _row("q01", _t(10), 5.0),
    _row("q02", _t(11), 5.0),
    _row("q03", _t(12), 4.2),
    _row("q04", _t(12), 6.3),
    _row("q05", _t(12), 5.0),
    _row("q06", _t(12), None),
    _row("q07", _t(14), 2.9),
    _row("q08", _t(15), 7.1),
]

_TIME_ASC = ["q01", "q02", "q03", "q04", "q05", "q06", "q07", "q08"]
_MAG_ASC = ["q07", "q03", "q01", "q02", "q05", "q04", "q08"]  # q06 has no magnitude


# --- shape and defaults -------------------------------------------------------


def test_default_page_shapes_rows_like_the_other_quake_endpoints(client):
    row = {
        "event_id": "us1000abcd",
        "occurred_at": datetime(2026, 7, 20, 10, 0, 0, tzinfo=timezone.utc),
        "magnitude": 5.4,
        "place": "10km SE of Somewhere",
        "latitude": 12.34,
        "longitude": 56.78,
        "depth_km": 10.5,
    }
    fake = FakeRepo(
        catalog=[row],
        coverage={
            "all_since": datetime(2016, 7, 1, 0, 0, 0, tzinfo=timezone.utc),
            "m4_since": datetime(2016, 8, 2, 3, 0, 0, tzinfo=timezone.utc),
        },
    )
    override(fake)

    response = client.get("/api/quakes")

    assert response.status_code == 200
    assert response.json() == {
        "items": [
            {
                "id": "us1000abcd",
                "time": "2026-07-20T10:00:00+00:00",
                "magnitude": 5.4,
                "place": "10km SE of Somewhere",
                "lat": 12.34,
                "lon": 56.78,
                "depth_km": 10.5,
            }
        ],
        "next_cursor": None,
        "coverage": {
            "all_since": "2016-07-01T00:00:00+00:00",
            "m4_since": "2016-08-02T03:00:00+00:00",
        },
    }


def test_default_params_reach_repo_with_one_spare_row_for_has_more(client):
    fake = FakeRepo()
    override(fake)

    response = client.get("/api/quakes")

    assert response.status_code == 200
    assert fake.catalog_calls == [
        {
            "sort": "time",
            "order": "desc",
            "min_mag": None,
            "max_mag": None,
            "start": None,
            "end": None,
            "limit": 26,  # 25 requested + the spare row that answers has-more
            "after_value": None,
            "after_id": None,
        }
    ]


def test_filter_params_are_parsed_and_passed_through(client):
    fake = FakeRepo()
    override(fake)

    response = client.get(
        "/api/quakes",
        params={
            "sort": "magnitude",
            "order": "asc",
            "min_mag": 2.5,
            "max_mag": 8.0,
            "start": "2026-07-01T00:00:00Z",
            "end": "2026-07-15T12:30:00",  # naive - taken as UTC, like _iso does
            "limit": 50,
        },
    )

    assert response.status_code == 200
    call = fake.catalog_calls[0]
    assert call["sort"] == "magnitude"
    assert call["order"] == "asc"
    assert call["min_mag"] == 2.5
    assert call["max_mag"] == 8.0
    assert call["start"] == datetime(2026, 7, 1, 0, 0, 0, tzinfo=timezone.utc)
    assert call["end"] == datetime(2026, 7, 15, 12, 30, 0, tzinfo=timezone.utc)
    assert call["limit"] == 51


# --- query param validation ---------------------------------------------------


@pytest.mark.parametrize(
    "params",
    [
        {"sort": "depth"},
        {"sort": "TIME"},
        {"order": "sideways"},
        {"limit": 0},
        {"limit": 101},
        {"min_mag": -2.1},
        {"max_mag": 11.1},
        {"start": "not-a-timestamp"},
        {"end": "2026-13-01T00:00:00Z"},
    ],
)
def test_invalid_params_are_422_before_the_repo_is_touched(client, params):
    override(ExplodingRepo())

    response = client.get("/api/quakes", params=params)

    assert response.status_code == 422


# --- cursor walks ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("sort", "order", "expected"),
    [
        ("time", "asc", _TIME_ASC),
        ("time", "desc", list(reversed(_TIME_ASC))),
        ("magnitude", "asc", _MAG_ASC),
        ("magnitude", "desc", list(reversed(_MAG_ASC))),
    ],
)
def test_cursor_walk_yields_every_row_exactly_once_across_tied_pages(client, sort, order, expected):
    override(KeysetFakeRepo(_DATASET))

    pages = _walk(client, {"sort": sort, "order": order, "limit": 3})

    # Three pages whose concatenation is exactly the expected total order:
    # no duplicates, no gaps, ties broken by event_id at every boundary.
    assert [len(page) for page in pages] == [3, 3, len(expected) - 6]
    assert [event_id for page in pages for event_id in page] == expected


def test_magnitude_sort_excludes_unmeasured_rows_time_sort_keeps_them(client):
    override(KeysetFakeRepo(_DATASET))

    by_magnitude = client.get("/api/quakes", params={"sort": "magnitude", "limit": 100}).json()
    by_time = client.get("/api/quakes", params={"sort": "time", "limit": 100}).json()

    assert "q06" not in [item["id"] for item in by_magnitude["items"]]
    assert "q06" in [item["id"] for item in by_time["items"]]
    assert by_magnitude["next_cursor"] is None  # page came back shorter than limit


# --- filters compose with the cursor --------------------------------------------


def test_filters_hold_across_cursor_pages(client):
    override(KeysetFakeRepo(_DATASET))

    pages = _walk(
        client,
        {"sort": "time", "order": "asc", "limit": 3, "min_mag": 4.2, "start": "2026-07-12T00:00:00Z"},
    )

    # q06 sits inside the T12 tie group just past the page-1 cursor but has
    # no magnitude - page 2 must keep filtering it out, not resurrect it.
    assert pages == [["q03", "q04", "q05"], ["q08"]]


def test_max_mag_and_end_bound_the_listing(client):
    override(KeysetFakeRepo(_DATASET))

    response = client.get("/api/quakes", params={"max_mag": 5.0, "end": "2026-07-12T23:59:59Z"})

    body = response.json()
    # SQL comparison semantics: magnitude <= 5.0 is NULL for q06, so the
    # unmeasured row drops out even under sort=time.
    assert [item["id"] for item in body["items"]] == ["q05", "q03", "q02", "q01"]
    assert body["next_cursor"] is None


# --- next_cursor minting ---------------------------------------------------------


def test_next_cursor_encodes_the_last_visible_row_and_trims_the_spare(client):
    rows = [_row(f"q0{i}", _t(15 - i), 5.0 + i) for i in range(1, 5)]
    fake = FakeRepo(catalog=rows)  # endpoint asked for 3 + 1 and got 4: more pages exist
    override(fake)

    response = client.get("/api/quakes", params={"limit": 3})

    body = response.json()
    assert [item["id"] for item in body["items"]] == ["q01", "q02", "q03"]  # spare row never shown
    assert _decode(body["next_cursor"]) == {
        "s": "time",
        "o": "desc",
        "v": "2026-07-12T12:00:00+00:00",
        "id": "q03",
    }


def test_next_cursor_carries_the_magnitude_under_magnitude_sort(client):
    rows = [_row(f"q0{i}", _t(10 + i), 8.0 - i) for i in range(1, 5)]
    fake = FakeRepo(catalog=rows)
    override(fake)

    response = client.get("/api/quakes", params={"sort": "magnitude", "limit": 3})

    assert _decode(response.json()["next_cursor"]) == {
        "s": "magnitude",
        "o": "desc",
        "v": 5.0,
        "id": "q03",
    }


def test_next_cursor_is_null_when_no_spare_row_came_back(client):
    rows = [_row(f"q0{i}", _t(10 + i), 5.0) for i in range(1, 4)]
    fake = FakeRepo(catalog=rows)  # exactly the page, no spare: nothing beyond it
    override(fake)

    response = client.get("/api/quakes", params={"limit": 3})

    body = response.json()
    assert len(body["items"]) == 3
    assert body["next_cursor"] is None


# --- cursor rejection ------------------------------------------------------------


@pytest.mark.parametrize(
    "params",
    [
        {"cursor": "%%%not-base64%%%"},
        {"cursor": base64.urlsafe_b64encode(b"not json").decode()},
        {"cursor": _cursor(["not", "an", "object"])},
        {"cursor": _cursor({"v": "2026-07-12T00:00:00+00:00"})},  # missing keys
        {"cursor": _cursor({"s": "time", "o": "desc", "v": 123, "id": "q01"})},  # non-ISO time value
        {"cursor": _cursor({"s": "time", "o": "desc", "v": "2026-07-12T00:00:00+00:00", "id": 5})},
        {"sort": "magnitude", "cursor": _cursor({"s": "magnitude", "o": "desc", "v": "high", "id": "q01"})},
    ],
)
def test_malformed_cursor_is_422_never_500(client, params):
    override(ExplodingRepo())

    response = client.get("/api/quakes", params=params)

    assert response.status_code == 422
    assert "cursor" in response.json()["detail"]


@pytest.mark.parametrize(
    "params",
    [
        {},  # minted under sort=magnitude, replayed under the default sort=time
        {"sort": "magnitude", "order": "asc"},  # right sort, wrong order
    ],
)
def test_cursor_from_a_different_sort_or_order_is_refused(client, params):
    override(ExplodingRepo())
    minted = _cursor({"s": "magnitude", "o": "desc", "v": 5.0, "id": "q01"})

    response = client.get("/api/quakes", params={**params, "cursor": minted})

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert "cursor" in detail
    assert "sort=magnitude" in detail


# --- empty table and database failure ---------------------------------------------


def test_empty_table_returns_empty_page_and_null_coverage(client):
    override(FakeRepo())

    response = client.get("/api/quakes")

    assert response.status_code == 200
    assert response.json() == {
        "items": [],
        "next_cursor": None,
        "coverage": {"all_since": None, "m4_since": None},
    }


def test_database_error_returns_503_with_exact_body(client):
    override(FakeRepo(error=psycopg.OperationalError("connection refused")))

    response = client.get("/api/quakes")

    assert response.status_code == 503
    assert response.json() == {"error": "database unavailable"}
