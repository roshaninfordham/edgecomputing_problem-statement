# 02 — Architecture Diagrams

Inherits `00-system-prompt.md`.

## GOAL

Produce a set of Mermaid diagrams that let a reviewer understand the whole system on
one page and then trace any single flow (ingest, control loop, offline buffer,
notification) without reading prose, so the architecture is legible before the words.

## APPROACH

1. **Draw the five layers as stable interfaces first.** Edge, connectivity, cloud
   ingest, storage/warehouse, and application/dashboard. Fix the contract between
   each pair (what crosses the boundary: MQTT messages, S3 URIs, warehouse rows,
   dashboard APIs) before drawing internals. The boundaries are the design; the boxes
   inside them can change without breaking neighbors.
2. **Keep the diagrams generic, then map to AWS separately.** Boxes are named by role
   (IoT hub, rules/routing, stream-to-warehouse, object store, notifications, device
   registry, model/OTA distribution, auth). Provide the AWS mapping as a table in the
   accompanying doc, not baked into the box labels, so the design reads on any cloud.
3. **Give each concern its own diagram at the right altitude.** One system-on-a-page
   overview; one dataflow spine (detection to warehouse); one cloud-ingest detail;
   one control-plane loop (dashboard to device); one data-lifecycle (hot S3 to
   Glacier, metadata forever in Snowflake); one ER diagram matching the schema; and
   sequence diagrams for the flows where timing and ordering matter.
4. **Make the non-negotiables visible in the pictures.** Video path terminates at S3,
   never at Snowflake. The edge has a local-detection and buffer path that does not
   depend on the WAN. The control plane shows staged rollout (canary, percentage,
   fleet). Show these, do not just assert them in text.
5. **Use sequence diagrams for the two flows a reviewer will poke:** notification
   end to end (detect, publish, rule, fan-out, deliver, with the sub-5s p95 budget
   annotated) and offline buffer (link drop, local store-and-forward, ordered
   durable replay on reconnect, telemetry last-value-wins).
6. **Keep the ER diagram in lockstep with the SQL** from prompt 01 so the picture and
   the DDL never diverge.

## CONSTRAINTS

- All diagrams are valid Mermaid and render without edits.
- Box labels are role-generic; the AWS mapping lives in a table in the doc.
- Layer boundaries are explicit and versioned; a reader can point to where firmware,
  model, and schema versions cross.
- The video path must visibly terminate at object storage, not the warehouse.
- No emojis in labels. Keep labels short enough to render cleanly.

## OUTPUT SPEC

- `diagrams/01-system-on-a-page.mmd` — five layers and their interfaces.
- `diagrams/02-dataflow-spine.mmd` — detection to warehouse, plus the video branch.
- `diagrams/03-cloud-ingest.mmd` — MQTT, rules/routing, stream-to-warehouse, storage.
- `diagrams/04-control-plane-loop.mmd` — dashboard to device: config and staged
  model/OTA push with rollback.
- `diagrams/05-data-lifecycle.mmd` — hot S3, Glacier archive, Snowflake metadata forever.
- `diagrams/06-snowflake-er.mmd` — entities and relationships matching the SQL.
- `diagrams/07-notification-sequence.mmd` — detect to delivery with latency budget.
- `diagrams/08-offline-buffer-sequence.mmd` — link drop, buffer, ordered replay.
- `diagrams/09-embedding-pipeline.mmd` — edge backbone to VECTOR column (shared with 07).
- `docs/01-architecture.md` — the five layers in prose, the dataflow spine, and the
  generic-to-AWS mapping table. First person; embeds or references each diagram.

## EVAL RUBRIC

- [ ] Every `.mmd` file renders as valid Mermaid with no manual fixing.
- [ ] The overview shows five layers with named interfaces between them.
- [ ] The video path ends at object storage in every diagram it appears in.
- [ ] A local-detection/offline path exists that does not touch the WAN.
- [ ] Staged rollout (canary, percentage, fleet) with rollback appears in the control loop.
- [ ] The ER diagram matches the entities in `sql/`.
- [ ] Both sequence diagrams exist; the notification one is annotated with the latency budget.
- [ ] The AWS mapping is a table in the doc, not baked into diagram labels.
- Fails if: any diagram routes video into Snowflake; boxes are AWS-specific; or the
  ER diagram and SQL disagree.
