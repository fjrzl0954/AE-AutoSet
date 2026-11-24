# AE AutoSet Workflow

## Input and session

- Accept one exact scene folder or a parent of configured scene folders. A path on any drive is valid. First run the wrapper's read-only `Profile` action and use the nearest ancestor `.ae-autoset.json`; see [project-profile.md](project-profile.md).
- If the input contains only ZIP archives, safely extract each into a same-named child folder while preserving the archive. Reject rooted entries, traversal, links, duplicate targets, and overwrites. Keep combined-cut archives intact and create independent scene folders only when current SHEET CUT evidence clearly separates them; copy shared sources with hash verification.
- Record a wall-clock start before inventory. Use the wrapper's `Begin` action and retain its exact `session.json`.
- A fresh cut must not use `-Overwrite`. For an explicitly requested rework, use it so previous generated results are archived.
- `begin` creates current full previews, crops, hashes, and camera templates. Crops are navigation aids; inspect each full original too.
- Sheet and LO folders come from the work pack (`scene_folders`, several names and `*` wildcards allowed; default sheet rule `*sheet*`). SHEET images are found recursively under the matching immediate folders; LO images are the direct images of the first matching LO folder (`LO`, `_lo`). Comparisons ignore case.

## Fresh visual reading

Read SHEET pages in natural filename order and inspect header, left/right body, memo, and both CAMERA columns. Inspect every LO. OCR and generated hints may locate evidence but cannot decide the answer.

- Effective CUT is the scene-folder number. Preserve a different or blank written value as `cut_raw` plus a worker warning and continue.
- Blank SHEET numbering becomes the actual image count and selection order; preserve blank `sheet_raw`. Do not silently repair explicit duplicate or reverse page numbering.
- SECOND is `seconds+frames` at 24 fps. Determine page duration, full scene duration, and camera ending independently. Do not truncate later cells to a camera key or multiply a repeated full-cut SECOND by page count.
- Read every explicitly labelled track with a present source, including tracks beyond A–F and exact suffix tracks such as `A_go`. Record only the first 1-based frame where a value changes; continuations are HOLD. `X/×` is an empty event.
- An exact `D_r`-style revised source replaces the base source. Do not treat `_go`, `_cover`, or `_m` as aliases.
- Sparse positive cell numbers are supported. Keep source filenames and ARDJ numbers unchanged; the runtime binds each original number to a verified dense import cache and uses that same map for remapping and FX analysis. A referenced number without a real source still fails preparation. Preserve `_timesheet_auto/_sources` with the saved AEP.
- Exclude only source-absent tracks and continue with the others. Never invent a cross-letter mapping.
- Resolve ambiguous numbers using the strokes, adjacent frames, repeated handwriting, and available source range. If one candidate is best, apply it with an `apply_with_warning` uncertainty and worker note. If no value can be supported, write `매핑 실패.txt` with track and frames and skip that scene.

Write one fresh review per page under `_timesheet_auto`: `<CUT>.review.json` for one page or `<CUT>_sheetN.review.json` for several (N counts every image in the sheet folder). Use the current run ID and source SHA-256 in `audit_entry`. A page that is not a timesheet (production slip, composite slip, memo sheet) gets a review containing only `"page_kind": "not_timesheet"`, a one-line `note`, and its `audit_entry`; it is skipped and listed in the worker note. Never use this to drop an unreadable timesheet page. The bundled schema and examples are under `assets/AE-AutoSet_TeamKit/schemas` and `assets/AE-AutoSet_TeamKit/examples`.

## Conflicting timing evidence

When timing conflicts, compare SECOND and LO TIME with the cut-end line, valid cell HOLD end, masking/end marks, page count, and explicit user timing. Do not use an empty printed grid boundary as the scene end. Preserve audit_entry.second_raw and timing_review with scene_total_frames, page_total_frames, camera_end_frames, scene_end_evidence, and camera_end_evidence. Unresolved scene length blocks that scene; unresolved camera timing defers camera only. Do not invent source frame numbers or silently resolve CELL/ACTION conflicts.

## Camera decision

Every scene needs a completed `camera.decision.json` copied from its current template data. Evidence must cover every current SHEET and LO. If any motion/framing evidence is present or uncertain, read [camera.md](camera.md) before deciding. Camera uncertainty defers camera only; it does not stop cell work.

## Apply and save

Run, with the exact session path:

```powershell
& "<skill>\scripts\Invoke-AutoSet.ps1" -Action Prepare -SessionPath "<session.json>"
& "<skill>\scripts\Invoke-AutoSet.ps1" -Action Launch  -SessionPath "<session.json>"
& "<skill>\scripts\Invoke-AutoSet.ps1" -Action Finish  -SessionPath "<session.json>"
```

After launch, read status without dumping the complete session/report:

```powershell
& "<skill>\scripts\Read-AutoSetState.ps1" -SessionPath "<session.json>"
```

The reader preserves scene errors, warnings, save receipts and camera decisions; `-Scene "<exact-folder-name>"` narrows scene details. `report_complete:true` permits `Finish`, not a success claim. A missing report is pending, while malformed or wrong-run reports require targeted diagnosis. Neither permits duplicate dispatch. If required detail is absent, read that field from the reported source path; do not infer success from an empty error or summary-reader exit code.

Default state output omits camera coordinates/expressions and internal FX comp names, while retaining errors, warnings, key frames and per-character FX outcomes. Use `-Scene "<exact-folder-name>" -Detail` only when those internal values are needed; source records remain unchanged. Summary output does not add a new completion check or replace `Finish`.

Wait for the matching `ae.report.json` to become complete before `Finish`. Use short bounded waits, not rapid polling. `Launch` starts a separate AE instance (`AfterFX.exe -m`) for this run from a plain-ASCII copy of the launcher; it applies every cut in order, records the report and quits by itself. The worker's own AE stays open and is never touched, so unsaved work there does not block the run. A new AE can take minutes to start: a `dispatched` launch without a panel receipt is still starting, not a failure. Retry dispatch only after confirming AE did not receive it. `-ReuseAE` sends the run to the already open AE instead (former behaviour; that AE must have no unsaved changes). Do not run `prepare` again after AE application starts.

The runtime applies these invariants using the names resolved from the active project profile:

- use the configured cell, LO, camera, direct-output, top-comp, and project-folder names (`01_Comp stage`, `02_camera`, and `01_LO` for DEMO);
- Color Key `#FFFFFF`, cell precomp, HOLD Time Remap, and empty opacity;
- stage and cell-comp canvas from maximum mapped source size;
- cell comps, stage, and top scene comp use full scene duration;
- mapped cell names descending, then existing `BG_blur` / `Camera Lens Blur`, then LO; move cells above the topmost matching background-blur layer without changing its settings;
- each LO imported to `01_LO` and placed independently at the absolute bottom for the full duration;
- preparation keeps every original LO unchanged and creates a verified RGB PNG fallback under `LO/_AE_AutoSet_RGB`. AE tries the original first, retries that RGB copy after an import rejection, and skips only that LO if both fail. Record the fallback or skip in the worker note; if a camera plan depends on the skipped LO, defer only the camera and still save the remaining scene work;
- preserve source scale, upper compositions, output resolution, effects, expressions, and existing blur values;
- no new blur and no `ae_remap_data`;
- save into the configured rendered AEP name (`DEMO_SC###.tk1.aep` for DEMO), never an alternate Save As result.

## Report

Distinguish saved, saved-with-note, excluded, failed, camera-applied, not-applicable, and deferred. Include scene length versus last camera key. Report post-save structural and visual review time as zero and state that review was skipped. Finish cleans up after saving: for each saved scene it deletes `_timesheet_auto` and the LO RGB fallback except files the saved AEP links to (such as `_timesheet_auto/_sources`), then deletes `_sessions` and the root summary files, keeping the archived previous results of any scene that did not save. Failed scenes keep their work files. Finish prints the per-scene results (`results`) and what it removed (`cleanup`); write the report from that output, because the session files are gone afterwards. Use `-KeepWorkFiles` only when the worker asks to keep them.
