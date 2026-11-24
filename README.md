# AE AutoSet

**Set up After Effects cuts from anime timesheets with an AI agent.**
Point it at cut folders (timesheet scans, cel folders, layout), and Codex or Claude Code reads the
timesheet, then After Effects builds the cut: cel timing (time remap), layout and camera moves,
saved as a new AEP for each cut.

[한국어 안내는 아래에 있어요.](#한국어)

---

## What it does

- **Reads timesheets with AI.** The agent reads each sheet image (cel columns, holds, frame counts,
  camera notes). You use your own Codex or Claude Code subscription; no API keys.
- **Builds the cut in After Effects.** A separate After Effects instance opens the work's master AEP,
  places cels and layout, applies the timing and camera keys, saves `<cut>.tk1.aep`, and closes.
  Your own open After Effects and its unsaved work are never touched.
- **Any work, your naming.** Register a work once from its master AEP; the window reads the comps and
  suggests where cels and layout go and how cut folders are named.
- **Desktop window in four languages.** English, Korean, Japanese or Simplified Chinese (switch at the bottom left);
  worker notes are written in the same language. Pick a work, drop cut folders, check the cuts, press *Start*.

## Requirements

- Windows 10/11
- Adobe After Effects 2025 or later
- [Codex CLI](https://github.com/openai/codex) or [Claude Code](https://claude.com/claude-code), signed in
- [F's Plugins](https://github.com/bryful/F-s-PluginsProjects) (free, MIT): `F's Frame.aex` for the DEMO camera rig.
  It is in the older *F's Plugins* packages (`FsPlugins*.zip` on the Releases page), not in the newer NF-Plugins.
  Copy it into `C:\Program Files\Adobe\Adobe After Effects <version>\Support Files\Plug-ins\` and restart After Effects.

## Install

1. Download this repository (Code → Download ZIP) or clone it:
   `git clone https://github.com/fjrzl0954/AE-AutoSet.git`
2. Put the folder where your AI agent finds skills, named `AE-AutoSet`:
   - Codex: `%USERPROFILE%\.agents\skills\AE-AutoSet`
   - Claude Code: `%USERPROFILE%\.claude\skills\AE-AutoSet`
3. Double-click **`AE AutoSet.cmd`** once. It opens the window and adds a desktop / Start menu shortcut.

The full guide (English, Korean, Japanese, Simplified Chinese) is in [`READ ME.txt`](READ%20ME.txt).

## Use

**Try the DEMO work first.** A neutral `DEMO` work is included (`assets/AE-AutoSet_TeamKit/projects/DEMO`):
a master AEP built from scratch (stage, `02_camera` output, a 2D `camera` rig framed by F's Frame) with no
footage. Name a cut folder `DEMO_SC001` with `sheet/`, `LO/` and cel folders such as `A/A0001.png`, then run it.
`make_demo_template.jsx` in the same folder rebuilds the master.

1. **Register your work** (once per work): *+ New work* → choose the master AEP (the empty cut-000
   template) and, if you can, one real cut folder. Confirm the suggested comps and naming.
2. **Pick cuts**: select the work on the left, drop a cut folder or a parent folder of cuts, check the cuts.
3. **Start**: choose Codex or Claude and press *Start*. Each cut gets its AEP and, when something needs a look, a short worker note.
   To redo cuts that already have results, turn on *Include redo* below the cut list.

## Notes

- **Cost.** Each run uses your AI plan. Several cuts per run cost less per cut than one cut per run.
  Lower models or reasoning levels are cheaper but may misread sheets.
- **Privacy.** Sheet and layout images of the cuts you run are sent to the AI service you choose
  (Codex or Claude), under your own account.
- **Format.** Built around Japanese-style anime timesheets and cel/LO folder layouts.
- **Camera rig.** The camera reads its frame size from F's Frame on the `camera` layer. In your own works
  the plug-in is optional: without it the output comp (`02_camera`) defines the frame.
- **Crash dialog.** If After Effects crashed before, the separate instance answers its
  *Crash Repair Options* dialog with *Continue* automatically.
- Your registered works, master AEPs and settings stay on your PC.

## Feedback

Bugs, questions and ideas go to [Issues](https://github.com/fjrzl0954/AE-AutoSet/issues/new/choose):
pick *Bug report* or *Feature request*. Paste the text of the note files and any error the window showed.
**The page is public: don't attach timesheets, cels, LO or AEPs from real works.** Use the DEMO work instead.

## License

[MIT](LICENSE). Third-party notices: `assets/AE-AutoSet_TeamKit/licenses/THIRD_PARTY_LICENSES.md`.
After Effects is a trademark of Adobe. This project is not affiliated with Adobe, OpenAI or Anthropic.

---

## 한국어

**애니 타임시트를 AI가 읽고 After Effects 컷 세팅까지 자동으로 해 주는 도구예요.**
컷 폴더(타임시트 스캔, 셀 폴더, LO)를 넣으면 Codex나 Claude Code가 시트를 읽고, After Effects가 셀 타이밍(타임리맵),
LO, 카메라를 적용해 컷마다 AEP로 저장해요.

### 필요 환경
- Windows 10/11, After Effects 2025 이상
- 로그인된 Codex CLI 또는 Claude Code
- DEMO 카메라용 무료 플러그인 [F's Plugins](https://github.com/bryful/F-s-PluginsProjects)의 `F's Frame.aex`
  (Releases의 예전 `FsPlugins*.zip` 묶음에 들어 있어요. AE의 `Support Files\Plug-ins` 폴더에 넣고 AE를 다시 켜세요.)

### 설치
1. 이 저장소를 내려받아요(Code → Download ZIP), 또는 복제해요:
   `git clone https://github.com/fjrzl0954/AE-AutoSet.git`
2. 폴더 이름을 `AE-AutoSet`으로 해서 스킬 폴더에 넣어요.
   - Codex: `%USERPROFILE%\.agents\skills\AE-AutoSet`
   - Claude Code: `%USERPROFILE%\.claude\skills\AE-AutoSet`
3. **`AE AutoSet.cmd`**를 한 번 두 번 눌러요. 창이 열리고 바탕화면·시작 메뉴에 바로가기가 생겨요.

창은 English·한국어·日本語·简体中文 중에서 고를 수 있고(왼쪽 아래), 결과 메모도 같은 언어로 적혀요.
자세한 안내는 [`READ ME.txt`](READ%20ME.txt)에 4개 언어로 들어 있어요.

### 사용
처음에는 포함된 **DEMO 작품**으로 시험해 보세요. 소스 없이 새로 만든 양식(스테이지, `02_camera` 출력, F's Frame으로 틀을 그린 2D `camera` 리그)이에요.
컷 폴더 이름을 `DEMO_SC001`로 하고 `sheet/`, `LO/`, 셀 폴더(`A/A0001.png` 등)를 넣으면 돼요.

1. **작품 등록**(작품마다 한 번): 왼쪽 "+ 새 작품" → 000컷 양식 AEP와 실제 컷 폴더 하나를 골라요.
2. **컷 고르기**: 왼쪽에서 작품을 고르고, 컷 폴더나 상위 폴더를 끌어다 놓은 뒤 작업할 컷을 체크해요.
3. **작업 시작**: Codex나 Claude를 고르고 "작업 시작"을 눌러요. 작업 중인 AE와는 별도의 AE가 열려 작업하고 스스로 닫혀요.
   이미 결과가 있는 컷을 다시 하려면 컷 목록 아래 "재작업 포함"을 켜요.

### 참고
- AI 사용량은 본인 요금제에서 나가요. 한 번에 여러 컷을 넣을수록 컷당 사용량이 줄어요.
- 작업한 컷의 시트·LO 이미지는 본인 계정으로 고른 AI 서비스(Codex 또는 Claude)에 전송돼요.
- 등록한 작품, 양식 AEP, 설정은 각자 PC에만 저장돼요.

### 피드백
오류, 질문, 아이디어는 [Issues](https://github.com/fjrzl0954/AE-AutoSet/issues/new/choose)에 남겨 주세요.
"오류 신고" 또는 "기능 요청"을 고르고, 메모 파일 내용과 창에 나온 오류를 붙여 넣어 주세요.
**공개 페이지라서 실제 작품의 시트·셀·LO·AEP는 올리지 마세요.** 그림이 필요하면 DEMO 작품을 써 주세요.

라이선스: [MIT](LICENSE)
