-- =====================================================================
-- 01_registry.sql  -  The slowly-changing spine
-- =====================================================================
-- Design principle: separate the things that RARELY change (device and
-- sensor identity, model catalog) from the things that CONSTANTLY append
-- (readings, events). This file is the registry: small, stable, referenced
-- by everything downstream.
--
-- Snowflake note: PRIMARY KEY / FOREIGN KEY / UNIQUE are declarative here.
-- Snowflake enforces NOT NULL, but treats key constraints as metadata used
-- for modelling intent, the optimizer, and BI tools. I still declare them
-- because they document the model and travel with the schema.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS EDGEIOT;
USE DATABASE EDGEIOT;

CREATE SCHEMA IF NOT EXISTS CORE;
USE SCHEMA CORE;

-- ---------------------------------------------------------------------
-- tenant: who owns the data.
-- One row today. I model it now so that multi-tenant later is a data
-- change, not a migration. Retrofitting tenant isolation onto a
-- single-tenant schema is one of the more expensive things you can be
-- asked to do; adding an unused column today is free.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE tenant (
    tenant_id    NUMBER        AUTOINCREMENT PRIMARY KEY,
    tenant_uid   STRING        NOT NULL UNIQUE DEFAULT UUID_STRING(),
    name         STRING        NOT NULL,
    created_at   TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Owning customer. One row now; modelled so multi-tenant later needs no migration.';

-- ---------------------------------------------------------------------
-- site: a physical location belonging to a tenant.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE site (
    site_id      NUMBER        AUTOINCREMENT PRIMARY KEY,
    tenant_id    NUMBER        NOT NULL REFERENCES tenant(tenant_id),
    name         STRING        NOT NULL,
    timezone     STRING        COMMENT 'IANA tz, e.g. America/New_York',
    latitude     FLOAT,
    longitude    FLOAT,
    created_at   TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'A physical location. A tenant may have many sites.';

-- ---------------------------------------------------------------------
-- device: an edge device (Jetson, Pi, ...).
-- hardware_model and firmware_version are the reason a HETEROGENEOUS
-- fleet costs nothing here: the difference between device 1 (Jetson,
-- 3 cameras) and device 2 (Pi + Coral, 1 camera + 2 motion) is a data
-- value, not a schema branch.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE device (
    device_id         NUMBER        AUTOINCREMENT PRIMARY KEY,
    device_uid        STRING        NOT NULL UNIQUE
                      COMMENT 'Matches the X.509 cert CN / IoT thing name used at the edge.',
    site_id           NUMBER        NOT NULL REFERENCES site(site_id),
    hardware_model    STRING        COMMENT 'e.g. nvidia-jetson-orin-nano, raspberry-pi-5+coral',
    firmware_version  STRING        COMMENT 'Current firmware. The fleet is heterogeneous by design.',
    status            STRING        DEFAULT 'provisioned'
                      COMMENT 'provisioned | online | offline | retired',
    registered_at     TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    last_seen_at      TIMESTAMP_TZ  COMMENT 'Updated from the device heartbeat / shadow.'
) COMMENT = 'An edge device. hardware_model + firmware_version make heterogeneity a value, not a branch.';

-- ---------------------------------------------------------------------
-- sensor_type: THE CATALOG. This is the future-proof hinge.
-- Adding a brand-new kind of sensor (humidity, air quality, LiDAR) is
-- ONE insert here. See the worked example in 04_privacy_and_views.sql.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE sensor_type (
    sensor_type_id  NUMBER        AUTOINCREMENT PRIMARY KEY,
    code            STRING        NOT NULL UNIQUE
                    COMMENT 'stable machine code: camera, motion, humidity, temperature, ...',
    display_name    STRING        NOT NULL,
    modality        STRING        COMMENT 'vision | binary | scalar',
    unit            STRING        COMMENT 'percent_rh, celsius, boolean, NULL for camera',
    created_at      TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Catalog of sensor kinds. A new sensor type next year is one row here + one sensor row. Zero DDL.';

-- ---------------------------------------------------------------------
-- sensor: a specific physical sensor instance on a device.
-- config VARIANT holds per-type settings (resolution/fps for a camera,
-- sensitivity for a motion sensor) so we never add a column per type.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE sensor (
    sensor_id       NUMBER        AUTOINCREMENT PRIMARY KEY,
    sensor_uid      STRING        NOT NULL UNIQUE,
    device_id       NUMBER        NOT NULL REFERENCES device(device_id),
    sensor_type_id  NUMBER        NOT NULL REFERENCES sensor_type(sensor_type_id),
    label           STRING        COMMENT 'human label, e.g. north-dock-cam, entry-motion-1',
    config          VARIANT       COMMENT 'per-type config as JSON (schema-on-read)',
    installed_at    TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    is_active       BOOLEAN       DEFAULT TRUE
) COMMENT = 'A physical sensor instance. config VARIANT absorbs per-type settings without new columns.';

-- ---------------------------------------------------------------------
-- detection_algorithm: a versioned model artifact that runs on the edge.
-- This is the thing the dashboard pushes to devices.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE detection_algorithm (
    algorithm_id     NUMBER        AUTOINCREMENT PRIMARY KEY,
    name             STRING        NOT NULL COMMENT 'e.g. person-ppe-yolov8s',
    version          STRING        NOT NULL COMMENT 'semver, e.g. 1.4.0',
    task             STRING        COMMENT 'person_detection | ppe_detection | fire_detection | ...',
    artifact_uri     STRING        COMMENT 's3://edgeiot-models/person-ppe-yolov8s/1.4.0.trt',
    checksum_sha256  STRING        COMMENT 'verified on-device before the model swap',
    embedding_dim    NUMBER        COMMENT '512 if this model also emits event embeddings',
    created_at       TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    UNIQUE (name, version)
) COMMENT = 'A versioned detection model. What the web dashboard pushes down to the fleet.';

-- ---------------------------------------------------------------------
-- algorithm_deployment: which algorithm runs on which device, and the
-- staged-rollout state. This records the control-plane push so the
-- schema can answer "what is running where, and did it roll back?".
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE algorithm_deployment (
    deployment_id    NUMBER        AUTOINCREMENT PRIMARY KEY,
    algorithm_id     NUMBER        NOT NULL REFERENCES detection_algorithm(algorithm_id),
    device_id        NUMBER        NOT NULL REFERENCES device(device_id),
    rollout_stage    STRING        DEFAULT 'canary'
                     COMMENT 'canary | partial | fleet | rolled_back',
    status           STRING        DEFAULT 'pending'
                     COMMENT 'pending | active | failed | superseded',
    deployed_at      TIMESTAMP_TZ,
    acknowledged_at  TIMESTAMP_TZ  COMMENT 'device confirmed checksum + swap',
    deployed_by      STRING        COMMENT 'user who initiated the push (audit trail)'
) COMMENT = 'Records staged model rollout per device. Supports canary -> partial -> fleet and rollback.';

-- ---------------------------------------------------------------------
-- app_user: the ~10 people who use the dashboard. role drives what they
-- can see and do; it maps to a Snowflake role and a Cognito group so the
-- same identity governs both the warehouse policies and the web app.
-- (See docs/09-user-experience.md for the permission matrix.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE app_user (
    user_id       NUMBER        AUTOINCREMENT PRIMARY KEY,
    tenant_id     NUMBER        NOT NULL REFERENCES tenant(tenant_id),
    email         STRING        NOT NULL UNIQUE,
    display_name  STRING,
    role          STRING        NOT NULL COMMENT 'admin | operator | viewer | auditor',
    is_active     BOOLEAN       DEFAULT TRUE,
    created_at    TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Dashboard users. role governs privacy-first access; maps to a Snowflake role and Cognito group.';

-- ---------------------------------------------------------------------
-- notification_rule: user-configurable alerting. This is what the
-- dashboard writes when someone sets "fire = always page me, motion =
-- quiet hours only". Notification policy is data, not code, so changing
-- it never needs a deploy.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE notification_rule (
    rule_id        NUMBER        AUTOINCREMENT PRIMARY KEY,
    tenant_id      NUMBER        NOT NULL REFERENCES tenant(tenant_id),
    user_id        NUMBER        REFERENCES app_user(user_id) COMMENT 'NULL = applies to all users in tenant',
    event_type     STRING        NOT NULL COMMENT 'person | ppe_violation | fire | motion | * (any)',
    device_id      NUMBER        REFERENCES device(device_id) COMMENT 'NULL = any device',
    min_confidence FLOAT         DEFAULT 0.5 COMMENT 'suppress below this score',
    channel        STRING        DEFAULT 'push' COMMENT 'push | email | both',
    quiet_hours    VARIANT       COMMENT 'optional {tz, start, end} to mute non-critical alerts',
    is_active      BOOLEAN       DEFAULT TRUE,
    created_at     TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Per-user / per-tenant alerting rules. Drives the cloud notification handler; fire is never silenced.';

-- ---------------------------------------------------------------------
-- Seed the current deployment so the model is not abstract.
-- ---------------------------------------------------------------------
INSERT INTO tenant (name) VALUES ('Primary Tenant (single tenant)');

INSERT INTO site (tenant_id, name, timezone)
SELECT tenant_id, 'Primary Site', 'America/New_York' FROM tenant WHERE name = 'Primary Tenant (single tenant)';

INSERT INTO device (device_uid, site_id, hardware_model, firmware_version, status)
SELECT 'edge-1', site_id, 'nvidia-jetson-orin-nano', '1.0.0', 'online' FROM site WHERE name = 'Primary Site'
UNION ALL
SELECT 'edge-2', site_id, 'raspberry-pi-5+coral',   '1.0.0', 'online' FROM site WHERE name = 'Primary Site';

INSERT INTO sensor_type (code, display_name, modality, unit) VALUES
    ('camera', 'Camera',        'vision', NULL),
    ('motion', 'Motion Sensor', 'binary', 'boolean');

-- edge-1: 3 cameras ; edge-2: 1 camera + 2 motion sensors
INSERT INTO sensor (sensor_uid, device_id, sensor_type_id, label, config)
SELECT 'edge1-cam-1', d.device_id, st.sensor_type_id, 'cam-1', OBJECT_CONSTRUCT('res','1080p','fps',15)
FROM device d, sensor_type st WHERE d.device_uid='edge-1' AND st.code='camera'
UNION ALL SELECT 'edge1-cam-2', d.device_id, st.sensor_type_id, 'cam-2', OBJECT_CONSTRUCT('res','1080p','fps',15)
FROM device d, sensor_type st WHERE d.device_uid='edge-1' AND st.code='camera'
UNION ALL SELECT 'edge1-cam-3', d.device_id, st.sensor_type_id, 'cam-3', OBJECT_CONSTRUCT('res','1080p','fps',15)
FROM device d, sensor_type st WHERE d.device_uid='edge-1' AND st.code='camera'
UNION ALL SELECT 'edge2-cam-1', d.device_id, st.sensor_type_id, 'cam-1', OBJECT_CONSTRUCT('res','720p','fps',10)
FROM device d, sensor_type st WHERE d.device_uid='edge-2' AND st.code='camera'
UNION ALL SELECT 'edge2-motion-1', d.device_id, st.sensor_type_id, 'motion-1', OBJECT_CONSTRUCT('sensitivity','high')
FROM device d, sensor_type st WHERE d.device_uid='edge-2' AND st.code='motion'
UNION ALL SELECT 'edge2-motion-2', d.device_id, st.sensor_type_id, 'motion-2', OBJECT_CONSTRUCT('sensitivity','high')
FROM device d, sensor_type st WHERE d.device_uid='edge-2' AND st.code='motion';

-- A few of the ~10 dashboard users, one per role, to make the access model concrete.
INSERT INTO app_user (tenant_id, email, display_name, role)
SELECT t.tenant_id, x.email, x.display_name, x.role
FROM tenant t,
     (SELECT 'admin@example.com'    AS email, 'Site Admin'    AS display_name, 'admin'    AS role
      UNION ALL SELECT 'ops@example.com',     'Shift Operator',  'operator'
      UNION ALL SELECT 'viewer@example.com',  'Ops Viewer',      'viewer'
      UNION ALL SELECT 'audit@example.com',   'Compliance',      'auditor') x
WHERE t.name = 'Primary Tenant (single tenant)';

-- Default rule: fire always pages everyone in the tenant; PPE violations email the operator.
INSERT INTO notification_rule (tenant_id, user_id, event_type, min_confidence, channel)
SELECT t.tenant_id, NULL, 'fire', 0.30, 'both' FROM tenant t WHERE t.name = 'Primary Tenant (single tenant)'
UNION ALL
SELECT t.tenant_id, u.user_id, 'ppe_violation', 0.60, 'email'
FROM tenant t JOIN app_user u ON u.tenant_id = t.tenant_id AND u.role = 'operator'
WHERE t.name = 'Primary Tenant (single tenant)';
