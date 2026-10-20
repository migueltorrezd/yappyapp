# Words, snippets and sharing them

YappYapp keeps two lists in the WORDS tab. Both stay on this Mac in the app support folder (`~/Library/Application Support/YappYapp/`), written with private permissions (file 0600, folder 0700).

- `glossary.json`: your spellings. A misheard "sounds like" spelling is swapped for the "write it as" spelling.
- `snippets.json`: spoken phrases that expand to stored text. Say "my email address", get the address.

## How snippets apply

1. The engine transcribes, then the glossary fixes spellings.
2. Optional cleanup and voice commands run.
3. Snippets run last, in one pass, on the finished text.

Rules:

- Exact phrase only. Case and extra spaces do not matter; accents do ("cafe" is not "café").
- Word boundaries on both sides. A letter, digit, apostrophe, hyphen or underscore next to the phrase stops it, so "adresse mail" never fires inside "l'adresse mail".
- Chinese, Japanese, Thai and other scripts written without spaces match anywhere in the sentence.
- A phrase needs at least two words (two characters in a spaceless script) and cannot be all everyday words like "and the".
- Where two phrases overlap, the longer one wins. Inserted text is never expanded again.
- When the whole dictation is just the phrase, the stored text is inserted exactly, without the period the model adds.
- A phrase that is exactly one of your glossary spellings is refused, because the glossary would rewrite it first. A longer phrase that contains a misheard spelling still matches after the glossary fixes it.

## snippets.json

A JSON array. `id` is optional on import.

```json
[
  { "id": "0D5B6C1E-3F7A-4E0C-9C55-2B1F1E4C7A10", "trigger": "my email address", "expansion": "you@example.com" }
]
```

A damaged `snippets.json` never blocks launch. It is kept as `snippets.json.unreadable-<time>` and the WORDS tab says so.

## Export

WORDS > EXPORT offers two formats. Neither ever contains transcripts, stats, settings or models.

JSON (words and snippets):

```json
{
  "format": "yappyapp-words",
  "version": 1,
  "glossary": [
    { "canonical": "Genial", "variants": ["jenial", "jen yal"], "notes": "Company name" }
  ],
  "snippets": [
    { "trigger": "my email address", "expansion": "you@example.com" }
  ]
}
```

CSV (words only), UTF-8 with a header row:

```csv
write_it_as,sounds_like,notes
Genial,"jenial, jen yal",Company name
```

Sounds-like spellings share one cell, separated by commas (semicolons and `|` also work on import). A cell that starts with `=`, `+`, `-` or `@` is written with a leading apostrophe so a spreadsheet never runs it as a formula; import removes it.

## Import

WORDS > IMPORT reads any of:

- a YappYapp words JSON file (above),
- a plain `glossary.json` or `snippets.json` array,
- a glossary CSV, with or without the header row.

Files over 2 MB are refused, and only the first 5,000 rows are read. Only the fields above are read from each row; anything else in the file is ignored.

Nothing changes until you confirm the preview, which counts new words, words that gain spellings, new snippets, clashes, duplicates and skipped rows. Import is off while the WORDS tab has unsaved edits.

Merge rules:

- Words match on "write it as", ignoring case. Your spelling, casing and notes stay. New sounds-like spellings are added; empty notes are filled.
- Sounds-like spellings that would rewrite normal speech (one character, everyday words) are left out and counted.
- Snippets match on the phrase, ignoring case and spacing. Same text: a duplicate, skipped. Other text: a clash. KEEP MINE (default) keeps your text; USE THEIRS takes the shared text and keeps your entry.
- Snippets that are unsafe, empty or clash with a glossary spelling are skipped and counted.
- Importing your own export changes nothing.
