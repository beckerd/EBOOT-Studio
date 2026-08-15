# EBOOT Studio

<img width="200"  alt="EBOOT Studio" src="https://github.com/user-attachments/assets/dbe63c60-ffb6-4996-b28b-d7d8cc50128f" />



A native macOS app for customizing PSP EBOOT artwork and converting PlayStation 1 disc images into PSP `EBOOT.PBP` files.

EBOOT Studio is a GUI wrapper around two existing projects — [pop-fe](https://github.com/sahlberg/pop-fe) and Neill Corlett's `unecm` — with their conversion logic ported to Swift so everything runs natively, no external tools required.

The code for EBOOT Studio was written by Claude Fable 5, Anthropic's AI model. If you are not comfortable with AI-written code, this is not a project for you.

<img width="400"  alt="Screenshot 2026-08-15 at 6 40 38 PM" src="https://github.com/user-attachments/assets/1faff90e-0f0d-44d4-ad93-a98b8a0a62d7" />

## Features
<img width="400" alt="Screenshot 2026-08-15 at 6 58 19 PM" src="https://github.com/user-attachments/assets/a0faeea8-d848-4a8c-b882-9aa03aff782b" />

- **Edit an existing PBP** — open any `EBOOT.PBP` and:
  - Replace the game icon (`ICON0.PNG`), menu background (`PIC1.PNG`), and info panel (`PIC0.PNG`)
  - Rename the title shown on the PSP (`PARAM.SFO`)
  - Export the existing images


<img width="400"  alt="Screenshot 2026-08-15 at 6 41 00 PM" src="https://github.com/user-attachments/assets/5dc8dbf9-3e28-48be-adaa-d46777a09423" />

- **Convert PSX → PSP** — turn a PS1 disc rip into a ready-to-use `EBOOT.PBP`:
  - BIN/CUE, CloneCD (CCD/IMG/SUB), plain ISO/IMG, and ECM-compressed images
  - Multi-track rips split across several BIN files
  - Multi-disc games (up to 5 discs in one EBOOT)
  - LibCrypt subchannel injection from `.sub` files
  - Optional swap of the POPS launch splash for the classic PlayStation boot screen


## Download

Grab `EBOOT Studio.app` from the [Releases](../../releases) page. The app is signed and notarized, so it runs out of the box on both Apple Silicon and Intel Macs.

## Usage

1. Launch the app and drop your disc files (or an `EBOOT.PBP`) anywhere on the window.
2. For conversions: set the title and disc ID, pick an opening screen, and hit **Convert…**.
3. Copy the resulting `EBOOT.PBP` to your PSP at `PSP/GAME/<anything>/EBOOT.PBP`.

Games converted this way run under POPS, Sony's official PS1 emulator, on a PSP with custom firmware.

## Building

Open `EBOOT Studio.xcodeproj` in Xcode and build the *EBOOT Studio* target. No package dependencies. The project has no development team configured — select your own team under *Signing & Capabilities* (or leave it empty and sign to run locally).

## Legal

This project contains no game content. Use it only with backups of discs you own.

The bundled popstation template blobs (`Resources/_*.bin`) originate from the pop-fe project. "PlayStation" and "PSP" are trademarks of Sony Interactive Entertainment; this project is not affiliated with or endorsed by Sony.

## Credits

- [pop-fe](https://github.com/sahlberg/pop-fe) by Ronnie Sahlberg (LGPL-2.1) — the PSX→PSP converter, CUE/CCD parsing, and template blobs are ported from it
- `unecm.c` by Neill Corlett (GPLv2) — the ECM decoder is a Swift port
- The PSP homebrew community's documentation of the PBP and PSAR formats

## License

GPL-2.0 — see [LICENSE](LICENSE). Portions derived from LGPL-2.1 code are redistributed under GPLv2 as permitted by section 3 of the LGPL.
