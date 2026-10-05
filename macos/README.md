# Ritrovo

Ritrovo is a native macOS app (SwiftUI) for recovering photos, videos and documents from disks, memory cards and disk images.

**The recovery engine is [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) by Christophe Grenier (CGSecurity).** Ritrovo is only an interface: every file is found and rebuilt by the PhotoRec command line program bundled inside the app, so recovery results are the same as PhotoRec's own. Ritrovo is not an official CGSecurity product.

## How it works

- The app runs the bundled `photorec` binary in batch mode (`/cmd`), reads its progress from the JSON log (`/logjson`) and watches the output folders to show the recovered images.
- Partitions are detected by PhotoRec itself, so the choice offered by the app is exactly what PhotoRec sees.
- Stopping sends SIGINT: PhotoRec saves its session (`photorec.ses`) like in the terminal.
- Raw disks need root: the app asks for the administrator password through the standard macOS prompt and only reads the disk.
- File formats come from the PhotoRec sources (`tools/gen_formats.py`), with search and quick selections.
- Image filters (minimum width, height, megapixels and file size for JPG and PNG) use the `image_min_*` options added to PhotoRec in this fork. Images whose dimensions cannot be read from the header are always recovered.

## Build

Requirements: Xcode command line tools, Homebrew `autoconf automake libtool pkgconf cmake`, python3.

```sh
macos/build-app.sh
```

The result is `build-macos/app/Ritrovo.app` and a DMG, universal (Apple Silicon and Intel), macOS 13 or later. The app is signed ad-hoc: on another Mac the first launch needs right click, Open (or removing the quarantine attribute), until it is signed with a Developer ID and notarized.

Logic tests: `cd macos/Ritrovo && swift run RitrovoCoreTests`

## License

GNU General Public License, version 2 or later, like PhotoRec. See `COPYING`.
