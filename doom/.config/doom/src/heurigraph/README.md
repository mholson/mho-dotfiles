# Heurigraph Emacs suite

The Emacs suite is intentionally thin: Emacs handles authoring ergonomics and
completion, while the `heurigraph` CLI remains the source of truth for ids,
the project-owned ontology, validation, graph extraction, HTML generation, PDF
generation, and suggestion promotion. Taxon, subject, predicate, and structure
prompts are populated from the forest's resolved ontology rather than a global
vocabulary.

Configure one durable graph namespace in the forest's `heurigraph.toml`:

```toml
[ids]
default_prefix = "mho"
```

`heurigraph-new` delegates blank-ID allocation to that setting. Selecting a
subject affects metadata and initial folder placement, never the permanent ID
prefix. Journal and weeknote commands create sources under `notes/journal/`
and `notes/weeknotes/` respectively.

## Files

- `heurigraph.el` — main CLI bridge and authoring commands.
- `heurigraph-mode.el` — optional minor mode with a `C-c h` keymap.
- `heurigraph-lsp.el` — forest-aware lsp-mode add-on and Eglot helper.
- `heurigraph-pkg.el` — package metadata for local package installation.

## Minimal setup

```elisp
(add-to-list 'load-path "~/src/heurigraph/emacs")
(require 'heurigraph)
(require 'heurigraph-mode)
(require 'heurigraph-lsp)
(setq heurigraph-executable "heurigraph")
(setq heurigraph-notes-directory "~/math/heurigraph")
(add-hook 'typst-ts-mode-hook #'heurigraph-enable-for-typst)
(add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-collection)
(add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-ontology)
(add-hook 'toml-mode-hook #'heurigraph-enable-for-collection)
(add-hook 'toml-mode-hook #'heurigraph-enable-for-ontology)
```

## Doom Emacs 30.2 setup

Use the current Doom release (`doom upgrade`) with Emacs 30.2. Add this to
`config.el`:

```elisp
(use-package! heurigraph
  :load-path "~/src/heurigraph/emacs"
  :config
  (setq heurigraph-executable "heurigraph"
        heurigraph-notes-directory "~/math/heurigraph"))

(use-package! heurigraph-mode
  :after heurigraph
  :load-path "~/src/heurigraph/emacs"
  :hook ((typst-ts-mode . heurigraph-enable-for-typst)
         (toml-ts-mode . heurigraph-enable-for-collection)
         (toml-ts-mode . heurigraph-enable-for-ontology)
         (toml-mode . heurigraph-enable-for-collection)
         (toml-mode . heurigraph-enable-for-ontology))
  :config
  (heurigraph-doom-setup-keybindings))
```

Restart Doom after updating `config.el`. Heurigraph's Doom shortcuts are under
`SPC e`; the portable `C-c h` map remains available.

| Doom key | Command |
|---|---|
| `SPC e n` | New tree |
| `SPC e p` | New page |
| `SPC e c` | New content page |
| `SPC e j` | New journal entry |
| `SPC e W` | New weeknote |
| `SPC e D` | New CeTZ diagram from the bundled template |
| `SPC e i` | Insert a diagram with editable image parameters |
| `SPC e M` | Insert a managed non-CeTZ image by `img-XXXX` ID |
| `SPC e A` | Add subjects from the project ontology |
| `SPC e f` | Find node |
| `SPC e l` | Insert link |
| `SPC e t` | Insert transclusion |
| `SPC e r` | Insert namespaced assertion |
| `SPC e R` | Rename an id safely |
| `SPC e v` | Validate |
| `SPC e b` / `SPC e B` | Build web / web + PDFs |
| `SPC e w` | Watch |
| `SPC e g` | Open graph page |
| `SPC e O` | Open a project ontology file |
| `SPC e F` | Refresh ontology/title completions and validate |
| `SPC e P` | Compile PDF |
| `SPC e L` | Start the language server |
| `SPC e I` | Refresh the language-server index |

## Important commands

| Command | Purpose |
|---|---|
| `heurigraph-new` | Create a typed id-bearing tree. |
| `heurigraph-new-page` | Choose content, journal, or weeknote. |
| `heurigraph-new-content` | Create a content page in the project-wide `prefix-XXXX` sequence. |
| `heurigraph-new-journal` | Create a journal entry in the project-wide `prefix-XXXX` sequence. |
| `heurigraph-new-weeknote` | Create `YYYY-WXX`, defaulting to the current ISO week. |
| `heurigraph-new-diagram` | Create and open the next `cetz-XXXX` CeTZ source. |
| `heurigraph-insert-diagram` | Insert a diagram with editable alt text, width, and caption. |
| `heurigraph-import-image` | Copy an external image into `images/` under the next `img-XXXX` ID. |
| `heurigraph-rename-image` | Rename a file already in `images/` to the next managed ID. |
| `heurigraph-insert-image` | Look up a managed image by ID and insert its `#image(...)` call. |
| `heurigraph-add-subjects` | Add one or more project-ontology subjects to the current tree. |
| `heurigraph-find-node` | Search titles, ids, subjects, taxons, and keywords. |
| `heurigraph-insert-link` | Search by title and insert `#link-to("id", text: "Title")`. |
| `heurigraph-insert-transclusion` | Search by title and insert `#transclude("id")`. |
| `heurigraph-insert-assertion` | Insert a namespaced ontology assertion. |
| `heurigraph-ontology-open` | Open a TOML file under the project ontology. |
| `heurigraph-ontology-refresh` | Validate sources and regenerate ontology completion data. |
| `heurigraph-refresh-completions` | Refresh ontology/title data and validate the forest. |
| `heurigraph-validate` | Validate ids, ontology, assertions, metadata, and pages. |
| `heurigraph-build` | Build static HTML. |
| `heurigraph-build-all` | Build HTML and PDFs. |
| `heurigraph-watch` | Rebuild on save and optionally serve locally. |
| `heurigraph-open-graph-page` | Open generated interactive graph navigation. |
| `heurigraph-pdf` | Compile the current/default tree to PDF. |
| `heurigraph-agent-context` | Export LLM-ready graph context. |
| `heurigraph-suggest-list` | Review pending semantic assertion suggestions. |
| `heurigraph-rename-id` | Preview and safely apply a graph-wide tree-id rename. |

## Default keymap

Enable `heurigraph-note-mode` and use `C-c h`:

| Key | Command |
|---|---|
| `C-c h n` | New tree |
| `C-c h p` | New page |
| `C-c h c` | New content page |
| `C-c h j` | New journal entry |
| `C-c h W` | New weeknote |
| `C-c h D` | New CeTZ diagram |
| `C-c h i` | Insert a CeTZ diagram image |
| `C-c h M` | Insert a managed non-CeTZ image by ID |
| `C-c h A` | Add subjects from the project ontology |
| `C-c h V` | Toggle explicit public/private metadata |
| `C-c h f` | Find node |
| `C-c h l` | Insert link |
| `C-c h t` | Insert transclusion |
| `C-c h r` | Insert a namespaced assertion |
| `C-c h R` | Insert `math:depends_on` |
| `C-c h u` | Insert `math:uses` |
| `C-c h e` | Insert `math:enables_method` |
| `C-c h x` | Insert `edu:solution_to` |
| `C-c h s` | Insert `edu:strategy_for` |
| `C-c h m` | Insert `edu:addresses` |
| `C-c h v` | Validate |
| `C-c h b` | Build web |
| `C-c h B` | Build web + PDFs |
| `C-c h w` | Watch |
| `C-c h g` | Open graph page |
| `C-c h O` | Open a project ontology file |
| `C-c h F` | Refresh project completions and validate |
| `C-c h P` | Compile PDF |


## Collection publishing commands

Open a manifest under `collections/` to enable `heurigraph-collection-mode`.

| Key | Command |
|---|---|
| `C-c h c` | Validate the selected collection/profile |
| `C-c h b` | Build the selected collection/profile |
| `C-c h p` | Build and preview its PDF |
| `C-c h o` | Open the most recent/default PDF output |
| `C-c h s` | Select a buffer-local publication profile |
| `C-c h j` | Jump from an explicit tree id to its note |
| `C-c h e` | Insert an ordered entry block |
| `C-c h t` | Insert connecting inline prose (`C-u` prompts for a source file) |
| `C-c h x` | Insert an exercise and optional solution block |
| `C-c h L` | Start the Heurigraph language server |

In a note buffer, `C-c h C` finds collection manifests containing the current
tree.

## Ontology authoring

Open a TOML file under `ontology/` to enable `heurigraph-ontology-mode`. It
provides schema-aware starter tables without taking ownership away from the
project files:

| Key | Command |
|---|---|
| `C-c h t` | Insert a taxon with parent and presentation metadata |
| `C-c h s` | Insert a subject with broader subject and aliases |
| `C-c h p` | Insert a predicate with domain, range, context, and graph constraints |
| `C-c h S` | Insert a mathematical structure and implication list |
| `C-c h o` | Open another ontology file |
| `C-c h r` | Run a scan and refresh `build/ontology.json` |
| `C-c h v` | Validate the complete forest |

`heurigraph-new` reads taxons and subjects from the resolved project registry.
`heurigraph-insert-assertion` and `heurigraph-suggest-add` read its predicates;
if a predicate requires `framework`, `stage`, `audience`, `jurisdiction`, or
`language`, Emacs prompts for every required value and writes/forwards it.
Predicates with `external_targets = true` also accept an external identity
instead of forcing selection of a local tree.

By default, completion checks whether an ontology TOML file is newer than
the configured ontology JSON export (`build/ontology.json` by default) and runs
`heurigraph scan` once when necessary. Set
`heurigraph-ontology-auto-refresh` to nil to make refresh explicit. After a
schema change, use `C-c h r` in the ontology buffer and `C-c h I` in an active
language-server note buffer.

The complete file formats, first working extension, versioning policy, and
failure guide are in
[Creating and Evolving an Ontology](../docs/ONTOLOGY_AUTHORING.md).

## Graph-wide rename

`M-x heurigraph-rename-id` always obtains and confirms a CLI dry-run plan
before changing files. Save or revert modified affected buffers first. The
command also refuses unsaved project buffers containing the old id and refuses
an already-open destination filename, because those states are absent from or
conflict with the disk-based plan. After success, clean affected buffers are
reloaded and the source buffer follows its renamed file. A valid plan containing
only that source-file rename is still applied.

Filename-derived defaults recognise both project tree IDs such as `mho-0001`
and ISO weeknote IDs such as `2026-W07`. All CLI-backed commands first check
that `heurigraph-executable` is available, and JSON-backed completion and book
commands turn malformed output into a concise editor error. Serve and watch
open the browser only after the local listener is ready.

## Completion model

Node completion candidates are title-first by default, but every insertion uses
the stable id. This lets you type `Null Factor Law` and insert
`#transclude("mho-0001")` without memorising the id. Ontology candidates show
their label, namespaced id, and description; the inserted value remains the
stable namespaced id.

Prompted text is escaped as a literal body before insertion. TOML-generating
commands and Typst-generating commands each escape a source backslash and quote
exactly once, so quoted labels do not signal an Emacs replacement error and
paths are not over-escaped. Regression tests exercise quotes, backslashes, and
mixed strings through both helpers. The metadata scanner also treats nested
Typst content blocks as content, so literal parentheses inside `[...]` do not
truncate the surrounding call.

## Language server

`heurigraph lsp` provides live forest-aware diagnostics, title/id completion,
hover cards, go-to-definition, references, safe tree-id rename, quick fixes,
collection-manifest checking, document symbols, and workspace symbols.

### Doom/lsp-mode — recommended

lsp-mode supports add-on clients, so Heurigraph can run beside Tinymist:

```elisp
(use-package! heurigraph-lsp
  :after (heurigraph lsp-mode)
  :load-path "~/src/heurigraph/emacs"
  :config
  (heurigraph-lsp-register-lsp-mode))
```

Open a Heurigraph Typst note and run `M-x lsp` or
`M-x heurigraph-lsp-start`. Tinymist continues to provide Typst syntax
intelligence; Heurigraph adds graph semantics.

### Eglot

Eglot normally manages one server per buffer. Run
`M-x heurigraph-eglot-enable` to select Heurigraph for the current Typst
session. This may replace Tinymist in that buffer.

| Key | Command |
|---|---|
| `C-c h L` | Start the Heurigraph language server |
| `C-c h I` | Refresh the live workspace index |
