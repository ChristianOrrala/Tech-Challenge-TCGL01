"""Pure-logic tests for the ingestion Lambda: transform() and window_chunks().

Neither this module nor handler.py's module scope imports psycopg or
boto3 - this suite has to run in a venv that has neither installed, same
as the local test environment used to develop the Lambda.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# handler.py is a standalone Lambda file, not an installed package - add
# its directory to sys.path explicitly so this test collects the same way
# regardless of invocation cwd (repo root via `-m pytest`, or `pytest` run
# from inside ingestion/ as CI will do later).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from handler import transform, window_chunks  # noqa: E402

FIXTURE_PATH = Path(__file__).resolve().parent / "fixtures" / "usgs_sample.json"


def _load_features() -> list[dict]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))["features"]


# --- transform ----------------------------------------------------------


def test_transform_maps_all_fields_with_tz_aware_utc_datetimes():
    feature = _load_features()[0]

    row = transform(feature)

    assert row["event_id"] == "us7000example1"
    assert row["occurred_at"] == datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    assert row["occurred_at"].tzinfo is not None
    assert row["updated_at"] == datetime(2026, 1, 15, 12, 5, 30, tzinfo=timezone.utc)
    assert row["updated_at"].tzinfo is not None
    assert row["magnitude"] == 5.2
    assert row["place"] == "12km SE of Springfield"


def test_transform_honors_coordinate_order_lon_lat_depth():
    feature = _load_features()[0]

    row = transform(feature)

    # geometry.coordinates is [lon, lat, depth] - distinct values per axis
    # so a transposition bug (e.g. lat/lon swapped) would fail this.
    assert row["longitude"] == -122.4194
    assert row["latitude"] == 37.7749
    assert row["depth_km"] == 8.2


def test_transform_preserves_null_magnitude_and_null_updated():
    feature = _load_features()[1]

    row = transform(feature)

    assert row["event_id"] == "us7000example2"
    assert row["magnitude"] is None
    assert row["updated_at"] is None


def test_transform_missing_id_returns_none():
    feature = _load_features()[2]

    assert transform(feature) is None


def test_transform_missing_time_returns_none():
    feature = _load_features()[3]

    assert transform(feature) is None


# --- window_chunks --------------------------------------------------------


def test_window_chunks_3_5_days_yields_4_chunks_last_partial():
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    end = start + timedelta(days=3, hours=12)

    chunks = list(window_chunks(start, end))

    assert chunks == [
        (datetime(2026, 1, 1, tzinfo=timezone.utc), datetime(2026, 1, 2, tzinfo=timezone.utc)),
        (datetime(2026, 1, 2, tzinfo=timezone.utc), datetime(2026, 1, 3, tzinfo=timezone.utc)),
        (datetime(2026, 1, 3, tzinfo=timezone.utc), datetime(2026, 1, 4, tzinfo=timezone.utc)),
        (datetime(2026, 1, 4, tzinfo=timezone.utc), end),
    ]
    assert chunks[-1][1] - chunks[-1][0] == timedelta(hours=12)  # last chunk partial


def test_window_chunks_exact_1_day_yields_single_chunk():
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    end = start + timedelta(days=1)

    assert list(window_chunks(start, end)) == [(start, end)]


def test_window_chunks_start_equal_end_is_empty():
    start = end = datetime(2026, 1, 1, tzinfo=timezone.utc)

    assert list(window_chunks(start, end)) == []


def test_window_chunks_start_after_end_is_empty():
    start = datetime(2026, 1, 2, tzinfo=timezone.utc)
    end = datetime(2026, 1, 1, tzinfo=timezone.utc)

    assert list(window_chunks(start, end)) == []
