-- =====================================================================
-- 04_privacy_and_views.sql  -  Governance, privacy, analytics, extensibility
-- =====================================================================
-- Privacy is the word the customer repeated most, so it is modelled as
-- schema, not written up as a paragraph:
--   * dynamic data masking on PII columns (masked by default),
--   * a row access policy for tenant/site isolation,
--   * an access_audit trail (provable access, not just restricted access).
-- Then: the analytics views, the semantic-search queries, and the
-- "add a humidity sensor" worked example that proves the schema is
-- future-proof.
-- =====================================================================

USE DATABASE EDGEIOT;
CREATE SCHEMA IF NOT EXISTS GOVERNANCE;
CREATE SCHEMA IF NOT EXISTS ANALYTICS;

-- ---------------------------------------------------------------------
-- Roles (created by an admin; illustrative). Privilege tiers referenced
-- by the policies below. See docs/01-architecture.md for the full model.
--   EDGEIOT_ADMIN     - full access incl. user mgmt and unmasked PII
--   EDGEIOT_OPERATOR  - config, push algorithms, view live/clip PII
--   EDGEIOT_VIEWER    - dashboards + telemetry, NO camera PII by default
--   EDGEIOT_AUDITOR   - read + access-audit logs, PII stays masked
-- ---------------------------------------------------------------------

-- =====================================================================
-- 1) DYNAMIC DATA MASKING
-- =====================================================================
USE SCHEMA GOVERNANCE;

-- Hide the S3 pointer to camera media unless the role may see PII.
-- A viewer sees that an event happened, not a link to the footage.
CREATE OR REPLACE MASKING POLICY mask_media_uri AS (uri STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('EDGEIOT_ADMIN', 'EDGEIOT_OPERATOR') THEN uri
        ELSE '***redacted***'
    END;

-- The attributes VARIANT can carry identity hints (e.g. a matched id).
-- Collapse it to a masked marker for non-privileged roles.
CREATE OR REPLACE MASKING POLICY mask_attributes AS (v VARIANT) RETURNS VARIANT ->
    CASE
        WHEN CURRENT_ROLE() IN ('EDGEIOT_ADMIN', 'EDGEIOT_OPERATOR') THEN v
        ELSE OBJECT_CONSTRUCT('masked', TRUE)
    END;

ALTER TABLE EDGEIOT.EVENTS.media_object     MODIFY COLUMN s3_uri     SET MASKING POLICY mask_media_uri;
ALTER TABLE EDGEIOT.EVENTS.detection_event  MODIFY COLUMN attributes SET MASKING POLICY mask_attributes;

-- =====================================================================
-- 2) ROW ACCESS POLICY  -  tenant / site isolation
-- =====================================================================
-- The same query returns different rows per user. One row today, but the
-- policy is live so onboarding a second tenant needs no query rewrite.
CREATE OR REPLACE TABLE role_tenant_entitlement (
    role_name  STRING,
    tenant_id  NUMBER
) COMMENT = 'Maps a Snowflake role to the tenant(s) it may read.';

-- Policy takes device_id (present on the append tables) and resolves the
-- owning tenant through device -> site. Admin sees everything.
CREATE OR REPLACE ROW ACCESS POLICY device_tenant_isolation
    AS (device_id NUMBER) RETURNS BOOLEAN ->
    CURRENT_ROLE() = 'EDGEIOT_ADMIN'
    OR EXISTS (
        SELECT 1
        FROM EDGEIOT.CORE.device d
        JOIN EDGEIOT.CORE.site   s ON s.site_id = d.site_id
        JOIN EDGEIOT.GOVERNANCE.role_tenant_entitlement e ON e.tenant_id = s.tenant_id
        WHERE d.device_id = device_id
          AND e.role_name = CURRENT_ROLE()
    );

ALTER TABLE EDGEIOT.EVENTS.detection_event ADD ROW ACCESS POLICY device_tenant_isolation ON (device_id);
ALTER TABLE EDGEIOT.EVENTS.telemetry       ADD ROW ACCESS POLICY device_tenant_isolation ON (device_id);
ALTER TABLE EDGEIOT.EVENTS.media_object    ADD ROW ACCESS POLICY device_tenant_isolation ON (device_id);
-- Note: the subquery costs a small join per scan. Fine at this scale. If it
-- ever matters, denormalize tenant_id onto the append tables and switch the
-- policy to a direct comparison - same policy shape, cheaper lookup.

-- =====================================================================
-- 3) ACCESS AUDIT  -  privacy-first means provable access
-- =====================================================================
CREATE OR REPLACE TABLE GOVERNANCE.access_audit (
    audit_id         STRING        DEFAULT UUID_STRING(),
    ts               TIMESTAMP_TZ  DEFAULT CURRENT_TIMESTAMP(),
    actor            STRING        COMMENT 'user / role that acted',
    action           STRING        COMMENT 'view_live | view_clip | export | search',
    media_object_id  STRING,
    device_id        NUMBER,
    detail           VARIANT       COMMENT 'e.g. {signed_url_ttl_s:120, query:"..."}'
) COMMENT = 'Who viewed which camera data, when. Every signed-URL issue and every search writes a row here.';

-- =====================================================================
-- 4) ANALYTICS VIEWS
-- =====================================================================
USE SCHEMA ANALYTICS;

-- Daily detection counts per device and type (duplicates excluded).
CREATE OR REPLACE VIEW v_daily_detections AS
SELECT TO_DATE(ts) AS day, device_id, event_type,
       COUNT(*) AS n, AVG(confidence) AS avg_confidence
FROM EDGEIOT.EVENTS.detection_event
WHERE NOT is_duplicate
GROUP BY 1, 2, 3;

-- PPE compliance: violations vs total person events per device per day.
CREATE OR REPLACE VIEW v_ppe_compliance AS
SELECT TO_DATE(ts) AS day, device_id,
       COUNT_IF(event_type = 'ppe_violation')             AS violations,
       COUNT_IF(event_type IN ('person', 'ppe_violation')) AS person_events
FROM EDGEIOT.EVENTS.detection_event
WHERE NOT is_duplicate
GROUP BY 1, 2;

-- Latest value of each health metric per device (for the status panel).
CREATE OR REPLACE VIEW v_device_health AS
SELECT device_id, metric, value_num, ts
FROM EDGEIOT.EVENTS.telemetry
QUALIFY ROW_NUMBER() OVER (PARTITION BY device_id, metric ORDER BY ts DESC) = 1;

-- =====================================================================
-- 5) SEMANTIC SEARCH  (see docs/07 for the math and the why)
-- =====================================================================
-- 5a) Incident search: given a query embedding :q (512-dim, L2-normalized),
--     return the 10 most similar non-duplicate events in the last 30 days.
--     Exact kNN (full scan) is fine at this scale; docs/07 covers the
--     crossover where an ANN index becomes worth it.
--
--   SELECT event_id, device_id, event_type, ts, confidence,
--          VECTOR_COSINE_SIMILARITY(embedding, :q) AS similarity
--   FROM EDGEIOT.EVENTS.detection_event
--   WHERE ts >= DATEADD(day, -30, CURRENT_TIMESTAMP())
--     AND NOT is_duplicate
--     AND embedding IS NOT NULL
--   ORDER BY similarity DESC
--   LIMIT 10;

-- 5b) Near-duplicate audit: consecutive events from the same sensor within
--     10s whose embeddings are near-identical (cosine > 0.97). Suppression
--     runs at ingest; this view lets us verify and tune the threshold.
CREATE OR REPLACE VIEW v_duplicate_candidates AS
WITH ordered AS (
    SELECT event_id, sensor_id, ts, embedding,
           LAG(event_id) OVER (PARTITION BY sensor_id ORDER BY ts) AS prev_event_id,
           LAG(ts)       OVER (PARTITION BY sensor_id ORDER BY ts) AS prev_ts
    FROM EDGEIOT.EVENTS.detection_event
)
SELECT o.event_id,
       o.sensor_id,
       DATEDIFF('second', o.prev_ts, o.ts)                        AS gap_s,
       VECTOR_COSINE_SIMILARITY(o.embedding, p.embedding)         AS sim_to_prev
FROM ordered o
JOIN EDGEIOT.EVENTS.detection_event p ON p.event_id = o.prev_event_id
WHERE DATEDIFF('second', o.prev_ts, o.ts) <= 10;
-- The app marks is_duplicate = TRUE where sim_to_prev > 0.97.

-- =====================================================================
-- 6) EXTENSIBILITY TEST  -  the only test that matters here
-- =====================================================================
-- "A humidity sensor is added to device 2 next year. What changes?"
-- Answer: ONE catalog row + ONE sensor row. Zero DDL. Zero migration.
-- Readings flow into the SAME telemetry table. Existing dashboards that
-- read telemetry by metric pick it up automatically.
-- ---------------------------------------------------------------------
INSERT INTO EDGEIOT.CORE.sensor_type (code, display_name, modality, unit)
VALUES ('humidity', 'Humidity Sensor', 'scalar', 'percent_rh');

INSERT INTO EDGEIOT.CORE.sensor (sensor_uid, device_id, sensor_type_id, label, config)
SELECT 'edge2-humidity-1', d.device_id, st.sensor_type_id, 'bay-humidity',
       OBJECT_CONSTRUCT('sample_interval_s', 60)
FROM EDGEIOT.CORE.device d, EDGEIOT.CORE.sensor_type st
WHERE d.device_uid = 'edge-2' AND st.code = 'humidity';

-- A reading. No new column, no ALTER TABLE - the point of the design.
INSERT INTO EDGEIOT.EVENTS.telemetry (device_id, sensor_id, ts, metric, value_num)
SELECT s.device_id, s.sensor_id, CURRENT_TIMESTAMP(), 'humidity_rh', 54.2
FROM EDGEIOT.CORE.sensor s WHERE s.sensor_uid = 'edge2-humidity-1';
