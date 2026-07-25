-- =====================================================================
-- 02_events_telemetry.sql  -  The high-volume append tables
-- =====================================================================
-- These are the tables that grow forever. The rule I follow: type the
-- COMMON fields every record shares, and push the per-model / per-sensor
-- tail into a VARIANT column. That is what lets a new sensor type or a
-- new model land with zero DDL - the point of the whole exercise.
--
-- Raw video NEVER lands here. media_object holds a pointer (S3 URI) and
-- metadata only. This is non-negotiable #1.
-- =====================================================================

USE DATABASE EDGEIOT;

-- =====================================================================
-- RAW landing layer
-- =====================================================================
-- In plain English: devices dump their messages here exactly as sent, as
-- JSON. Nothing is validated or reshaped at this door. That is deliberate:
-- if a device on new firmware adds a field, or a brand-new sensor sends a
-- shape we have never seen, it still lands cleanly. Cleaning happens later
-- (03_pipeline_streams_tasks.sql), never at ingest.
-- ---------------------------------------------------------------------
USE SCHEMA RAW;

CREATE OR REPLACE TABLE raw_ingest (
    raw_id       STRING        DEFAULT UUID_STRING(),
    topic        STRING        COMMENT 'MQTT topic, e.g. events/edge-2 or telemetry/edge-1',
    payload      VARIANT       NOT NULL COMMENT 'the device message, verbatim',
    source_file  STRING        COMMENT 'Snowpipe stage file it arrived in',
    loaded_at    TIMESTAMP_TZ  DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Landing zone. Snowpipe auto-loads device payloads here as-is. Schema-on-read absorbs any shape.';

-- =====================================================================
-- EVENTS curated layer
-- =====================================================================
USE SCHEMA EVENTS;

-- ---------------------------------------------------------------------
-- detection_event: one row per detection.
--   * Common fields are typed for cheap, index-friendly analytics.
--   * attributes VARIANT carries the model-specific tail (schema-on-read).
--   * embedding is an L2-normalized vector for cosine similarity search
--     (see docs/07-semantic-search-and-similarity.md).
--   * event_id is client-generatable so retries after a link drop are
--     idempotent (MQTT QoS 1 is at-least-once; we dedupe on event_id).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE detection_event (
    event_id                 STRING            DEFAULT UUID_STRING()
                             COMMENT 'client-generated where possible, for idempotent dedupe',
    device_id                NUMBER            NOT NULL,
    sensor_id                NUMBER            NOT NULL,
    algorithm_id             NUMBER            COMMENT 'which model version produced this',
    event_type               STRING            NOT NULL
                             COMMENT 'person | ppe_violation | fire | motion | ... (extensible)',
    ts                       TIMESTAMP_TZ      NOT NULL COMMENT 'event time at the edge',
    ingested_at              TIMESTAMP_TZ      DEFAULT CURRENT_TIMESTAMP()
                             COMMENT 'cloud arrival time; ingested_at - ts exposes buffering lag',
    confidence               FLOAT             COMMENT 'model score 0..1',
    bounding_box             VARIANT           COMMENT 'normalized {x,y,w,h}',
    attributes               VARIANT           COMMENT 'model-specific tail, e.g. {ppe:{hard_hat:false,vest:true}}',
    media_object_id          STRING            COMMENT 'pointer into media_object for the clip/frame',
    embedding                VECTOR(FLOAT, 512) COMMENT 'L2-normalized event embedding for cosine search',
    embedding_model_version  STRING            COMMENT 'never compare cosine across different versions',
    is_duplicate             BOOLEAN           DEFAULT FALSE
                             COMMENT 'set by near-duplicate suppression; excluded from analytics views'
)
CLUSTER BY (TO_DATE(ts))
COMMENT = 'Every detection. Common fields typed; per-model tail in attributes VARIANT. Clustered on event date for month-window pruning.';

-- ---------------------------------------------------------------------
-- telemetry: generic numeric time series.
-- One shape fits every scalar sensor AND device health. A humidity
-- sensor writes metric='humidity_rh'; a Jetson writes metric='gpu_temp_c'.
-- No column is ever added for a new metric.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE telemetry (
    telemetry_id  STRING        DEFAULT UUID_STRING(),
    device_id     NUMBER        NOT NULL,
    sensor_id     NUMBER        COMMENT 'NULL for device-level health metrics',
    ts            TIMESTAMP_TZ  NOT NULL,
    metric        STRING        NOT NULL
                  COMMENT 'temp_c | humidity_rh | motion_count | cpu_pct | fps | queue_depth | ...',
    value_num     FLOAT         COMMENT 'numeric value (the common case)',
    value_text    STRING        COMMENT 'rare: categorical/status values'
)
CLUSTER BY (TO_DATE(ts))
COMMENT = 'Generic (sensor, metric, value) series. New metrics need zero schema change - the extensibility hinge for telemetry.';

-- ---------------------------------------------------------------------
-- media_object: metadata + pointer for each video clip / frame / thumb.
-- The bytes live in S3 and tier hot (Standard, <=30 days) -> cold
-- (Glacier Deep Archive, all history). This row stays queryable forever
-- and is how the dashboard resolves a signed, short-lived URL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE media_object (
    media_object_id  STRING        DEFAULT UUID_STRING(),
    device_id        NUMBER        NOT NULL,
    sensor_id        NUMBER        NOT NULL,
    kind             STRING        COMMENT 'clip | frame | thumbnail',
    s3_uri           STRING        NOT NULL COMMENT 's3://edgeiot-video/... (bytes live here)',
    ts_start         TIMESTAMP_TZ  NOT NULL,
    ts_end           TIMESTAMP_TZ,
    duration_s       FLOAT,
    bytes            NUMBER,
    storage_tier     STRING        DEFAULT 'hot' COMMENT 'hot (S3 Standard, <=30d) | cold (Glacier Deep Archive)',
    contains_pii     BOOLEAN       DEFAULT TRUE  COMMENT 'camera media is PII by default',
    created_at       TIMESTAMP_TZ  DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (TO_DATE(ts_start))
COMMENT = 'Pointer + metadata for each media artifact. No pixels in Snowflake; the S3 bytes tier to Glacier, this row does not.';

-- ---------------------------------------------------------------------
-- notification_log: one row per alert the cloud actually sent. This closes
-- the loop - it tells us not just that an event happened, but that a human
-- was told, through which channel, and whether delivery succeeded. It also
-- lets us measure the debounce (how many events collapsed into one alert).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE notification_log (
    notification_id  STRING        DEFAULT UUID_STRING(),
    event_id         STRING        NOT NULL COMMENT 'the detection_event that triggered it',
    rule_id          NUMBER        COMMENT 'which notification_rule matched',
    device_id        NUMBER        NOT NULL,
    channel          STRING        COMMENT 'push | email',
    recipient        STRING        COMMENT 'user email / device token target',
    status           STRING        DEFAULT 'sent' COMMENT 'sent | suppressed | failed',
    suppressed_reason STRING       COMMENT 'near_duplicate | quiet_hours | below_confidence | rate_limited',
    sent_at          TIMESTAMP_TZ  DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (TO_DATE(sent_at))
COMMENT = 'Every alert decision (sent/suppressed/failed). Proves notification happened and quantifies debounce.';

-- ---------------------------------------------------------------------
-- Time Travel vs long-term history (resolves F3.3 vs F3.4):
--   * ALL history stays as normal rows in these tables. Snowflake keeps
--     it cheaply (compressed, ~flat $/TB), so "available at any point in
--     time" = query any date; clustering on ts prunes the month window.
--   * Snowflake Time Travel is a RECOVERY feature (undrop / as-of query),
--     not the mechanism for long-term history. Extended Time Travel adds
--     storage cost, so I cap it deliberately rather than lean on it.
-- ---------------------------------------------------------------------
ALTER TABLE detection_event SET DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE telemetry       SET DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE media_object    SET DATA_RETENTION_TIME_IN_DAYS = 7;
