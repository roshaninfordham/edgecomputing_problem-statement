# 03 — Edge Hardware Research

Inherits `00-system-prompt.md`.

## GOAL

Produce a grounded comparison of the edge compute options with real, dated
throughput numbers, so the choice of Jetson for the multi-camera device and Pi plus
Coral for the single-camera device is defended with evidence, not vibes.

## APPROACH

1. **Anchor to the two real devices before comparing anything.** Device 1 is the
   installed multi-stream unit (three cameras, likely Jetson); device 2 is the new
   low-power unit (one camera, two motion sensors, likely Raspberry Pi 5 plus Coral
   USB TPU). The research serves these two roles, not a generic survey.
2. **Pull dated, sourced throughput numbers.** For each candidate, cite real FPS for
   a named detection model at a named resolution, with the date and source of the
   figure (for example, "as of July 2026, per the vendor's published benchmark for
   YOLO-class detection at 640x640"). Label anything estimated rather than measured
   as an assumption. Never present an unsourced number as fact.
3. **Compare on the axes that decide the deployment:** multi-stream capacity (how
   many camera feeds at target FPS), power draw, INT8/quantization support, thermal
   and enclosure needs, unit cost, and software maturity. Put these in a table.
4. **Explain the split, do not just state it.** Jetson earns the three-camera device
   because multi-stream real-time inference needs the GPU; Pi plus Coral earns the
   single-camera device because a motion-gated, quantized single stream fits a cheap,
   low-power TPU. Show the reasoning that makes each the right tool for its role.
5. **Give Arduino its actual job.** It is the motion and GPIO node: cheap, reliable
   digital sensing that wakes the vision device. It does not run CV. Say why that
   division of labor is correct (cost, power, reliability of a simple MCU).
6. **Make motion-gating a first-class technique.** Explain how motion sensors and
   frame-differencing gate the expensive vision pipeline: idle until motion, then
   burst inference. Tie it to the volume assumptions (roughly 200 detections per
   camera per day) and to power and cost. This is the lever that makes the Pi device
   viable and the cost model believable.

## CONSTRAINTS

- Every hardware throughput number is dated and sourced, or explicitly labelled an
  assumption. No bare numbers.
- Respect the confirmed deployment: Jetson-class for the three-camera device, Pi plus
  Coral for the one-camera device. Do not contradict these.
- Keep model and resolution attached to every FPS figure; an FPS with no model or
  resolution is meaningless and fails review.
- First person. Recommend, and own the recommendation.

## OUTPUT SPEC

- `docs/02-edge-research.md`. Sections: the two device roles; a candidate comparison
  table (Jetson tier vs Pi plus Coral, with dated FPS, power, quantization, cost);
  the reasoning for each device's assignment; the Arduino motion/GPIO role; and a
  motion-gating section tying inference bursts to the volume and power assumptions.
  Include a short sources list with dates.

## EVAL RUBRIC

- [ ] Every FPS number carries a model, a resolution, a date, and a source (or an
      explicit "assumption" label).
- [ ] A comparison table covers throughput, power, quantization, and cost.
- [ ] The Jetson-for-3-cameras and Pi+Coral-for-1-camera split is reasoned, not asserted.
- [ ] Arduino is scoped to motion/GPIO, with a stated reason it does not run CV.
- [ ] Motion-gating is explained and tied to the volume and cost assumptions.
- Fails if: any headline number is undated or unsourced without being labelled an
  assumption; or the recommendation contradicts the confirmed deployment.
