# 03 - Cloud, notifications, and the control plane

**Three flows define the cloud: data **in** (ingest), event to **human** (notification), model **out** to the fleet (control plane).** AWS is the reference implementation; generic mapping is in [`01-architecture.md`](01-architecture.md).

## 1. Ingest: device to cloud

| Aspect | Choice | Why |
|---|---|---|
| Transport | MQTT to AWS IoT Core | Small headers, pub/sub, built-in keep-alive doubling as heartbeat — right fit for constrained, intermittently-connected edge |
| Identity | Per-device **X.509 certificate** (CN = `device.device_uid`) | Not a shared key, so one compromised device is revoked on its own without re-keying the fleet |
| Topics | Split by shape: `telemetry/*`, `events/*`, `state/*` | Different consumers subscribe to different topics — keeps the three-way fan-out clean |
| Delivery | **QoS 1** (at-least-once), dedupe on client-generated `event_id` | Edge retries after a link drop, so duplicates are expected; a duplicate detection event is cheap, a lost one is not |
| Landing | Kinesis Firehose → Snowflake via Snowpipe micro-batch, ~1-2 min freshness | Warehouse is for analysis, not a real-time control loop |

## 2. Notification: event to human

```mermaid
sequenceDiagram
    autonumber
    participant D as Edge device
    participant C as IoT Core (MQTT)
    participant R as IoT Rule
    participant L as Lambda handler
    participant Q as Debounce / dedupe
    participant N as SNS / SES
    participant H as Human (operator)
    D->>C: publish detection_event (QoS 1)
    C->>R: match event topic
    R->>L: invoke with event
    L->>Q: same incident within window? user opted in?
    alt suppressed (near-duplicate or quiet hours)
        Q-->>L: drop / aggregate
    else deliver
        Q-->>L: pass
        L->>N: push + email
        N->>H: alert (target < 5 s from detection)
    end
    Note over D,H: Fire also fires a LOCAL alarm at the edge,<br/>< 1 s, independent of the WAN.
```

- **Routing.** IoT Rule matches a detection event → EventBridge routes → Lambda handler decides and delivers via SNS (push) and SES (email).
- **User-configurable rules.** A dashboard rule table decides *which* events notify *whom* — fire always on, motion quiet-hours-only, PPE violations to the site supervisor. Policy is data, not code.
- **Debounce and aggregate.** Two layers stop a flickering detector sending 400 emails: edge-side near-duplicate suppression ([`07-semantic-search-and-similarity.md`](07-semantic-search-and-similarity.md)) collapses repeats into one incident; the cloud handler rate-limits and rolls up per (device, event_type) within a window. Failure mode is alarm fatigue — users muting the channel meant to keep them safe.
- **Latency budget.** p95 < 5 s end-to-end: edge detect + publish < 1 s, cloud rule + fan-out < 1 s, provider delivery 1-3 s.
- **Life-safety exception.** Fire fires a LOCAL edge alarm < 1 s, independent of the WAN — safety must not depend on the internet.

## 3. Control plane: dashboard to device

**The "push new detection algorithms with a click" requirement — drawn as its own loop because doing it *safely* is the point; a bad model pushed fleet-wide at once is a self-inflicted outage.**

```mermaid
sequenceDiagram
    autonumber
    participant U as Operator (dashboard)
    participant R as Model registry (S3, signed)
    participant J as IoT Jobs (rollout controller)
    participant D as Edge device
    participant DB as algorithm_deployment
    U->>R: upload model artifact + version
    R->>R: sign + record checksum (sha256)
    U->>J: start staged rollout
    J->>DB: record deployment (stage=canary, status=pending)
    J->>D: deploy to canary device
    D->>R: pull artifact
    D->>D: verify checksum, swap model
    alt checksum ok and self-test passes
        D->>J: ack success
        J->>DB: status=active
        J->>D: advance rollout (partial -> fleet)
    else verify fails or health drops
        D->>J: ack failure
        J->>DB: stage=rolled_back
        J->>D: restore previous model
    end
    J-->>U: rollout status (live)
```

- **Versioned, signed artifacts.** Model uploaded to an S3 registry, versioned, signed; `checksum_sha256` recorded in `detection_algorithm`. Device verifies checksum before swap — a corrupted or tampered artifact is never loaded.
- **Staged rollout.** Canary (one device) → partial (a fraction) → fleet, driven by IoT Jobs. Every step written to `algorithm_deployment`, so the schema can always answer "what is running where, and did it roll back?" Satisfies non-negotiable #4: no fleet-wide flash without a canary and a rollback path.
- **Rollback.** If checksum fails or device health drops post-swap, the device restores the previous model, acks failure, and the rollout stops itself.

**Model push vs firmware OTA** — same mechanism, different blast radius:

| | Model push | Firmware OTA |
|---|---|---|
| Frequency | Frequent, app-level | Rare, riskier |
| Worst case | Detects poorly | Bricks a device |
| Guardrails | Standard staged rollout | Smaller canary, longer soak, mandatory health gate before advancing |
