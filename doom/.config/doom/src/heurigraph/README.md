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
forest_iri = "https://example.org/forests/my-mathematics"
```

`heurigraph-new` delegates blank-ID allocation to that setting. Its subject
prompt includes `[No subject]`; that is the default for `curriculum:*` taxons,
while other taxons retain `heurigraph-default-subject`. Selecting a subject
affects metadata and initial folder placement, never the permanent ID prefix.
New nodes remain private by default. To have `heurigraph-new` pass `--public`
for newly created knowledge nodes, customize:

```elisp
(setq heurigraph-new-public-by-default t)
```

The option is safe as a directory-local Boolean when only selected forests
should use this authoring default. It does not change existing nodes or direct
CLI calls.
Journal and weeknote commands create sources under `notes/journal/` and
`notes/weeknotes/` respectively.

## Files

- `heurigraph.el` — main CLI bridge and authoring commands.
- `heurigraph-mode.el` — optional minor mode with a `C-c h` keymap.
- `heurigraph-education.el` — module-aware education activation plus
  assessment, exam, curriculum-relation, manuscript, and explicit module
  migration commands.
- `heurigraph-lsp.el` — forest-aware lsp-mode add-on and Eglot helper.
- `heurigraph-pkg.el` — package metadata for local package installation.

## Requirements and compatibility

Heurigraph supports Emacs 30.2 or newer and should be used with the matching
CLI release.  The package uses only built-in Emacs libraries for its
CLI authoring commands.  `lsp-mode` and Tinymist are optional and are required
only for the recommended dual-server setup; Eglot is built into Emacs.

## Minimal setup

```elisp
(add-to-list 'load-path "~/src/heurigraph/emacs")
(require 'heurigraph)
(require 'heurigraph-mode)
(require 'heurigraph-education)
(require 'heurigraph-lsp)
(setq heurigraph-executable "heurigraph")
(setq heurigraph-notes-directory "~/math/heurigraph")
(add-hook 'typst-ts-mode-hook #'heurigraph-education-enable-for-typst)
(add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-collection)
(add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-ontology)
(add-hook 'toml-mode-hook #'heurigraph-enable-for-collection)
(add-hook 'toml-mode-hook #'heurigraph-enable-for-ontology)
```

## Command output

Synchronous CLI commands use a hybrid output policy by default. Short,
successful output is collapsed into one minibuffer/echo-area message. Long
output opens `*heurigraph*`, and failures always open that buffer so complete
diagnostics remain visible. The full command, unabridged output, and exit status
are retained in `*heurigraph*` even when only a message is shown.

Customize `heurigraph-output-display` to change the policy:

```elisp
;; Default: short successes in the echo area, long output in a buffer.
(setq heurigraph-output-display 'auto)

;; Keep every successful command in the echo area, truncating long messages.
(setq heurigraph-output-display 'minibuffer)

;; Restore the always-open-buffer behaviour from Heurigraph 2.0.4.
(setq heurigraph-output-display 'buffer)
```

`heurigraph-minibuffer-output-max-length` controls the default 160-column
boundary and the truncation width. Build operations that run asynchronously
continue to use compilation buffers for progress and clickable diagnostics.

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
  :hook ((toml-ts-mode . heurigraph-enable-for-collection)
         (toml-ts-mode . heurigraph-enable-for-ontology)
         (toml-mode . heurigraph-enable-for-collection)
         (toml-mode . heurigraph-enable-for-ontology)))

(use-package! heurigraph-education
  :after heurigraph-mode
  :load-path "~/src/heurigraph/emacs"
  :hook (typst-ts-mode . heurigraph-education-enable-for-typst)
  :config
  (heurigraph-education-doom-setup-keybindings))
```

Restart Doom after updating `config.el`. Heurigraph's Doom shortcuts are under
`SPC e`; the portable `C-c h` map remains available. The Typst hook
automatically enables persistent lsp-mode workspaces for both Tinymist and
Heurigraph. Do not also run Eglot in those Typst buffers.

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
| `SPC e E` | Insert structured assessment item data |
| `SPC e G` | Insert an assessment scheme |
| `SPC e C` | Insert an assessment component |
| `SPC e K` | Insert an ordered mark-scheme point |
| `SPC e z` | Insert exam administration and provenance |
| `SPC e Q` | Insert reusable rights metadata |
| `SPC e k` | Insert an external platform/database identity |
| `SPC e y` | Insert an edition-aware publication reference |
| `SPC e A` | Add subjects from the project ontology |
| `SPC e V` | Toggle explicit public/private metadata |
| `SPC e N` | Rename the current note file from its knowledge-node title |
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
| `SPC e ?` | Open the guided AI workflow |
| `SPC e X` | Inspect the proposal-aware MCP connector |
| `SPC e L` | Ensure Tinymist and Heurigraph are running |
| `SPC e I` | Refresh the language-server index |

## Important commands

| Command | Purpose |
|---|---|
| `heurigraph-education-module-preview` | Display the read-only education-module migration plan and its exact digest. |
| `heurigraph-education-module-migrate` | Apply a reviewed plan digest through the transactional CLI migration boundary. |
| `heurigraph-new` | Create a typed id-bearing tree. |
| `heurigraph-new-page` | Choose content, journal, or weeknote. |
| `heurigraph-new-content` | Create a content page in the project-wide `prefix-XXXX` sequence. |
| `heurigraph-new-journal` | Create a journal entry in the project-wide `prefix-XXXX` sequence. |
| `heurigraph-new-weeknote` | Create `YYYY-WXX`, defaulting to the current ISO week. |
| `heurigraph-new-diagram` | Create and open the next `cetz-XXXX` CeTZ source. |
| `heurigraph-insert-diagram` | Insert a diagram with editable alt text, width, and caption. |
| `heurigraph-import-image` | Copy an external image into `images/` under the next `img-XXXX` ID. |
| `heurigraph-rename-image` | Rename a file already in `images/` to the next managed ID. |
| `heurigraph-insert-image` | Look up a managed image by ID, prompt for contextual alt text (empty means decorative), and insert its `#image(...)` call. |
| `heurigraph-insert-assessment-data` | Insert typed order, marks, calculator, response, cognitive-demand, and inquiry data. |
| `heurigraph-insert-assessment-scheme-data` | Insert complete/partial scheme totals and declared external duration. |
| `heurigraph-insert-assessment-component-data` | Insert external/internal mode, weighting, timed duration, and notional hours. |
| `heurigraph-insert-mark-scheme-point` | Insert one ordered scoring criterion. |
| `heurigraph-insert-exam-administration` | Insert sitting identity, duration, declared source total, coverage, status, and permitted materials. |
| `heurigraph-insert-rights` | Insert controlled rights status, evidence, permitted uses, and restrictions. |
| `heurigraph-add-subjects` | Add one or more project-ontology subjects to the current tree. |
| `heurigraph-rename-file-from-title` | Rename the current tree file from its metadata title while preserving its ID. |
| `heurigraph-find-node` | Search titles, ids, subjects, taxons, and aliases. |
| `heurigraph-insert-link` | Search by title and insert `#link-to("id", text: "Title")`. |
| `heurigraph-insert-transclusion` | Search by title and insert `#transclude("id")`. |
| `heurigraph-insert-assertion` | Insert a namespaced ontology assertion. |
| `heurigraph-ontology-open` | Open a TOML file under the project ontology. |
| `heurigraph-ontology-refresh` | Validate sources and regenerate ontology completion data. |
| `heurigraph-refresh-completions` | Refresh ontology/title data and validate the forest. |
| `heurigraph-validate` | Validate ids, ontology, assertions, metadata, and pages. |
| `heurigraph-build` | Build static HTML. |
| `heurigraph-build-all` | Build HTML and PDFs. |
| `heurigraph-manuscript-build` | Build one semantic manuscript as its reference Typst project and PDF. |
| `heurigraph-watch` | Rebuild on save and optionally serve locally. |
| `heurigraph-open-graph-page` | Open generated interactive graph navigation. |
| `heurigraph-pdf` | Compile the current/default tree to PDF. |
| `heurigraph-agent-context` | Export LLM-ready graph context. |
| `heurigraph-ai-workflow` | Inspect/setup the connector, review proposals or suggestions, and validate through one guided prompt. |
| `heurigraph-mcp-inspect` | Verify canonical-source reads and append-only advisory proposals. |
| `heurigraph-mcp-copy-configuration` | Copy desktop-client JSON with absolute executable and forest paths. |
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
| `C-c h ?` | Open the guided AI workflow |
| `C-c h X` | Inspect the proposal-aware MCP connector |
| `C-c h Y` | Open the consolidated local review center |
| `C-c h E` | Insert structured assessment item data |
| `C-c h G` | Insert an assessment scheme |
| `C-c h H` | Insert an assessment component |
| `C-c h K` | Insert an ordered mark-scheme point |
| `C-c h z` | Insert formal exam administration metadata |
| `C-c h Q` | Insert reusable rights and permitted-use metadata |
| `C-c h k` | Insert an external platform/database identity |
| `C-c h y` | Insert an edition-aware publication reference |
| `C-c h A` | Add subjects from the project ontology |
| `C-c h V` | Toggle explicit public/private metadata |
| `C-c h N` | Rename the current note file from its knowledge-node title |
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
| `C-c h S` | Scan the forest |
| `C-c h b` | Build web |
| `C-c h B` | Build web + PDFs |
| `C-c h w` | Watch |
| `C-c h d` | Run project diagnostics |
| `C-c h g` | Open graph page |
| `C-c h o` | Open the generated site |
| `C-c h a` | Export agent context |
| `C-c h q` | Review semantic suggestions |
| `C-c h O` | Open a project ontology file |
| `C-c h F` | Refresh project completions and validate |
| `C-c h P` | Compile PDF |
| `C-c h L` | Ensure the language-server clients are running |
| `C-c h I` | Refresh Heurigraph's language-server index |
| `C-c h C` | Find collections containing the current tree |


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
| `C-c h I` | Refresh Heurigraph's language-server index |

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
Assertion insertion then offers any remaining context fields as optional
qualifiers. Framework and stage values complete suitable local framework,
course, and stage nodes while still accepting external identifiers.
Predicates with `external_targets = true` also accept an external identity
instead of forcing selection of a local tree.

By default, completion checks whether an ontology TOML file is newer than
the configured ontology JSON export (`build/ontology.json` by default) and runs
`heurigraph scan` once when necessary. Set
`heurigraph-ontology-auto-refresh` to nil to make refresh explicit. After a
schema change, use `C-c h r` in the ontology buffer and `C-c h I` in an active
language-server note buffer. Notes and pages created through the Emacs commands
refresh an active Heurigraph language-server workspace immediately. The server
also watches for notes created by terminal commands; use `C-c h I` as a manual
fallback and after ontology or project-configuration changes.

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

`M-x heurigraph-rename-file-from-title` is the narrower filename-only command.
It converts the current `#knowledge-node` title to the same ASCII slug used by
`heurigraph new`, preserves the permanent ID, normalizes the name to
`id--slug.typ`, refuses collisions and symbolic links, saves the buffer, and
keeps it attached to the renamed file. It never changes graph references.

## Local MCP connector

`M-x heurigraph-mcp-inspect` performs a finite
`heurigraph mcp inspect --root ... --json` check and shows the result in
`*heurigraph-mcp*`. `M-x heurigraph-mcp-copy-configuration` copies this shape
for the current forest:

```json
{
  "mcpServers": {
    "heurigraph": {
      "command": "/absolute/path/to/heurigraph",
      "args": ["mcp", "serve", "--stdio", "--root", "/absolute/forest"]
    }
  }
}
```

Both paths are canonical and absolute so a desktop application does not
depend on the interactive shell's `PATH` or current directory. Emacs does not
start a persistent MCP process: the desktop MCP client must own the stdio
process. Canonical forest sources remain read-only to MCP. The connector can
append strictly validated import, content, manuscript, and generation proposals
to local review queues; those queues are writable, but accepting, rejecting,
editing, building, publishing, running configured commands, and calling a model
remain outside MCP authority. Interactive configuration copying inspects this
authority and asks you to confirm the exact canonical forest root first.

## Guided AI workflow

Run `M-x heurigraph-ai-workflow` (`C-c h ?`, or `SPC e ?` after Doom setup) for
one discoverable entry point to connector inspection/setup, the local proposal
review center, semantic suggestions, and validation. The command does not call
a model and does not bypass local review.

For token-efficient work, ask the connected assistant to start with
`get_capabilities`, then use `forest_summary`, a bounded `search_trees`, and
`get_tree_context` only for selected results. For source imports, use
`get_import_context`, `preview_import_bundle`, and `submit_import_proposal`;
large whole-forest context exports should be an explicit last resort. Finish by
opening the local review center and validating before accepting or publishing.

## Completion model

Node completion candidates are title-first by default, but every insertion uses
the stable id. This lets you type `Null Factor Law` and insert
`#transclude("mho-0001")` without memorising the id. Ontology candidates show
their label, namespaced id, and description; the inserted value remains the
stable namespaced id.

`heurigraph-new` uses the same forest index while prompting for a title. Its
default `flex` completion style finds approximate title matches, IDs, taxons,
subjects, and aliases, while still accepting any new title. An exact
case-insensitive title match asks for confirmation before creating a duplicate.
Customize `heurigraph-new-title-completion-styles` to change or disable the
prompt-specific completion styles.

When `heurigraph-new-public-by-default` is non-nil, `heurigraph-new` adds the
CLI's `--public` flag and the generated knowledge node contains
`public: true`. The option defaults to nil and does not affect page commands.

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

Opening a Heurigraph Typst note starts both clients automatically and keeps
their repository workspaces alive. `M-x heurigraph-lsp-start` ensures the pair
manually, and `M-x heurigraph-lsp-status` reports both connections. Tinymist
continues to provide Typst syntax intelligence; Heurigraph adds graph
semantics.

### Eglot

Eglot normally manages one server per buffer. Run
`M-x heurigraph-eglot-enable` to select Heurigraph for the current Typst
session. The helper is deliberately limited to governed Typst buffers and does
not claim TOML buffers globally. If Eglot already manages the buffer, stop that
server first with `M-x eglot-shutdown`; the helper refuses to replace a running
server implicitly. Do not combine Eglot with lsp-mode in the same Typst buffer.

## Package checks

Release checks use Emacs 30.2. Run the ERT suite directly with:

```sh
emacs -Q --batch -L emacs -l emacs/heurigraph-tests.el \
  -f ert-run-tests-batch-and-exit
```

The local verification gate byte-compiles the four runtime libraries and runs
Checkdoc over the runtime libraries and tests. Generated `.elc` files are
ignored and should not be included in a source release.

| Key | Command |
|---|---|
| `C-c h L` | Ensure Tinymist and Heurigraph are running |
| `C-c h I` | Refresh the live workspace index |
