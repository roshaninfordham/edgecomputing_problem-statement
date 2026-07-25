# 05 — Cost Model

Inherits `00-system-prompt.md`.

## GOAL

Produce a monthly cloud cost estimate built from stated assumptions and per-line
arithmetic, so a reviewer can check every number and see the headline: video storage
and the warehouse dominate, and the design already tiers the expensive things.

## APPROACH

1. **State every assumption before any dollar figure.** List the volume drivers up
   front and label each as an assumption, not a fact: roughly 800 detection events
   per day fleet-wide, roughly 2,000 motion signals per day, a telemetry heartbeat
   every 30 to 60 seconds per device, video at 720p H.264 motion-gated at roughly
   3 GB per device per day retained 30 days hot then archived, and one 512-dim
   float32 embedding (~2 KB) per detection. Every later line traces to one of these.
2. **Cost each layer on its own line with visible arithmetic.** Show the calculation,
   not just the total: units times rate equals line cost, with the rate dated and
   sourced. Cover ingest/messaging, object storage (hot S3 and Glacier separately),
   stream-to-warehouse, the Snowflake warehouse (X-Small, 60 s auto-suspend, so
   compute is bursty and cheap), notifications, and embedding storage. A reader must
   be able to redo each line by hand.
3. **Separate storage growth from steady-state.** Hot video is a rolling 30-day
   window (bounded); archive grows forever (small per-GB but monotonic). Show the
   month-one number and note the growth trajectory so the estimate is honest about
   the future, not just today.
4. **Lead with the headline.** After the arithmetic, state plainly that video storage
   and the warehouse are the two dominant costs and that the structured
   event/telemetry/embedding data is nearly free by comparison. This is the whole
   reason the design tiers video and keeps only pointers in Snowflake; the cost model
   is where that decision pays off. Show the sensitivity: what happens if retention
   doubles or the event rate 10x's.
5. **Keep the warehouse cost honest.** With auto-suspend the warehouse bills for
   query time, not wall-clock. Estimate credits from the micro-batch ingest cadence
   and dashboard query pattern, and say what would change the number (more users,
   heavier analytics).

## CONSTRAINTS

- Assumptions come first and are labelled as assumptions.
- Every line shows units, rate, and product; no bare totals.
- Every rate is dated and sourced, or labelled an estimate.
- Hot storage and archive are costed separately.
- The headline (video plus warehouse dominate) is stated explicitly and falls out of
  the arithmetic, not asserted ahead of it.
- First person. Round sensibly and say so; this is an estimate, not a quote.

## OUTPUT SPEC

- `docs/05-cost-estimate.md`. Sections: **Assumptions** (the volume drivers, each
  labelled), **Per-line monthly cost** (a table or itemized list with units, rate,
  source/date, and line total per layer), **Headline** (video plus warehouse
  dominate, with the sensitivity note), and a stated total with its rounding and
  caveats. First person.

## EVAL RUBRIC

- [ ] All volume assumptions are listed and labelled before any cost.
- [ ] Every cost line shows units times rate equals total.
- [ ] Rates are dated and sourced or labelled estimates.
- [ ] Hot S3 and Glacier archive are separate lines.
- [ ] The warehouse line reflects auto-suspend (query-time billing), not 24/7.
- [ ] The headline names video and warehouse as dominant and it follows from the math.
- [ ] A sensitivity note covers retention or event-rate changes.
- Fails if: a total appears with no arithmetic; a rate is unsourced and unlabelled;
  or the headline contradicts the line items.
