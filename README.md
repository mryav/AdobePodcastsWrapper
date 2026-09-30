# Enhance

A small macOS app that runs audio and video files through
[Adobe Podcast Enhance](https://podcast.adobe.com/en/enhance) without you ever
seeing Adobe's website.

Drop or paste a file, watch one progress bar, click the resulting filename to
reveal the enhanced audio in Finder — saved next to the file you started with.

## How it works

1. **ffprobe** inspects the file. If it has a video track (or is in a format
   Adobe's uploader rejects, or is over ~450 MB), **ffmpeg** strips it down to a
   48 kHz stereo AAC `.m4a`.
   Adobe's file input accepts `.mp3 .wav .aac .flac .oga .ogg .m4a` — *not*
   `.mp4` — so video always gets extracted first. Files already in an accepted
   format are uploaded untouched.
2. A hidden `WKWebView` loads podcast.adobe.com. An injected script attaches the
   file to the page's upload control, watches for progress, then clicks Download
   and hands the resulting blob back to the app.
3. The enhanced audio lands in the original file's folder as
   `<original name> (enhanced).wav`.

The web view is fully transparent and click-through. It only becomes visible if
Adobe needs you to sign in, and hides itself again once you have. The login is
kept in the app's own cookie store, so it survives relaunches.

## Building

```sh
./build.sh              # -> build/Enhance.app
./build.sh --install    # also copies it to /Applications
```

Requires Xcode's command line tools and `ffmpeg` on the system
(`brew install ffmpeg`). If ffmpeg lives somewhere unusual, the idle screen
offers a **Locate ffmpeg…** button.

## Using it

| Action | |
|---|---|
| Drop a file on the window | |
| `⌘V` | paste a file copied in Finder |
| `⌘O` | file picker |
| `⌘.` | cancel |

Multiple files are processed one after another.

## When Adobe changes their page

Everything the automation looks for is a heuristic over visible text and ARIA
roles rather than a CSS path, so small redesigns shouldn't break it. If a big
one does, you don't need to rebuild:

1. **Debug → Show Adobe Window** to watch what the automation is doing.
2. **Debug → Open Log** for a step-by-step trace.
3. Copy `Sources/AdobeEnhancer/Enhance/AutomationScript.swift`'s script body to
   `~/Library/Application Support/AdobeEnhancer/automation.js`, edit it, and
   restart. That file wins over the built-in copy.

To iterate without spending a real Adobe conversion, there's a mock page that
imitates the parts of the site the driver depends on:

```sh
python3 -m http.server 8765 --directory Tests/MockEnhancePage
ENHANCER_PAGE=http://127.0.0.1:8765/ build/Enhance.app/Contents/MacOS/Enhance some-video.mp4
```

## Notes

- You need your own Adobe account, and Adobe's usual limits apply (roughly 1
  hour and 500 MB per file, plus whatever quota your account has).
- The app is ad-hoc signed and not sandboxed — it needs to write next to your
  source files and to run ffmpeg.
