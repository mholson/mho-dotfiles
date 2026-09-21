# Heurigraph for Emacs

The Emacs package is a thin source-authoring client for a Heurigraph
workspace. It keeps Typst notes and the project-owned ontology close to normal
Emacs editing while the Heurigraph engine remains the authority for IDs,
validation, graph-aware lookup, and mutation.

The Education extension adds Typst metadata helpers and accepted-document
generation actions.
It does not embed a second ontology or maintain fallback vocabulary.

## Requirements

- Emacs 30.2 or newer
- the `heurigraph` executable
- a Typst major mode (`typst-ts-mode` or `typst-mode`)
- built-in Eglot for Heurigraph editor intelligence

## Install from the repository

Add the directory to `load-path` and enable the modes:

```elisp
(add-to-list 'load-path "/path/to/Heurigraph/emacs")

(require 'heurigraph-mode)
(require 'heurigraph-education)

(add-hook 'typst-ts-mode-hook #'heurigraph-education-enable-for-typst)
(add-hook 'typst-mode-hook #'heurigraph-education-enable-for-typst)
(add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-ontology)
(add-hook 'conf-toml-mode-hook #'heurigraph-enable-for-ontology)
(add-hook 'toml-mode-hook #'heurigraph-enable-for-ontology)
```

Use `heurigraph-enable-for-typst` instead when the Education metadata helpers
are not wanted.

For Doom Emacs, call this after Doom has initialized its leader map:

```elisp
(heurigraph-doom-setup-keybindings)
```

Education actions appear inside the same Edit dispatcher when the extension is
loaded; they do not add a second key hierarchy.

### Updating an existing Doom configuration

Remove old `heurigraph-enable-for-collection` hooks. Collections were retired;
`use-package!` otherwise creates an autoload for that absent function and reports
“failed to define function” when a TOML buffer opens, aborting the remaining
hooks. Keep the ontology hook for each TOML major mode you use:

```elisp
(use-package! heurigraph-mode
  :load-path "~/.config/doom/src/heurigraph"
  :hook ((typst-ts-mode . heurigraph-enable-for-typst)
         (typst-mode . heurigraph-enable-for-typst)
         (toml-ts-mode . heurigraph-enable-for-ontology)
         (conf-toml-mode . heurigraph-enable-for-ontology)
         (toml-mode . heurigraph-enable-for-ontology))
  :config
  (heurigraph-doom-setup-keybindings))
```

Also remove the old `heurigraph-lsp-register-lsp-mode` setup and its
`:after (heurigraph lsp-mode)` block. The current mode loads the Eglot client
and starts it for governed Typst buffers. Keep your existing executable and
workspace preferences. Restart Emacs after replacing the configuration so old
autoloads and hook values do not remain in the current session.

### TOML syntax highlighting

`heurigraph-ontology-mode` adds authoring commands without replacing the TOML
major mode. Tree-sitter highlighting requires both Emacs tree-sitter support and
a compiled TOML grammar; merely having `toml-ts-mode` available is insufficient.
Check `M-: (treesit-language-available-p 'toml)`. If it returns nil, use
`M-x treesit-install-language-grammar` with your configured TOML recipe and then
reopen the buffer. Doom's tree-sitter module supplies the grammar recipe.

The built-in `M-x conf-toml-mode` provides TOML highlighting without a grammar.
With the fallback hook above, ontology authoring remains available in that mode.
If an updated hook still appears missing, use `M-x locate-library` with
`heurigraph-mode` to check that Emacs is loading the intended installation;
remove obsolete copied libraries from `load-path` rather than mixing versions.

## Workspace authority

The nearest `heurigraph.toml` determines the active workspace. Emacs project
discovery, the Heurigraph language server, and all CLI-backed commands use that
same root when `heurigraph-notes-directory` is nil (the default). Leave that
setting nil when working across projects; an explicit value overrides CLI
workspace discovery.

Completion for taxons, subjects, predicates, and structures comes directly
from `heurigraph ontology --json`. Emacs never reads a generated graph output,
parses project TOML, or maintains a second ontology cache. There is no
hard-coded Education fallback list.

Use:

- `M-x heurigraph-ontology-open` to open a project ontology source file.
- `M-x heurigraph-problems` to ask the engine for current diagnostics.

The ontology minor mode can insert validated TOML skeletons for taxons,
subjects, predicates, and mathematical structures.

## Source-authoring commands

### Everyday surface

| Command | Purpose |
| --- | --- |
| `heurigraph-init` | Initialize a named workspace with an automatic UUID. |
| `heurigraph-edit` | Create nodes/pages or insert metadata, images, and figures. |
| `heurigraph-generate` | Build Graph/Neo4j/CSV/XLSX, Web, manuscript, assessment, Solution Design, PDF, or archive output. |
| `heurigraph-problems` | Show authoritative workspace diagnostics. |
| `heurigraph-find-node` | Find and open a node by graph-aware completion. |
| `heurigraph-insert-link` | Insert a title-aware link to another node. |
| `heurigraph-insert-transclusion` | Insert a node transclusion. |
| `heurigraph-insert-assertion` | Insert a predicate and its required context. |
| `heurigraph-lsp-start` | Start Heurigraph editor intelligence through Eglot. |

`heurigraph-edit` contains the less frequent structured editing actions without
turning each one into a permanent key binding:

- create a knowledge node or page;
- open ontology source;
- insert rights, external identity, or publication-reference metadata; and
- insert a managed image or published CeTZ figure.

Semantic mutations such as changing subjects or publication state go through
the engine, not local Typst parsing in Emacs.

### Images and figures

| Command | Purpose |
| --- | --- |
| `heurigraph-import-image` | Import an image through the engine's ID allocator. |
| `heurigraph-insert-image` | Insert an imported image reference. |
| `heurigraph-insert-diagram` | Insert a published CeTZ source by UUID. |

Create, repair, preview, and publish Figure drafts in HeurigraphUX. Emacs
deliberately exposes only insertion of already published CeTZ sources.

## Education metadata

Loading `heurigraph-education` contributes five thin Typst insertion actions to
`heurigraph-edit`:

| Command | Purpose |
| --- | --- |
| `heurigraph-insert-assessment-data` | Assessment-item metadata. |
| `heurigraph-insert-assessment-scheme-data` | Assessment-scheme metadata. |
| `heurigraph-insert-assessment-component-data` | Weighted component metadata. |
| `heurigraph-insert-mark-scheme-point` | One ordered mark-scheme point. |
| `heurigraph-insert-exam-administration` | Formal exam administration metadata. |

These helpers write Typst only. Education semantics are supplied by the
compiled Education extension and the editable project ontology.

## Language server

`heurigraph-lsp-start` starts `heurigraph lsp` through built-in Eglot for graph
IDs, ontology-aware completion, refactors, and workspace diagnostics. The
nearest manifest remains the authoritative Eglot project root.

`heurigraph-lsp-refresh` requests an explicit graph refresh.
`heurigraph-lsp-status` reports whether it is active. Because Eglot manages one
server per buffer, stop another Eglot server before selecting Heurigraph.

## Default key map

`heurigraph-note-mode` uses the `C-c h` prefix:

| Key | Command |
| --- | --- |
| `e` | Edit/create dispatcher |
| `g` | Generate dispatcher |
| `p` | Problems |
| `f` | Find node |
| `l` | Link |
| `t` | Transclude |
| `r` | Relationship |
| `R` | Rename stable ID |
| `L` | Start/attach language services |

The Doom map uses the same final key below `SPC e`.

## Deliberate boundary

Emacs invokes maintained projections but does not infer paths, parse generated
artifacts, own preview/publication workflow, watch files, administer models, or
configure MCP. Those responsibilities belong to HeurigraphUX and the focused
CLI. This keeps Emacs centered on editing the one project source of truth.

## Verify the package

From the repository root:

```sh
scripts/verify-emacs.sh
```

The check byte-compiles with warnings as errors, checks documentation style,
runs ERT, builds two identical package archives, and verifies installation into
an isolated Emacs package directory.
