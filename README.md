# komPX

Compress images and videos locally on your Mac. Drop media into one queue, choose a quality preset, and keep control of where the results go.

![komPX showing its drag-and-drop queue](docs/images/kompx-ui.jpg)

## Features

- Process images and videos together in one queue, with progress and per-file results.
- Choose **High**, **Balanced**, or **Smallest** quality, from up to 4K through 1080p to 720p.
- Pause, resume, or safely cancel a batch. komPX can offer to restore unfinished work when you reopen it.
- Review verified, smaller output before it is saved. If compression does not reduce a file's size, komPX keeps the original.
- Choose between replacing originals, keeping a separate `_compressed` copy, or saving to a custom folder.
- Process media on your Mac; your files are not uploaded to a service.

**Images:** JPG, JPEG, HEIC, HEIF, PNG, and TIFF. **Video:** MP4, MOV, and M4V. Multi-page images and videos with extra audio or video tracks are skipped to preserve their contents.

Requires **macOS 14 or later**. The app runs natively on **Apple Silicon and Intel**.

## Install

### Homebrew

```sh
brew install --cask macfreeapps/tap/kompx
```

### Download

Download the latest [universal DMG](https://github.com/macfreeapps/kompx/releases/latest), open it, and drag **komPX** into **Applications**.

komPX is ad-hoc signed and is not notarized by Apple. On first launch, macOS may ask you to approve it in **System Settings → Privacy & Security → Open Anyway**.

## Use

Add files by dropping them onto the queue or choosing them in Finder. Dropping a folder adds the supported media files it contains. Choose a preset, then select **Compress**.

By default, a smaller result replaces the original, and the original moves to Trash. To keep your original, turn on **Add _compressed suffix** or select a custom output folder. If the result is not smaller, the original stays in place.

For images, the default output is HEIC. JPG/JPEG can also keep their original format. PNG/TIFF conversion uses HEIC when available.

## Build from source

Open `komPX.xcodeproj` in Xcode, or build a universal app from Terminal:

```sh
xcodebuild -project komPX.xcodeproj -scheme komPX -configuration Release \
  -derivedDataPath build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

The optional runtime smoke test creates temporary media fixtures and requires Xcode and FFmpeg:

```sh
scripts/smoke-test.sh
```

## Support

If komPX is useful to you, [buy me a bánh mì](https://buy-me-a-banhmi.vercel.app/#donate). Thank you for supporting its development.

Made by [@tarudesu](https://github.com/tarudesu).
