"""Invocation-mode tests for lambda_handler plus the deep-seed additions.

Same constraint as test_transform.py: no psycopg, no boto3, no network -
CI runs this suite with bare pytest. lambda_handler's seams (_connect,
fetch_window, _put_metric_data) are replaced with small hand-rolled
recording fakes (same no-mock-framework style as the api tests), which
is enough to prove mode routing, chunk math, the USGS-cap counter, and
that the scheduled path keeps today's request URLs and response contract
byte for byte.
"""
from __future__ import annotations

import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

# handler.py is a standalone Lambda file, not an installed package - add
# its directory to sys.path explicitly so this test collects the same way
# regardless of invocation cwd (repo root via `-m pytest`, or `pytest` run
# from inside ingestion/ as CI does).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import handler  # noqa: E402


# --- fakes ----------------------------------------------------------------


def _feature(event_id: str) -> dict:
    """One USGS GeoJSON feature that transform() accepts."""
    return {
        "id": event_id,
        "properties": {
            "time": 1_750_000_000_000,
            "updated": 1_750_000_300_000,
            "mag": 4.6,
            "place": "somewhere offshore",
        },
        "geometry": {"coordinates": [-122.4, 37.7, 8.0]},
    }


class FakeCursor:
    def __init__(self, conn):
        self._conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql):
        self._conn.executed.append(sql)

    def executemany(self, sql, rows):
        self._conn.executemany_batches.append(list(rows))

    def fetchone(self):
        return (self._conn.existing_rows,)


class FakeConn:
    """Stand-in for a psycopg connection - records SQL and rows, no DB.

    The real upsert()/ensure_schema() run against it, so the tests
    exercise everything except the actual wire protocols.
    """

    def __init__(self, existing_rows=0):
        self.existing_rows = existing_rows
        self.executed = []
        self.executemany_batches = []
        self.commits = 0
        self.closed = False

    def cursor(self):
        return FakeCursor(self)

    def commit(self):
        self.commits += 1

    def close(self):
        self.closed = True


class FetchRecorder:
    """Recording fake for fetch_window - canned features per call."""

    def __init__(self, features_for=None):
        self._features_for = features_for or (lambda call: [_feature(f"ev{call}")])
        self.calls = []

    def __call__(self, start, end, min_magnitude=None):
        self.calls.append({"start": start, "end": end, "min_magnitude": min_magnitude})
        return self._features_for(len(self.calls) - 1)


def _invoke(monkeypatch, event, *, existing_rows=0, features_for=None):
    """Run lambda_handler with every network/DB/metrics seam faked out."""
    conn = FakeConn(existing_rows=existing_rows)
    fetch = FetchRecorder(features_for)
    published = []
    monkeypatch.setattr(handler, "_connect", lambda: conn)
    monkeypatch.setattr(handler, "fetch_window", fetch)
    monkeypatch.setattr(handler, "_put_metric_data", published.append)
    result = handler.lambda_handler(event, None)
    return result, conn, fetch, published


# --- mode routing -----------------------------------------------------------


def test_scheduled_event_without_mode_key_runs_incremental_unchanged(monkeypatch):
    # What EventBridge actually sends: an envelope with no "mode" key.
    event = {"version": "0", "detail-type": "Scheduled Event", "source": "aws.events"}

    result, conn, fetch, _ = _invoke(monkeypatch, event, existing_rows=4231)

    # Exact legacy response contract - no deep-seed keys may leak in.
    assert result == {"status": "ok", "mode": "incremental", "upserted": 1}
    assert len(fetch.calls) == 1
    assert fetch.calls[0]["end"] - fetch.calls[0]["start"] == timedelta(hours=2)
    assert fetch.calls[0]["min_magnitude"] is None
    # The scheduled path still consults the row count to pick its branch.
    assert any("count(*)" in sql for sql in conn.executed)


def test_empty_event_on_empty_table_runs_backfill_without_magnitude_floor(monkeypatch):
    monkeypatch.setenv("BACKFILL_DAYS", "3")

    result, _, fetch, _ = _invoke(monkeypatch, {}, existing_rows=0)

    assert result == {"status": "ok", "mode": "backfill", "upserted": 3}
    assert [c["end"] - c["start"] for c in fetch.calls] == [timedelta(days=1)] * 3
    assert {c["min_magnitude"] for c in fetch.calls} == {None}


@pytest.mark.parametrize("existing_rows", [0, 4231], ids=["empty-table", "populated-table"])
def test_deep_seed_routes_independent_of_table_state(monkeypatch, existing_rows):
    # Deep seed must not consult the row count nor fall into the
    # empty-table backfill branch: with BACKFILL_DAYS absent, taking that
    # branch would raise KeyError.
    monkeypatch.delenv("BACKFILL_DAYS", raising=False)
    event = {"mode": "deep_seed", "seed_days": 2, "chunk_days": 1}

    result, conn, fetch, _ = _invoke(monkeypatch, event, existing_rows=existing_rows)

    assert result["mode"] == "deep_seed"
    assert result["chunks"] == 2
    assert not any("count(*)" in sql for sql in conn.executed)
    assert {c["min_magnitude"] for c in fetch.calls} == {4.0}


# --- deep-seed params: defaults and overrides -------------------------------


def test_deep_seed_default_params_cover_3650_days_in_30_day_chunks(monkeypatch):
    result, conn, fetch, _ = _invoke(monkeypatch, {"mode": "deep_seed"})

    assert result == {
        "status": "ok",
        "mode": "deep_seed",
        "chunks": 122,
        "upserted": 122,
        "capped_chunks": 0,
    }
    spans = [c["end"] - c["start"] for c in fetch.calls]
    assert spans[:-1] == [timedelta(days=30)] * 121
    assert spans[-1] == timedelta(days=20)  # 3650 = 121 * 30 + 20
    assert all(fetch.calls[i]["end"] == fetch.calls[i + 1]["start"] for i in range(121))
    assert fetch.calls[-1]["end"] - fetch.calls[0]["start"] == timedelta(days=3650)
    assert {c["min_magnitude"] for c in fetch.calls} == {4.0}
    assert conn.commits == 1
    assert conn.closed


def test_deep_seed_honors_overridden_event_params(monkeypatch):
    event = {"mode": "deep_seed", "seed_days": 10, "min_magnitude": 5.5, "chunk_days": 4}

    result, _, fetch, _ = _invoke(monkeypatch, event)

    assert result == {
        "status": "ok",
        "mode": "deep_seed",
        "chunks": 3,
        "upserted": 3,
        "capped_chunks": 0,
    }
    assert [c["end"] - c["start"] for c in fetch.calls] == [
        timedelta(days=4),
        timedelta(days=4),
        timedelta(days=2),
    ]
    assert {c["min_magnitude"] for c in fetch.calls} == {5.5}


def test_deep_seed_publishes_the_same_success_metrics_as_a_normal_run(monkeypatch):
    event = {"mode": "deep_seed", "seed_days": 2, "chunk_days": 1}

    _, _, _, published = _invoke(monkeypatch, event)

    assert published == [
        [
            {"MetricName": "EventsUpserted", "Value": 2.0, "Unit": "Count"},
            {"MetricName": "IngestionFreshnessSeconds", "Value": 0.0, "Unit": "Seconds"},
            {"MetricName": "IngestionSuccess", "Value": 1.0, "Unit": "Count"},
        ]
    ]


# --- USGS cap detection -------------------------------------------------------


def test_deep_seed_counts_capped_chunks_and_warns_naming_the_window(monkeypatch, caplog):
    # 20000 is the USGS-documented per-query cap, hardcoded on purpose -
    # if the handler's limit ever drifts, this test should notice.
    def features_for(call):
        if call == 0:
            return [_feature(f"cap{i}") for i in range(20000)]
        return [_feature("tail0"), _feature("tail1")]

    event = {"mode": "deep_seed", "seed_days": 60, "chunk_days": 30}
    with caplog.at_level(logging.WARNING):
        result, _, fetch, _ = _invoke(monkeypatch, event, features_for=features_for)

    assert result == {
        "status": "ok",
        "mode": "deep_seed",
        "chunks": 2,
        "upserted": 20002,
        "capped_chunks": 1,
    }
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1
    assert fetch.calls[0]["start"].isoformat() in warnings[0].getMessage()
    assert fetch.calls[0]["end"].isoformat() in warnings[0].getMessage()


# --- fetch_window URL construction -------------------------------------------


class _FakeHTTPResponse:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return b'{"features": []}'


def _capture_fetch_urls(monkeypatch):
    seen = []

    def fake_urlopen(url, timeout=None):
        seen.append({"url": url, "timeout": timeout})
        return _FakeHTTPResponse()

    monkeypatch.setenv("USGS_BASE", "https://usgs.example/query")
    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    return seen


# Captured from the pre-deep-seed implementation - the scheduled path's
# URLs must stay exactly this, byte for byte.
_LEGACY_URL = (
    "https://usgs.example/query?format=geojson"
    "&starttime=2026-01-01T00%3A00%3A00%2B00%3A00"
    "&endtime=2026-01-02T00%3A00%3A00%2B00%3A00"
    "&limit=20000&orderby=time"
)

_START = datetime(2026, 1, 1, tzinfo=timezone.utc)
_END = datetime(2026, 1, 2, tzinfo=timezone.utc)


def test_fetch_window_without_min_magnitude_builds_byte_identical_legacy_url(monkeypatch):
    seen = _capture_fetch_urls(monkeypatch)

    handler.fetch_window(_START, _END)
    handler.fetch_window(_START, _END, min_magnitude=None)

    assert [s["url"] for s in seen] == [_LEGACY_URL, _LEGACY_URL]
    assert seen[0]["timeout"] == 30


def test_fetch_window_with_min_magnitude_appends_only_minmagnitude(monkeypatch):
    seen = _capture_fetch_urls(monkeypatch)

    handler.fetch_window(_START, _END, min_magnitude=4.0)

    assert seen[0]["url"] == _LEGACY_URL + "&minmagnitude=4.0"


# --- chunk math ---------------------------------------------------------------


def test_window_chunks_3650_days_by_30_yields_122_chunks_last_partial():
    start = datetime(2016, 1, 1, tzinfo=timezone.utc)
    end = start + timedelta(days=3650)

    chunks = list(handler.window_chunks(start, end, days=30))

    assert len(chunks) == 122
    assert chunks[0][0] == start
    assert chunks[-1][1] == end
    assert all(e - s == timedelta(days=30) for s, e in chunks[:-1])
    assert chunks[-1][1] - chunks[-1][0] == timedelta(days=20)
    assert all(chunks[i][1] == chunks[i + 1][0] for i in range(121))


# --- operator payload validation ----------------------------------------------


@pytest.mark.parametrize(
    ("event", "match"),
    [
        ({"mode": "deepseed"}, "mode"),
        ({"mode": "deep_seed", "seed_days": "3650"}, "seed_days"),
        ({"mode": "deep_seed", "seed_days": 0}, "seed_days"),
        ({"mode": "deep_seed", "seed_days": -5}, "seed_days"),
        ({"mode": "deep_seed", "seed_days": True}, "seed_days"),
        ({"mode": "deep_seed", "seed_days": 36.5}, "seed_days"),
        ({"mode": "deep_seed", "chunk_days": "30"}, "chunk_days"),
        ({"mode": "deep_seed", "chunk_days": 0}, "chunk_days"),
        ({"mode": "deep_seed", "min_magnitude": "4.0"}, "min_magnitude"),
        ({"mode": "deep_seed", "min_magnitude": None}, "min_magnitude"),
        ({"mode": "deep_seed", "min_magnitude": True}, "min_magnitude"),
    ],
)
def test_deep_seed_rejects_bad_params_before_touching_the_database(monkeypatch, event, match):
    def _no_connect():
        raise AssertionError("bad operator payloads must fail before any DB connection")

    monkeypatch.setattr(handler, "_connect", _no_connect)

    with pytest.raises(ValueError, match=match):
        handler.lambda_handler(event, None)
