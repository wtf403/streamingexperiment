We trying reproduce https://x.com/anupambatra_/status/2042720647055577177



can you reserach if its possible to make ̧MacOS window to flow behind to top edge of the screen? for example we can drag it to the left,right,bottom border but not the top!No — not for normal app windows. macOS deliberately stops you from dragging a window so its title bar goes off the top of the screen or under the menu bar. Left, right, and bottom edges work; the top does not.
Why the top is special

The menu bar is reserved. Apple keeps the title bar reachable so you can always grab, close, or move a window.
Dragging to the top is used for other actions: Mission Control / new Space, and (on Sequoia+) tiling or “fill screen.”
Even with the menu bar set to auto-hide, the constraint usually remains.

This has been consistent for years. Window managers and scripts that try to set a window’s Y position to 0 still get pushed down below the menu bar.
What does work
Upper monitor. If another display is arranged above the current one, you can drag a window up through the top onto that screen. The block is per-display, not a hard physical-screen limit.
Turn off the top-edge gestures so the window at least sits flush under the menu bar instead of maximizing or opening Mission Control:

System Settings → Desktop & Dock → Windows
Off: “Drag windows to menu bar to fill screen”
Off: “Tile by dragging windows to screen edges”

System Settings → Desktop & Dock → Mission Control
Off: “Drag windows to top of screen to enter Mission Control” (added in macOS 15.1)


Terminal equivalent:
Bashdefaults write com.apple.dock enterMissionControlByTopWindowDrag -bool false
killall Dock
Auto-hide the menu bar (Control Center → Menu Bar) gives a little extra room but still won’t let the title bar go off-screen.
Third-party tools
Rectangle, Magnet, and BetterTouchTool can snap a window to the top (maximize below the menu bar) and let you move a window by holding a modifier and dragging anywhere inside it. They generally cannot put a standard titled window above the menu bar — the window server blocks it. BTT’s own docs note that windows cannot be programmatically moved higher than the menu bar.
Only special windows can sit over the menu bar
Apps that create borderless windows or use a high window level (NSMainMenuWindowLevel / NSStatusWindowLevel) can draw over or above the menu bar. That’s how some overlays, widgets, and games work. Regular Safari, Finder, Notes, etc. windows cannot.
Practical takeaway: You can get the window parked right against the menu bar and stop the maximize / Mission Control triggers. You cannot make a normal window hang off the top edge the way it can hang off the other three sides. That’s by design, not a hidden setting.Can I somehow modify existing windows to transform to NSMainMenuWindowLevel / NSStatusWindowLevelShort answer: not for other apps’ existing windows, at least not in a supported way. You can only set NSMainMenuWindowLevel / NSStatusWindowLevel on windows your own process owns. Raising the level also does not reliably let a titled window hang off the top of the screen.
Those two things are different:




















PropertyWhat it controlsDoes it let a Safari/Finder window go past the top edge?Window levelZ-order (always on top of other windows)NoFrame constraint (constrainFrameRect)Whether the title bar may leave the visible area / go under the menu barThis is the actual blocker
Apple documents mainMenu as reserved for the app’s menu, and statusBar for status windows. An app can do window.level = .statusBar on its windows. It cannot reach into Safari and call setLevel: on Safari’s NSWindow.
What public APIs allow
Accessibility / System Events can usually:

move and resize another app’s window
focus it
read title, role, frame

They generally cannot change window level. There is no supported AX attribute for NSWindow.level.
So AppleScript like “set level of window 1 of process Safari” is not a real, supported path.
What people actually use instead
1. Pin-on-top tools (closest practical option)

BetterTouchTool’s “Pin/Unpin Focused Window to Float on Top”, plus apps like Floaty, do the job users usually want: keep a window visible above others.
BTT does not magically rewrite the other app’s NSWindow. The author has said macOS has no real API for that, so BTT keeps a floating replica/stream of the window. That is why pinning can feel a bit odd when you move or click the window. Typical level used is floating (3), not menu-bar / status (24/25). It still will not sit over the menu bar or go off the top like a borderless overlay.
2. Inject into the other process (true setLevel:)

Old approach: Afloat / AfloatX / SIMBL / MacForge load code inside the target app, then that app changes its own window level.
That is the only way to literally transform an existing NSWindow. On current macOS it is fragile: SIP, hardened runtime, and Apple Silicon make injection unreliable. Afloat is effectively dead for modern systems.
3. Private Window Server APIs (yabai-style)

With SIP partially disabled, yabai’s scripting addition can change another window’s layer (below / normal / above) via SkyLight (SLS…) APIs. That is “always on top / always below,” not “this is now a status-bar window,” and it still does not remove the menu-bar frame clamp for titled windows. It is unsupported and breaks across OS updates.
Why menu-bar level still wouldn’t solve the original problem
A titled window at .mainMenu or .statusBar usually:

stacks above normal apps
still gets its frame constrained so the title bar stays below the menu bar
can cover the menu bar only if it is borderless (or similar) and owned by the process that created it

That is how menu extras, HUD overlays, and some widgets work. Finder/Safari windows are not built that way, and you cannot flip that style from the outside.
Practical recommendation
If the goal is “keep this window visible”:

Use BetterTouchTool → Pin/Unpin Focused Window to Float on Top, or a dedicated pin app.
Don’t chase NSMainMenuWindowLevel on foreign windows.

If the goal is still “drag a normal window off the top edge”:

Raising the level will not enable that.
Only a multi-monitor display arranged above this one, or writing your own borderless high-level window, gets content into that region.

You cannot cleanly convert an existing third-party window into a menu-bar-level window without injecting into that app or using private Window Server hooks. Both are unsupported.are there any other ways, like make 1px height virtual monitor?That’s a clever idea — I’ll check whether a tiny virtual display above the main screen actually lets windows cross the top edge, and what else people use.Exploring virtual monitor workaroundsYes — a second display arranged above the real one is the only “legal” way macOS lets a normal window’s frame cross the top edge. A tiny virtual monitor is that idea taken to an extreme. It can work in principle. A 1px strip is a bad version of it.
Why the idea is valid
The rule is not “never leave the physical panel.” It is “the title bar must stay on some display’s visible frame.”
If Display Arrangement has another screen above this one, you can drag a window up onto that screen. Part of the window can then sit on the lower (real) screen and part on the upper one. That is the only supported way a titled window hangs off the top.
A virtual display (CGVirtualDisplay via BetterDisplay, SimpleDisplay, DeskPad, or an HDMI dummy plug) counts as a real extra screen in Arrangement.
Why 1px is a poor target

Virtual displays have practical minimum sizes. 1×N often will not create, or WindowServer will reject/sanitize it.
The title bar would live on a 1px desktop. You then cannot grab, close, or move the window.
The cursor can vanish into an invisible sliver.
Mission Control, Spaces, and “move window to display” get confused.
Extra displays cost GPU/memory and can wake/sleep oddly.

AeroSpace’s docs match this: macOS will not let a window disappear completely off every visible frame; a sliver must remain somewhere.
What is more realistic
Use a short, full-width strip, not 1px. Something like:

1920 × 32 or 1920 × 48 (or your screen width × ~30–50 px)
Created in BetterDisplay → Create New Virtual Screen (custom resolution)
Connect it, do not make it the main display
System Settings → Displays → Arrange… and put that virtual screen flush above the real one, same left edge
Leave it unstreamed / no PIP so it is only an off-panel desktop

Then a window can be dragged so its title bar sits on the strip and the content hangs down over the real screen.
Still expect friction:

Menu bar still catches the drag on the lower display, especially with “Displays have separate Spaces” on. People with a real monitor above hit this too.
Turn off:
Desktop & Dock → Mission Control → Drag windows to top of screen to enter Mission Control
Desktop & Dock → Windows → Drag windows to menu bar to fill screen

If the window still stops at the menu bar, try Displays have separate Spaces = off (log out required). One shared space makes “drag onto the screen above” more reliable.
Do not put the menu bar on the 32px virtual screen. Keep the real panel as main.

Other variants of the same trick



































MethodWhat you getWorth it?BetterDisplay / SimpleDisplay virtual screen aboveInvisible extra desktop above the panelBest software version of your ideaHDMI/DP dummy dongle as a second “monitor,” arranged aboveSame, hardware EDID fakeSame idea, extra dongleDeskPad / BetterDisplay PIP of the virtual screenThe “upper monitor” is a window on the real screenDoes not hang off the physical top; it just moves into another windowStream virtual desktop to the real panel, shifted up (BetterDisplay underscan/offset)Fake a taller desktop and crop the topHeavy; menu bar / Spaces get weirdSidecar / Vision Pro virtual display arranged aboveReal extra screenWorks if you actually have the device
PIP/DeskPad is the wrong tool if the goal is “pixels above the laptop lid.” You need an extra screen in Arrangement that is not drawn on this panel.
Other approaches that are not a virtual monitor

Hide menu bar — still cannot go past the top edge.
Raise window level — z-order only; frame still clamped.
Rotate the display 180° — old screenshot hack; unusable as a daily setup.
Notch hacks / SIP — different problem (fullscreen under the notch), not general window dragging.

Practical takeaway
The virtual-monitor-above trick is the closest legitimate workaround. Use a thin strip (tens of pixels), not 1px, arrange it above, disable top-edge Mission Control / fill-screen, and keep the real display as main.
It will feel like a hack: cursor can get lost on the strip, some apps refuse to straddle displays, and reconnecting displays can shuffle Arrangement. If you only want “window always visible,” pin-on-top (BTT / Floaty) is still less painful than a fake 32px monitor.Can I open macos window hidden (to not show them on mac) or show but just stream window content itself to the electron app/ server?
https://x.com/anupambatra_/status/2042720647055577177That tweet is doing two separate things: drive real macOS windows, and show clones of them in a web canvas. The native windows on the right are still real, visible Safari windows. The left side is tldraw drawing cards that follow those windows (and live cursors). You can get close to “not on my Mac screen” — you cannot reliably make a normal app window fully invisible and keep a live pixel stream.
Fully hidden (orderOut / Hide / show: false)
No, not if you need live content.
If the window is not part of the compositor:

Many apps stop drawing (Chrome video, Metal/GL, games).
ScreenCaptureKit’s single-window stream pauses when the window is minimized.
A window on an inactive Space often keeps a stale still frame; video/GPU content goes black.

“Hidden from the user” and “still rendered” are different. macOS only keeps rendering windows that it thinks are on a real desktop.
What does work: shown to macOS, not shown on your panel
Best pattern for an Electron “agent OS”:

Create a virtual display (BetterDisplay, DeskPad, SimpleDisplay, or CGVirtualDisplay in a native helper).
Move target windows onto that display (Accessibility / AppleScript / your helper).
Leave that display unmirrored on the built-in panel so you don’t see those windows while you work.
Capture either:
that whole virtual display, or
each window with SCContentFilter(desktopIndependentWindow:)

Push frames into Electron (native addon → VideoFrame / WebRTC) or to a server.

That is the same idea DeskPad / BrowserDisplay use: the window is “on a monitor,” so apps keep rendering, but that monitor is only a software screen. SimpleDisplay even calls this “hidden screens.”
Or: keep windows on the real screen, stream only their pixels
Apple’s ScreenCaptureKit rule for a desktop-independent window filter:

Full window content even if covered by other windows
Full content if moved off-screen or onto another display
Stream stops if minimized

So you can leave Safari in a pile on the desktop (or park it on a virtual screen), cover it with your Electron UI, and still get a clean per-window stream — as long as it is not minimized and stays on an active Space.
That matches the tweet more than true invisibility: native windows exist; the React canvas is just another view of them.
Electron / server pipeline

































PieceAPIList windowsSCShareableContent (prefer onScreenWindowsOnly: false if you need off-screen)Capture one windowSCContentFilter(desktopIndependentWindow:) + SCStreamCapture the fake monitorfilter on that SCDisplayInto Electronnative Swift/ObjC module, or desktopCapturer (weaker, window list + thumbnails)To a serverencode H.264/HEVC or send WebRTCMove/resize/clickAccessibility + CGEvent, not the video stream
Permissions: Screen Recording for capture, Accessibility for control. Some apps set sharingType = .none and won’t appear in capture.
Electron webContents.capturePage({ stayHidden: true }) only snapshots your own BrowserWindow, not Safari/Finder.
Practical architecture for a tldraw-style agent OS

Virtual display = staging area for “agent windows”
One SCK stream per interesting window (or one stream of the virtual display)
tldraw nodes show those textures; sync engine shares cursor/window frames
Clicks in the canvas map back to the real window in local coordinates
Do not hide/minimize those windows
Keep that virtual display’s Space active (don’t switch away from it), or video dies

What you should not expect

window.hide() + live 60fps Safari video
Capturing a window that never ordered in
Pixel-perfect isolation without Screen Recording permission
Apps with protected content (Netflix-style, some Electron apps) always being capturable

Bottom line: open the windows on a virtual monitor (or leave them occluded on an active Space), stream window content with ScreenCaptureKit into Electron/WebRTC. That is the supported way. Fully hidden native windows will not keep a trustworthy live stream.explain how real macos windows are streamed to canvasA real macOS window is never “put into” the canvas. The window stays a Window Server object. What the canvas shows is a live copy of its pixels, updated many times per second.
textSafari / Finder / whatever
        │  draws into its backing store
        ▼
Window Server (compositor)
        │  Screen Recording permission
        ▼
ScreenCaptureKit  →  CMSampleBuffer (IOSurface)
        │
        ▼
your app  →  <video> / WebGL / Canvas2D / tldraw image
1. The window already exists as pixels
Every on-screen window has a backing surface. Window Server composites those surfaces into the desktop. ScreenCaptureKit does not scrape the panel with a screenshot loop. It asks Window Server for that window’s surface, already composited, including title bar and shadows if you don’t crop them.
Filter used for “just this window, wherever it is”:
Swiftlet content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let safari = content.windows.first { $0.windowID == theCGWindowID }
let filter = SCContentFilter(desktopIndependentWindow: safari!)
That filter keeps delivering the full window even if another window covers it, or it sits on another display. Minimized windows pause. Inactive Spaces often freeze or go black for video.
2. Frames come out as GPU buffers, not PNGs
You configure size/fps, start an SCStream, and implement SCStreamOutput:
Swiftfunc stream(_ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // sampleBuffer.imageBuffer → CVPixelBuffer → IOSurface
}
Each complete frame is a CVPixelBuffer backed by an IOSurface (shared GPU memory). Attachments (SCStreamFrameInfo) tell you:

























MetadataWhy it mattersstatus.complete = new picture; .idle = nothing changedcontentRectWhere the real window sits inside the buffer (buffer is often larger)contentScale / scaleFactorRetina vs stream resolutiondirtyRectsOnly these regions changed — crop/encode those
Chrome had to crop to contentRect or you get garbage around the window. Same if you blit the whole IOSurface into a canvas.
3. How those pixels reach a canvas
Three common bridges:
A. Electron / Chromium (easiest for a web UI)

Main process lists sources, renderer treats the window like a camera:
JavaScriptconst sources = await desktopCapturer.getSources({ types: ['window'] })
const stream = await navigator.mediaDevices.getUserMedia({
  audio: false,
  video: {
    mandatory: {
      chromeMediaSource: 'desktop',
      chromeMediaSourceId: sources.find(s => s.id.includes(windowId)).id
    }
  }
})
video.srcObject = stream
Under the hood Electron uses ScreenCaptureKit on modern macOS. You then either:

leave it as a <video> (tldraw can wrap a video/HTML element), or
ctx.drawImage(video, 0, 0) each animation frame, or
new VideoFrame(video) into WebGL/WebGPU.

B. Native helper → Electron (what serious “agent OS” apps do)

Swift captures IOSurface → wrap as CVPixelBuffer → send over IPC, or publish a CMSampleBuffer into an AVSampleBufferDisplayLayer / encode H.264 and pipe into WebRTC. Zero-copy path: IOSurface → Metal texture → WebGPU/WebGL texture. No PNG, no JPEG.
C. Screenshot loop (what many prototypes actually ship)

SCScreenshotManager.captureImage or screencapture -l <windowID> every 100–250ms, Image/Blob into tldraw. Looks like the tweet at low motion, dies on video and costs CPU.
The tweet’s left pane is almost certainly B or C mapped onto tldraw shapes: each card is a node whose fill is the latest frame of one CGWindowID. Moving the card does not move the native window unless you also send an Accessibility set position command.
4. Canvas coordinates ≠ window coordinates
Two spaces you must keep in sync:
textnative window frame   (Cocoa points, top-left of that display)
        ↕  scale + contentRect
captured buffer       (pixels)
        ↕  how you draw it in tldraw
canvas shape          (tldraw page coords)
Click at canvas point P:

Map P into the shape’s local 0–1 box
Multiply by the window’s content size (not the IOSurface size)
Add the window’s screen origin
Post a CGEvent click there

Cursors in the tweet are the same idea on a second channel: tldraw presence, not the macOS pointer, unless you also warp the real cursor.
5. What “streamed to canvas” is not

The NSWindow is not parented into Chromium.
CSS cannot style Safari’s title bar; you only see a bitmap of it.
Hiding the real window often stops the stream. Park it on a virtual display or leave it occluded instead.
sharingType = .none windows never appear.
You need Screen Recording (pixels) and Accessibility (move/click). Different TCC prompts.

End-to-end for one Safari window → tldraw card

Resolve CGWindowID (SCK list or CGWindowListCopyWindowInfo).
Start SCStream with desktopIndependentWindow.
On .complete frames, crop to contentRect.
Publish texture / VideoFrame / JPEG to the renderer.
tldraw shape id = windowID draws that texture.
Shape resize/drag → Accessibility set frame on the real window (optional).
Shape click → map to screen point → CGEvent.
Sync engine replicates shape transform + maybe a compressed frame for remote users.

Remote multiplayer usually cannot ship raw 60fps IOSurfaces. Locals see the live SCK stream; remotes see a downscaled, dirty-rect, or keyframe version — or only the window chrome and a cursor, if you do not want to send pixels off-machine.so, I wouldn't able to stream real macos windows to canvas and interact with them on canvas?You can. That tweet is doing exactly that. The limits from earlier were about hiding windows or shoving them past the menu bar — not about streaming or clicking them from a canvas.
What works

Stream a real window’s pixels into a <video>, Canvas2D, WebGL, or a tldraw shape (ScreenCaptureKit / Electron desktopCapturer).
Interact from the canvas: map the click/drag on the shape back to the real window with Accessibility + CGEvent (click, type, move, resize).
Keep the real window on a virtual display or covered on an active Space so your Mac desktop stays clean, while the canvas is the thing you look at.

Locally this is a solved pattern: capture pixels on one pipe, send input on another.
What does not work (easy to mix up)





























You wantRealityWindow fully hidden / minimized and still liveStream pauses or goes staleThe canvas is the NSWindowNo — it is a video of itClick the canvas and macOS routes the event by itselfNo — you must translate coords and inject eventsCSS-style the native title barNo — bitmap onlyDo this without Screen Recording + AccessibilityNo
Mental model
textreal Safari window  ──pixels──►  canvas card
real Safari window  ◄─clicks──  canvas card
Two windows exist: the native one (must keep rendering) and the fake one (what you use). They stay in sync only because your app copies frames one way and input the other way.
So: stream + interact on canvas = yes.

Invisible-to-macOS yet still live = no. Park the real windows on a virtual screen instead of hiding them.
