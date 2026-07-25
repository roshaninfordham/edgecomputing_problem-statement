# Prompt Library

This directory is the prompt library I used to produce this submission. Each file
here is a structured, reusable prompt: the exact instruction set I would hand to a
capable model (or a junior engineer) to generate one deliverable of the IoT
platform design, plus the rubric I would use to judge the result.

I am shipping this on purpose. How someone decomposes a large, ambiguous problem
into instructions is a good proxy for how they think. A one-shot "design an IoT
platform for me" ask produces a plausible blob you cannot review. A library of
narrow, contract-bound prompts produces artifacts you can review, regenerate, and
defend one at a time.

## Why structured prompts beat one-shot asks

- **Reproducibility.** The same prompt against the same context produces the same
  shape of artifact. When I change an assumption (say, the retention window), I edit
  one prompt and regenerate one file instead of re-deriving everything by hand.
- **Reviewability.** Each prompt states its own pass/fail rubric. That turns "does
  this look good?" into a checklist an interviewer, a teammate, or I can run. The
  intent is visible next to the output, not buried in my head.
- **Separation of intent from output.** The prompt captures *what good looks like
  and why*; the generated `docs/`, `sql/`, and `diagrams/` files are the *what*. If
  the output drifts, the prompt is the source of truth I correct against.
- **Composability.** Every task prompt inherits one shared system prompt, so the
  voice, the non-negotiables, and the assumptions stay consistent across seven
  deliverables without me restating them seven times.

## The shared five-part contract

Every deliverable prompt (`01` through `07`) uses the same five headings, in this
order. The contract is the point: a reader knows where to look, and a generator
knows what to fill in.

| Section | What it fixes |
|---|---|
| `## GOAL` | One sentence: what artifact this produces and why it matters. |
| `## APPROACH` | The ordered thinking steps. This is where the engineering judgment lives. |
| `## CONSTRAINTS` | Hard rules and self-imposed non-negotiables for this artifact. |
| `## OUTPUT SPEC` | The exact shape of the output: file name, format, sections, depth. |
| `## EVAL RUBRIC` | A short checklist for whether the output passes or fails. |

`00-system-prompt.md` is not a deliverable prompt; it is the persona and context
header that every task prompt assumes has already been read.

## Eval-driven approach

I wrote the `EVAL RUBRIC` for each deliverable *before* I was satisfied with its
output, so the rubric is a spec and not a post-hoc rationalization. A generated
artifact is "done" when it passes its own rubric. The rubrics are deliberately
short and concrete (presence of a masking policy, dated hardware numbers, per-line
cost arithmetic) so they are cheap to run and hard to fudge.

## Map: prompt to deliverable

| Prompt | Produces | Repo target |
|---|---|---|
| `01-snowflake-schema.prompt.md` | Future-proof warehouse schema + SQL | `docs/04-snowflake-data-model.md`, `sql/01_registry.sql`, `sql/02_events_telemetry.sql`, `sql/04_privacy_and_views.sql` |
| `02-architecture-diagrams.prompt.md` | Mermaid architecture + sequence diagrams | `diagrams/01`–`09*.mmd`, `docs/01-architecture.md` |
| `03-edge-research.prompt.md` | Edge hardware research with dated numbers | `docs/02-edge-research.md` |
| `04-cloud-controlplane.prompt.md` | Ingest, notifications, staged rollout/OTA | `docs/03-cloud-controlplane.md` |
| `05-cost-model.prompt.md` | Monthly cost estimate with per-line math | `docs/05-cost-estimate.md` |
| `06-tradeoffs.prompt.md` | Trade-offs and failure modes | `docs/06-tradeoffs-failure-modes.md` |
| `07-semantic-search.prompt.md` | Semantic search and similarity subsystem | `docs/07-semantic-search-and-similarity.md`, `diagrams/09-embedding-pipeline.mmd` |

## How to use this library

1. Read `00-system-prompt.md`. Treat it as prepended to every task prompt below.
2. Pick the deliverable you want and open its prompt.
3. Generate against the five-part contract.
4. Run the `EVAL RUBRIC`. If it fails, fix the artifact (or, if the rubric was
   wrong, fix the prompt). Do not ship a red rubric.
