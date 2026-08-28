https://x.com/MarkKnd/status/2082207361276465611
Can you explain how to create his stanning onboarding experience in your app, what technoloties was used to create it, create me an agent prompt and find all possible references/implementations on github. Also I  would like to have this screen recording permission flow described https://x.com/lexrus/status/2044929029334245819 Design and suggest me possible onboarding animation scenario


I'll pull the permission-flow post, inspect the original animation context, and search GitHub plus product docs so the onboarding design and agent prompt match how Coast actually works.The Lex Tang video and the open-source clones in the replies look like the actual permission-flow references. I’ll inspect those next.The stunning piece people remember is two different products glued together in one mental model: Coast’s **memory reveal** animation, and Codex Computer Use’s **drag-to-grant permission coach**. Build both as one first-run sequence.

## What the Coast-style onboarding actually is

Coast is a local Mac memory layer: always-on screen capture plus on-device inference on Apple’s Neural Engine so you (and agents) can ask “what did I get done today?” without sending frames to the cloud.

The Skale clip for AttentionInc is a **product motion demo**, not the live app UI. It sells the idea in four beats:

1. Empty desktop / wallpaper
2. Logo birth (stacked ovals → `coast`)
3. Command bar: “what did I get done today?”
4. The day explodes into real windows (calls, docs, feeds), then a calm “Welcome to Coast”

That is the emotional onboarding. The **functional** onboarding is the permission coach from Lex Tang’s clip of Codex Computer Use.

## Technologies to use

**In-app product (what users actually launch)**
- Native **Swift + SwiftUI** window + menu bar
- **ScreenCaptureKit** for capture (not the old `CGDisplayStream` path if you can avoid it)
- TCC APIs: `AXIsProcessTrustedWithOptions`, `CGPreflightScreenCaptureAccess()`, `CGRequestScreenCaptureAccess()`
- Deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and `Privacy_ScreenCapture`
- Capture/encode: ScreenCaptureKit → HEVC/H.264, idle-stop, exclude password apps
- Local enrichment: Apple **Neural Engine** via Core ML / MLX
- Stable **Developer ID** signing so TCC grants survive rebuilds
- Optional agent surface: local CLI + MCP

**The Skale-style hero animation**
- Design in After Effects / Rive / Lottie
- Ship as **Rive** or **Lottie** inside the SwiftUI welcome window so it is interactive, not a muted MP4
- Recorded marketing versions: Screen Studio / Cap / OpenScreen

Do not try to fake System Settings. Coach *over* the real Settings window.

## The Lex Tang / Codex permission flow, step by step

This is the flow in [the Lex Tang post](https://x.com/lexrus/status/2044929029334245819). It is Codex Computer Use, not Coast, but it is the reference implementation for “make TCC feel designed.”

1. **In-app permission card** stays on screen: “Enable Codex Computer Use,” with two rows — **Accessibility** and **Screenshots** — each with its own Allow button. Copy says permissions are used only when the user asks Codex to act.
2. User hits **Allow** on Accessibility. App opens **System Settings → Privacy & Security → Accessibility**.
3. A **floating helper chip** docks under the Settings list: “Drag Codex Computer Use to the list above to allow Accessibility,” with the app icon as a draggable proxy. User adds/toggles the app.
4. The original card flips that row to **Done**. Settings stays open; the card does not steal focus in a way that hides the list.
5. User hits **Allow** on Screenshots. App opens **Screen & System Audio Recording**. Same drag helper, now labeled for screenshots.
6. After the toggle, macOS shows **Quit & Reopen** — screen recording does not attach to a live process until relaunch.
7. On next capture, macOS may show the **private window picker / bypass picker** alert (“requesting to bypass the system private window picker and directly access your screen and audio”). User must Allow.
8. Only then does computer-use start: screenshot + Accessibility tree, clicks in Music, live “Looking at / Clicking in” status.

Hard constraints you must design for:
- Screen Recording cannot be pre-granted by MDM. The user has to click.
- Grant is tied to **code signature / cdhash**. Rebuilds look like a new app and loop forever unless you detect stale TCC and tell the user to toggle off/on + full quit.
- Sequoia/Tahoe re-prompt periodically. Treat re-approval as a first-class state, not an error.
- Ask Accessibility **before** Screen Recording. If Screen Recording is granted first, some setups get fragile. That is the exact question in the Lex thread.

## How to build this onboarding in your app

Treat first launch as a state machine, not a slideshow.

`Welcome → Why local memory → PermissionCoach(AX) → PermissionCoach(Screen) → QuitRelaunch → FirstCapturePulse → FirstQuery`

Implementation rules:
- Keep a persistent, always-on-top **coach window** while Settings is frontmost.
- Poll `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` every ~0.5s while the coach is visible; flip rows live.
- Present a **draggable NSView** that is a proxy of your `.app` bundle so users can drop it into the TCC list (this is what Permiso clones).
- After Screen Recording, **you** offer Quit & Reopen; do not fight the system sheet.
- Exclude password managers, banking, and lock screens from capture from minute one. Show that exclusion during onboarding or trust dies.
- First success must be immediate: after relaunch, run a 3-second capture and answer one canned query (“what’s on my screen right now?”). Permission without payoff feels like spyware.

## Suggested onboarding animation scenario

**0:00–0:04 · Quiet desktop**  
Your real wallpaper. Menu bar gets a tiny Coast/your-app pulse. No modal yet.

**0:04–0:08 · Logo birth**  
Four stacked ovals rise from the dock like a tide, merge into the wordmark. This is the Skale beat. Use Rive so the mark can later become the recording indicator.

**0:08–0:14 · The ask**  
A single command field fades in, already typed: “what did I get done today?” Cursor blinks. Do not auto-submit.

**0:14–0:18 · Trust before capture**  
Field morphs into the permission card. Two rows only. Under them: “Frames stay on this Mac. Agents query a local index. You can pause anytime.”

**0:18–0:40 · Coach, not animation**  
This is the Lex flow. Animation stops being cinematic and becomes a **live overlay** on System Settings. Helper chip, drag, Done checkmarks, then Quit & Reopen.

**0:40–0:48 · First memory**  
On relaunch, the command field returns and *answers* using the last 10 seconds: a small stack of real window thumbnails fans out (meetings, editor, browser), then collapses into one recap line.

**0:48–0:55 · Hand-off**  
Welcome sheet: Pause / Exclude apps / Ask your agent. Menu-bar icon turns from idle to “listening.” Onboarding never shows again unless a permission drops.

Motion language: slow tide, not bounce. One accent color (Coast cyan). Windows should feel like they were already there, not spawned from a logo.

## Agent prompt

Use this as the system prompt for the engineer/design agent that will implement it.

```text
You are implementing first-run onboarding for a local-first macOS memory / computer-use app.

Goal
Ship a two-act first launch:
1) A short Rive/Lottie hero that explains local screen memory.
2) A live TCC permission coach matching Codex Computer Use (see zats/permiso): in-app checklist + floating drag helper over System Settings.

Product constraints
- Native Swift/SwiftUI, Developer ID signed, stable bundle ID.
- Required TCC: Accessibility then Screen Recording.
- Capture with ScreenCaptureKit. Inference on-device. Nothing leaves the machine unless the user later enables a cloud path.
- Exclude password managers, 1Password/Bitwarden/Keychain, banking apps, and lock screens by default.
- Detect stale TCC (grant row ON but CGPreflightScreenCaptureAccess() == false after a rebuild). Instruct: toggle OFF/ON, full Quit, relaunch. Never loop the system prompt.

Permission coach behavior
- Window: “Enable [App]” with rows Accessibility and Screen Recording.
- Allow on a row: open the exact Settings pane, show a floating “Drag [App] to the list above” chip containing a draggable app-icon proxy.
- Poll permission state twice a second; mark row Done without dismissing Settings.
- After Screen Recording grant, handle Quit & Reopen, then the private-window-picker bypass alert.
- Do not request Screen Recording until Accessibility is Done.

Hero animation beats
Quiet desktop → logo birth → command bar “what did I get done today?” → permission card → (real Settings coach) → first local recap from a 3s capture.

Success criteria
Cold Mac, never granted: user completes both permissions in under 90 seconds without leaving the coach. After relaunch, one query returns a real recap. Menu bar shows pause/exclude. Re-approval on Sequoia/Tahoe is a first-class resume state.

Do not
Fake System Settings. Pre-grant Screen Recording. Capture before consent. Store frames off-device. Use ad-hoc signing for permission testing and then ship that binary.
```

## GitHub references and implementations

Closest clones of the Lex Tang / Codex drag-to-grant UI:

- [zats/permiso](https://github.com/zats/permiso) — explicit recreation of that X post; `PermisoAssistant.shared.present(panel:)`
- [harichen/enable-permission](https://github.com/harichen/enable-permission) — app picker + drag helper, built on Permiso
- [smitmartijn/qdragtogrant](https://github.com/smitmartijn/qdragtogrant) — Qt/C++ version of the same overlay, plus cdhash drift + `tccutil reset`

Full permission onboarding kits:

- [arpitagarwal1301/PermissionPilot](https://github.com/arpitagarwal1301/PermissionPilot) — SwiftUI wizard, 16 TCC types, deep links, Sequoia relaunch notes
- [MacPaw/PermissionsKit](https://github.com/MacPaw/PermissionsKit) — older AppKit wrapper (FDA-oriented; not Screen Recording-first)
- [karaggeorge/mac-screen-capture-permissions](https://github.com/karaggeorge/mac-screen-capture-permissions) — Electron/Node: check, prompt, open Settings, reset
- [bvanpeski/ScreenNudge](https://github.com/bvanpeski/ScreenNudge) — MDM/IT prompt script that reads TCC.db

Capture + onboarding apps to steal UX from:

- [getopenscreen/openscreen](https://github.com/getopenscreen/openscreen) — Electron + `NSScreenCaptureUsageDescription` + Screen/Accessibility first-run
- [Glyph-Software/OpenScreenStudio](https://github.com/Glyph-Software/OpenScreenStudio) — dedicated permissions window vs HUD
- [danieloquelis/EasyDemo](https://github.com/danieloquelis/EasyDemo) — native Swift recorder with a permission flow
- [CapSoftware/Cap](https://github.com/CapSoftware/Cap) — useful issue history on Sequoia + unsigned-binary TCC failure

Computer-use stacks (the thing after permissions work):

- [paralym/codex-computer-use-cli](https://github.com/paralym/codex-computer-use-cli) — ScreenCaptureKit + AX, `permissions --request`
- [TheGuyWithoutH/mac-computer-use](https://github.com/TheGuyWithoutH/mac-computer-use) — MCP + Swift helper

Apple-level references in the wild: Chromium’s `permissions_utils.mm` (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`), and ScreenCaptureKit’s `SCStreamErrorUserDeclined`.

Start with **Permiso + PermissionPilot + ScreenCaptureKit**. Use the Skale animation only as the first 10 seconds of emotion; spend the rest of the engineering budget on the coach, signing, and the first successful local recap.
