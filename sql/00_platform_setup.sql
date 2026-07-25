-- =====================================================================
-- 00_platform_setup.sql  -  Account setup: layers, warehouses, cost caps, roles
-- =====================================================================
-- In plain English: before any table exists, I set up the "building" the
-- data lives in - the rooms (schemas), the engines that run queries
-- (warehouses), a hard spending cap (resource monitors), and who is
-- allowed in (roles). Getting this right up front is what makes the whole
-- thing safe to hand to a small team.
--
-- Run this file first. Requires a role that can create warehouses, roles,
-- and resource monitors (ACCOUNTADMIN or a delegated admin).
-- =====================================================================

CREATE DATABASE IF NOT EXISTS EDGEIOT;
USE DATABASE EDGEIOT;

-- ---------------------------------------------------------------------
-- Layered schemas (a "medallion" layout). Data flows left to right and
-- gets cleaner at each step. The point: the messy outside world only ever
-- touches RAW, so a new sensor or a new model can never break the tables
-- the dashboard depends on.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS RAW        COMMENT = 'Landing zone. Snowpipe writes device payloads here as-is (VARIANT). Absorbs any shape.';
CREATE SCHEMA IF NOT EXISTS CORE       COMMENT = 'Registry: slowly-changing identity - tenant, site, device, sensor, models, users, rules.';
CREATE SCHEMA IF NOT EXISTS EVENTS     COMMENT = 'Curated high-volume append: detection events, telemetry, media pointers, notifications.';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE COMMENT = 'Access policies, entitlements, and the access audit trail.';
CREATE SCHEMA IF NOT EXISTS ANALYTICS  COMMENT = 'Views and materialized views the dashboard and BI tools read.';

-- ---------------------------------------------------------------------
-- Virtual warehouses. Each workload gets its own engine so a heavy report
-- can never slow down data loading, and each one suspends when idle so we
-- only pay while it is actually working.
--
-- In plain English: three separate "engines", each turns itself off after
-- 60 seconds of no work. That auto-suspend is the single biggest cost
-- control in the whole design.
-- ---------------------------------------------------------------------
CREATE OR REPLACE WAREHOUSE WH_LOAD WITH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Ingestion: Snowpipe + Tasks that transform RAW into CORE/EVENTS.';

CREATE OR REPLACE WAREHOUSE WH_BI WITH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dashboard + analytics queries. Bursts to SMALL under concurrency (see docs/05).';

CREATE OR REPLACE WAREHOUSE WH_VECTOR WITH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'On-demand heavy cosine search / clustering jobs, kept off the BI engine.';

-- ---------------------------------------------------------------------
-- Resource monitors: a hard credit ceiling so a runaway query or a
-- warehouse left running can never produce a surprise bill. This is the
-- guard for the top cost risk called out in docs/05-cost-estimate.md.
-- ---------------------------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR rm_account WITH
    CREDIT_QUOTA = 200                 -- ~monthly budget in credits; tune to the plan
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80  PERCENT DO NOTIFY          -- warn early
        ON 100 PERCENT DO SUSPEND         -- stop new statements, let running ones finish
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;  -- hard stop
ALTER ACCOUNT SET RESOURCE_MONITOR = rm_account;

-- Per-warehouse monitor so one workload cannot burn the whole budget.
CREATE OR REPLACE RESOURCE MONITOR rm_bi WITH
    CREDIT_QUOTA = 120 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 90 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE WH_BI SET RESOURCE_MONITOR = rm_bi;

-- ---------------------------------------------------------------------
-- Roles. Business roles map to what a person does; functional roles map to
-- what a system does. Least privilege: the loader cannot read camera PII,
-- a viewer cannot write, and only admin manages users.
-- ---------------------------------------------------------------------
-- Business roles (people)
CREATE ROLE IF NOT EXISTS EDGEIOT_ADMIN    COMMENT = 'Full access incl. user management and unmasked PII.';
CREATE ROLE IF NOT EXISTS EDGEIOT_OPERATOR COMMENT = 'Config, push algorithms, view live/clip footage.';
CREATE ROLE IF NOT EXISTS EDGEIOT_VIEWER   COMMENT = 'Dashboards + telemetry. No camera PII by default.';
CREATE ROLE IF NOT EXISTS EDGEIOT_AUDITOR  COMMENT = 'Read + access-audit logs. PII stays masked.';
-- Functional roles (systems)
CREATE ROLE IF NOT EXISTS EDGEIOT_LOADER   COMMENT = 'Snowpipe + Tasks. Writes RAW->CORE/EVENTS. No PII read.';
CREATE ROLE IF NOT EXISTS EDGEIOT_ANALYST  COMMENT = 'BI/modelling read access over ANALYTICS + masked EVENTS.';

-- Warehouse usage grants (who may run which engine)
GRANT USAGE ON WAREHOUSE WH_LOAD   TO ROLE EDGEIOT_LOADER;
GRANT USAGE ON WAREHOUSE WH_BI     TO ROLE EDGEIOT_OPERATOR;
GRANT USAGE ON WAREHOUSE WH_BI     TO ROLE EDGEIOT_VIEWER;
GRANT USAGE ON WAREHOUSE WH_BI     TO ROLE EDGEIOT_ANALYST;
GRANT USAGE ON WAREHOUSE WH_BI     TO ROLE EDGEIOT_AUDITOR;
GRANT USAGE ON WAREHOUSE WH_VECTOR TO ROLE EDGEIOT_ANALYST;
GRANT USAGE ON WAREHOUSE WH_VECTOR TO ROLE EDGEIOT_OPERATOR;

-- Schema visibility (object-level grants on tables are added alongside the
-- tables in later files; this establishes the baseline).
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_ADMIN;
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_OPERATOR;
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_VIEWER;
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_AUDITOR;
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_LOADER;
GRANT USAGE ON DATABASE EDGEIOT TO ROLE EDGEIOT_ANALYST;
