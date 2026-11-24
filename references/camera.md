# Camera Interpretation

Use this reference only when current SHEET or LO evidence may describe a camera move.

## Evidence gate

Inspect every page's full sheet, memo, left CAMERA column, and right CAMERA column, plus every LO. Colored strokes are attention hints, not OCR answers. A blank right column does not cancel a move written elsewhere.

Complete the current template as follows:

- confirmed timing and framing: `mode:"expected"`, `status:"planned"`;
- no instruction in any current source: `mode:"unchanged"`, `status:"not_applicable"`;
- only one side confirmed or any essential ambiguity: `mode:"unchanged"`, `status:"deferred"`.

For each SHEET retain `source`, `sha256`, observed `motion`, a concrete `note`, and `regions_checked:["full","memo","camera_left","camera_right"]`. For each LO retain its source/hash, `framing`, and note. Use the current template's version/run_id and scene-relative source paths. motion/framing are none/present/uncertain. A colored hint classified as no motion requires non_motion_explanation explaining the actual non-motion mark.

## Plan

For confirmed movement, write `camera.plan.json` version 1 with:

- current run ID and current evidence;
- `stage_name` and `camera_layer` from the active profile (DEMO: `01_Comp stage`, `camera`), `fps:24`;
- `total_frames` equal to full scene length, not the last camera key;
- the framing-positive scene-relative `<LO folder>/<filename>` (the work's LO folder name, such as `LO/` or `_lo/`) and its original image size;
- increasing 1-based keys containing labels and original-pixel `[left,top,right,bottom]` rectangles.

Measure each rectangle from the current original LO. Do not copy coordinates or timing from another cut. Use the existing 2D `camera` layer's Position and X/Y Scale. Preserve Anchor Point, Rotation, inverse output expressions, the profile's output comp (DEMO: `02_camera`), and final output dimensions.

Apply Easy Ease only when `Slow` (or the Japanese-sheet equivalent `Fairing` / `フェアリング`) is written for that movement, and only to its destination key. The start key and every move without Slow remain Linear. A camera ending before the scene stays at the destination framing through the scene end.

Do not convert lighting triangles, focus instructions, matte fades, blur directions, or compositing notes into camera keys. Record unsupported effect directions for the worker without blocking cell mapping.

For exact plan fields use [camera.plan.schema.json](../assets/AE-AutoSet_TeamKit/schemas/camera.plan.schema.json); keys contain frame,label,rect,slow and evidence is bound to the current run. See [coordinate contract](../assets/AE-AutoSet_TeamKit/docs/CAMERA_LAYOUT_KO.md) only when implementing or diagnosing conversion. Do not confuse a cell's SL/effect direction with camera Slow. F9 destination ease uses speed 0 and influence 33.33.
