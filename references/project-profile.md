# Work Packs

AE AutoSet separates each work's rules from each worker's absolute paths. The worker supplies only a cut folder or a parent of cut folders. Every work is a pack under the runtime:

```
assets/AE-AutoSet_TeamKit/projects/<ID>/project.json
assets/AE-AutoSet_TeamKit/projects/<ID>/<master>.aep
```

Workers create and edit packs in the settings window (`AE AutoSet.cmd` → `+ 새 작품`). It reads the master AEP without After Effects, suggests every value, and stores a validated pack. Never write or change a pack during a scene run; if a cut folder matches no pack, ask the worker to register the work.

## Selection

For each cut folder the runtime uses, in order:

1. the nearest `.ae-autoset.json` above it — either a full legacy v1 profile, or `{"project": "<ID>"}` to pin a pack;
2. the single pack whose `scene_pattern` matches the folder name (two matching packs is an error until one is pinned);
3. `DEMO_SC###` folders fall back to the built-in DEMO settings.

Folders naming several cuts (`XYZ_03_112_116`) match no pack and stay worker-only.

## Pack fields

- `scene_pattern`: folder rule with one cut token and optionally one episode token: `{cut}`/`{cutN}`, `{ep}`/`{epN}` (`XYZ_{ep2}_{cut3}`, `DEMO_SC{cut3}`). A terminal cut token accepts trailing letters and `_kari` (`006A`, `155_kari`) as separate scenes with the same numeric cut.
- `template`: the master AEP in the pack folder (or the runtime root for the bundled DEMO master). Absolute paths and `..` are rejected. Cut 000 is protected.
- `output.aep`, `output.ardj`, `output.main_comp`: names rendered from `{scene}`, `{project_code}`, `{cut}`/`{cutN}`, `{ep}`/`{epN}`.
- `comps.main`: the master's top comp, renamed to `output.main_comp`. `comps.cell` / `comps.lo`: where cells and LO go.
- `camera`: `{layer, comp, output_comp}` of the 2D inverse camera rig, or `null` when the work has no supported rig (camera moves are then deferred to the worker).
- `project_folders`: Project-panel folders for cell footage, cell comps and LO (created when missing).
- `cell_anchor_layers`: cells go directly above the topmost layer with one of these names; `[]` puts cells at the top.
- `scene_folders.sheet` / `scene_folders.lo`: folder names, several allowed (the settings window accepts `,` or `/`). `*` and `?` are wildcards: `*sheet*` (the default) means any folder whose name contains `sheet`. Wildcards never match underscore-prefixed folders unless the pattern starts with `_`, so AutoSet's `_timesheet_auto` is never read; exact names such as `_sheet` or `_lo` are allowed.
- `modules.character_fx`: not available in this edition; keep `false`.
- `fps`: the handwritten-sheet parser requires 24. The output comp keeps the master's own frame rate.

Before any write, use the wrapper's read-only resolver:

```powershell
& "<skill>\scripts\Invoke-AutoSet.ps1" -Action Profile -TargetPath "<work-path>" [-Only "<cut>,<cut>"]
```

Confirm the reported work, template, rendered output names, and comp names. A malformed pack stops before a session is created. Scene variants are separate jobs, ordered by numeric cut then full folder name.
