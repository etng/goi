# Goi（語彙）

A native macOS dictionary app built with Swift — dynamic MDX/MDD dictionary
loading, Spotlight-style lookup from the menu bar, lemmatization for English
and Japanese, a familiarity-aware vocabulary book, and two-way Anki sync via
AnkiConnect.

> Status: design phase. No code yet.

## Planned features

- **MDX/MDD dictionaries, loaded in place** — import uses APFS copy-on-write
  clones: zero extra disk space, and deleting or moving the original files
  never breaks the app.
- **Instant lookup** — menu-bar residence, global hotkey summons a
  Spotlight-style panel; select text in any app and look it up with a hotkey
  (with the surrounding sentence captured as context).
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

If Goi is useful to you, consider buying the author a coffee — donation QR
codes live in [`assets/donate/`](assets/donate/) and show up on the app's
About page. A donor wall is planned.

## License

[GPLv3](LICENSE).
