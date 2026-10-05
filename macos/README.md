# Ritrovo

Ritrovo is a native macOS app (SwiftUI) for recovering photos, videos and documents from disks, memory cards and disk images.

**The recovery engine is [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) by Christophe Grenier (CGSecurity).** Ritrovo is only an interface: every file is found and rebuilt by the PhotoRec command line program bundled inside the app, so recovery results are the same as PhotoRec's own. Ritrovo is not an official CGSecurity product.

## How it works

- The app runs the bundled `photorec` binary in batch mode (`/cmd`), reads its progress from the JSON log (`/logjson`) and watches the output folders to show the recovered images.
- Partitions are detected by PhotoRec itself, so the choice offered by the app is exactly what PhotoRec sees.
- Stopping sends SIGINT: PhotoRec saves its session (`photorec.ses`) like in the terminal.
- Raw disks need root: the app asks for the administrator password through the standard macOS prompt and only reads the disk.
- File formats come from the PhotoRec sources (`tools/gen_formats.py`), with search and quick selections.
- Image filters (minimum width, height and megapixels for JPG, PNG, GIF, BMP, ICO, WebP, PSD and PCX, minimum file size for every image format) use the `image_min_*` options added to PhotoRec in this fork. Images whose dimensions cannot be read from the header are always recovered.

## Security

Reading a raw disk needs root, so PhotoRec runs as root after the macOS administrator prompt. The helper script `ritrovo-run.sh` creates the destination folder itself, refuses an existing folder or a symbolic link, makes PhotoRec write only inside that folder with relative paths, only checks the stop request for existence, and gives the files back to the user with `chown -R -P`. `RITROVO_*` development variables are ignored for anything run as root.

Known limit: the script and the `photorec` binary run as root from the app bundle, which belongs to the user. Malware already running as that user could modify them before the user types the password. The proper fix is a privileged helper installed with `SMAppService` and checked by its code signature, which needs a Developer ID: planned for the signed releases.

## Build

Requirements: Xcode command line tools, Homebrew `autoconf automake libtool pkgconf cmake`, python3.

```sh
macos/build-app.sh
```

The result is `build-macos/app/Ritrovo.app` and a DMG, universal (Apple Silicon and Intel), macOS 13 or later. The app is signed ad-hoc: on another Mac the first launch needs right click, Open (or removing the quarantine attribute), until it is signed with a Developer ID and notarized.

Logic tests: `cd macos/Ritrovo && swift run RitrovoCoreTests`

## License

GNU General Public License, version 2 or later, like PhotoRec. See `COPYING`.
