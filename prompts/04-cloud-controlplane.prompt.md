# 04 — Cloud Control Plane

Inherits `00-system-prompt.md`.

## GOAL

Produce the cloud control-plane design covering device ingest, human notification,
and staged model/OTA rollout, so that devices connect securely, humans are alerted
without being spammed, and pushing new code to the fleet is safe and reversible.

## APPROACH

1. **Design ingest around identity and delivery guarantees first.** Per-device X.509
   certificates for authentication (no shared secrets; a compromised device is
   revoked individually). MQTT with QoS 1 (at-least-once) so nothing is silently
   lost, which forces consumers to dedupe on a message key. State the topic
   structure and how old-firmware and new-firmware payloads both land (VARIANT
   schema-on-read at the warehouse). Name the generic components and their AWS map.
2. **Make notifications humane, not just correct.** A raw detection stream would
   alert-storm a human. Debounce near-duplicate detections within a time window and
   aggregate related detections into a single incident before fan-out. Tie the
   debounce to the near-duplicate suppression in prompt 07 (cosine similarity over
   embeddings) so the two subsystems use one definition of "the same event." Respect
   the end-to-end budget: detect to delivered under 5 s at p95, broken into edge,
   cloud, and provider legs.
3. **Treat model and firmware rollout as the highest-risk operation and stage it.**
   Canary to a single device, then a percentage of the fleet, then the whole fleet,
   with a health gate between stages. Verify every artifact by checksum before a
   device activates it. Keep the previous version on the device so rollback is a
   local switch, not a re-download. Firmware OTA uses the same pipeline with a larger
   blast radius, so its gates are stricter and its canary soak is longer.
4. **Separate the two control loops.** Model/algorithm updates are frequent and
   low-risk relative to firmware; firmware is infrequent and high-risk. Same
   mechanism, different thresholds and approvals. Say which is which and why.
5. **Handle the offline device explicitly.** A device that was offline during a
   rollout must reconcile to the intended version on reconnect via desired-state
   (device shadow), not miss the update. Show that path.

## CONSTRAINTS

- Device auth is per-device X.509; no shared credentials.
- MQTT QoS 1; consumers must dedupe. Say on what key.
- Notifications must debounce and aggregate; a single real event must not produce a
  burst of messages.
- Rollout is always canary, then percentage, then fleet, with checksum verify and a
  working rollback. No direct-to-fleet push exists as an option.
- The detect-to-notify p95 budget is under 5 s, with the breakdown shown.
- Name components generically; provide the AWS mapping alongside.

## OUTPUT SPEC

- `docs/03-cloud-controlplane.md`. Sections: **Ingest** (X.509, MQTT QoS 1, topics,
  dedupe key, versioned payloads), **Notifications** (debounce and aggregation rules,
  the sub-5s budget breakdown, delivery channels), and **Staged rollout / OTA**
  (canary to percentage to fleet, health gates, checksum verify, rollback,
  firmware-vs-model differences, offline reconciliation). First person; reference the
  control-plane and notification-sequence diagrams from prompt 02.

## EVAL RUBRIC

- [ ] Ingest specifies X.509 per device and MQTT QoS 1 with a named dedupe key.
- [ ] Versioned payload handling (old + new firmware) is addressed at ingest.
- [ ] Notifications debounce and aggregate; the anti-storm behavior is concrete.
- [ ] The under-5s p95 budget is broken into edge, cloud, and provider legs.
- [ ] Rollout is staged (canary, percentage, fleet) with a health gate between stages.
- [ ] Checksum verification and a real rollback path are both present.
- [ ] Firmware OTA is distinguished from model push by blast radius and gate strictness.
- [ ] Offline-device reconciliation via desired-state is shown.
- Fails if: any push can go straight to the fleet; rollback is missing; or a single
  detection can produce an alert storm.
