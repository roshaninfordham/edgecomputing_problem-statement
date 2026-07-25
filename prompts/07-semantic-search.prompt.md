# 07 — Semantic Search and Similarity

Inherits `00-system-prompt.md`.

## GOAL

Produce the semantic-search and similarity subsystem doc: four features built on one
cosine metric over per-detection embeddings, each explained and defended, so a
reviewer sees a simple, coherent design rather than a bag of ML tricks.

## APPROACH

1. **Establish the one metric up front and reuse it everywhere.** Store one
   L2-normalized 512-dim embedding per detection event in Snowflake
   `VECTOR(FLOAT, 512)`. Because the vectors are L2-normalized, cosine similarity
   equals the dot product and is monotonic in Euclidean distance, so cosine is the
   natural single metric for all four features. State this once; then every feature
   reuses it. Simplicity is the design goal: resist adding a second metric.
2. **Feature 1 — Semantic incident search.** Top-k by
   `VECTOR_COSINE_SIMILARITY(q, e_i)`. Exact kNN (full scan) is fine below roughly a
   million vectors and meets the sub-300 ms budget over the hot window. Give the
   formula, the plain-English why, why-not-ANN-yet (exact is simpler and correct at
   this scale), the crossover point where HNSW/ANN starts earning its complexity, the
   complexity (O(N*d) per query), and edge cases.
3. **Feature 2 — Near-duplicate / debounce suppression.** At ingest, if
   cos(e_t, e_{t-1}) > tau within window W, collapse into one incident. Default tau
   around 0.97. Derive the threshold and explain the tradeoff: too high misses dupes
   and causes an alert storm; too low merges genuinely distinct events. Tie this to
   the notification debounce in prompt 04 so the platform has one definition of "the
   same event."
4. **Feature 3 — Anomaly / clustering.** Cluster embeddings with k-means on the
   normalized vectors (spherical k-means, cosine). Score anomaly(e) = 1 - max_j
   cos(e, centroid_j); flag if above a threshold. Give the formula, why this feeds
   the modelling use case, why-not-alternatives (a heavier density model is
   unjustified at this scale), threshold derivation, complexity, and edge cases.
5. **Feature 4 — Embedding pipeline.** Where embeddings come from (the edge CV
   backbone's penultimate layer, d=512, L2-normalized on device), how they flow (edge
   into the event payload, through stream-to-warehouse ingest, into the VECTOR
   column), and how backfill works for events that predate the pipeline. This is the
   plumbing the other three features stand on.
6. **Make each feature self-contained.** Every feature gets: the formula, a
   plain-English why, why-not-alternatives, the chosen threshold and how it was
   derived, the complexity, and the edge cases. Same template four times so the doc
   is skimmable and each feature is independently defensible.
7. **Confront the three edge cases the reviewer will poke, explicitly.** Cold-start
   (an empty index or too few vectors to cluster: fall back gracefully, do not crash
   or return garbage). Embedding-model version drift (store
   `embedding_model_version`; never compare cosine across versions; re-embed on a
   version bump or scope queries to one version). Exact-vs-ANN crossover (state the N
   at which the full scan stops meeting the latency budget and ANN is worth it).

## CONSTRAINTS

- Keep it simple. One metric (cosine over L2-normalized vectors) for all four
  features. Do not introduce a second distance without a stated reason.
- Every feature includes formula, plain-English why, why-not-alternatives, threshold
  derivation, complexity, and edge cases. No feature skips a slot.
- Every threshold is derived or reasoned, never dropped in as a magic number.
- Cross-version embedding comparison is forbidden and the doc must say why and how it
  is prevented.
- First person. Explain the math so it can be re-derived, not just cited.

## OUTPUT SPEC

- `docs/07-semantic-search-and-similarity.md`. Sections: the shared metric and why
  L2-normalization makes cosine the one metric; then the four features, each with the
  six-slot template; then a consolidated edge-cases section (cold-start, model-version
  drift, exact-vs-ANN crossover). First person.
- `diagrams/09-embedding-pipeline.mmd` — edge backbone penultimate layer to event
  payload to stream ingest to VECTOR column, with the backfill path. Valid Mermaid.

## EVAL RUBRIC

- [ ] One metric (cosine over L2-normalized vectors) is established and reused for all four.
- [ ] The L2-norm identity (cosine = dot product, monotonic in Euclidean) is stated.
- [ ] Each of the four features has formula, why, why-not, threshold derivation,
      complexity, and edge cases.
- [ ] The debounce threshold (~0.97) is derived with the storm-vs-merge tradeoff.
- [ ] Anomaly scoring and clustering use cosine and feed the modelling use case.
- [ ] The embedding pipeline covers source, flow, and backfill.
- [ ] Cold-start, model-version drift, and exact-vs-ANN crossover are each addressed.
- [ ] The embedding-pipeline diagram is valid Mermaid.
- Fails if: a second metric appears without justification; any threshold is a magic
  number; cross-version comparison is allowed; or a feature skips a template slot.
