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

## License

TBD.
