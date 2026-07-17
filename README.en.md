# Goi（語彙）

*[中文说明见 README.md](README.md) · English below*

A native macOS dictionary app built with Swift — dynamic MDX/MDD dictionary
loading, Spotlight-style lookup from the menu bar, lemmatization for English
and Japanese, a familiarity-aware vocabulary book, and two-way Anki sync via
AnkiConnect.

> Status: working prototype.

## Install

Download `Goi.dmg` (universal — Apple Silicon and Intel) from the
[latest release](https://github.com/etng/goi/releases/latest), open it, and drag
Goi into Applications. The current release is not yet notarized with Apple
Developer. If macOS says it can't verify Goi or that the app is damaged, first
make sure the download came from the official release page above, then paste
this into Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Goi.app" && open "/Applications/Goi.app"
```

This only allows the installed copy of Goi; it does not disable Gatekeeper for
other apps. Add `sudo` before `xattr` if macOS reports a permissions error. If
you prefer not to use Terminal, open System Settings → Privacy & Security and
click "Open Anyway". A newly downloaded version may need to be allowed again.
The app checks GitHub for updates and can also be checked from its About page.

## Features

- **MDX/MDD dictionaries, loaded in place** — import uses APFS copy-on-write
  clones: zero extra disk space, and deleting or moving the original files
  never breaks the app.
- **Instant lookup** — menu-bar residence, global hotkey summons a
  Spotlight-style panel; select text in any app and look it up with a hotkey
  (with the surrounding sentence captured as context).
- **Cross-app lookup** — browsers, launchers, and other apps can open
  `goi://search?word=justforfun` to look up a word directly in Goi.
- **Lemmatization** — plurals, tenses, and Japanese conjugations are resolved
  to their base form before lookup.
- **Familiarity model** — every lookup is logged; words you keep looking up
  form a vocabulary book automatically, with manual additions weighted higher.
- **Anki integration** — words sync to Anki as an open, documented note type
  via AnkiConnect; review results flow back to adjust familiarity. Full
  JSON/CSV import & export as well.

## Acknowledgements

- **minilzo** (Markus F.X.J. Oberhumer, GPL-2.0-or-later) — the LZO1X block
  decompressor in MdictKit is a Swift port of its algorithm.
- **readmdict / js-mdict** — reverse-engineering documentation of the MDict
  (MDX/MDD) container format. No code included.
- **RIPEMD-128** — implemented from the public COSIC specification, used for
  encrypted MDX key indexes.
- Optional runtime integrations (not bundled): **mecab + IPADIC** for Japanese
  deconjugation, **Anki + AnkiConnect** for spaced-repetition sync.

## Support the project

If Goi is useful to you, consider buying the author a coffee — scan either
QR code below (they also live on the app's About page). A donor wall is
planned.

| 微信支付 | 支付宝 |
|---|---|
| <img src="assets/donate/微信支付.png" width="220" alt="WeChat Pay"> | <img src="assets/donate/支付宝.jpg" width="220" alt="Alipay"> |

## Built with

Developed with [Claude Code](https://claude.com/claude-code).

## License

[GPLv3](LICENSE).
