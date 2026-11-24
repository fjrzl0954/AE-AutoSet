# Recovery and Continue Rules

Do not stop the batch for a condition whose outcome is defined here.

Use the table for evidence decisions; do not ask the worker to choose again. A missing permission or undefined destructive choice is different: preserve completed work, explain what action is blocked, and ask one concise question. If a skill rule causes the pause, link its exact file and identify the relevant rule rather than blaming the model or reporting only "blocked".

| Condition | Required action |
| --- | --- |
| Track source missing | Exclude that track and continue all other sources |
| Ambiguous number with a supported best candidate | Apply candidate, record uncertainty and worker note, continue |
| Cell number cannot be supported | Write `매핑 실패.txt`; skip that scene and continue |
| Camera timing or framing uncertain | Defer camera, record reason, continue cell work |
| Sheet letter and source folder disagree | Do not cross-map; exclude absent exact track and continue |
| CUT written differently or blank | Use scene-folder CUT; preserve raw value and warning |
| SHEET field blank | Use actual image count/order; preserve blank raw value and warning |
| Nothing can be processed | Record scene failure; continue, or report if it is the only scene |

Note files are written by the engine in the window's language (`AE_AUTOSET_LANG`: ko, ja, en, zh), so `매핑 실패.txt` may appear as `マッピング失敗.txt`, `Mapping failed.txt` or `映射失败.txt`; likewise `분석 실패.txt` (`解析失敗.txt`, `Analysis failed.txt`, `分析失败.txt`), `적용 실패.txt` (`適用失敗.txt`, `Apply failed.txt`, `应用失败.txt`) and `작업자 확인 필요.txt` (`要確認.txt`, `Needs review.txt`, `需要确认.txt`). Treat every name as the same note.

For a preparation failure, correct only that failed input before AE starts and run the wrapper's `-Action Prepare -SessionPath <session> -RetryFailed`; it prepares only the failed scenes again. Never delete unresolved evidence to force success. After AE starts, do not rebuild the manifest or re-prepare.

If the real After Effects `Crash Repair Options` window appears, choose **Continue** only. Do not use Safe Mode, reset preferences, or change plugins. Do not dismiss unrelated error dialogs blindly: capture the exact error, identify the current AEP, preserve the scene, record `적용 실패.txt`, and continue to the next scene when safe.

Finish exit code 2 means a failed or incomplete result and must not be reported as success. A camera-deferred scene may finish with code 0 as `saved_unreviewed_camera_deferred`, but camera is not complete. Never describe skipped review as passed review.

## Targeted diagnostics

- Missing fresh review: recreate it from this run's images and hashes; never borrow another cut's answer.
- Missing stage/output: compare the selected profile against the bundled template; do not rename old comps or delete expressions to force acceptance.
- Single-scene rejection: inspect the installed Session version and profile pattern. Never add a junction or unrelated scenes. SC000 remains protected.
- Changed prepared evidence: never edit hashes or receipts to force acceptance. Preserve applied results; start a new session only for authorized rework.
- Source/cell canvas mismatch: when explicitly reported, check maximum mapped-source width/height, source scale, output dimensions, and camera preservation. Do not add routine post-save QA.
- Missing AEP or unexpected ae_remap_data: inspect the scene failure note and result report; check for an older/parallel execution path.
- Security warning or missing files: run the bundled integrity verifier. HASH FAIL means do not execute the package.

## AE dispatch and UI

Do not restart AE just to rearrange windows. If UI interaction is needed, maximize the main AE window and keep Project, Composition, Timeline and Effects/Properties visible; no comp-only fullscreen, workspace reset, or QA-only Fit/frame steps.

If launch state is dispatched, check the current panel receipt/report before retrying. Only when neither exists and AE did not receive the request may --retry-dispatch resend once; otherwise avoid duplicate application. If still unconfirmed, use the same manifest through the manual Session panel, not another workflow. The default launch uses a separate AE instance, so the worker's unsaved projects do not block it; it can take minutes to start, and it records errors in the report and closes itself instead of waiting on an alert. If AE crashed earlier, that instance shows "Crash Repair Options" at start; Launch watches only that instance and presses Continue (noted in `ae.dialog.json` in the session folder). If `ae.dialog.json` says another dialog was seen and no report arrives, tell the user an AE dialog may be waiting instead of polling again. Only `-ReuseAE` needs unsaved project changes resolved before dispatch. Do not close the worker's own AE. AE shutdown requests belong to the compatibility Batch, not normal Session.

