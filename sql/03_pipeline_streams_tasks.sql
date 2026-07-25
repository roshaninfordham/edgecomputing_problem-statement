-- =====================================================================
-- 03_pipeline_streams_tasks.sql  -  The ingestion pipeline (RAW -> curated)
-- =====================================================================
-- In plain English: this file is the conveyor belt. Device messages land
-- in RAW as raw JSON; a "stream" notices the new rows; a "task" runs every
-- minute, cleans and reshapes them, and drops them into the tidy EVENTS
-- tables the dashboard reads. If the belt stops, nothing is lost - the RAW
-- rows just wait. This is what lets the system keep working through spikes
-- and lets a new payload shape arrive without breaking anything downstream.
--
-- Run after 00, 01, 02. Uses WH_LOAD.
-- =====================================================================

USE DATABASE EDGEIOT;

-- ---------------------------------------------------------------------
-- 1) Auto-ingest from S3 with Snowpipe.
--    The edge (or Firehose) writes JSON files to an S3 bucket; Snowpipe
--    loads them into RAW.raw_ingest within a minute or two, serverless,
--    no warehouse required. The IAM role ARN is created in the AWS layer
--    (see docs/08-aws-implementation.md).
-- ---------------------------------------------------------------------
CREATE STORAGE INTEGRATION IF NOT EXISTS edgeiot_s3_int
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<account-id>:role/edgeiot-snowpipe'
    STORAGE_ALLOWED_LOCATIONS = ('s3://edgeiot-ingest/');

CREATE FILE FORMAT IF NOT EXISTS RAW.ff_json TYPE = JSON STRIP_OUTER_ARRAY = TRUE;

CREATE STAGE IF NOT EXISTS RAW.stg_ingest
    URL = 's3://edgeiot-ingest/'
    STORAGE_INTEGRATION = edgeiot_s3_int
    FILE_FORMAT = RAW.ff_json;

CREATE PIPE IF NOT EXISTS RAW.pipe_ingest AUTO_INGEST = TRUE AS
    COPY INTO RAW.raw_ingest (payload, source_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @RAW.stg_ingest);

-- ---------------------------------------------------------------------
-- 2) Streams: one per consumer so each gets its own copy of "what's new".
--    Two consumers (detections, telemetry) => two streams on the same
--    RAW table, each tracking its own offset.
-- ---------------------------------------------------------------------
CREATE OR REPLACE STREAM RAW.strm_detections ON TABLE RAW.raw_ingest;
CREATE OR REPLACE STREAM RAW.strm_telemetry  ON TABLE RAW.raw_ingest;

-- ---------------------------------------------------------------------
-- 3) Tasks: reshape RAW JSON into typed EVENTS rows.
--    Schema-on-read happens HERE, not at ingest - so a new field or a new
--    sensor payload changes this transform, never the landing table.
--    Tasks run only WHEN their stream has data, so an idle system spends
--    nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK EVENTS.tsk_load_detections
    WAREHOUSE = WH_LOAD
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('RAW.strm_detections')
AS
    INSERT INTO EVENTS.detection_event
        (event_id, device_id, sensor_id, algorithm_id, event_type, ts,
         confidence, bounding_box, attributes, media_object_id,
         embedding, embedding_model_version)
    SELECT
        payload:event_id::string,
        payload:device_id::number,
        payload:sensor_id::number,
        payload:algorithm_id::number,
        payload:event_type::string,
        payload:ts::timestamp_tz,
        payload:confidence::float,
        payload:bounding_box,
        payload:attributes,
        payload:media_object_id::string,
        payload:embedding::vector(float, 512),   -- array payload cast to VECTOR
        payload:embedding_model_version::string
    FROM RAW.strm_detections
    WHERE payload:kind::string = 'detection';

CREATE OR REPLACE TASK EVENTS.tsk_load_telemetry
    WAREHOUSE = WH_LOAD
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('RAW.strm_telemetry')
AS
    INSERT INTO EVENTS.telemetry (device_id, sensor_id, ts, metric, value_num, value_text)
    SELECT
        payload:device_id::number,
        payload:sensor_id::number,
        payload:ts::timestamp_tz,
        payload:metric::string,
        payload:value_num::float,
        payload:value_text::string
    FROM RAW.strm_telemetry
    WHERE payload:kind::string = 'telemetry';

-- 3b) Mark near-duplicates just after loading detections (a small task DAG).
--     Same cosine rule as docs/07: consecutive same-sensor events within
--     10s whose embeddings are near-identical are one incident.
CREATE OR REPLACE TASK EVENTS.tsk_mark_duplicates
    WAREHOUSE = WH_LOAD
    AFTER EVENTS.tsk_load_detections
AS
    MERGE INTO EVENTS.detection_event t
    USING (
        WITH ordered AS (
            SELECT event_id, sensor_id, ts, embedding,
                   LAG(event_id) OVER (PARTITION BY sensor_id ORDER BY ts) AS prev_event_id,
                   LAG(ts)       OVER (PARTITION BY sensor_id ORDER BY ts) AS prev_ts
            FROM EVENTS.detection_event
            WHERE ts >= DATEADD(minute, -15, CURRENT_TIMESTAMP())   -- only the fresh tail
        )
        SELECT o.event_id
        FROM ordered o
        JOIN EVENTS.detection_event p ON p.event_id = o.prev_event_id
        WHERE DATEDIFF('second', o.prev_ts, o.ts) <= 10
          AND VECTOR_COSINE_SIMILARITY(o.embedding, p.embedding) > 0.97
    ) d
    ON t.event_id = d.event_id
    WHEN MATCHED THEN UPDATE SET t.is_duplicate = TRUE;

-- Tasks are created suspended. Resume children first, then the root.
ALTER TASK EVENTS.tsk_mark_duplicates RESUME;
ALTER TASK EVENTS.tsk_load_telemetry  RESUME;
ALTER TASK EVENTS.tsk_load_detections RESUME;

-- ---------------------------------------------------------------------
-- 4) Search Optimization: makes the "find this device's fire events"
--    point lookups fast without a full scan, as event volume grows.
-- ---------------------------------------------------------------------
ALTER TABLE EVENTS.detection_event
    ADD SEARCH OPTIMIZATION ON EQUALITY(device_id), EQUALITY(event_type);

-- ---------------------------------------------------------------------
-- 5) Materialized view: keep the daily rollup pre-computed so the
--    dashboard's headline charts are instant and cheap. Snowflake keeps it
--    fresh automatically as new events land.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MATERIALIZED VIEW ANALYTICS.mv_daily_detections AS
SELECT TO_DATE(ts) AS day, device_id, event_type, COUNT(*) AS n
FROM EVENTS.detection_event
WHERE NOT is_duplicate
GROUP BY 1, 2, 3;
