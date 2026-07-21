"""USGS earthquake ingestion - scheduled Lambda entrypoint."""


def lambda_handler(event, context):
    """Stub entrypoint - replaced by a later task.

    The scheduled EventBridge rule invokes this every 5 minutes. Real
    ingestion logic (fetch from USGS, upsert into PostgreSQL, emit
    CloudWatch metrics) lands in a later commit.
    """
    return {
        "status": "stub",
        "note": "ingestion logic lands in a later commit",
    }
