;;; heurigraph.el --- Authoring layer for Heurigraph  -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 6.4.24
;; Keywords: tools, tex, outlines
;; Package-Requires: ((emacs "30.2"))
;; URL: https://github.com/mholson/Heurigraph
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; A thin Emacs layer over the `heurigraph' command-line tool.  It does not
;; reimplement any Heurigraph logic; every command shells out to the binary so
;; that Emacs and the native client agree on behaviour.  The CLI is the source of
;; truth; this client supplies source-editing ergonomics.
;; Setup:
;;   (require 'heurigraph)
;;   (setq heurigraph-notes-directory "~/forest")
;;
;; The everyday entry points are `heurigraph-edit', `heurigraph-generate',
;; `heurigraph-problems', and the direct graph-editing commands.

;;; Code:

(require 'project)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup heurigraph nil
  "Authoring layer for the Heurigraph publishing engine."
  :group 'tools
  :prefix "heurigraph-")

(defconst heurigraph-version "6.4.24"
  "Version of the installed Heurigraph Emacs package.")

(defcustom heurigraph-executable "heurigraph"
  "Path to the `heurigraph' command-line binary."
  :type 'string
  :group 'heurigraph)

(defcustom heurigraph-notes-directory nil
  "Root of the Heurigraph project (the directory containing heurigraph.toml).
When nil, use the nearest ancestor containing heurigraph.toml, then the editor
project root or current `default-directory' as a fallback."
  :type '(choice (const :tag "Auto-detect" nil) directory)
  :group 'heurigraph)

(defcustom heurigraph-new-public-by-default nil
  "When non-nil, create new knowledge nodes with `public: true'.
This affects only `heurigraph-new'; it passes `--public' to the Heurigraph CLI.
Keep the default nil when new material should require an explicit publication
decision."
  :type 'boolean
  :safe #'booleanp
  :group 'heurigraph)

(defcustom heurigraph-diagram-default-width "70%"
  "Default Typst width offered by `heurigraph-insert-diagram'.
The prompt remains editable and accepts values such as `auto', `8cm', or
`100%'."
  :type 'string
  :group 'heurigraph)

(defcustom heurigraph-diagram-default-caption ""
  "Default caption offered by `heurigraph-insert-diagram'.
An empty caption omits the `caption' parameter."
  :type 'string
  :group 'heurigraph)

;;; Internals ----------------------------------------------------------------

(defcustom heurigraph-publication-reference-roles
  '("appears-in" "adapted-from" "reproduced-in" "referenced-by" "inspired-by")
  "Controlled role values accepted by publication-reference metadata."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-assertion-context-fields
  '("framework" "course" "level" "audience" "jurisdiction" "language")
  "Context fields offered by `heurigraph-insert-assertion'.
Fields required by the selected ontology predicate are always prompted.
Any remaining fields may be selected interactively and left absent."
  :type '(repeat string)
  :group 'heurigraph)

(defvar heurigraph-assertion-context-candidate-filter-functions nil
  "Functions that refine local context candidates for an extension.
Each function receives FIELD and CANDIDATES and returns the remaining list.")

(defun heurigraph--root ()
  "Return the Heurigraph project root as an absolute directory."
  (let* ((start (or (and buffer-file-name
                         (file-name-directory buffer-file-name))
                    default-directory))
         (forest-root (and start
                           (locate-dominating-file start "heurigraph.toml"))))
    (expand-file-name
     (or heurigraph-notes-directory
         forest-root
         (when-let ((pr (project-current)))
           (project-root pr))
         default-directory))))

(defun heurigraph--resolve-executable ()
  "Return the configured Heurigraph executable as an absolute path."
  (let* ((configured heurigraph-executable)
         (explicit (and (stringp configured)
                        (string-match-p "[/\\\\]" configured)
                        (expand-file-name configured)))
         (available (and (stringp configured)
                         (not (string-empty-p configured))
                         (or (executable-find configured)
                             (and explicit
                                  (file-executable-p explicit)
                                  explicit)))))
    (unless available
      (user-error
       "Cannot find Heurigraph executable `%s'; install it or customize `heurigraph-executable'"
       configured))
    (expand-file-name available)))

(defun heurigraph--require-executable ()
  "Return the configured Heurigraph executable or raise `user-error'."
  (heurigraph--resolve-executable))

(defun heurigraph--run (args &optional buffer-name)
  "Run the heurigraph binary with ARGS (a list of strings) in the project root.
Output is retained and displayed in BUFFER-NAME (default *heurigraph*).
Return the exit code."
  (let ((default-directory (heurigraph--root))
        (executable (heurigraph--require-executable))
        (buf (get-buffer-create (or buffer-name "*heurigraph*"))))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "$ %s %s\n\n"
                      executable (string-join args " "))))
    (let ((code (apply #'call-process executable nil buf t args)))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (format "\n[exit %s]\n" code))
        (special-mode))
      (display-buffer buf)
      code)))

(defun heurigraph--call-output (args)
  "Run Heurigraph with ARGS and return (EXIT-CODE . OUTPUT)."
  (let ((default-directory (heurigraph--root))
        (executable (heurigraph--require-executable)))
    (with-temp-buffer
      (let ((code (apply #'call-process executable nil t nil args)))
        (cons code (buffer-string))))))

(defun heurigraph--parse-json-output (output description)
  "Parse JSON OUTPUT for DESCRIPTION, reporting malformed output cleanly."
  (condition-case error
      (json-parse-string output :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil)
    (json-parse-error
     (user-error "Heurigraph returned invalid JSON for %s: %s"
                 description (error-message-string error)))))

(defun heurigraph--refresh-active-lsp ()
  "Refresh an active Heurigraph LSP workspace after an external CLI write.
The editor package remains usable without `heurigraph-lsp.el'; in that case
there is no live in-memory index to refresh."
  (when (fboundp 'heurigraph-lsp-refresh-if-active)
    (heurigraph-lsp-refresh-if-active)))

;;;; Project ontology -------------------------------------------------------

(defun heurigraph--ontology-root-path ()
  "Return the one editable project ontology directory."
  (expand-file-name "ontology" (heurigraph--root)))

(defun heurigraph--ontology-source-files ()
  "Return project ontology TOML files, or nil when the directory is absent."
  (let ((directory (heurigraph--ontology-root-path)))
    (when (file-directory-p directory)
      (directory-files-recursively directory "\\.toml\\'"))))

(defun heurigraph--ontology-registry ()
  "Return the current ontology directly from the authoritative CLI service."
  (pcase-let* ((`(,code . ,output)
                (heurigraph--call-output '("ontology" "--json"))))
    (unless (zerop code)
      (user-error "Cannot read the project ontology: %s" (string-trim output)))
    (heurigraph--parse-json-output output "project ontology")))

(defun heurigraph--ontology-items (kind)
  "Return ontology entries of KIND from the resolved project registry.
KIND is one of the symbols `taxons', `subjects', `predicates', or
`structures'."
  (alist-get kind (heurigraph--ontology-registry)))

(defun heurigraph--ontology-item-label (item)
  "Return a searchable completion label for ontology ITEM."
  (let ((id (alist-get 'id item))
        (label (alist-get 'label item))
        (description (alist-get 'description item)))
    (string-join
     (delq nil
           (list (and label (not (string-empty-p label)) label)
                 (format "— %s" id)
                 (and description (not (string-empty-p description))
                      (format "· %s" description))))
     " ")))

(defun heurigraph--ontology-candidates (kind)
  "Return completion candidates for ontology KIND.
Each candidate maps its display label to the complete resolved ontology item."
  (let ((items (heurigraph--ontology-items kind)))
    (mapcar (lambda (item)
              (cons (heurigraph--ontology-item-label item) item))
            items)))

(defun heurigraph--read-ontology-item (prompt kind &optional default)
  "Read one project ontology KIND entry with PROMPT and DEFAULT id."
  (let* ((candidates (heurigraph--ontology-candidates kind))
         (_ (unless candidates
              (user-error "No project ontology %s are available; refresh the ontology first"
                          kind)))
         (default-label
          (car (seq-find (lambda (candidate)
                           (equal (alist-get 'id (cdr candidate)) default))
                         candidates)))
         (choice (completing-read prompt candidates nil t nil nil default-label)))
    (cdr (assoc choice candidates))))

(defun heurigraph--read-ontology-id (prompt kind &optional default)
  "Read and return a project ontology id with PROMPT, KIND, and DEFAULT."
  (alist-get 'id
             (heurigraph--read-ontology-item prompt kind default)))

(defun heurigraph--read-optional-subject (prompt &optional default)
  "Read an optional project subject with PROMPT and DEFAULT.
Completion includes an explicit choice that returns nil.  When DEFAULT is nil,
that choice is selected by default."
  (let* ((none-label "[No subject]")
         (candidates (heurigraph--ontology-candidates 'subjects))
         (default-label
          (or (car (seq-find (lambda (candidate)
                               (equal (alist-get 'id (cdr candidate)) default))
                             candidates))
              none-label))
         (choice
          (completing-read prompt
                           (cons (cons none-label nil) candidates)
                           nil t nil nil default-label)))
    (unless (equal choice none-label)
      (alist-get 'id (cdr (assoc choice candidates))))))

;;;###autoload
(defun heurigraph-ontology-open (file)
  "Open a project ontology FILE selected relative to `ontology/'."
  (interactive
   (let* ((root (file-name-as-directory
                 (heurigraph--ontology-root-path)))
          (files (heurigraph--ontology-source-files))
          (relative (mapcar (lambda (path) (file-relative-name path root)) files)))
     (unless files
       (user-error "No ontology directory found; run M-x heurigraph-init first"))
     (list (completing-read "Ontology file: " relative nil t nil nil
                            "manifest.toml"))))
  (find-file (expand-file-name file (heurigraph--ontology-root-path))))

(defun heurigraph--ontology-ids (kind)
  "Return resolved project ids for ontology KIND."
  (mapcar (lambda (item) (alist-get 'id item))
          (heurigraph--ontology-items kind)))

(defun heurigraph--toml-array (values)
  "Format string VALUES as a TOML array."
  (format "[%s]"
          (mapconcat (lambda (value)
                       (format "\"%s\"" (heurigraph--toml-string value)))
                     values
                     ", ")))

(defun heurigraph--ontology-insert-table (table fields)
  "Append ontology TABLE with preformatted FIELDS to the current buffer."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (unless (or (= (point) (point-min))
              (save-excursion
                (forward-line -1)
                (looking-at-p "^[[:space:]]*$")))
    (insert "\n"))
  (insert (format "[[%s]]\n" table))
  (dolist (field fields)
    (pcase-let ((`(,name ,value) field))
      (when value
        (insert (format "%s = %s\n" name value)))))
  (insert "\n"))

;;;###autoload
(defun heurigraph-ontology-insert-taxon (id label parent style description)
  "Insert taxon ID with LABEL, PARENT, STYLE, and DESCRIPTION."
  (interactive
   (let* ((id (read-string "Taxon id (namespace:term): "))
          (label (read-string "Label: "))
          (parents (heurigraph--ontology-ids 'taxons)))
     (list id label
           (completing-read "Parent (blank only for a root): "
                            (cons "" parents) nil t)
           (read-string "Presentation style (optional): " "concept")
           (read-string "Description: "))))
  (unless (string-match-p "^[a-z0-9_-]+:[a-z0-9_-]+$" id)
    (user-error "Taxon id must be namespaced, for example probability:distribution"))
  (let ((scheme (car (split-string id ":"))))
    (heurigraph--ontology-insert-table
     "taxons"
     `(("id" ,(format "\"%s\"" (heurigraph--toml-string id)))
       ("label" ,(format "\"%s\"" (heurigraph--toml-string label)))
       ("scheme" ,(format "\"%s\"" (heurigraph--toml-string scheme)))
       ("parent" ,(unless (string-empty-p (or parent ""))
                     (format "\"%s\"" (heurigraph--toml-string parent))))
       ("description" ,(format "\"%s\"" (heurigraph--toml-string description)))
       ("style" ,(format "\"%s\"" (heurigraph--toml-string style)))))))

;;;###autoload
(defun heurigraph-ontology-insert-subject (id label broader aliases description)
  "Insert subject ID with LABEL, BROADER, ALIASES, and DESCRIPTION."
  (interactive
   (let* ((id (read-string "Subject id (namespace:term): "))
          (label (read-string "Label: "))
          (subjects (heurigraph--ontology-ids 'subjects)))
     (list id label
           (completing-read "Broader subject (blank for a root): "
                            (cons "" subjects) nil t)
           (split-string (read-string "Aliases (comma-separated): ")
                         "[[:space:]]*,[[:space:]]*" t)
           (read-string "Description: "))))
  (unless (string-match-p "^[a-z0-9_-]+:[a-z0-9_-]+$" id)
    (user-error "Subject id must be namespaced, for example probability:statistics"))
  (heurigraph--ontology-insert-table
   "subjects"
   `(("id" ,(format "\"%s\"" (heurigraph--toml-string id)))
     ("label" ,(format "\"%s\"" (heurigraph--toml-string label)))
     ("broader" ,(unless (string-empty-p (or broader ""))
                    (format "\"%s\"" (heurigraph--toml-string broader))))
     ("aliases" ,(heurigraph--toml-array aliases))
     ("description" ,(format "\"%s\"" (heurigraph--toml-string description))))))

;;;###autoload
(defun heurigraph-ontology-insert-structure (id label implies description)
  "Insert structure ID with LABEL, IMPLIES, and DESCRIPTION."
  (interactive
   (let ((structures (heurigraph--ontology-ids 'structures)))
     (list (read-string "Structure id (namespace:term): ")
           (read-string "Label: ")
           (completing-read-multiple "Implies (comma-separated): " structures nil t)
           (read-string "Description: "))))
  (unless (string-match-p "^[a-z0-9_-]+:[a-z0-9_-]+$" id)
    (user-error "Structure id must be namespaced, for example domain:structure"))
  (heurigraph--ontology-insert-table
   "structures"
   `(("id" ,(format "\"%s\"" (heurigraph--toml-string id)))
     ("label" ,(format "\"%s\"" (heurigraph--toml-string label)))
     ("implies" ,(heurigraph--toml-array implies))
     ("description" ,(format "\"%s\"" (heurigraph--toml-string description))))))

;;;###autoload
(defun heurigraph-ontology-insert-predicate
    (id label layer source-taxons target-taxons contexts
        external-targets acyclic symmetric description)
  "Insert predicate ID, LABEL, LAYER, domains, constraints, and DESCRIPTION.
SOURCE-TAXONS and TARGET-TAXONS set the domain and range.  CONTEXTS names
required qualifiers; EXTERNAL-TARGETS, ACYCLIC, and SYMMETRIC set graph rules."
  (interactive
   (let ((taxons (heurigraph--ontology-ids 'taxons)))
     (list (read-string "Predicate id (namespace:term): ")
           (read-string "Label: ")
           (read-string "Semantic layer: ")
           (completing-read-multiple "Source taxons (comma-separated): " taxons nil t)
           (completing-read-multiple "Target taxons (comma-separated): " taxons nil t)
           (completing-read-multiple
            "Required context fields: "
            '("framework" "course" "level" "audience" "jurisdiction" "language") nil t)
           (y-or-n-p "Permit unresolved external targets? ")
           (y-or-n-p "Require this predicate to be acyclic? ")
           (y-or-n-p "Is this predicate symmetric? ")
           (read-string "Description: "))))
  (unless (string-match-p "^[a-z0-9_-]+:[a-z0-9_-]+$" id)
    (user-error "Predicate id must be namespaced, for example probability:approximates"))
  (heurigraph--ontology-insert-table
   "predicates"
   `(("id" ,(format "\"%s\"" (heurigraph--toml-string id)))
     ("label" ,(format "\"%s\"" (heurigraph--toml-string label)))
     ("layer" ,(format "\"%s\"" (heurigraph--toml-string layer)))
     ("source_taxons" ,(heurigraph--toml-array source-taxons))
     ("target_taxons" ,(heurigraph--toml-array target-taxons))
     ("required_context" ,(heurigraph--toml-array contexts))
     ("external_targets" ,(if external-targets "true" "false"))
     ("acyclic" ,(if acyclic "true" "false"))
     ("symmetric" ,(if symmetric "true" "false"))
     ("description" ,(format "\"%s\"" (heurigraph--toml-string description))))))

(defconst heurigraph--uuid-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}"
  "Canonical UUIDv4 spelling; short display labels are never stored IDs.")

;;; Commands -----------------------------------------------------------------

;;;###autoload
(defun heurigraph-new (title taxon subject aliases)
  "Create a new note titled TITLE with TAXON.
The engine creates a new immutable UUID.  SUBJECT and
comma-separated ALIASES are optional.  Delegates to `heurigraph node new',
then visits the created file if it can be located."
  (interactive
   (let* ((title (heurigraph--read-new-node-title))
          (taxon
           (heurigraph--read-ontology-id
            "Taxon: " 'taxons))
          (subject
           (heurigraph--read-optional-subject
            "Subject (optional): "))
          (aliases
           (read-string "Aliases (comma-separated, blank for none): ")))
     (list title taxon subject aliases)))
  (let ((args (list "node" "new" title "--taxon" taxon "--json")))
    (when (and subject (not (string-empty-p subject)))
      (setq args (append args (list "--subject" subject))))
    (when (and aliases (not (string-empty-p (string-trim aliases))))
      (setq args (append args (list "--aliases" aliases))))
    (when heurigraph-new-public-by-default
      (setq args (append args (list "--public"))))
    (pcase-let* ((`(,code . ,output) (heurigraph--call-output args))
                 (created (when (zerop code)
                            (heurigraph--parse-json-output output "new note"))))
      (unless (zerop code)
        (user-error "Heurigraph node new failed: %s" (string-trim output)))
      ;; `heurigraph node new' writes outside the LSP protocol.  Refresh while the
      ;; originating note buffer still owns the active workspace, before
      ;; visiting the newly created file.
      (heurigraph--refresh-active-lsp)
      (let ((path (alist-get 'path created)))
        (unless (and (stringp path) (file-exists-p path))
          (user-error "Heurigraph reported an invalid created path: %S" path))
        (find-file path)))))

;;;###autoload
(defun heurigraph-problems ()
  "Show authoritative workspace diagnostics (`heurigraph check')."
  (interactive)
  (let ((code (heurigraph--run '("check"))))
    (message (if (zerop code)
                 "Heurigraph: no problems found"
               "Heurigraph: problems found (see *heurigraph*)"))))

(defvar heurigraph-extra-edit-actions nil
  "Additional labelled source-editing commands contributed by a client extension.")

(defun heurigraph--edit-actions ()
  "Return the available source-editing actions for the current client."
  (append
   '(("Create knowledge node" . heurigraph-new)
     ("Create page" . heurigraph-new-page)
     ("Open ontology" . heurigraph-ontology-open)
     ("Insert managed image" . heurigraph-insert-image)
     ("Insert published CeTZ figure" . heurigraph-insert-diagram)
     ("Insert rights" . heurigraph-insert-rights)
     ("Insert external identity" . heurigraph-insert-external-id)
     ("Insert publication reference" . heurigraph-insert-publication-reference))
   heurigraph-extra-edit-actions))

;;;###autoload
(defun heurigraph-edit (action)
  "Dispatch one source-of-truth editing ACTION contributed by the active client."
  (interactive
   (let* ((actions (heurigraph--edit-actions))
          (choice (completing-read "Edit or create: " actions nil t)))
     (list (cdr (assoc choice actions)))))
  (call-interactively action))

(defun heurigraph--required-id (label)
  "Read one required stable id described by LABEL."
  (let ((id (string-trim (read-string (format "%s id: " label)))))
    (when (string-empty-p id)
      (user-error "%s id is required" label))
    id))

(defvar heurigraph-extra-generate-actions nil
  "Additional labelled generation commands contributed by a client extension.")

(defun heurigraph--generate-graph ()
  "Generate the complete graph projection set."
  (interactive)
  (heurigraph--run '("generate" "graph")))

(defun heurigraph--generate-web ()
  "Generate the public web projection."
  (interactive)
  (heurigraph--run '("generate" "web")))

(defun heurigraph--generate-current-pdf ()
  "Generate PDF for the current or selected node."
  (interactive)
  (let ((id (or (heurigraph--id-at-file)
                (heurigraph--required-id "Node"))))
    (heurigraph--run (list "generate" "pdf" id))))

(defun heurigraph--generate-archive ()
  "Generate a portable workspace archive."
  (interactive)
  (heurigraph--run
   (list "generate" "archive"
         (expand-file-name
          (read-file-name "Archive path: " (heurigraph--root)
                          "heurigraph.hgf" nil "heurigraph.hgf")))))

(defun heurigraph--generate-actions ()
  "Return generation actions available to the current client."
  (append
   '(("Graph, Neo4j, CSV, and XLSX" . heurigraph--generate-graph)
     ("Web" . heurigraph--generate-web)
     ("Current note PDF" . heurigraph--generate-current-pdf)
     ("Workspace archive" . heurigraph--generate-archive))
   heurigraph-extra-generate-actions))

;;;###autoload
(defun heurigraph-generate (action)
  "Run one projection ACTION through the authoritative CLI."
  (interactive
   (let* ((actions (heurigraph--generate-actions))
          (choice (completing-read "Generate: " actions nil t)))
     (list (cdr (assoc choice actions)))))
  (unless (commandp action)
    (user-error "Unknown generation action: %S" action))
  (call-interactively action))

(defun heurigraph--toml-string (value)
  "Escape VALUE for a TOML basic string literal body."
  (replace-regexp-in-string
   "\"" "\\\""
   (replace-regexp-in-string "\\\\" "\\\\" (or value "") t t)
   t t))

;;; Identity refactoring -----------------------------------------------------

;;;; Finding trees and inserting relations ---------------------------------

(defun heurigraph--nodes ()
  "Every tree in the forest, via `heurigraph node find --json'.
Returns a list of alists with keys `id', `title', `taxon', `source'."
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output
                '("node" "find" "--json" "--limit" "0" ""))))
    (unless (zerop code)
      (user-error "Heurigraph node find failed (exit %s): %s"
                  code (string-trim output)))
    (append (heurigraph--parse-json-output output "node completion") nil)))

(defcustom heurigraph-completion-title-first t
  "When non-nil, show note titles before ids in completion candidates.
The inserted text still uses the stable Heurigraph id, so you can search by
\"Null Factor Law\" and insert a link with its complete UUID."
  :type 'boolean
  :group 'heurigraph)

(defcustom heurigraph-new-title-completion-styles '(flex basic)
  "Completion styles used by the title prompt in `heurigraph-new'.
The default enables built-in fuzzy matching while retaining ordinary prefix
completion as a fallback.  Set this to nil to inherit `completion-styles'."
  :type '(repeat symbol)
  :group 'heurigraph)

(defun heurigraph--node-label (node)
  "Return a completion label for NODE.
The label intentionally contains title, id, taxon, subjects, and aliases so
ordinary Emacs completion can narrow by any of those fields."
  (let* ((id (or (alist-get 'short_id node) (alist-get 'id node)))
         (title (or (alist-get 'title node) "Untitled"))
         (taxon (or (alist-get 'taxon node) (alist-get 'kind node) ""))
         (subjects (alist-get 'subjects node))
         (aliases (alist-get 'aliases node))
         (alias-text (when aliases (string-join aliases ", "))))
    (if heurigraph-completion-title-first
        (string-join
         (delq nil (list title (format "— %s" id)
                         (unless (string-empty-p taxon) (format "[%s]" taxon))
                         (when subjects (format "{%s}" (string-join subjects ",")))
                         (when (and alias-text (not (string-empty-p alias-text)))
                           (format "aka %s" alias-text))))
         " ")
      (string-join
       (delq nil (list (format "%-16s" id) title
                       (unless (string-empty-p taxon) (format "[%s]" taxon))
                       (when subjects (format "{%s}" (string-join subjects ",")))
                       (when (and alias-text (not (string-empty-p alias-text)))
                         (format "aka %s" alias-text))))
       " "))))

(defun heurigraph--node-candidates (&optional kind)
  "Completion candidates -> node alist.
With KIND (\"tree\" or \"page\"), restrict to that kind.  Relation and
transclusion targets must be trees; ordinary #link-to mentions may target
either trees or pages."
  (mapcar (lambda (n) (cons (heurigraph--node-label n) n))
          (seq-filter (lambda (n)
                        (or (null kind)
                            (equal (alist-get 'kind n) kind)))
                      (heurigraph--nodes))))

(defun heurigraph--read-node (prompt &optional kind)
  "Using PROMPT, pick a node by title/id/subject/taxon/alias; return an alist.
Type a title, UUID, or subject to narrow the candidates.
When KIND is \"tree\" or \"page\", restrict candidates to that kind."
  (let* ((cands (heurigraph--node-candidates kind))
         (choice (completing-read prompt cands nil t)))
    (cdr (assoc choice cands))))

(defun heurigraph--read-new-node-title ()
  "Read a non-empty title while searching existing tree titles fuzzily.
The prompt accepts arbitrary input because its purpose is to create a new
tree.  Choosing an existing completion candidate uses that node's title.
An exact case-insensitive title collision requires explicit confirmation."
  (let* ((candidates (heurigraph--node-candidates "tree"))
         (completion-styles
          (or heurigraph-new-title-completion-styles completion-styles))
         (choice
          (completing-read
           "Title (search existing or enter new): "
           candidates nil nil))
         (selected (cdr (assoc choice candidates)))
         (title (string-trim
                 (or (and selected (alist-get 'title selected)) choice)))
         (duplicates
          (seq-filter
           (lambda (candidate)
             (string-equal-ignore-case
              title
              (or (alist-get 'title (cdr candidate)) "")))
           candidates)))
    (when (string-empty-p title)
      (user-error "A new node title cannot be empty"))
    (when duplicates
      (let* ((node (cdar duplicates))
             (id (alist-get 'id node))
             (taxon (alist-get 'taxon node))
             (description
              (string-join
               (delq nil
                     (list id
                           (and taxon (not (string-empty-p taxon)) taxon)))
               ", ")))
        (unless
            (yes-or-no-p
             (format
              "A node titled %S already exists%s; create another anyway? "
              title
              (if (string-empty-p description)
                  ""
                (format " (%s)" description))))
          (user-error
           "New node cancelled; use `heurigraph-find-node' to open the existing node"))))
    title))

(defun heurigraph--target-id (node)
  "Return the stable target string for NODE."
  (alist-get 'id node))

(defun heurigraph--typst-string (s)
  "Escape S for use as a Typst string literal body."
  (replace-regexp-in-string
   "\"" "\\\""
   (replace-regexp-in-string "\\\\" "\\\\" (or s "") t t)
   t t))

(defun heurigraph--read-optional-positive-integer (prompt)
  "Read an optional positive integer using PROMPT; return nil for blank."
  (let ((value (string-trim (read-string prompt))))
    (unless (string-empty-p value)
      (unless (string-match-p "\\`[1-9][0-9]*\\'" value)
        (user-error "Expected a positive integer or blank"))
      (string-to-number value))))

(defun heurigraph--normalize-string-list (values)
  "Trim VALUES and discard empty strings."
  (seq-filter
   (lambda (value) (not (string-empty-p value)))
   (mapcar #'string-trim values)))

;;;###autoload
(defun heurigraph-insert-rights
    (status holder license permitted-uses restrictions attribution source)
  "Insert reusable rights and permitted-use metadata at point.
STATUS is one of `restricted', `licensed', `public-domain', or `unknown'.
HOLDER, LICENSE, PERMITTED-USES, RESTRICTIONS, ATTRIBUTION, and SOURCE describe
evidence and allowed or prohibited uses.  This record never makes a node
public; `public: false' remains the publication gate."
  (interactive
   (list
    (completing-read "Rights status: "
                     '("restricted" "licensed" "public-domain" "unknown")
                     nil t)
    (string-trim (read-string "Rights holder (blank for none): "))
    (string-trim (read-string "Licence (blank for none): "))
    (split-string
     (read-string "Permitted uses (comma-separated, blank for none): ")
     "[[:space:]]*,[[:space:]]*" t)
    (split-string
     (read-string "Restrictions (comma-separated, blank for none): ")
     "[[:space:]]*,[[:space:]]*" t)
    (string-trim (read-string "Attribution (blank for none): "))
    (string-trim (read-string "Rights source or URL (blank for none): "))))
  (unless (member status '("restricted" "licensed" "public-domain" "unknown"))
    (user-error
     "Rights status must be restricted, licensed, public-domain, or unknown"))
  (setq permitted-uses (heurigraph--normalize-string-list permitted-uses)
        restrictions (heurigraph--normalize-string-list restrictions))
  (let ((fields
         (list
          (format "  status: \"%s\"," (heurigraph--typst-string status)))))
    (dolist (field
             `(("holder" . ,holder)
               ("license" . ,license)))
      (unless (string-empty-p (cdr field))
        (setq fields
              (append
               fields
               (list
                (format "  %s: \"%s\","
                        (car field)
                        (heurigraph--typst-string (cdr field))))))))
    (dolist (field
             `(("permitted-uses" . ,permitted-uses)
               ("restrictions" . ,restrictions)))
      (when (cdr field)
        (setq fields
              (append
               fields
               (list
                (format
                 "  %s: (%s),"
                 (car field)
                 (mapconcat
                  (lambda (value)
                    (format "\"%s\"" (heurigraph--typst-string value)))
                  (cdr field) ", ")))))))
    (dolist (field
             `(("attribution" . ,attribution)
               ("source" . ,source)))
      (unless (string-empty-p (cdr field))
        (setq fields
              (append
               fields
               (list
                (format "  %s: \"%s\","
                        (car field)
                        (heurigraph--typst-string (cdr field))))))))
    (unless (bolp) (insert "\n"))
    (insert "#rights(\n" (mapconcat #'identity fields "\n") "\n)")))

;;;###autoload
(defun heurigraph-insert-external-id
    (system value url record-type revision)
  "Insert a stable external platform identity at point.
SYSTEM and VALUE form the forest-wide unique identity.  URL, RECORD-TYPE,
and REVISION are optional descriptive integration fields."
  (interactive
   (list
    (string-trim (read-string "External system (for example question-bank): "))
    (string-trim (read-string "External record ID: "))
    (string-trim (read-string "Record URL (blank for none): "))
    (string-trim (read-string "Record type (blank for none): "))
    (string-trim (read-string "Revision (blank for none): "))))
  (when (or (string-empty-p system) (string-empty-p value))
    (user-error "External system and record ID must not be blank"))
  (let ((fields
         (list
          (format "  system: \"%s\"," (heurigraph--typst-string system))
          (format "  value: \"%s\"," (heurigraph--typst-string value)))))
    (unless (string-empty-p url)
      (setq fields
            (append fields
                    (list (format "  url: \"%s\","
                                  (heurigraph--typst-string url))))))
    (unless (string-empty-p record-type)
      (setq fields
            (append fields
                    (list (format "  record-type: \"%s\","
                                  (heurigraph--typst-string record-type))))))
    (unless (string-empty-p revision)
      (setq fields
            (append fields
                    (list (format "  revision: \"%s\","
                                  (heurigraph--typst-string revision))))))
    (unless (bolp) (insert "\n"))
    (insert "#external-id(\n" (mapconcat #'identity fields "\n") "\n)")))

;;;###autoload
(defun heurigraph-insert-publication-reference
    (citation role locator edition page)
  "Insert an edition-aware publication occurrence or provenance record.
CITATION is a bibliography key, ROLE is a controlled provenance role, and
LOCATOR identifies the occurrence.  EDITION and PAGE are optional."
  (interactive
   (list
    (string-trim (read-string "Bibliography citation key: "))
    (completing-read "Publication role: "
                     heurigraph-publication-reference-roles nil t nil nil
                     "appears-in")
    (string-trim
     (read-string "Locator (for example Chapter 2, Exercise 14): "))
    (string-trim (read-string "Edition (blank for none): "))
    (heurigraph--read-optional-positive-integer "Page (blank for none): ")))
  (when (or (string-empty-p citation) (string-empty-p locator))
    (user-error "Citation key and locator must not be blank"))
  (unless (member role heurigraph-publication-reference-roles)
    (user-error "Unknown publication-reference role: %s" role))
  (let ((fields
         (list
          (format "  citation: \"%s\"," (heurigraph--typst-string citation))
          (format "  role: \"%s\"," (heurigraph--typst-string role))
          (format "  locator: \"%s\"," (heurigraph--typst-string locator)))))
    (unless (string-empty-p edition)
      (setq fields
            (append fields
                    (list (format "  edition: \"%s\","
                                  (heurigraph--typst-string edition))))))
    (when page
      (setq fields (append fields (list (format "  page: %d," page)))))
    (unless (bolp) (insert "\n"))
    (insert "#publication-reference(\n"
            (mapconcat #'identity fields "\n")
            "\n)")))

;;;###autoload
(defun heurigraph-insert-link (node text)
  "Insert a #link-to mention at point, selecting NODE by title.
Unlike typed semantic relations, #link-to is an inline navigational mention;
it may target either an id-bearing tree or a non-mathematical page.
Completion is title-first by default, but the inserted target remains the
stable id.  TEXT is the visible link label."
  (interactive
   (let* ((node (heurigraph--read-node "Link to title/id: "))
          (default (alist-get 'title node)))
     (list node (read-string "Link text: " default))))
  (let ((target (heurigraph--target-id node))
        (label (heurigraph--typst-string text)))
    (insert (format "#link-to(\"%s\", text: \"%s\")" target label))
    (message "Inserted link to %s (%s)" target (alist-get 'title node))))

;;;###autoload
(defun heurigraph-insert-transclusion (node)
  "Insert #transclude for NODE, a tree selected by title.
Pages are excluded because transclusion must expand an id-bearing tree."
  (interactive (list (heurigraph--read-node "Transclude title/id: " "tree")))
  (let ((target (heurigraph--target-id node)))
    (unless (bolp) (insert "\n"))
    (insert (format "#transclude(\"%s\")" target))
    (message "Inserted transclusion of %s (%s)" target (alist-get 'title node))))

(defun heurigraph--ontology-item-by-id (kind id)
  "Return the ontology KIND entry identified by ID, or nil."
  (seq-find (lambda (item) (equal (alist-get 'id item) id))
            (heurigraph--ontology-items kind)))

(defun heurigraph--assertion-context-node-candidates (field)
  "Return local node completion candidates suitable for context FIELD."
  (when (member field '("framework" "course" "level"))
    (let ((candidates (heurigraph--node-candidates "tree")))
      (dolist (filter heurigraph-assertion-context-candidate-filter-functions)
        (setq candidates (funcall filter field candidates)))
      candidates)))

(defun heurigraph--read-assertion-context-value (field required)
  "Read assertion context FIELD, requiring a value when REQUIRED is non-nil.
Known role prompts complete matching local nodes while still accepting an
external or not-yet-indexed context identifier."
  (let* ((candidates (heurigraph--assertion-context-node-candidates field))
         (prompt (format "%s%s: "
                         (capitalize field)
                         (if required " (required)" " (optional)")))
         (choice
          (if candidates
              (completing-read prompt candidates nil nil)
            (read-string prompt)))
         (node (and candidates (cdr (assoc choice candidates))))
         (value (string-trim (or (and node (alist-get 'id node)) choice))))
    (when (and required (string-empty-p value))
      (user-error "%s is required by this predicate" field))
    (unless (string-empty-p value)
      value)))

(defun heurigraph--read-assertion-context (predicate-item)
  "Prompt for required and selected optional fields of PREDICATE-ITEM."
  (let* ((required (copy-sequence
                    (or (alist-get 'required_context predicate-item) nil)))
         (optional
          (seq-remove (lambda (field) (member field required))
                      heurigraph-assertion-context-fields))
         context)
    (dolist (field required)
      (when-let ((value (heurigraph--read-assertion-context-value field t)))
        (setq context (append context (list (cons field value))))))
    (when optional
      (dolist (field
               (completing-read-multiple
                "Optional context fields (comma-separated, blank for none): "
                optional nil t))
        (when-let ((value
                    (heurigraph--read-assertion-context-value field nil)))
          (setq context (append context (list (cons field value)))))))
    context))

(defun heurigraph--read-assertion-target (predicate-item)
  "Read a local tree or allowed external target for PREDICATE-ITEM."
  (if (alist-get 'external_targets predicate-item)
      (let* ((candidates (heurigraph--node-candidates "tree"))
             (choice (completing-read
                      "Target tree or external id: " candidates nil nil))
             (node (cdr (assoc choice candidates))))
        (or node
            (progn
              (when (string-empty-p (string-trim choice))
                (user-error "Target must not be empty"))
              `((id . ,choice) (title . "external target")))))
    (heurigraph--read-node "Target tree: " "tree")))

(defun heurigraph--format-assertion (predicate target context)
  "Format a Typst relation from PREDICATE, TARGET, and CONTEXT alist."
  (let ((predicate (heurigraph--typst-string predicate))
        (target (heurigraph--typst-string target)))
    (if (null context)
        (format "#rel(\"%s\", \"%s\")" predicate target)
      (concat
       (format "#rel(\n  \"%s\",\n  \"%s\",\n" predicate target)
     (mapconcat
      (lambda (pair)
        (format "  %s: \"%s\"," (car pair)
                (heurigraph--typst-string (cdr pair))))
      context
      "\n")
       "\n)"))))

;;;###autoload
(defun heurigraph-insert-assertion (predicate node &optional context)
  "Insert a typed ontology assertion at point, picking the target by name.
PREDICATE completion comes from the resolved project registry.  Target NODE
is searched by title, id, subject, taxon, and keyword; predicates which permit
external targets also accept a manually entered external identity.  When the
predicate requires framework, course, level, audience, jurisdiction, or
language, prompt for those fields and include them in the inserted `#rel'.
Remaining context fields can be selected interactively when they qualify an
otherwise unscoped predicate.  Optional CONTEXT is an alist of field-name
strings to values."
  (interactive
   (let* ((item (heurigraph--read-ontology-item
                 "Predicate: " 'predicates))
          (predicate (alist-get 'id item))
          (node (heurigraph--read-assertion-target item)))
     (list predicate node (heurigraph--read-assertion-context item))))
  (let ((id (alist-get 'id node)))
    (unless (bolp) (insert "\n"))
    (insert (heurigraph--format-assertion predicate id context))
    (message "Linked %s -%s-> %s (%s)"
             (or (heurigraph--id-at-file) "this note") predicate id
             (alist-get 'title node))))

;;;###autoload
(defun heurigraph-find-node (node)
  "Jump to NODE's source by searching titles, ids, and aliases."
  (interactive (list (heurigraph--read-node "Find tree: ")))
  (find-file (expand-file-name (alist-get 'source node) (heurigraph--root))))

;;;###autoload
(defun heurigraph-new-page (kind title &optional year week)
  "Create a non-mathematical page of KIND.
KIND is content, journal, or weeknote.  TITLE is used for content and journal;
YEAR and WEEK identify a weeknote.  The CLI remains the authority for ids."
  (interactive
   (let ((kind (completing-read "Page kind: "
                                '("content" "journal" "weeknote")
                                nil t nil nil "content")))
     (if (equal kind "weeknote")
         (list kind nil
               (read-number "ISO year: "
                            (string-to-number (format-time-string "%G")))
               (read-number "ISO week: "
                            (string-to-number (format-time-string "%V"))))
       (list kind (heurigraph--read-page-title
                   (format "%s title (blank = today): " (capitalize kind)))))))
  (pcase kind
    ((or "content" "journal")
     (heurigraph--create-page title kind))
    ("weeknote"
     (unless (and (integerp year) (<= 1 year 9999))
       (user-error "ISO year must be between 1 and 9999"))
     (unless (and (integerp week) (<= 1 week 53))
       (user-error "ISO week must be between 1 and 53"))
     (let ((id (format "%04d-W%02d" year week)))
       (heurigraph--create-page
        (format "Weeknotes %s" id) "weeknote"
        (list "--year" (number-to-string year)
              "--week" (number-to-string week)))))
    (_ (user-error "Unknown page kind: %s" kind))))

(defun heurigraph--create-page (title kind &optional extra-args)
  "Create TITLE as page KIND with EXTRA-ARGS, then visit it."
  (let* ((args (append (list "node" "new" "--page" "--kind" kind "--json")
                       extra-args
                       (list title)))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph node new --page failed: %s"
                  (string-trim output)))
    (let* ((created (heurigraph--parse-json-output output "new page"))
           (path (alist-get 'path created)))
      (unless (and (stringp path) (file-exists-p path))
        (user-error "Heurigraph reported an invalid created page path: %S" path))
      (heurigraph--refresh-active-lsp)
      (find-file path))))

(defun heurigraph--read-page-title (prompt)
  "Read a page title using PROMPT; blank means today's date."
  (let ((title (read-string prompt)))
    (if (string-empty-p (string-trim title))
        (format-time-string "%Y-%m-%d")
      title)))

(defun heurigraph--diagram-title (file name)
  "Read the template title from diagram FILE, falling back to NAME."
  (or (with-temp-buffer
        (insert-file-contents-literally file nil 0 2048)
        (goto-char (point-min))
        (when (re-search-forward "^// Title: \\(.+\\)$" nil t)
          (string-trim (match-string 1))))
      (replace-regexp-in-string "[-_/]+" " " name)))

(defun heurigraph--diagram-candidates ()
  "Return completion candidates for standalone project diagrams."
  (let ((dir (expand-file-name "diagrams" (heurigraph--root))))
    (when (file-directory-p dir)
      (mapcar
       (lambda (file)
         (let* ((name (file-name-sans-extension (file-relative-name file dir)))
                (title (heurigraph--diagram-title file name)))
           (cons (format "%s  [%s]" title name)
                 (list :name name :title title :path file))))
       (sort
        (let ((case-fold-search nil))
          (seq-filter
           (lambda (file)
             (string-match-p
              (concat "\\`" heurigraph--uuid-regexp "\\.typ\\'")
              (file-name-nondirectory file)))
           (directory-files-recursively dir "\\.typ\\'")))
        #'string<)))))

(defun heurigraph--read-diagram ()
  "Select a project diagram and return its metadata plist."
  (let ((candidates (heurigraph--diagram-candidates)))
    (unless candidates
      (user-error "No published figures found; create and publish one in HeurigraphUX"))
    (cdr (assoc (completing-read "Diagram: " candidates nil t) candidates))))

;;;###autoload
(defun heurigraph-insert-diagram (name alt width caption)
  "Insert a CeTZ diagram reference with editable parameters.
NAME is relative to `diagrams/' without `.typ'.  ALT is the accessible image
description, WIDTH is a Typst length, and an empty CAPTION omits the caption."
  (interactive
   (let* ((diagram (heurigraph--read-diagram))
          (name (plist-get diagram :name))
          (title (plist-get diagram :title)))
     (list name
           (read-string "Alt text: " title)
           (read-string "Width: " heurigraph-diagram-default-width)
           (read-string "Caption (blank = none): "
                        heurigraph-diagram-default-caption))))
  (unless (bolp) (insert "\n"))
  (insert "#cetz-diagram(\n")
  (insert (format "  \"%s\",\n" (heurigraph--typst-string name)))
  (insert (format "  alt: \"%s\",\n" (heurigraph--typst-string alt)))
  (insert (format "  width: %s,\n" (if (string-empty-p width) "auto" width)))
  (unless (string-empty-p (string-trim caption))
    (insert (format "  caption: \"%s\",\n"
                    (heurigraph--typst-string caption))))
  (insert ")")
  (message "Inserted diagram %s" name))

(defun heurigraph--image-assets ()
  "Return managed project images reported by the CLI."
  (let* ((result
          (heurigraph--call-output '("import" "image" "list" "--json")))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph image list failed: %s" (string-trim output)))
    (let ((assets (heurigraph--parse-json-output output "image list")))
      (unless (listp assets)
        (user-error "Heurigraph returned an invalid image list"))
      assets)))

(defun heurigraph--image-public-path (asset)
  "Return the safe public path represented by image ASSET."
  (let ((id (alist-get 'id asset))
        (path (alist-get 'path asset)))
    (let ((case-fold-search nil))
      (unless (and (stringp id)
                   (string-match-p (concat "\\`" heurigraph--uuid-regexp "\\'") id)
                   (stringp path)
                   (string-match-p
                    (concat "\\`images/" (regexp-quote id) "\\.\\(?:png\\|jpe?g\\|gif\\|svg\\)\\'")
                    path))
        (user-error "Heurigraph returned invalid image metadata")))
    (concat "/" path)))

(defun heurigraph--read-image ()
  "Select and return one managed project image."
  (let* ((assets (heurigraph--image-assets))
         (candidates
          (mapcar
           (lambda (asset)
             (let ((id (alist-get 'id asset))
                   (extension (alist-get 'extension asset)))
               (cons (format "%s  [%s]" id extension) asset)))
           assets)))
    (unless candidates
      (user-error "No managed images found; run M-x heurigraph-import-image"))
    (cdr (assoc (completing-read "Image id: " candidates nil t) candidates))))

(defun heurigraph--image-mutation (args description)
  "Run image ARGS and return one validated asset for DESCRIPTION."
  (let* ((result (heurigraph--call-output (append args '("--json"))))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph %s failed: %s" description (string-trim output)))
    (let ((asset (heurigraph--parse-json-output output description)))
      (heurigraph--image-public-path asset)
      asset)))

;;;###autoload
(defun heurigraph-import-image (file)
  "Copy external image FILE into `images/' with a new UUID."
  (interactive (list (read-file-name "Import image: " nil nil t)))
  (let* ((asset (heurigraph--image-mutation
                 (list "import" "image" "add" (expand-file-name file))
                 "image add"))
         (id (alist-get 'id asset)))
    (message "Imported image %s" id)
    asset))

;;;###autoload
(defun heurigraph-insert-image (id path &optional alt)
  "Insert the managed image identified by ID at project-relative PATH.
Interactive selection is by UUID.  The emitted Typst source resolves
the stored extension.  ALT is informative text; an explicitly empty string
marks the occurrence decorative.  Non-interactive callers that omit ALT get
the deliberately invalid `alt: none' placeholder."
  (interactive
   (let ((asset (heurigraph--read-image)))
     (list
      (alist-get 'id asset)
      (alist-get 'path asset)
      (read-string "Alternative text (empty = decorative): "))))
  (let ((public-path
         (heurigraph--image-public-path `((id . ,id) (path . ,path)))))
    (unless (bolp) (insert "\n"))
    (insert
     (format
      "#image(\"%s\", alt: %s)"
      (heurigraph--typst-string public-path)
      (if (stringp alt)
          (format "\"%s\"" (heurigraph--typst-string alt))
        "none")))
    (message "Inserted image %s" id)))

(defun heurigraph--id-at-file ()
  "Extract the complete immutable UUID from the current source filename."
  (when-let ((name (and buffer-file-name (file-name-nondirectory buffer-file-name))))
    (let ((case-fold-search nil))
      (when (string-match (concat "\\`\\(" heurigraph--uuid-regexp "\\)\\.typ\\'") name)
        (match-string 1 name)))))

;;;###autoload
(defun heurigraph-init ()
  "Initialise a Heurigraph project with an engine-issued workspace UUID.
If the selected directory is already initialised, visit its authoritative
`heurigraph.toml' instead of invoking the CLI again."
  (interactive)
  (let* ((heurigraph-notes-directory
          (read-directory-name "Initialise Heurigraph in: " (heurigraph--root)))
         (config-path
          (expand-file-name "heurigraph.toml" heurigraph-notes-directory)))
    (make-directory heurigraph-notes-directory t)
    (if (file-exists-p config-path)
        (progn
          (find-file config-path)
          (message "Heurigraph project is already initialised; opened %s"
                   config-path))
      (let ((name (string-trim (read-string "Project name: "))))
        (when (string-empty-p name) (user-error "Project name is required"))
        (heurigraph--run (list "init" "--name" name))))))
(provide 'heurigraph)

;;; heurigraph.el ends here
