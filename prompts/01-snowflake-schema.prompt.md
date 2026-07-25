# 01 — Snowflake Schema

Inherits `00-system-prompt.md`.

## GOAL

Produce a future-proof Snowflake data model plus the SQL to create it, so that
adding a new sensor type is a data change (a new row) and never a schema migration,
and so that privacy is enforced in the warehouse rather than trusted to callers.

## APPROACH

1. **Split the model by change rate before writing any DDL.** Separate the
   slowly-changing *registry* (tenants, sites, devices, sensors, users, roles,
   model versions) from the high-volume *append-only* streams (detection events,
   telemetry heartbeats, motion signals, media-object pointers). Registry rows are
   mutable and small; stream rows are immutable and large. Keeping them apart is
   what lets each be tuned, retained, and secured differently.
2. **Make a new sensor type a ROW, not a migration — this is the extensibility
   test.** Sensors reference a `sensor_type` registry table. Onboarding a fire
   sensor or an air-quality probe inserts a `sensor_type` row and starts landing
   readings; it changes no table definition. State this test explicitly and show it
   passing with a worked example.
3. **Use `VARIANT` for schema-on-read on the stream tables.** Every device firmware
   version emits a slightly different payload. Land the typed, stable fields as
   columns (device id, timestamp, event type, model version) and keep the variable
   body in a `VARIANT` column. Old-firmware and new-firmware devices both ingest
   without breaking. Show how to project frequently-queried keys out of the VARIANT.
4. **Design hot/cold tiering as metadata, not data movement.** Structured events and
   telemetry are tiny; keep them in Snowflake indefinitely. Video is the expensive
   thing: the `media_object` row (a pointer, size, tier, checksum) stays queryable
   in Snowflake forever while the bytes live in S3 Standard for 30 days then S3
   Glacier Deep Archive. The row records which tier the bytes are in.
5. **Bake privacy into the schema.** Apply a masking policy to PII-bearing columns
   (identity labels, unmasked crops, embeddings tied to a person) so viewers see
   masked values by default and only privileged roles see raw. Add a row access
   policy for tenant isolation (single tenant today, enforced now so multi-tenant
   needs no migration). Log privileged access to camera data in an access-audit
   table the `auditor` role reads.
6. **Model the embedding column now.** One `VECTOR(FLOAT, 512)` per detection event,
   plus `embedding_model_version`, so the semantic-search subsystem (prompt 07) has
   a home and cross-version comparisons are preventable.
7. **Write the DDL last, once the shape is settled**, split across the three SQL
   files so registry, streams, and privacy read independently.

## CONSTRAINTS

- Raw video never enters Snowflake. Only pointers, metadata, and checksums. If a
  column would hold pixels, it is wrong.
- No PII-bearing column ships without a masking policy attached. Masked-by-default,
  unmask by role grant.
- The model must be tenant-scoped even though there is one tenant today.
- Adding a sensor type, a detection class, or a firmware payload field must not
  require `ALTER TABLE` on a stream table.
- Every layer boundary is versioned: keep `firmware_version`, `model_version`, and
  `embedding_model_version` where they belong.
- SQL must be valid Snowflake and must run top-to-bottom in file order.

## OUTPUT SPEC

- `docs/04-snowflake-data-model.md`: prose walkthrough. Sections: registry vs append
  split (with a rationale table), the VARIANT schema-on-read pattern, hot/cold
  tiering of media, privacy (masking policy, row access policy, access audit), the
  worked **extensibility test** (new sensor type as a row), and an entity list keyed
  to the ER diagram. First person, dated where numbers come from the web.
- `sql/01_registry.sql`: tenants, sites, devices, sensor_types, sensors, users,
  roles, model_versions. Slowly-changing, keyed, commented.
- `sql/02_events_telemetry.sql`: detection_events (typed columns + VARIANT + VECTOR),
  telemetry, motion_signals, media_objects (pointer + tier + checksum). Append-only.
- `sql/04_privacy_and_views.sql`: masking policies, row access policy, access-audit
  table, and role-facing views (masked default, privileged unmasked).

## EVAL RUBRIC

- [ ] Registry and append tables are cleanly separated with a stated reason.
- [ ] A new sensor type demonstrably needs only an INSERT, shown with an example.
- [ ] VARIANT is used for the variable payload; typed fields stay columns.
- [ ] Media is a pointer row with a tier field; no pixels in any table.
- [ ] At least one masking policy and one row access policy exist and are attached.
- [ ] An access-audit table exists and a role reads it.
- [ ] The embedding column and its model-version column are present.
- [ ] SQL is valid Snowflake and runs in file order.
- Fails if: any table could hold video; any PII column lacks masking; adding a
  sensor type requires DDL; or tenant scoping is absent.
