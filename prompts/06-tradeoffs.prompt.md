# 06 — Trade-offs and Failure Modes

Inherits `00-system-prompt.md`.

## GOAL

Produce an honest account of the trade-offs, failure modes, and named limitations of
this design, so a reviewer sees that I chose deliberately and know exactly where the
system breaks, rather than pretending it is bulletproof.

## APPROACH

1. **Lead with the internet-drops story, end to end.** Walk a WAN outage as a
   narrative: the link goes down, the edge keeps detecting locally, life-safety
   alarms (fire) fire locally in under a second independent of the WAN, events queue
   in a bounded store-and-forward buffer that survives 24 to 72 hours, telemetry is
   dropped last-value-wins because stale health is worthless, and on reconnect events
   replay durably and in order while consumers dedupe on QoS 1. Then state what still
   breaks: a buffer overrun past the window, and the dashboard going stale for
   operators. Name those, do not hide them.
2. **Justify each major service choice against its alternatives in a table.** For
   each significant decision (managed IoT hub vs self-hosted broker, Snowflake vs a
   time-series DB, S3 tiering vs keeping everything hot, MQTT QoS 1 vs QoS 2, exact
   kNN vs ANN today), give the chosen option, the main alternative, why I chose what
   I chose, and what I gave up. The point is to show the trade was made on purpose.
3. **Enumerate failure modes per layer and the mitigation.** Edge (device down,
   thermal throttle, camera blinded), connectivity (WAN outage, broker unavailable),
   cloud (region outage, ingest backpressure, hot-partition), warehouse (query cost
   runaway), and control plane (bad model reaches fleet). For each, the detection
   signal and the response. Where the response is "accept it," say so.
4. **Name the limitations plainly.** Single region us-east-1, so a regional outage
   takes the cloud down while the edge survives and buffers. Single tenant today.
   No cross-site failover. Exact kNN only up to roughly a million vectors. State each
   as a conscious scope decision with the condition that would make me revisit it.
5. **Distinguish "won't fix now" from "can't fix."** Some limits are deliberate scope
   cuts for a first deployment (DR, multi-tenant); others are physics (WAN latency,
   thermal ceilings). Label which is which so the reviewer knows what a quarter of
   work would move and what it would not.

## CONSTRAINTS

- The internet-drops story must show life-safety local alarms staying under 1 s and
  independent of the WAN, and must name what still degrades.
- Every service-choice row names the alternative and what was given up. No choice is
  presented as having had no alternative.
- Limitations are stated as owned decisions with a revisit trigger, not buried.
- No hand-waving: if the answer is "we accept this risk," say exactly that.
- First person. Confident about the choices, honest about the gaps.

## OUTPUT SPEC

- `docs/06-tradeoffs-failure-modes.md`. Sections: **Internet-drops walkthrough**
  (narrative plus what still breaks), **Service-choice justification table** (chosen,
  alternative, why, what was given up), **Failure modes by layer** (signal and
  response per mode), and **Named limitations** (each with a revisit trigger and a
  won't-fix vs can't-fix label). First person.

## EVAL RUBRIC

- [ ] The internet-drops walkthrough is end to end and names what still degrades.
- [ ] Life-safety local alarm under 1 s, WAN-independent, is explicit.
- [ ] The store-and-forward buffer window and telemetry last-value-wins are stated.
- [ ] The service-choice table has chosen, alternative, rationale, and cost-of-choice.
- [ ] Failure modes are enumerated per layer with a detection signal and a response.
- [ ] Limitations (single region, single tenant, exact-kNN ceiling) are named with triggers.
- [ ] Won't-fix vs can't-fix is distinguished.
- Fails if: any service choice is presented without an alternative; the failure
  analysis is all mitigation and no accepted risk; or limitations are omitted.
