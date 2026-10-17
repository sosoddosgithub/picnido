# Picnido

**A photo browser for macOS that treats your folders as the library. No import, no cloud, no catalogue that owns your files.**

Hi. I have been a Picasa user for a long time.

I learned photography with Picasa sitting open next to me. It was what I used to keep my photos in order, and when it stopped getting updates all those years ago I kept waiting for someone to make a viewer that felt as good. I never found one.

So Picnido is probably me rebuilding a wheel. That is fine by me. I built it with AI: the whole application was written with WorkBuddy and DeepSeek V4.1. I have used it as my own daily viewer for a while, I think it is genuinely nice to use, and that is why it is on GitHub. I hope you like it.

![The library window](docs/images/library.png)

![Browsing a folder, opening the full-screen viewer, moving along the filmstrip](docs/images/demo.gif)

The short version: you point it at folders you already have, and it shows you what is in them. Nothing is copied, nothing is moved, nothing is uploaded. Close it and your disk looks exactly as it did before.

The name is `pic` + `nido`, Italian for *nest*. Picasa was `pic` + `casa`, *house*: same idea, a home for your pictures.

[简体中文](README.zh-CN.md)

---

## Why this exists

Picasa was discontinued in 2016. Its Mac version was never as good as the Windows one, and the parts that made it pleasant never came back:

- It opened a folder, not a database. No twenty minute import, no "consolidating library", no asking where your originals went.
- It was quick on an ordinary machine and did not need a network.
- You could star, label and caption a photo without converting it or moving it into some private structure.

Picnido does that again on macOS. It works against the files on disk instead of inventing a library format of its own, so everything it knows about a photo, it can relearn by looking at the photo.

---

## Features

### Library

Point Picnido at as many folders as you like. The tree in the sidebar is the library, and subfolders appear as you expand them. A SQLite catalogue caches what has been learned about each file, so a relaunch paints the grid in tens of milliseconds and starts reconciling in the background afterwards.

The sidebar holds All Photos, Starred, Recent Changes, Places, Hidden, your colour labels, the folder tree, albums and tags. The grid takes a thumbnail size, square or masonry, optional folder headings and captions under each tile. Photo Tray is a holding area for batch work: collect photos from anywhere, then act on all of them at once. Search covers filenames, captions and tags, with a date filter alongside.

### Viewer

![The photo viewer](docs/images/viewer.png)

The photo sits centred in the space between the toolbar and the filmstrip, and it does not jump when the chrome auto-hides. Below it is the filmstrip for the current folder, with scroll to zoom, drag to pan and a readout of the real pixel size. Three ways out: click outside the photo, the button in the corner, or `Esc`.

### Editing

Adjustments are non-destructive. They are applied at display and export time, and the original file is untouched until you say so:

crop · straighten · fill light · highlights · shadows · colour temperature · saturation · sharpening · black & white · Sepia · film grain · vignette · plus Picasa's *I'm Feeling Lucky* one-shot fix.

Effects can be copied from one photo and pasted onto another, applied to a whole selection, and undone.

### Animated images

Animated WebP, APNG and GIF play in the grid, in the filmstrip and in the viewer, under a decoder budget that keeps the window responsive. That is what `Vendor/libwebp` is for. The build links libwebp statically, so there is no external image library to install.

### Create

Collage puts several photos on one sheet, with layouts and spacing you can adjust. Movie renders a slideshow, music included, to a video file. Poster and Frame are print-oriented layouts. HTML gallery exports a folder as a self-contained page you can open in a browser, generated in code, so there are no template files to install. Export handles resize, re-encode, rename and metadata.

### Organise

Rename, move, copy and delete run in batches, with a preview of what will happen first. You can fix the capture date when a camera's clock was wrong, and the duplicate finder compares content rather than filenames. Stars, colour labels and captions are written into a `.picasa.ini` sidecar in the folder, so they survive a reinstall and other tools can read them.

---

## Installation

### Download

Two builds ship with every release. Pick the one for your machine:

| Mac | Asset |
|---|---|
| Apple Silicon (M1 and later) | `Picnido-1.3.3.zip` |
| Intel | `Picnido-1.3.3-x86.zip` |

Download from [Releases](https://github.com/sosoddosgithub/picnido/releases), unzip, and drag `Picnido.app` to `/Applications`. Both bundles carry the same identifier, so install one or the other, not both.

**The build is ad-hoc signed, not notarised** (there is no paid Apple Developer account behind it). macOS will refuse the first launch with *"Picnido can't be opened because Apple cannot check it for malicious software"*. That is Gatekeeper, not a crash. To allow it:

- **Right-click the app → Open → Open**, or
- `System Settings → Privacy & Security → Open Anyway`, or
- `xattr -dr com.apple.quarantine /Applications/Picnido.app`

### Requirements

| | |
|---|---|
| macOS | **14.0 Sonoma** or later |
| Architecture | Apple Silicon, and Intel as a separate self-contained build |
| Disk | ~9 MB for the app |

The Intel build needs macOS 14 as well, because the code uses `@Observable`, which does not exist in macOS 13. If your Mac tops out at 13, this will not run, and Rosetta will not change that.

---

## Getting started

1. **Launch Picnido.** The first window is empty by design.
2. **Find Photo Folders…** (`⇧⌘F`) and pick a folder: `~/Pictures`, an external drive, a network share. Pick as many as you like.
3. **Wait for the first scan.** Thumbnails are built once and cached; the second launch is immediate.
4. **Click a photo** to open the viewer, or press `⌘2` to edit.

Nothing is imported. If you delete a file in Finder, it disappears from Picnido on the next scan. If you remove a folder from the sidebar, the files are still exactly where they were.

### Keyboard

| Shortcut | Action |
|---|---|
| `⇧⌘F` | Find photo folders |
| `⇧⌘I` | Import a folder |
| `⌘F` | Search |
| `⌘1` / `⌘2` / `⌘↵` | Library / Edit / Photo viewer |
| `F2` | Rename |
| `⇧⌘D` | Adjust photo date |
| `⇧⌘E` | Export |
| `⌥⌘H` / `⇧⌘H` | Hide photo / show hidden |
| `⇧⌘C` / `⇧⌘V` | Copy / paste all effects |
| `⌘Z` / `⇧⌘Z` | Undo / redo edit |
| `⌘P` | Print |
| `⌘/` | Every shortcut, in one panel |
| `Esc` | Close the viewer |

In the viewer: scroll to zoom, drag to pan, `←`/`→` to move through the filmstrip.

---

## Supported formats

41 extensions, in two families:

| Family | Count | Examples |
|---|---|---|
| Common images | 15 | `jpg` `jpeg` `png` `gif` `tif` `tiff` `bmp` `heic` `heif` `webp` `avif` `psd` `ico` `tga` `jxl` |
| Camera raw | 26 | `cr2` `cr3` `nef` `nrw` `arw` `srf` `sr2` `raf` `orf` `rw2` `rwl` `pef` `dng` `srw` `x3f` `3fr` `fff` `iiq` `mos` `mrw` `erf` `kdc` `dcr` `raw` `nefx` `mef` |

Animated WebP, APNG and GIF are decoded as animations, not as their first frame.

The list lives in one place, `Sources/Picnido/Model/FileTypes.swift`, and the scan, the open panel and *Set as Default* all read from it.

---

## Building from source

Only the Command Line Tools are needed; there is no Xcode project.

```bash
git clone https://github.com/<you>/picnido.git
cd picnido
./build_app.sh release          # → dist/Picnido.app
open dist/Picnido.app
```

`build_app.sh` builds with SwiftPM, assembles the bundle, copies the four `.lproj` tables, signs it ad-hoc and registers it with LaunchServices. Run the script rather than `swift build`: it passes the sandbox and cache paths that SwiftPM needs on a plain CLT install.

**Intel build:**

```bash
./build_app_x86.sh release      # → dist-x86/Picnido.app
```

This cross-compiles for `x86_64` and refuses to assemble the bundle if the payload is not actually x86_64. It stages into `dist-x86/` so it never overwrites the arm build, and it deliberately does not register the bundle with LaunchServices, because a second copy with the same bundle identifier would fight your main install over which app opens a JPEG. It has only ever been exercised under Rosetta 2 on Apple Silicon, never on a real Intel Mac.

`Vendor/libwebp` holds libwebp 1.6.0 as fat static libraries (arm64 + x86_64), so both builds use the same vendored bytes.

---

## Privacy

Picnido makes no network requests. There is no account, no telemetry, no crash reporter, no update check, no analytics, and no code that could send a photo anywhere. Three things get written:

- `~/Library/Application Support/Picnido/`: `library.json` with settings and the folder list, and `index.db` with the metadata catalogue.
- `~/Library/Caches/Picnido/thumbs/`: JPEG thumbnails, safe to delete at any time.
- `.picasa.ini` inside a folder: only when you set a star, label or caption, and only in that folder.

Sandbox is not enabled. The app has to read arbitrary folders and external drives, which is the whole point.

---

## Known limitations

- Ad-hoc signed, so Gatekeeper needs one manual approval per machine.
- No face recognition, no geotag map, no cloud sync, no mobile app.
- Videos are listed but not played; they open in QuickTime.
- The Intel build is cross-compiled and has never been run on real Intel hardware. It is verified under Rosetta 2 on Apple Silicon, which is not the same thing.
- Raw decoding goes through ImageIO, so it is only as good as the system's support for your camera.
- Interface is in English, 简体中文, 日本語, 한국어. The menu bar follows the system language rather than the in-app picker.

---

## Contributing

Issues and pull requests are welcome. Two things worth knowing before you send one:

- The verification scripts come first. `work/verify_*.sh` drive the app from outside the process with window lists, geometry reports and PNG captures, because "it looks right" is not a check. If a change moves things around or alters behaviour, it is expected to come with a rule that can fail.
- Read the comment above the line you are about to change. The comments here explain why a thing is the way it is, and the ones carrying a `⚠️` mark a regression that already happened once. Several of them exist because the obvious implementation was tried first and was wrong.

---

## Licence

MIT, see [LICENSE](LICENSE).

Bundled third-party code:

| Component | Licence |
|---|---|
| libwebp 1.6.0 (`Vendor/libwebp`) | BSD 3-Clause, © Google Inc. |

---

<p align="center"><sub>Not affiliated with Google. Picasa is a trademark of Google LLC.</sub></p>
