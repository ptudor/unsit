# Localization

The app's text lives in String Catalogs under `packaging/Localization`, one per
part of the interface:

| Catalog | Holds | Swift lookup |
|---|---|---|
| `Extraction.xcstrings` | Main window, queue, results, extraction errors, the quit alert | `Strings.extraction(...)` |
| `Menus.xcstrings` | The menu bar | `Strings.menus(...)` |
| `Updates.xcstrings` | The update sheet, its messages, and update errors | `Strings.updates(...)` |
| `InfoPlist.xcstrings` | The Finder file kind and the copyright line | read by macOS |

There is deliberately no `Localizable.xcstrings`. A bare SwiftUI literal such as
`Text("Done")` looks in that default table, so without one it would silently
stay English; `make check` rejects such literals instead. The wordmark "Unsit"
on its own is never translated. The command-line tool, its diagnostics in the
Details sheet, the `(extracted)` folder suffix, and `Help.html` are English in
every language. Help is the one still to be done: see `HELP IS NOT LOCALIZED YET`
in `scripts/package.py`.

## Adding or changing a string

1. Call `Strings.<table>("English wording", arguments...)` with a plain string
   literal. The English wording is the key. Use `%@` for text and `%lld` for a
   count; number the arguments (`%1$@`, `%2$@`) when there are several, so that a
   translation can reorder them. Build a sentence in one string, never by
   joining pieces.
2. Add the key to the matching catalog by hand, in case-insensitive order, with
   `"extractionState" : "manual"` and a `comment`. The comment is all a
   translator sees: say where the text appears, what each argument is, and which
   sense of an ambiguous or technical word is meant ("archive", "extract",
   "recover", "release", "check"). A `%lld` key also needs English `one` and
   `other` plural variations, even when both read the same, so that other
   languages can vary the form.
3. Run `make check`. `scripts/check-localization.py` compares the source, the
   catalogs, and `Info.plist` in both directions, counts format arguments at
   every call, and checks every translation's placeholders against its key.

Changing the English wording changes the key, which discards its translations.
To remove a string, retire its key in the translation pipeline first, then delete
the catalog entry; otherwise the next pull brings it back.

Nothing extracts keys from the source, and Xcode never edits these files: they
sit outside every SwiftPM target, and `swift build` would only copy a catalog
without compiling it. `scripts/package.py` compiles each one with
`xcstringstool` into `<language>.lproj` tables inside the app, writes the English
tables itself so that they do not vary with the Xcode that built the app, and
`scripts/verify-release.py` requires every bundled language to carry every table.

## Translations

Translations are produced outside this repository and arrive as edits to the same
catalog files. Do not translate by hand in a pull request; improve the English
wording or its translator comment instead, and report a wrong translation as an
issue naming the language and the text.

## Trying a language

```sh
make app
open -n dist/Unsit.app --args -AppleLanguages '(de)'
```

A development run (`swift run UnsitApp`) has no string tables. It shows the
English keys, so a count reads in its plural form ("Extracted 1 files"). Check
real wording, text that no longer fits, and right-to-left layout in a packaged app.
