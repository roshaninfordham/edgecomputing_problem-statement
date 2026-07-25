# 08 - AWS implementation, reference deployment, and operations

The "if a team had to build this on Monday, here is how" document - the concrete AWS wiring under the rest of the repo. Reasoning lives elsewhere:

- Architecture: [`01-architecture.md`](01-architecture.md); control plane: [`03-cloud-controlplane.md`](03-cloud-controlplane.md); data model: [`04-snowflake-data-model.md`](04-snowflake-data-model.md); cost: [`05-cost-estimate.md`](05-cost-estimate.md); failure list: [`06-tradeoffs-failure-modes.md`](06-tradeoffs-failure-modes.md).
- Diagrams: service map [`diagrams/11-aws-reference-architecture.mmd`](../diagrams/11-aws-reference-architecture.mmd); deploy/CI-CD flow [`diagrams/13-deployment-cicd.mmd`](../diagrams/13-deployment-cicd.mmd).

## In plain English

**A small, managed IoT platform in one AWS region - almost all serverless, nothing to patch.**

- Field devices talk to a managed MQTT broker; events fan out to tiny functions that notify people, drop video into cheap object storage, and stream structured data into Snowflake.
- A static-site dashboard lets ten users watch device health, review clips under privacy controls, and push detection models with a click.
- Managed and per-use billed, so at today's two-device scale it is cheap to run.

## The AWS service map, and why each one

**Every moving part, grouped by plane: the service, why it, the self-hosted alternative, and what flips the choice.**

Two resilience services cut across these planes (depth in
[`10-production-engineering.md`](10-production-engineering.md)):

- **SQS + dead-letter queue** in front of the notification and object-processing handlers: bounded retries, then a poison message lands in the DLQ for replay instead of blocking or vanishing.
- **AWS WAF** in front of CloudFront and API Gateway: rate rules plus API Gateway usage-plan throttling. That doc also consolidates rate limiting, queues, concurrency, idempotency, algorithms, and the threat model.

### Edge / device plane

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Device connectivity + identity | AWS IoT Core | Managed MQTT broker with per-device X.509 identity and a device registry; nothing to run for a 2-device fleet | Mosquitto / EMQX broker on a VM | A hard "no specific cloud" requirement, or a fleet large enough that self-hosted broker economics beat the managed premium |
| Fleet security posture | AWS IoT Device Defender | Continuously audits device certs, policies, and behavior and flags anomalies (a device suddenly publishing 100x) without us writing the detector | A SIEM plus custom MQTT audit rules | Only if we outgrew its rule set or needed detections it cannot express |
| Last-known device state | AWS IoT Device Shadow | A durable JSON "desired vs reported" state per device the dashboard reads without waking the device | A Postgres/Redis state table updated by the ingest handler | Needing richer state history or query patterns a key-value shadow cannot serve |
| Optional edge runtime/agent | AWS IoT Greengrass | Optional: gives the device a managed local runtime for the OTA agent, local Lambda, and offline logic if we standardize the fleet on it | A hand-rolled systemd agent that pulls signed artifacts | We keep it optional because the Jetson and the Pi+Coral run their own inference stacks today; we adopt it only if we want AWS-managed local compute across a growing fleet |

### Ingest plane

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Stream buffer to warehouse | Kinesis Data Firehose | Buffers ingest spikes and batches records to the S3 stage so the warehouse loads efficiently, not per-message | Kafka + a sink connector | Needing sub-second load latency below what the Firehose + Snowpipe micro-batch gives |
| Event handler compute | AWS Lambda | Traffic is spiky and low-volume; per-request billing is near-free and there is no server to run | Containers on ECS Fargate or a VM | Sustained high throughput, long-lived state, or a handler needing >15 min runtime |
| Routing + schedules | Amazon EventBridge | Decouples "an event happened" from "who reacts": IoT Rules and EventBridge route events to handlers and run scheduled jobs (e.g. daily rollups) | A Kafka topic + consumer, plus cron | Needing routing logic or ordering guarantees a bus does not give |
| Warehouse auto-ingest | Snowflake Snowpipe | Snowflake-native auto-ingest: it watches the S3 stage and micro-batches new files into the RAW schema, giving ~1-2 min freshness | A custom loader polling S3 and issuing COPY | Needing streaming ingest below micro-batch latency (Snowpipe Streaming) |

### Notification plane

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Push notifications | Amazon SNS | Already in the stack, cheap, fans out mobile/web push to operators on a detection | A queue + a push gateway | Needing rich delivery analytics or channels SNS does not carry |
| Email | Amazon SES | Cheap transactional email for alerts and digests; ~$0.10 per 1,000 | A queue + a mailer (Postfix / a provider) | Needing high-touch deliverability, templating, or marketing-grade tooling |

### Control plane / OTA

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Staged OTA / model rollout | AWS IoT Jobs | Native staged rollout controller: target a canary, then a fraction, then the fleet, with per-device ack and rollback recorded to the schema | A signed-artifact CDN + a custom rollout agent | Needing rollout logic (traffic-shaping, complex gates) IoT Jobs cannot express |
| Rollout orchestration | AWS Step Functions (optional) | Optional: if the canary-to-fleet promotion needs multi-step gates (soak, health check, approval) it is cleaner as an explicit state machine than as Lambda glue | A workflow engine or hand-coded state in DynamoDB | We add it only when the promotion logic outgrows a single handler; a simple rollout does not need it |

### Storage plane

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Video + model artifacts + Snowpipe stage | Amazon S3 | Cheap, durable object store; holds raw clips, signed model artifacts, and the Firehose landing stage. Raw video never enters Snowflake by design | MinIO or any blob store | A hard cost/latency requirement object storage cannot meet |
| Hot-to-cold tiering | S3 lifecycle policies | Automatically ages clips from S3 Standard (30 days hot) to Glacier Deep Archive (all history) - roughly a 20x storage saving on cold video, enforced as config not cron | A cron job moving objects between tiers | Needing instant retrieval of old video (then keep more in Standard, and pay for it) |
| Device state / config | Amazon DynamoDB | Key-value store for per-device config and shadow-backed state the dashboard reads at single-digit-ms latency | Postgres + a state table | Needing relational queries or transactions across many keys |

### Dashboard / API plane

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Dashboard auth (the 10 users) | Amazon Cognito | Managed user pool with the four roles; first 10k monthly users free, so our 10 cost nothing | Keycloak or Auth0 | Needing an identity feature Cognito lacks, or an existing corporate IdP we must federate deeply with |
| Dashboard backend API | API Gateway + Lambda (or ECS Fargate) | API Gateway fronts the private backend and enforces Cognito auth at the edge; Lambda behind it is near-free at this traffic. Fargate is the fallback if the API needs long-lived connections | ALB + containers | WebSocket-heavy or long-lived server-side sessions push us from Lambda to Fargate |
| Dashboard SPA hosting | CloudFront + S3 | Static single-page app served from S3 behind a CloudFront CDN: cheap, fast, no web server, TLS terminated at the edge | Nginx on a VM, or any static host | Needing server-side rendering at scale |

### Security spine (cuts across every plane)

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Secrets and credentials | AWS Secrets Manager | Central store for the Snowflake service credential, SES/API keys, and rotation, so nothing sits in code or env files | HashiCorp Vault | Wanting a single multi-cloud secrets plane (then Vault) |
| Encryption keys | AWS KMS | Customer-managed keys for S3 at-rest encryption, DynamoDB, and the signing/short-lived-URL path for privacy-controlled video access | Vault Transit / an HSM | A compliance requirement for a specific key custody model |

### Observability

| Function | AWS service | Why this service | Self-hosted alternative | What would flip the choice |
|---|---|---|---|---|
| Metrics, logs, alarms | Amazon CloudWatch | One place for Lambda logs, IoT metrics, and the alarms we page on (credit burn, S3 Standard bytes, heartbeat gaps, notification failures) | Prometheus + Grafana + Loki | Wanting a single dashboarding plane across clouds, or metrics CloudWatch prices poorly at high cardinality |

## Reference deployment

**One region, the dashboard's brain on a private network, least-privilege everywhere, secrets in managed vaults, all described as code.** Map in [`diagrams/11-aws-reference-architecture.mmd`](../diagrams/11-aws-reference-architecture.mmd).

### Region and network

- Single region, `us-east-1`. DR is a named, deferred limitation ([`06-tradeoffs-failure-modes.md`](06-tradeoffs-failure-modes.md)): a regional outage takes the cloud down, but the edge keeps detecting and buffers.
- VPC split into public and private subnets across two AZs:
  - **Public subnets** - only what must face the internet: NAT gateways and any public LB surface. CloudFront and API Gateway are AWS edge services, in front of the VPC, not in a subnet.
  - **Private subnets** - dashboard backend compute (Lambda in-VPC or Fargate); reach S3, DynamoDB, Secrets Manager, KMS over **VPC endpoints** (gateway for S3/DynamoDB, interface for the rest) so traffic never crosses the public internet.
- **Why the API is private:** the browser talks only to API Gateway, which authenticates against Cognito then forwards to a backend with no public IP. The only public surface is CloudFront (static assets) and the authenticated API front door. Devices are separate ingress: mutual TLS to IoT Core's MQTT endpoint, not through the VPC.

### IAM least-privilege

Two identity systems, both scoped tight:

- **Per-device X.509 certificates.** Each device publishes/subscribes only on its own topic prefixes (`telemetry/<device_uid>/*`, `events/<device_uid>/*`, `state/<device_uid>/*`) and fetches only jobs targeted at it. Cert CN matches `device.device_uid`. One compromised device is revoked on its own, no fleet re-keying.
- **Per-service IAM roles.** Every Lambda, the Firehose delivery role, the Snowpipe storage-integration role, and the API backend role name only the exact resources they touch (this table, this bucket prefix, this secret ARN) - nothing wildcarded. The notification handler can call SNS/SES and read the rules table but not the video bucket; the media handler can write a `media_object` row and read the video bucket but not send email. Blast radius of a bug or compromised role: one function.

### Secrets and keys

- **Secrets Manager** holds the Snowflake service-account credential (Snowpipe integration and backend query path), SES/API keys, and third-party tokens; rotation enabled where the downstream supports it. Nothing lives in code, env files, or Terraform state.
- **KMS** provides customer-managed keys for S3 at-rest, DynamoDB, and the short-lived signed-URL path. The dashboard never hands a client a raw S3 URL; it asks the backend, which (subject to role) mints a time-boxed pre-signed URL. Masked-by-default camera access (non-negotiable #3) is enforced here and in the Snowflake masking policies.

### Infrastructure as code

**Terraform, not CDK** - the stack spans AWS and Snowflake and Terraform has mature providers for both, so the S3 stage, Snowpipe storage integration, and Snowflake warehouses/roles live in one plan with one state. CDK would leave Snowflake a separate tool.

Split into stacks with separate state, so a dashboard deploy cannot touch the ingest plane:

| Stack | Contents |
|---|---|
| **`network`** | VPC, subnets, NAT, VPC endpoints, security groups |
| **`iot`** | IoT Core policies, X.509 provisioning template, Device Defender audit config, IoT Jobs templates, Device Shadow |
| **`ingest`** | Firehose delivery streams, S3 stage bucket, IoT Rules, EventBridge rules, event/telemetry/media Lambdas + roles |
| **`storage`** | video bucket + lifecycle (30d Standard -> Glacier Deep Archive), DynamoDB tables, KMS keys |
| **`snowflake`** | database, five schemas (RAW/CORE/EVENTS/GOVERNANCE/ANALYTICS), three warehouses (WH_LOAD/WH_BI/WH_VECTOR), resource monitors, storage integration, Snowpipe. Mirrors `sql/00_platform_setup.sql` |
| **`dashboard`** | Cognito user pool, API Gateway, backend Lambda/Fargate, CloudFront + SPA bucket |
| **`observability`** | CloudWatch alarms, SNS alert topic, log retention |

The point is the boundaries and separate state, not the HCL - that is what makes a change to one plane safe.

## CI/CD

**Three pipelines, because three things ship on different cadences with different blast radii - the dashboard app, the infrastructure, and the detection models.** Flow in [`diagrams/13-deployment-cicd.mmd`](../diagrams/13-deployment-cicd.mmd).

| Pipeline | Trigger | Steps | Rollback / blast radius |
|---|---|---|---|
| **Dashboard app** | merge to `main` | install, unit + integration tests, build SPA; on green sync static assets to S3, invalidate CloudFront, deploy backend (Lambda/Fargate) behind API Gateway | redeploy previous artifact; a bad build annoys ten users, touches no device |
| **Infra** | PR (plan) + merge (apply) | Terraform `plan` on every PR posts the diff; `apply` gated on human approval, per-stack; remote state (S3 + DynamoDB lock) prevents concurrent apply | `snowflake`/`iot` stacks get an extra reviewer (widest reach); plan-approve-apply is the discipline |
| **Model / algorithm** | new artifact | upload to S3 model registry, sign, record `sha256` in `detection_algorithm`; **IoT Jobs** staged rollout with health gate between stages | device verifies checksum before swap, rolls back on failure; blast radius is one canary |

Model rollout reuses the control-plane loop from [`03-cloud-controlplane.md`](03-cloud-controlplane.md): canary (one device) -> partial (a fraction) -> fleet, each stage written to `algorithm_deployment`. Nothing goes fleet-wide without passing the canary. Firmware OTA rides the same path with a smaller canary and a longer soak.

## How it scales

**The bill and load are dominated by two lines - Snowflake compute and video storage ([`05-cost-estimate.md`](05-cost-estimate.md)); everything else is cents with huge headroom.** Scaling means watching those two and knowing each next trigger.

- **At ~20 devices (design headroom).** Ingest rises ~10x from cents, so IoT Core, Firehose, Lambda, DynamoDB together are still a few dollars/month - no architectural change. Video hot-tier climbs ~180 GB -> ~1.8 TB (~$41/month); lifecycle handles the cold tier. Real watch item: if dashboard/BI load pushes the WH_BI X-Small past comfortable concurrency, step it up to a **Small** (2 credits/hour) for that workload - that step-up, not device count, moves the total.

**Where each service hits its next limit:**

| Service | Next limit | Mitigation |
|---|---|---|
| IoT Core | per-connection / per-publish throttling quotas on a burst | raise account limits before a large onboarding |
| Lambda | per-region concurrency (default 1,000); a detection storm approaches it | reserved concurrency on the notification handler |
| Firehose | per-stream throughput | a 10x fleet stays well under |
| DynamoDB | - | on-demand absorbs the growth |
| S3 | cost, not capacity (effectively unbounded) | lifecycle tiering |

- **When to split warehouses.** WH_LOAD/WH_BI/WH_VECTOR already separate so one workload cannot starve another. Next split: a heavy analytics/BI user base contends with dashboard reads - then WH_BI splits by workload or scales to multi-cluster.
- **When to add an ANN index.** Exact kNN (full cosine scan) is fine below ~1M vectors. Past that, or under a hard sub-300ms SLA, add an ANN/HNSW index ([`07-semantic-search-and-similarity.md`](07-semantic-search-and-similarity.md)).
- **When to go multi-region.** Only when a contract requires cloud-side DR or in-region residency. The edge already survives a regional outage by buffering, so multi-region buys cloud availability, not safety - a deferred upgrade.

## Where it breaks (failure modes at the implementation level)

**Honest list of how this build fails in production, and the one concrete mitigation for each.**

| Failure | Mitigation |
|---|---|
| **Region outage (`us-east-1` down)** - no dashboard, notifications, or ingest | The design itself: edge keeps detecting, fires local life-safety alarms in <1s, buffers events durably (ordered, deduped on `event_id`) for 24-72h, flushes on recovery. We accept cloud downtime, not lost events. Multi-region DR is the deferred upgrade |
| **IoT Core throttling** - firmware bug or detection storm pushes publish past quota | Device Defender flags the anomalous rate; edge near-duplicate suppression (tau ~0.97) collapses repeats before they leave the device; pre-raise IoT quotas before onboarding; the edge buffer absorbs backpressure |
| **Snowpipe backlog** - S3 stage fills faster than the pipe drains, freshness slips to minutes/hours | Alarm on pending-file age and stage object count; data is safe in S3 (delayed, not lost); scale WH_LOAD or resume the pipe. Firehose+S3 decoupling makes this a latency event, not data loss |
| **Lambda concurrency limit** - a detection burst exhausts the region pool, delaying notifications | Reserved concurrency guarantees the notification handler a slice; IoT/EventBridge retries throttled invocations; the debounce layer means we never sent one notification per raw detection anyway |
| **A bad model rollout** - new model misses PPE or floods false positives | Exactly what the staged rollout contains: canary catches it before partial/fleet, checksum gate blocks corrupt artifacts, self-test + health gate stop promotion, device restores the previous model on failure. `algorithm_deployment` answers "what is running where, did it roll back?" Blast radius: one canary device |

## Operational runbook basics

**What we watch, and the three alarms worth waking a human for - cost and safety dominate, since they hurt most if they drift silently.**

| Signal | Alarm | Page? |
|---|---|---|
| **Snowflake credit burn** | resource monitors (hard cap) + CloudWatch daily-credit metric; biggest risk is a warehouse left running 24/7 (~10x the bill) | **Yes** - fastest way to a four-figure bill, always operator error, always actionable |
| **Notification failure rate** | SNS/SES delivery failures; a pipeline that silently stops is a safety problem disguised as a metrics problem | **Yes** - the platform's core promise failing; a missed PPE/fire alert is the worst outcome |
| **Fleet-wide heartbeat loss** | many devices offline at once (bad rollout, IoT Core issue, regional event) | **Yes** - one device offline is routine; the whole fleet dark is systemic |
| **S3 Standard bytes** | hot-tier bytes exceed the 30-day rolling window = lifecycle-to-Glacier broken; at 20 devices that is ~$40 vs ~$500+/month | No - dashboard + ticket |
| **Single device heartbeat gap** | missed heartbeats (shadow/telemetry cadence 30-60s); offline only after several misses so a flaky link does not flap | No - dashboard + ticket |
| Lambda error/throttle, Snowpipe pending age, Firehose errors, IoT throttle, Device Defender findings | supporting metrics | No - dashboard + ticket |
