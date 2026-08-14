;;; heurigraph.el --- Authoring layer for Heurigraph  -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 4.2.0
;; Keywords: tools, tex, outlines
;; Package-Requires: ((emacs "30.2"))
;; URL: https://github.com/mholson/Heurigraph
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; A thin Emacs layer over the `heurigraph' command-line tool.  It does not
;; reimplement any Heurigraph logic; every command shells out to the binary so
;; that Emacs and CI always agree on behaviour.  The CLI is the source of
;; truth; this file is just ergonomics: read and edit the project ontology,
;; create notes, insert qualified assertions, scan, validate, export the graph,
;; and compile a note to PDF without leaving the buffer.
;;
;; Setup:
;;   (require 'heurigraph)
;;   (setq heurigraph-notes-directory "~/forest")
;;
;; Then M-x heurigraph-new, heurigraph-insert-link, heurigraph-insert-transclusion, heurigraph-validate, heurigraph-build, heurigraph-watch, etc.

;;; Code:

(require 'project)
(require 'compile)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup heurigraph nil
  "Authoring layer for the Heurigraph publishing engine."
  :group 'tools
  :prefix "heurigraph-")

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

(defcustom heurigraph-output-display 'auto
  "How synchronous Heurigraph command output is presented.
The full output is always retained in the command's output buffer.

With `auto', successful output that fits within
`heurigraph-minibuffer-output-max-length' is shown as one compact echo-area
message; longer output opens the output buffer.  With `minibuffer', every
successful command uses a compact, possibly truncated echo-area message.
With `buffer', every command opens its output buffer, preserving the behaviour
from Heurigraph 2.0.4 and earlier.

Failures always open their output buffer so diagnostics remain complete.
Asynchronous build commands continue to use compilation buffers independently
of this setting."
  :type '(choice
          (const :tag "Automatic" auto)
          (const :tag "Minibuffer for successful commands" minibuffer)
          (const :tag "Always show output buffer" buffer))
  :group 'heurigraph)

(defcustom heurigraph-minibuffer-output-max-length 160
  "Maximum width of a compact Heurigraph echo-area message.
In `auto' output mode, successful output wider than this opens its output
buffer.  In `minibuffer' mode, output wider than this is truncated in the
echo area; the complete text remains available in the output buffer."
  :type 'natnum
  :group 'heurigraph)

(defcustom heurigraph-default-subject nil
  "Default ontology subject offered by \\[heurigraph-new]."
  :type '(choice (const :tag "None" nil) string)
  :group 'heurigraph)

(defcustom heurigraph-subjectless-taxon-prefixes '()
  "Taxon prefixes for which \\[heurigraph-new] should not offer a default subject.
Domain extensions may set this buffer-locally; the resolved ontology remains
authoritative."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-new-public-by-default nil
  "When non-nil, create new knowledge nodes with `public: true'.
This affects only `heurigraph-new'; it passes `--public' to the Heurigraph CLI.
Keep the default nil when new material should require an explicit publication
decision."
  :type 'boolean
  :safe #'booleanp
  :group 'heurigraph)

(defcustom heurigraph-ontology-auto-refresh t
  "When non-nil, refresh stale ontology completion data on demand.
Heurigraph writes the resolved project registry to `ontology.json' under the
configured build directory.  If that file is absent or older than a source
under the configured ontology root, authoring prompts run `heurigraph scan'
once before reading it.  Set this to nil to use the last generated registry
or the built-in fallback completion lists."
  :type 'boolean
  :group 'heurigraph)

(defcustom heurigraph-book-default-profile "student"
  "Default publication profile used by Heurigraph book commands."
  :type 'string
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

(defvar-local heurigraph-book-profile nil
  "Publication profile selected for the current collection buffer.")

(defvar heurigraph--last-book-output nil
  "Plist describing the latest book preview (:root :book :profile :path).")

;; Used only for completion prompts; the ontology registry remains authoritative.
(defcustom heurigraph-taxons '()
  "Fallback taxon ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

;;; Internals ----------------------------------------------------------------

(defcustom heurigraph-subjects '()
  "Fallback subject ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-predicate-types '()
  "Fallback predicate ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-publication-reference-roles
  '("appears-in" "adapted-from" "reproduced-in" "referenced-by" "inspired-by")
  "Controlled role values accepted by publication-reference metadata."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-assertion-context-fields
  '("framework" "stage" "audience" "jurisdiction" "language")
  "Context fields offered by `heurigraph-insert-assertion'.
Fields required by the selected ontology predicate are always prompted.
Any remaining fields may be selected interactively and left absent."
  :type '(repeat string)
  :group 'heurigraph)

(defvar heurigraph-assertion-context-candidate-filter-functions nil
  "Functions that refine local context candidates for a domain module.
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

(defun heurigraph--require-executable ()
  "Return `heurigraph-executable', or raise an actionable `user-error'."
  (let* ((configured heurigraph-executable)
         (explicit (and (stringp configured)
                        (string-match-p "[/\\\\]" configured)
                        (expand-file-name configured)))
         (available (and (stringp configured)
                         (not (string-empty-p configured))
                         (or (executable-find configured)
                             (and explicit (file-executable-p explicit))))))
    (unless available
      (user-error
       "Cannot find Heurigraph executable `%s'; install it or customize `heurigraph-executable'"
       configured))
    configured))

(defun heurigraph--compact-output (output)
  "Return OUTPUT trimmed and collapsed to one line."
  (replace-regexp-in-string
   "[[:space:]\n\r]+" " " (string-trim output)))

(defun heurigraph--output-in-minibuffer-p (code output)
  "Return non-nil when successful CODE and OUTPUT belong in the echo area."
  (and (integerp code)
       (zerop code)
       (pcase heurigraph-output-display
         ('minibuffer t)
         ('auto
          (<= (string-width (heurigraph--compact-output output))
              heurigraph-minibuffer-output-max-length))
         (_ nil))))

(defun heurigraph--minibuffer-summary (args output)
  "Return a compact status message for command ARGS and OUTPUT."
  (let* ((command (or (car args) "command"))
         (compact (heurigraph--compact-output output))
         (detail (if (string-empty-p compact)
                     "completed successfully"
                   (truncate-string-to-width
                    compact heurigraph-minibuffer-output-max-length
                    nil nil "…"))))
    (format "Heurigraph %s: %s" command detail)))

(defun heurigraph--present-output (args buffer code output)
  "Present Heurigraph ARGS result in BUFFER according to CODE and OUTPUT."
  (if (heurigraph--output-in-minibuffer-p code output)
      (message "%s" (heurigraph--minibuffer-summary args output))
    (display-buffer buffer)))

(defun heurigraph--run (args &optional buffer-name)
  "Run the heurigraph binary with ARGS (a list of strings) in the project root.
Output is retained in BUFFER-NAME (default *heurigraph*) and presented according
to `heurigraph-output-display'.  Returns the exit code."
  (let ((default-directory (heurigraph--root))
        (executable (heurigraph--require-executable))
        (buf (get-buffer-create (or buffer-name "*heurigraph*"))))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "$ %s %s\n\n"
                      executable (string-join args " "))))
    (let* ((output-start (with-current-buffer buf (point-max)))
           (code (apply #'call-process executable nil buf t args))
           (output (with-current-buffer buf
                     (buffer-substring-no-properties
                      output-start (point-max)))))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (format "\n[exit %s]\n" code))
        (special-mode))
      (heurigraph--present-output args buf code output)
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
      (json-parse-string output :object-type 'alist :array-type 'list)
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

(defun heurigraph--config-string (section key fallback)
  "Read string KEY from TOML SECTION in heurigraph.toml, or return FALLBACK.
This intentionally handles only the quoted project-path values needed by the
editor layer; the CLI remains responsible for complete TOML validation."
  (let ((path (expand-file-name "heurigraph.toml" (heurigraph--root))))
    (if (not (file-readable-p path))
        fallback
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (if (not (re-search-forward
                  (format "^[[:space:]]*\\[%s\\][[:space:]]*$"
                          (regexp-quote section))
                  nil t))
            fallback
          (let ((end (save-excursion
                       (or (and (re-search-forward "^[[:space:]]*\\[" nil t)
                                (match-beginning 0))
                           (point-max)))))
            (if (re-search-forward
                 (format "^[[:space:]]*%s[[:space:]]*=[[:space:]]*\\(\"\\(?:\\\\.\\|[^\"]\\)*\"\\)"
                         (regexp-quote key))
                 end t)
                (condition-case nil
                    (json-parse-string (match-string-no-properties 1))
                  (error fallback))
              fallback)))))))

(defun heurigraph--ontology-root-path ()
  "Return the configured project ontology directory."
  (expand-file-name (heurigraph--config-string "ontology" "root" "ontology")
                    (heurigraph--root)))

(defun heurigraph--ontology-json-path ()
  "Return the resolved ontology export path for the current project."
  (expand-file-name
   "ontology.json"
   (expand-file-name (heurigraph--config-string "project" "build_dir" "build")
                     (heurigraph--root))))

(defun heurigraph--ontology-source-files ()
  "Return project ontology TOML files, or nil when the directory is absent."
  (let ((directory (heurigraph--ontology-root-path)))
    (when (file-directory-p directory)
      (directory-files-recursively directory "\\.toml\\'"))))

(defun heurigraph--ontology-export-stale-p ()
  "Return non-nil when the resolved ontology export is missing or stale."
  (let ((export (heurigraph--ontology-json-path)))
    (or (not (file-readable-p export))
        (seq-some (lambda (source) (file-newer-than-file-p source export))
                  (heurigraph--ontology-source-files)))))

(defun heurigraph--refresh-ontology-export ()
  "Regenerate the configured ontology JSON export and return its registry."
  (let* ((result (heurigraph--call-output '("scan")))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Cannot refresh the project ontology: %s"
                  (string-trim output)))
    (heurigraph--read-ontology-export)))

(defun heurigraph--read-ontology-export ()
  "Read and return the resolved project ontology, or nil if unavailable."
  (let ((path (heurigraph--ontology-json-path)))
    (when (file-readable-p path)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents path)
            (json-parse-buffer :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil))
        (error
         (display-warning
          'heurigraph
          (format "Could not read %s: %s" path (error-message-string err)))
         nil)))))

(defun heurigraph--ontology-registry (&optional force)
  "Return the resolved project ontology.
With FORCE, always regenerate it.  Otherwise regenerate only when automatic
refresh is enabled and the export is missing or older than ontology sources."
  (if (or force
          (and heurigraph-ontology-auto-refresh
               (heurigraph--ontology-export-stale-p)))
      (heurigraph--refresh-ontology-export)
    (heurigraph--read-ontology-export)))

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

(defun heurigraph--ontology-candidates (kind fallback)
  "Return completion candidates for ontology KIND, using FALLBACK ids.
Each candidate maps its display label to the complete resolved ontology item."
  (let ((items (heurigraph--ontology-items kind)))
    (if items
        (mapcar (lambda (item)
                  (cons (heurigraph--ontology-item-label item) item))
                items)
      (mapcar (lambda (id)
                (cons id `((id . ,id))))
              fallback))))

(defun heurigraph--read-ontology-item (prompt kind fallback &optional default)
  "Read one ontology KIND entry with PROMPT, FALLBACK ids, and DEFAULT id."
  (let* ((candidates (heurigraph--ontology-candidates kind fallback))
         (default-label
          (car (seq-find (lambda (candidate)
                           (equal (alist-get 'id (cdr candidate)) default))
                         candidates)))
         (choice (completing-read prompt candidates nil t nil nil default-label)))
    (cdr (assoc choice candidates))))

(defun heurigraph--read-ontology-id (prompt kind fallback &optional default)
  "Read and return an ontology id with PROMPT, KIND, FALLBACK, and DEFAULT."
  (alist-get 'id
             (heurigraph--read-ontology-item prompt kind fallback default)))

(defun heurigraph--read-optional-subject (prompt fallback &optional default)
  "Read an optional subject with PROMPT, FALLBACK ids, and DEFAULT.
Completion includes an explicit choice that returns nil.  When DEFAULT is nil,
that choice is selected by default."
  (let* ((none-label "[No subject]")
         (candidates (heurigraph--ontology-candidates 'subjects fallback))
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
(defun heurigraph-ontology-refresh ()
  "Validate sources and refresh project-owned ontology completion data.
This runs `heurigraph scan', regenerating ontology JSON in the configured
build directory.  Restart or refresh an active language-server workspace
separately after schema changes."
  (interactive)
  (let* ((registry (heurigraph--ontology-registry t))
         (version (alist-get 'ontology_version registry)))
    (message "Heurigraph ontology %s refreshed: %d taxons, %d subjects, %d predicates, %d structures"
             version
             (length (alist-get 'taxons registry))
             (length (alist-get 'subjects registry))
             (length (alist-get 'predicates registry))
             (length (alist-get 'structures registry)))))

;;;###autoload
(defun heurigraph-ontology-open (file)
  "Open a project ontology FILE selected relative to `ontology/'."
  (interactive
   (let* ((root (file-name-as-directory
                 (heurigraph--ontology-root-path)))
          (files (heurigraph--ontology-source-files))
          (relative (mapcar (lambda (path) (file-relative-name path root)) files))
          (manifest (heurigraph--config-string
                     "ontology" "manifest" "manifest.toml")))
     (unless files
       (user-error "No ontology directory found; run M-x heurigraph-init first"))
     (list (completing-read "Ontology file: " relative nil t nil nil
                            manifest))))
  (find-file (expand-file-name file (heurigraph--ontology-root-path))))

(defun heurigraph--ontology-ids (kind fallback)
  "Return resolved ids for ontology KIND, or FALLBACK when unavailable."
  (or (mapcar (lambda (item) (alist-get 'id item))
              (heurigraph--ontology-items kind))
      fallback))

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
          (parents (heurigraph--ontology-ids 'taxons heurigraph-taxons)))
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
          (subjects (heurigraph--ontology-ids 'subjects heurigraph-subjects)))
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
   (let ((structures (heurigraph--ontology-ids 'structures nil)))
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
   (let ((taxons (heurigraph--ontology-ids 'taxons heurigraph-taxons)))
     (list (read-string "Predicate id (namespace:term): ")
           (read-string "Label: ")
           (read-string "Semantic layer: ")
           (completing-read-multiple "Source taxons (comma-separated): " taxons nil t)
           (completing-read-multiple "Target taxons (comma-separated): " taxons nil t)
           (completing-read-multiple
            "Required context fields: "
            '("framework" "stage" "audience" "jurisdiction" "language") nil t)
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

(defun heurigraph--compilation-command (args)
  "Return a shell-safe command for Heurigraph ARGS."
  (mapconcat #'shell-quote-argument
             (cons (heurigraph--require-executable) args)
             " "))

(defun heurigraph--compile (args buffer-name)
  "Run Heurigraph ARGS in a compilation buffer named BUFFER-NAME."
  (let ((default-directory (heurigraph--root))
        (compilation-buffer-name-function (lambda (_mode) buffer-name)))
    (compilation-start (heurigraph--compilation-command args)
                       'compilation-mode)))

(defun heurigraph--typst-call-end (open)
  "Return the position after the Typst call closing OPEN, or nil.
OPEN must point at an opening parenthesis.  This scanner is independent of
the current major mode's syntax table, which tree-sitter modes may not teach
to `forward-sexp'.  Strings, content blocks, and line and nested block
comments are skipped."
  (save-excursion
    (goto-char open)
    (let ((depth 0)
          (content-depth 0)
          (state 'code)
          (block-depth 0)
          result)
      (while (and (< (point) (point-max)) (not result))
        (let ((char (char-after))
              (next (char-after (1+ (point)))))
          (pcase state
            ('string
             (cond
              ((eq char ?\\) (forward-char (min 2 (- (point-max) (point)))))
              ((eq char ?\") (setq state 'code) (forward-char 1))
              (t (forward-char 1))))
            ('line-comment
             (when (eq char ?\n) (setq state 'code))
             (forward-char 1))
            ('block-comment
             (cond
              ((and (eq char ?/) (eq next ?*))
               (setq block-depth (1+ block-depth))
               (forward-char 2))
              ((and (eq char ?*) (eq next ?/))
               (setq block-depth (1- block-depth))
               (forward-char 2)
               (when (zerop block-depth) (setq state 'code)))
              (t (forward-char 1))))
            ('code
             (cond
              ((and (eq char ?/) (eq next ?/))
               (setq state 'line-comment)
               (forward-char 2))
              ((and (eq char ?/) (eq next ?*))
               (setq state 'block-comment block-depth 1)
               (forward-char 2))
              ((eq char ?\") (setq state 'string) (forward-char 1))
              ((and (> content-depth 0) (eq char ?\\))
               (forward-char (min 2 (- (point-max) (point)))))
              ((eq char ?\[)
               (setq content-depth (1+ content-depth))
               (forward-char 1))
              ((and (eq char ?\]) (> content-depth 0))
               (setq content-depth (1- content-depth))
               (forward-char 1))
              ((and (zerop content-depth) (eq char ?\())
               (setq depth (1+ depth))
               (forward-char 1))
              ((and (zerop content-depth) (eq char ?\)))
               (setq depth (1- depth))
               (forward-char 1)
               (when (zerop depth) (setq result (point))))
              (t (forward-char 1)))))))
      result)))

(defun heurigraph--typst-string-literals (start end)
  "Return the non-empty Typst string literals in code between START and END.
Quotes inside line comments, nested block comments, and content blocks are
ignored, mirroring `heurigraph--typst-call-end', so a quoted token in a
comment is never mistaken for a real value."
  (save-excursion
    (goto-char start)
    (let ((state 'code)
          (block-depth 0)
          (content-depth 0)
          (literal-start nil)
          literals)
      (while (< (point) end)
        (let ((char (char-after))
              (next (char-after (1+ (point)))))
          (pcase state
            ('string
             (cond
              ((eq char ?\\) (forward-char (min 2 (- end (point)))))
              ((eq char ?\")
               (when (> (point) literal-start)
                 (push (buffer-substring-no-properties literal-start (point)) literals))
               (setq state 'code literal-start nil)
               (forward-char 1))
              (t (forward-char 1))))
            ('line-comment
             (when (eq char ?\n) (setq state 'code))
             (forward-char 1))
            ('block-comment
             (cond
              ((and (eq char ?/) (eq next ?*))
               (setq block-depth (1+ block-depth))
               (forward-char 2))
              ((and (eq char ?*) (eq next ?/))
               (setq block-depth (1- block-depth))
               (forward-char 2)
               (when (zerop block-depth) (setq state 'code)))
              (t (forward-char 1))))
            ('code
             (cond
              ((and (eq char ?/) (eq next ?/))
               (setq state 'line-comment)
               (forward-char 2))
              ((and (eq char ?/) (eq next ?*))
               (setq state 'block-comment block-depth 1)
               (forward-char 2))
              ((and (zerop content-depth) (eq char ?\"))
               (setq state 'string literal-start (1+ (point)))
               (forward-char 1))
              ((and (> content-depth 0) (eq char ?\\))
               (forward-char (min 2 (- end (point)))))
              ((eq char ?\[)
               (setq content-depth (1+ content-depth))
               (forward-char 1))
              ((and (eq char ?\]) (> content-depth 0))
               (setq content-depth (1- content-depth))
               (forward-char 1))
              (t (forward-char 1)))))))
      (nreverse literals))))

(defun heurigraph--find-top-level-typst-call (regexp)
  "Return bounds for the first top-level Typst call matching REGEXP.
The returned pair is (OPEN-END . CALL-END).  Calls in strings, comments,
content blocks, or another call's arguments are ignored.  REGEXP must match
through the opening parenthesis."
  (save-excursion
    (goto-char (point-min))
    (let ((state 'code)
          (block-depth 0)
          (content-depth 0)
          (paren-depth 0)
          result)
      (while (and (< (point) (point-max)) (not result))
        (let ((char (char-after))
              (next (char-after (1+ (point)))))
          (pcase state
            ('string
             (cond
              ((eq char ?\\) (forward-char (min 2 (- (point-max) (point)))))
              ((eq char ?\") (setq state 'code) (forward-char 1))
              (t (forward-char 1))))
            ('line-comment
             (when (eq char ?\n) (setq state 'code))
             (forward-char 1))
            ('block-comment
             (cond
              ((and (eq char ?/) (eq next ?*))
               (setq block-depth (1+ block-depth))
               (forward-char 2))
              ((and (eq char ?*) (eq next ?/))
               (setq block-depth (1- block-depth))
               (forward-char 2)
               (when (zerop block-depth) (setq state 'code)))
              (t (forward-char 1))))
            ('code
             (cond
              ((and (zerop content-depth) (zerop paren-depth)
                    (looking-at regexp))
               (let* ((open-end (match-end 0))
                      (call-end (heurigraph--typst-call-end (1- open-end))))
                 (if call-end
                     (setq result (cons open-end call-end))
                   (goto-char open-end))))
              ((and (eq char ?/) (eq next ?/))
               (setq state 'line-comment)
               (forward-char 2))
              ((and (eq char ?/) (eq next ?*))
               (setq state 'block-comment block-depth 1)
               (forward-char 2))
              ((eq char ?\") (setq state 'string) (forward-char 1))
              ((and (> content-depth 0) (eq char ?\\))
               (forward-char (min 2 (- (point-max) (point)))))
              ((eq char ?\[)
               (setq content-depth (1+ content-depth))
               (forward-char 1))
              ((and (eq char ?\]) (> content-depth 0))
               (setq content-depth (1- content-depth))
               (forward-char 1))
              ((and (zerop content-depth) (eq char ?\())
               (setq paren-depth (1+ paren-depth))
               (forward-char 1))
              ((and (zerop content-depth) (eq char ?\)) (> paren-depth 0))
               (setq paren-depth (1- paren-depth))
               (forward-char 1))
              (t (forward-char 1)))))))
      result)))

(defun heurigraph--metadata-call ()
  "Return (OPEN-END . CALL-END) for the first metadata call, or nil."
  (heurigraph--find-top-level-typst-call
   "#\\(?:knowledge-node\\|note-meta\\)("))

(defun heurigraph--knowledge-node-call ()
  "Return (OPEN-END . CALL-END) for the first knowledge-node call, or nil."
  (heurigraph--find-top-level-typst-call "#knowledge-node("))

(defun heurigraph--metadata-field-value-starts (bounds field)
  "Collect all top-level FIELD value positions within metadata BOUNDS.
Strings, content blocks, line comments, nested block comments, and nested
parenthesized values are skipped while looking for the field name."
  (save-excursion
    (goto-char (car bounds))
    (let ((depth 1)
          (content-depth 0)
          (state 'code)
          (block-depth 0)
          (field-rx (concat "\\_<" (regexp-quote field)
                            "\\_>[[:space:]]*:"))
          starts)
      (while (< (point) (1- (cdr bounds)))
          (let ((char (char-after))
                (next (char-after (1+ (point)))))
            (pcase state
              ('string
               (cond
                ((eq char ?\\) (forward-char (min 2 (- (point-max) (point)))))
                ((eq char ?\") (setq state 'code) (forward-char 1))
                (t (forward-char 1))))
              ('line-comment
               (when (eq char ?\n) (setq state 'code))
               (forward-char 1))
              ('block-comment
               (cond
                ((and (eq char ?/) (eq next ?*))
                 (setq block-depth (1+ block-depth))
                 (forward-char 2))
                ((and (eq char ?*) (eq next ?/))
                 (setq block-depth (1- block-depth))
                 (forward-char 2)
                 (when (zerop block-depth) (setq state 'code)))
                (t (forward-char 1))))
              ('code
               (cond
                ((and (= depth 1) (zerop content-depth)
                      (looking-at field-rx))
                 (goto-char (match-end 0))
                 (skip-chars-forward " \t\r\n" (cdr bounds))
                 (push (point) starts))
                ((and (eq char ?/) (eq next ?/))
                 (setq state 'line-comment)
                 (forward-char 2))
                ((and (eq char ?/) (eq next ?*))
                 (setq state 'block-comment block-depth 1)
                 (forward-char 2))
                ((eq char ?\") (setq state 'string) (forward-char 1))
                ((and (> content-depth 0) (eq char ?\\))
                 (forward-char (min 2 (- (point-max) (point)))))
                ((eq char ?\[)
                 (setq content-depth (1+ content-depth))
                 (forward-char 1))
                ((and (eq char ?\]) (> content-depth 0))
                 (setq content-depth (1- content-depth))
                 (forward-char 1))
                ((and (zerop content-depth) (eq char ?\())
                 (setq depth (1+ depth))
                 (forward-char 1))
                ((and (zerop content-depth) (eq char ?\)))
                 (setq depth (1- depth))
                 (forward-char 1))
                (t (forward-char 1)))))))
      (nreverse starts))))

(defun heurigraph--metadata-field-value-start (bounds field)
  "Return the first value start for top-level FIELD within metadata BOUNDS."
  (car (heurigraph--metadata-field-value-starts bounds field)))

(defun heurigraph--subject-metadata ()
  "Return a plist describing the current tree's subject metadata.
The plist contains `:call', `:tuple', and `:ids'.  `:tuple' is nil when the
knowledge-node has no subjects field yet."
  (let ((call (heurigraph--knowledge-node-call)))
    (unless call
      (user-error "No #knowledge-node declaration found"))
    (let ((start (heurigraph--metadata-field-value-start call "subjects")))
      (if (null start)
          (list :call call :tuple nil :ids nil)
        (unless (eq (char-after start) ?\()
          (user-error "The knowledge-node subjects field is not a tuple"))
        (let ((end (heurigraph--typst-call-end start)))
          (unless (and end (<= end (cdr call)))
            (user-error "The knowledge-node subjects tuple is incomplete"))
          (list :call call
                :tuple (cons start end)
                :ids (heurigraph--typst-string-literals (1+ start) (1- end))))))))

(defun heurigraph--read-additional-subjects ()
  "Read one or more subjects not already present in the current tree."
  (let* ((existing (plist-get (heurigraph--subject-metadata) :ids))
         (candidates
          (seq-remove
           (lambda (candidate)
             (member (alist-get 'id (cdr candidate)) existing))
           (heurigraph--ontology-candidates 'subjects heurigraph-subjects))))
    (unless candidates
      (user-error "This tree already has every registered subject"))
    (let ((choices
           (completing-read-multiple
            "Add subjects (comma-separated): " candidates nil t)))
      (delete-dups
       (mapcar (lambda (choice) (alist-get 'id (cdr (assoc choice candidates))))
               choices)))))

(defun heurigraph--insert-subject-tuple-items (tuple subjects)
  "Append SUBJECTS to the Typst subject TUPLE while preserving its layout."
  (let* ((open (car tuple))
         (close (1- (cdr tuple)))
         (multiline (save-excursion
                      (goto-char (1+ open))
                      (search-forward "\n" close t))))
    (if (not multiline)
        (save-excursion
          (goto-char close)
          (skip-chars-backward " \t" (1+ open))
          (let ((prefix
                 (cond
                  ((= (point) (1+ open)) "")
                  ((eq (char-before) ?,) " ")
                  (t ", "))))
            (insert prefix
                    (mapconcat (lambda (id) (format "\"%s\"," id))
                               subjects " "))))
      (save-excursion
        (goto-char close)
        (let* ((line-start (line-beginning-position))
               (close-prefix (buffer-substring-no-properties line-start close)))
          (if (string-match-p "\\`[ \t]*\\'" close-prefix)
              (let ((indent (concat close-prefix "  ")))
                (goto-char line-start)
                (dolist (id subjects)
                  (insert indent "\"" id "\",\n")))
            ;; Preserve non-canonical multiline tuples and their comments.
            (goto-char close)
            (skip-chars-backward " \t" (1+ open))
            (insert (if (eq (char-before) ?,) " " ", ")
                    (mapconcat (lambda (id) (format "\"%s\"," id))
                               subjects " "))))))))

;;;###autoload
(defun heurigraph-add-subjects (subjects)
  "Add ontology SUBJECTS to the current tree's knowledge-node metadata.
Interactively, completion shows the project registry's subject labels,
identifiers, and descriptions and accepts several comma-separated choices.
Existing subjects are excluded from completion and never duplicated."
  (interactive (list (heurigraph--read-additional-subjects)))
  (barf-if-buffer-read-only)
  (let* ((metadata (heurigraph--subject-metadata))
         (existing (plist-get metadata :ids))
         (subjects (seq-uniq (seq-remove (lambda (id) (member id existing))
                                        subjects)
                             #'equal)))
    (unless subjects
      (user-error "No new subjects selected"))
    (save-excursion
      (if-let ((tuple (plist-get metadata :tuple)))
          (heurigraph--insert-subject-tuple-items tuple subjects)
        (let* ((open-end (car (plist-get metadata :call)))
               (multiline (eq (char-after open-end) ?\n)))
          (goto-char open-end)
          (insert (if multiline "\n  subjects: (" "subjects: (")
                  (mapconcat (lambda (id) (format "\"%s\"," id))
                             subjects " ")
                  (if multiline ")," "), ")))))
    (message "Heurigraph added %s" (string-join subjects ", "))))

(defun heurigraph--metadata-public-value ()
  "Return the current buffer's explicit publication value, or nil."
  (when-let ((bounds (heurigraph--metadata-call)))
    (let ((starts (heurigraph--metadata-field-value-starts bounds "public")))
      (when (> (length starts) 1)
        (user-error "Metadata contains duplicate top-level public fields"))
      (when-let ((start (car starts)))
        (save-excursion
          (goto-char start)
          (cond
           ((looking-at "true\\_>") t)
           ((looking-at "false\\_>") nil)
           (t (user-error "The metadata public field must be true or false"))))))))

;;;###autoload
(defun heurigraph-toggle-public ()
  "Toggle explicit publication consent for the current note or page.
Missing `public' metadata means private and is changed to `public: true'.
Publishing requires confirmation; making an item private does not."
  (interactive)
  (save-excursion
    (let ((bounds (heurigraph--metadata-call)))
      (unless bounds
        (user-error "No #knowledge-node or #note-meta declaration found"))
      (let* ((open-end (car bounds))
             (starts (heurigraph--metadata-field-value-starts bounds "public")))
        (when (> (length starts) 1)
          (user-error "Metadata contains duplicate top-level public fields"))
        (let* ((start (car starts))
               (current
                (when start
                  (save-excursion
                    (goto-char start)
                    (cond
                     ((looking-at "true\\_>") "true")
                     ((looking-at "false\\_>") "false")
                     (t (user-error
                         "The metadata public field must be true or false"))))))
             (next (if (string= current "true") "false" "true")))
        (when (and (string= next "true")
                   (not (yes-or-no-p "Mark this item PUBLIC for generated publications? ")))
          (user-error "Publication unchanged"))
        (if current
            (progn
              (delete-region start (+ start (length current)))
              (goto-char start)
              (insert next))
          (goto-char open-end)
          (insert (format "\n  public: %s," next)))
        (message "Heurigraph: this item is now %s"
                 (if (string= next "true") "PUBLIC" "private")))))))

;;; Commands -----------------------------------------------------------------

;;;###autoload
(defun heurigraph-new (title id taxon subject aliases)
  "Create a new note titled TITLE with TAXON.
Leave ID blank to auto-allocate the next free base-36 id (Forester
style) from `[ids].default_prefix'; give an explicit id like
mho-0X4B to choose one—the CLI refuses collisions.  SUBJECT and
comma-separated ALIASES are optional.  Delegates to `heurigraph new',
then visits the created file if it can be located."
  (interactive
   (let* ((title (heurigraph--read-new-node-title))
          (id (read-string "Id (blank = auto-allocate): "))
          (taxon
           (heurigraph--read-ontology-id
            "Taxon: " 'taxons heurigraph-taxons))
          (subject
           (heurigraph--read-optional-subject
            "Subject (optional): " heurigraph-subjects
            (unless (seq-some (lambda (prefix)
                                (string-prefix-p prefix taxon))
                              heurigraph-subjectless-taxon-prefixes)
              heurigraph-default-subject)))
          (aliases
           (read-string "Aliases (comma-separated, blank for none): ")))
     (list title id taxon subject aliases)))
  (let ((args (list "new" title "--taxon" taxon "--json")))
    (if (and id (not (string-empty-p id)))
        (setq args (append args (list "--id" id))))
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
        (user-error "Heurigraph new failed: %s" (string-trim output)))
      ;; `heurigraph new' writes outside the LSP protocol.  Refresh while the
      ;; originating note buffer still owns the active workspace, before
      ;; visiting the newly created file.
      (heurigraph--refresh-active-lsp)
      (let ((path (alist-get 'path created)))
        (unless (and (stringp path) (file-exists-p path))
          (user-error "Heurigraph reported an invalid created path: %S" path))
        (find-file path)))))

;;;###autoload
(defun heurigraph-next-id ()
  "Show the next free tree id without creating anything.
The namespace comes from `[ids].default_prefix'."
  (interactive)
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output '("next-id"))))
    (unless (zerop code)
      (user-error "Heurigraph next-id failed: %s" (string-trim output)))
    (message "Next id: %s" (string-trim output))))

;;;###autoload
(defun heurigraph-scan ()
  "Scan the forest and write the graph JSON (`heurigraph scan')."
  (interactive)
  (heurigraph--run '("scan")))

;;;###autoload
(defun heurigraph-validate ()
  "Validate the forest and report diagnostics (`heurigraph validate').
A non-zero exit is surfaced as an Emacs message."
  (interactive)
  (let ((code (heurigraph--run '("validate"))))
    (message (if (zerop code)
                 "Heurigraph: forest is valid"
               "Heurigraph: validation found problems (see *heurigraph*)"))))

;;;###autoload
(defun heurigraph-graph ()
  "Export the knowledge graph as JSON (`heurigraph graph --format json')."
  (interactive)
  (heurigraph--run '("graph" "--format" "json")))

;;;###autoload
(defun heurigraph-build ()
  "Render the static web site asynchronously (`heurigraph build --web')."
  (interactive)
  (heurigraph--compile '("build" "--web") "*heurigraph-build*"))

(defvar heurigraph--serve-processes (make-hash-table :test #'equal)
  "Running `heurigraph serve' processes keyed by canonical project root.")

(defconst heurigraph--server-ready-attempts 50
  "Number of local connection attempts before browser opening is abandoned.")

(defun heurigraph--browse-when-server-ready (process url port &optional attempt)
  "Open URL once PROCESS accepts local TCP connections on PORT.
ATTEMPT records how many asynchronous readiness checks have completed."
  (let ((attempt (or attempt 0)))
    (cond
     ((not (process-live-p process))
      (message "Heurigraph: server exited before becoming ready (see %s)"
               (buffer-name (process-buffer process))))
     ((condition-case nil
          (let ((probe (open-network-stream
                        "heurigraph-readiness-probe" nil "127.0.0.1" port)))
            (delete-process probe)
            t)
        (error nil))
      (browse-url url))
     ((>= attempt heurigraph--server-ready-attempts)
      (message "Heurigraph: server did not become ready at %s" url))
     (t
      (run-at-time 0.1 nil #'heurigraph--browse-when-server-ready
                   process url port (1+ attempt))))))

;;;###autoload
(defun heurigraph-serve (&optional port)
  "Serve the rendered forest locally and open it in a browser.
Starts `heurigraph serve' (default PORT 8383) as a background process;
call again with the server running to stop it."
  (interactive)
  (let* ((root (file-truename (heurigraph--root)))
         (running (gethash root heurigraph--serve-processes)))
  (if (process-live-p running)
      (progn
        (kill-process running)
        (remhash root heurigraph--serve-processes)
        (message "Heurigraph: server stopped"))
    (let ((default-directory root)
          (executable (heurigraph--require-executable))
          (port (or port 8383))
          process)
      (setq process
            (start-process "heurigraph-serve" "*heurigraph-serve*" executable
                           "serve" "--port" (number-to-string port)))
      (puthash root process heurigraph--serve-processes)
      (heurigraph--browse-when-server-ready
       process (format "http://127.0.0.1:%d/" port) port)
      (message "Heurigraph: serving on port %d (M-x heurigraph-serve to stop)" port)))))

;;;###autoload
(defun heurigraph-suggestions ()
  "List pending relation suggestions (`heurigraph suggest list')."
  (interactive)
  (heurigraph--run '("suggest" "list")))

;;;###autoload
(defun heurigraph-pdf (id)
  "Compile note ID to PDF via Typst (`heurigraph pdf ID').
With point in a note buffer, defaults ID to the id in the file name."
  (interactive
   (list (read-string "Tree id: " (heurigraph--id-at-file))))
  (heurigraph--run (list "pdf" id)))


;;; Declarative books and collections ---------------------------------------

(defun heurigraph--toml-string (value)
  "Escape VALUE for a TOML basic string literal body."
  (replace-regexp-in-string
   "\"" "\\\""
   (replace-regexp-in-string "\\\\" "\\\\" (or value "") t t)
   t t))

(defun heurigraph--insert-book-block (body)
  "Insert a schema-3 collection block containing BODY at point."
  (unless (bolp) (insert "\n"))
  (unless (or (= (point) (point-min))
              (save-excursion
                (forward-line -1)
                (looking-at-p "^[[:space:]]*$")))
    (insert "\n"))
  (insert "[[section.block]]\n" body "\n\n"))

;;;###autoload
(defun heurigraph-book-insert-entry-block (node)
  "Insert an ordered schema-3 entry block for tree NODE."
  (interactive (list (heurigraph--read-node "Collection entry: " "tree")))
  (heurigraph--insert-book-block
   (format "kind = \"entry\"\nid = \"%s\""
           (heurigraph--target-id node))))

;;;###autoload
(defun heurigraph-book-insert-prose-block (content source-p role)
  "Insert a connective prose block.
CONTENT is inline Typst markup, or a project-relative path when SOURCE-P is
non-nil.  ROLE is optional editorial metadata such as `transition'."
  (interactive
   (let* ((source-p current-prefix-arg)
          (content (read-string (if source-p "Typst source path: "
                                  "Connecting Typst text: ")))
          (role (read-string "Role (optional): " "transition")))
     (list content source-p role)))
  (let ((field (if source-p "source" "text"))
        (escaped (heurigraph--toml-string content)))
    (heurigraph--insert-book-block
     (concat "kind = \"prose\"\n"
             (unless (string-empty-p role)
               (format "role = \"%s\"\n" (heurigraph--toml-string role)))
             (format "%s = \"%s\"" field escaped)))))

;;;###autoload
(defun heurigraph-book-insert-exercise-block (exercise solution)
  "Insert an ordered exercise block for EXERCISE and optional SOLUTION."
  (interactive
   (let ((exercise (heurigraph--read-node "Exercise tree: " "tree")))
     (list exercise
           (when (y-or-n-p "Attach a solution tree? ")
             (heurigraph--read-node "Solution tree: " "tree")))))
  (heurigraph--insert-book-block
   (concat (format "kind = \"exercise\"\nid = \"%s\""
                   (heurigraph--target-id exercise))
           (when solution
             (format "\nsolution = \"%s\"" (heurigraph--target-id solution))))))

(defun heurigraph--book-rows ()
  "Return collection rows from `heurigraph book list --json'."
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output '("book" "list" "--json"))))
    (unless (zerop code)
      (user-error "Heurigraph book list failed: %s" (string-trim output)))
    (append (heurigraph--parse-json-output output "book list") nil)))

(defun heurigraph--book-id-at-file ()
  "Return the current collection id when visiting collections/ID.toml."
  (when buffer-file-name
    (let* ((root (file-truename (heurigraph--root)))
           (collections (file-name-as-directory
                         (expand-file-name "collections" root)))
           (file (file-truename buffer-file-name)))
      (when (and (string-prefix-p collections file)
                 (string= (file-name-extension file) "toml"))
        (file-name-base file)))))

(defun heurigraph--read-book-id (&optional prompt)
  "Read a collection id, defaulting to the current manifest.
PROMPT defaults to \"Book: \"."
  (let* ((rows (heurigraph--book-rows))
         (_ (unless rows (user-error "No collection manifests found")))
         (choices
          (mapcar (lambda (row)
                    (cons (format "%s — %s"
                                  (alist-get 'id row)
                                  (alist-get 'title row))
                          (alist-get 'id row)))
                  rows))
         (default (heurigraph--book-id-at-file))
         (default-label
          (car (seq-find (lambda (candidate)
                           (equal (cdr candidate) default))
                         choices)))
         (choice (completing-read (or prompt "Book: ") choices nil t
                                  nil nil default-label)))
    (or (cdr (assoc choice choices))
        (and (not (string-empty-p choice)) choice)
        (user-error "No collection selected"))))

(defun heurigraph--book-manifest (book)
  "Return the absolute manifest path for BOOK."
  (expand-file-name (format "collections/%s.toml" book)
                    (heurigraph--root)))

(defun heurigraph--book-output-name (book profile)
  "Return the configured PDF filename for BOOK and PROFILE."
  (let ((path (heurigraph--book-manifest book)))
    (if (not (file-readable-p path))
        (format "%s-%s.pdf" book profile)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (let ((book-start (and (re-search-forward "^\\[book\\]\\s-*$" nil t)
                               (point)))
              book-end)
          (when book-start
            (setq book-end
                  (or (save-excursion
                        (goto-char book-start)
                        (when (re-search-forward "^\\[" nil t)
                          (line-beginning-position)))
                      (point-max))))
          (if (and book-start
                   (progn
                     (goto-char book-start)
                     (re-search-forward
                      "^output\\s-*=\\s-*\"\\([^\"]+\\)\"\\s-*$"
                      book-end t)))
              (match-string-no-properties 1)
            (format "%s-%s.pdf" book profile)))))))

(defun heurigraph--book-profile-names (book)
  "Return built-in and custom publication profile names for BOOK."
  (let ((builtins (list "student" "teacher" "compact"))
        custom
        (path (heurigraph--book-manifest book)))
    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (while (re-search-forward
                "^\\[profiles\\.\\([[:alnum:]_-]+\\)\\]\\s-*$" nil t)
          (push (match-string-no-properties 1) custom))))
    (delete-dups (append builtins (nreverse custom)))))

(defun heurigraph--read-book-profile (book)
  "Read a publication profile for BOOK."
  (let* ((profiles (heurigraph--book-profile-names book))
         (default (or heurigraph-book-profile
                      heurigraph-book-default-profile)))
    (completing-read "Profile: " profiles nil t nil nil default)))

(defun heurigraph--book-interactive-args (&optional prompt)
  "Return interactive BOOK and PROFILE arguments.
PROMPT customizes the collection prompt."
  (let* ((book (heurigraph--read-book-id prompt))
         (profile (heurigraph--read-book-profile book)))
    (list book profile)))

(defun heurigraph--show-command-output (args output code buffer-name)
  "Display OUTPUT from ARGS with CODE in BUFFER-NAME using compilation mode."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "$ %s\n\n%s\n[exit %s]\n"
                      (heurigraph--compilation-command args)
                      output code))
      (compilation-mode))
    (display-buffer buffer)))

;;;###autoload
(defun heurigraph-book-select-profile (profile)
  "Select PROFILE for book commands in the current buffer."
  (interactive
   (let ((book (heurigraph--read-book-id)))
     (list (heurigraph--read-book-profile book))))
  (setq-local heurigraph-book-profile profile)
  (message "Heurigraph book profile: %s" profile))

;;;###autoload
(defun heurigraph-book-check (book profile)
  "Validate BOOK using publication PROFILE."
  (interactive (heurigraph--book-interactive-args "Check book: "))
  (heurigraph--compile
   (list "book" "check" book "--profile" profile)
   "*heurigraph-book-check*"))

;;;###autoload
(defun heurigraph-book-build (book profile)
  "Build BOOK with publication PROFILE in a compilation buffer."
  (interactive (heurigraph--book-interactive-args "Build book: "))
  (heurigraph--compile
   (list "book" "build" book "--profile" profile)
   "*heurigraph-book-build*"))

;;;###autoload
(defun heurigraph-book-preview (book profile)
  "Build BOOK with PROFILE and open the resulting PDF."
  (interactive (heurigraph--book-interactive-args "Preview book: "))
  (let* ((args (list "book" "build" book "--profile" profile))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (heurigraph--show-command-output
     args output code "*heurigraph-book-preview*")
    (unless (zerop code)
      (user-error "Book build failed; see *heurigraph-book-preview*"))
    (unless (string-match "->[[:space:]]*\\(.+\\)\\s-*$" output)
      (user-error "Book built, but the output path was not reported"))
    (let ((path (expand-file-name (string-trim (match-string 1 output))
                                  (heurigraph--root))))
      (setq heurigraph--last-book-output
            (list :root (file-truename (heurigraph--root))
                  :book book :profile profile :path path))
      (unless (file-exists-p path)
        (user-error "Book output does not exist: %s" path))
      (browse-url-of-file path)
      (message "Opened %s" path))))

;;;###autoload
(defun heurigraph-book-open-output (book profile)
  "Open the most recent output for BOOK and PROFILE."
  (interactive (heurigraph--book-interactive-args "Open book output: "))
  (let* ((default (expand-file-name
                   (concat "build/books/"
                           (heurigraph--book-output-name book profile))
                   (heurigraph--root)))
         (last-path (plist-get heurigraph--last-book-output :path))
         (path (if (and (equal (plist-get heurigraph--last-book-output :root)
                               (file-truename (heurigraph--root)))
                        (equal (plist-get heurigraph--last-book-output :book) book)
                        (equal (plist-get heurigraph--last-book-output :profile) profile)
                        last-path
                        (file-exists-p last-path))
                   last-path
                 default)))
    (unless (file-exists-p path)
      (user-error "No built PDF at %s; run heurigraph-book-preview first" path))
    (browse-url-of-file path)))

(defun heurigraph--quoted-value-at-point ()
  "Return the double-quoted string surrounding point, or nil."
  (save-excursion
    (let ((line-start (line-beginning-position))
          (line-end (line-end-position))
          start end)
      (when (search-backward "\"" line-start t)
        (setq start (1+ (point)))
        (goto-char start)
        (when (search-forward "\"" line-end t)
          (setq end (1- (point)))
          (buffer-substring-no-properties start end))))))

;;;###autoload
(defun heurigraph-book-jump-to-tree ()
  "Open the tree id at point from a collection manifest."
  (interactive)
  (let* ((id (heurigraph--quoted-value-at-point))
         (node (and id
                    (seq-find (lambda (candidate)
                                (equal (alist-get 'id candidate) id))
                              (heurigraph--nodes)))))
    (unless node
      (user-error "Point is not on a known tree id"))
    (find-file (expand-file-name (alist-get 'source node)
                                 (heurigraph--root)))))

;;;###autoload
(defun heurigraph-book-find-containing-tree (&optional id)
  "Open a collection manifest containing tree ID.
ID defaults to the current note's stable id."
  (interactive)
  (let* ((id (or id (heurigraph--id-at-file)
                 (read-string "Tree id: ")))
         (dir (expand-file-name "collections" (heurigraph--root)))
         (needle (format "\\\"%s\\\"" (regexp-quote id)))
         (matches
          (seq-filter
           (lambda (path)
             (with-temp-buffer
               (insert-file-contents path)
               (re-search-forward needle nil t)))
           (when (file-directory-p dir)
             (directory-files-recursively dir "\\.toml\\'")))))
    (pcase matches
      ('nil (user-error "Tree %s is not included in any collection" id))
      (`(,only) (find-file only))
      (_ (find-file
          (completing-read "Collection: " matches nil t))))))

;;; Release/build commands ---------------------------------------------------

;;;###autoload
(defun heurigraph-doctor ()
  "Run `heurigraph doctor' to inspect Typst and project configuration."
  (interactive)
  (heurigraph--run '("doctor")))

;;;###autoload
(defun heurigraph-build-all ()
  "Build the static web site and all PDFs asynchronously."
  (interactive)
  (heurigraph--compile '("build" "--web" "--pdf")
                       "*heurigraph-build-all*"))

(defvar heurigraph--watch-processes (make-hash-table :test #'equal)
  "Running `heurigraph watch' processes keyed by canonical project root.")

;;;###autoload
(defun heurigraph-watch (&optional no-serve port)
  "Watch the forest and rebuild on save.
With prefix argument NO-SERVE, run without the local server.  PORT defaults to
8383.  Calling this command while a watcher is active stops it."
  (interactive "P")
  (let* ((root (file-truename (heurigraph--root)))
         (running (gethash root heurigraph--watch-processes)))
  (if (process-live-p running)
      (progn
        (kill-process running)
        (remhash root heurigraph--watch-processes)
        (message "Heurigraph: watcher stopped"))
    (let* ((default-directory root)
           (executable (heurigraph--require-executable))
           (port (or port 8383))
           (args (append (list "watch" "--port" (number-to-string port))
                         (when no-serve (list "--no-serve"))))
           process)
      (setq process (apply #'start-process "heurigraph-watch" "*heurigraph-watch*"
                           executable args))
      (puthash root process heurigraph--watch-processes)
      (unless no-serve
        (heurigraph--browse-when-server-ready
         process (format "http://127.0.0.1:%d/" port) port))
      (message "Heurigraph: watching%s" (if no-serve "" (format " on port %d" port)))))))

;;;###autoload
(defun heurigraph-open-site ()
  "Open the generated web site index in a browser."
  (interactive)
  (browse-url-of-file (expand-file-name "build/web/index.html" (heurigraph--root))))

;;;###autoload
(defun heurigraph-open-graph-page ()
  "Open the generated interactive graph page in a browser."
  (interactive)
  (browse-url-of-file
   (expand-file-name "build/web/graph/index.html" (heurigraph--root))))

;;;###autoload
(defun heurigraph-agent-context ()
  "Write build/agent-context.json for LLM/agent workflows."
  (interactive)
  (heurigraph--run '("agent" "context")))

(defun heurigraph--mcp-root ()
  "Return the exact, canonical forest root granted to an MCP client."
  (directory-file-name (file-truename (heurigraph--root))))

(defun heurigraph--mcp-command ()
  "Return the resolved Heurigraph executable for desktop MCP configuration."
  (let* ((configured (heurigraph--require-executable))
         (explicit (and (string-match-p "[/\\\\]" configured)
                        (expand-file-name configured))))
    (or (executable-find configured) explicit configured)))

(defun heurigraph--mcp-args ()
  "Return proposal-aware stdio MCP arguments for the current forest."
  (list "mcp" "serve" "--stdio" "--root" (heurigraph--mcp-root)))

(defun heurigraph--mcp-inspection (&optional display-output)
  "Return the parsed MCP inspection report for the current forest.
When DISPLAY-OUTPUT is non-nil, also retain and display the complete report in
`*heurigraph-mcp*'."
  (let* ((args (list "mcp" "inspect" "--root" (heurigraph--mcp-root) "--json"))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (when display-output
      (heurigraph--show-command-output
       args output code "*heurigraph-mcp*"))
    (unless (zerop code)
      (user-error "Heurigraph MCP inspection failed%s"
                  (if display-output "; see *heurigraph-mcp*"
                    (format ": %s" (string-trim output)))))
    (let ((report (heurigraph--parse-json-output output "MCP inspection")))
      (unless (and (listp report) (consp (alist-get 'server report)))
        (user-error "Heurigraph returned an invalid MCP inspection report"))
      report)))

(defun heurigraph--mcp-authority-summary (report)
  "Summarize connector authority from MCP inspection REPORT."
  (let* ((server (alist-get 'server report))
         (canonical-entry (assq 'canonical_sources_read_only server))
         (proposal-entry (assq 'proposal_queue_write server))
         (version (alist-get 'version server)))
    (format
     "Heurigraph MCP%s for %s: canonical sources %s; proposal queues %s"
     (if (and (stringp version) (not (string-empty-p version)))
         (format " %s" version)
       "")
     (heurigraph--mcp-root)
     (cond
      ((null canonical-entry) "authority not reported")
      ((cdr canonical-entry) "read-only")
      (t "writable"))
     (cond
      ((null proposal-entry) "authority not reported")
      ((cdr proposal-entry) "append-only writable")
      (t "not writable")))))

;;;###autoload
(defun heurigraph-mcp-inspect ()
  "Check the local MCP connector against the current forest.
This inspects the canonical-read-only, append-only proposal boundary; the
desktop MCP client, rather than Emacs, owns the long-running stdio process."
  (interactive)
  (let ((report (heurigraph--mcp-inspection t)))
    (message "%s" (heurigraph--mcp-authority-summary report))
    report))

;;;###autoload
(defun heurigraph-mcp-copy-configuration ()
  "Copy desktop-client JSON for the current forest to the kill ring.
The generated command uses an absolute executable path and exact canonical
forest root, avoiding the reduced PATH commonly supplied to desktop apps.
When called interactively, inspect and confirm the connector's exact root and
canonical-read-only, append-only-proposal authority first."
  (interactive)
  (let* ((interactive-p (called-interactively-p 'interactive))
         (report (when interactive-p (heurigraph--mcp-inspection)))
         (summary (when report (heurigraph--mcp-authority-summary report)))
         (configuration
         `((mcpServers
            . ((heurigraph
                . ((command . ,(heurigraph--mcp-command))
                   (args . ,(vconcat (heurigraph--mcp-args))))))))))
    (when (and summary
               (not (yes-or-no-p (format "%s. Copy this configuration? " summary))))
      (user-error "MCP configuration not copied"))
    (kill-new (json-serialize configuration :null-object nil :false-object :json-false))
    (message "Copied Heurigraph MCP desktop configuration%s"
             (if summary (format " (%s)" summary) ""))))

;;;###autoload
(defun heurigraph-ai-workflow (action)
  "Open one guided, bounded AI authoring ACTION.
This entry point deliberately exposes only capability inspection, connector
setup, local proposal review, suggestion review, and validation.  The desktop
MCP client continues to own model interaction and proposal submission."
  (interactive
   (list
    (completing-read
     "Heurigraph AI workflow: "
     '("Inspect connector authority"
       "Copy desktop connector configuration"
       "Open proposal review center"
       "Review semantic suggestions"
       "Validate forest")
     nil t nil nil "Inspect connector authority")))
  (pcase action
    ("Inspect connector authority" (heurigraph-mcp-inspect))
    ("Copy desktop connector configuration"
     (call-interactively #'heurigraph-mcp-copy-configuration))
    ("Open proposal review center" (heurigraph-review-center))
    ("Review semantic suggestions" (heurigraph-suggest-list))
    ("Validate forest" (heurigraph-validate))
    (_ (user-error "Unknown Heurigraph AI workflow action: %s" action))))

;;;###autoload
(defun heurigraph-review-center ()
  "Build and open the consolidated local advisory-proposal review center."
  (interactive)
  (let* ((args '("review" "build" "--json"))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph review build failed: %s" (string-trim output)))
    (let* ((report (heurigraph--parse-json-output output "review center"))
           (path (alist-get 'path report)))
      (unless (and (stringp path) (file-exists-p path))
        (user-error "Heurigraph reported an invalid review path: %S" path))
      (browse-url-of-file path)
      (message "Opened Heurigraph review center"))))

(defun heurigraph--rename-id-plan (old-id new-id)
  "Return the parsed dry-run report for renaming OLD-ID to NEW-ID."
  (let* ((args (list "rename-id" old-id new-id "--dry-run" "--json"))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph rename preview failed: %s" (string-trim output)))
    (heurigraph--parse-json-output output "rename report")))

(defun heurigraph--rename-id-buffers-visiting (path)
  "Return live file buffers visiting PATH."
  (let ((path (file-truename (expand-file-name path))))
    (seq-filter
     (lambda (buffer)
       (when-let ((file (buffer-file-name buffer)))
         (string-equal path (file-truename file))))
     (buffer-list))))

(defun heurigraph--rename-id-affected-paths (report)
  "Return absolute paths modified by rename REPORT."
  (let* ((root (heurigraph--root))
         (files (mapcar
                 (lambda (file)
                   (expand-file-name (alist-get 'path file) root))
                 (alist-get 'files report)))
         (renamed-file (alist-get 'rename_file report)))
    (delete-dups
     (append files
             (when renamed-file
               (list (expand-file-name (car renamed-file) root)))))))

(defun heurigraph--rename-id-unsaved-reference-buffers (old-id)
  "Return modified project buffers containing OLD-ID."
  (let ((root (file-name-as-directory (file-truename (heurigraph--root)))))
    (seq-filter
     (lambda (buffer)
       (and (buffer-modified-p buffer)
            (when-let ((file (buffer-file-name buffer)))
              (file-in-directory-p (file-truename file) root))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-min))
                (search-forward old-id nil t)))))
     (buffer-list))))

(defun heurigraph--rename-id-prepare-buffers (report old-id)
  "Validate and return open buffers affected by REPORT for OLD-ID."
  (let* ((buffers (delete-dups
                   (mapcan #'heurigraph--rename-id-buffers-visiting
                           (heurigraph--rename-id-affected-paths report))))
         (modified (delete-dups
                    (append (seq-filter #'buffer-modified-p buffers)
                            (heurigraph--rename-id-unsaved-reference-buffers
                             old-id))))
         (renamed-file (alist-get 'rename_file report)))
    (when modified
      (user-error
       "Save or revert affected buffer%s before renaming: %s"
       (if (= (length modified) 1) "" "s")
       (mapconcat #'buffer-name modified ", ")))
    (when renamed-file
      (let* ((destination (expand-file-name (cadr renamed-file)
                                            (heurigraph--root)))
             (destination-buffers
              (heurigraph--rename-id-buffers-visiting destination)))
        (when destination-buffers
          (user-error
           "Rename destination is already open in buffer%s: %s"
           (if (= (length destination-buffers) 1) "" "s")
           (mapconcat #'buffer-name destination-buffers ", ")))))
    buffers))

(defun heurigraph--rename-id-refresh-buffers (buffers report)
  "Refresh BUFFERS after successfully applying rename REPORT."
  (let* ((renamed-file (alist-get 'rename_file report))
         (root (heurigraph--root))
         (old-path (when renamed-file
                     (file-truename
                      (expand-file-name (car renamed-file) root))))
         (new-path (when renamed-file
                     (expand-file-name (cadr renamed-file) root))))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and old-path buffer-file-name
                     (string-equal old-path (file-truename buffer-file-name)))
            (set-visited-file-name new-path t))
          (revert-buffer t t t))))))

;;;###autoload
(defun heurigraph-rename-id (old-id new-id &optional preview-only)
  "Preview and apply a graph-wide rename from OLD-ID to NEW-ID.
With prefix argument PREVIEW-ONLY, validate and report the plan without
changing files."
  (interactive
   (list (read-string "Current tree id: " (heurigraph--id-at-file))
         (read-string "New tree id: ")
         current-prefix-arg))
  (let* ((report (heurigraph--rename-id-plan old-id new-id))
         (files (alist-get 'files report))
         (renamed-file (alist-get 'rename_file report))
         (summary (format "%d file%s%s"
                          (length files)
                          (if (= (length files) 1) "" "s")
                          (if renamed-file " plus a source-file rename" ""))))
    (if (or preview-only (and (null files) (null renamed-file)))
        (message "Heurigraph rename preview: %s" summary)
      (when (yes-or-no-p
             (format "Apply %s -> %s across %s? " old-id new-id summary))
        (let ((buffers (heurigraph--rename-id-prepare-buffers report old-id)))
          (when (zerop (heurigraph--run (list "rename-id" old-id new-id)))
            (heurigraph--rename-id-refresh-buffers buffers report)
            (message "Heurigraph renamed %s to %s" old-id new-id)))))))

;;;; Finding trees and inserting relations ---------------------------------

(defun heurigraph--nodes ()
  "Every tree in the forest, via `heurigraph find --json'.
Returns a list of alists with keys `id', `title', `taxon', `source'."
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output
                '("find" "--json" "--limit" "0" ""))))
    (unless (zerop code)
      (user-error "Heurigraph find failed (exit %s): %s"
                  code (string-trim output)))
    (append (heurigraph--parse-json-output output "node completion") nil)))

(defcustom heurigraph-completion-title-first t
  "When non-nil, show note titles before ids in completion candidates.
The inserted text still uses the stable Heurigraph id, so you can search by
\"Null Factor Law\" and insert #link-to(\"mho-0001\") or #transclude(\"mho-0001\")."
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
  (let* ((id (alist-get 'id node))
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
Type what you remember (\"Null Factor\", \"mho-0001\", \"factoring\") and
completion narrows over the displayed title-rich candidate.  When KIND is
\"tree\" or \"page\", restrict candidates to that kind."
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
  "Insert reusable rights and distribution metadata at point.
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
  (when (member field '("framework" "stage"))
    (let ((candidates (heurigraph--node-candidates "tree")))
      (dolist (filter heurigraph-assertion-context-candidate-filter-functions)
        (setq candidates (funcall filter field candidates)))
      candidates)))

(defun heurigraph--read-assertion-context-value (field required)
  "Read assertion context FIELD, requiring a value when REQUIRED is non-nil.
Framework and stage prompts complete local framework, course, and stage nodes
while still accepting an external or not-yet-indexed context identifier."
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
predicate requires framework, stage, audience, jurisdiction, or language,
prompt for those fields and include them in the inserted `#rel'.  Remaining
context fields can be selected interactively when they qualify an otherwise
unscoped predicate.  Optional CONTEXT is an alist of field-name strings to
values."
  (interactive
   (let* ((item (heurigraph--read-ontology-item
                 "Predicate: " 'predicates heurigraph-predicate-types))
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
(defun heurigraph-new-page (kind)
  "Create a non-mathematical page of KIND.
KIND is one of content, journal, or weeknote.  This dispatcher keeps the
three page categories explicit while the CLI remains the authority for ids."
  (interactive
   (list (completing-read "Page kind: "
                          '("content" "journal" "weeknote") nil t nil nil
                          "content")))
  (pcase kind
    ("content" (call-interactively #'heurigraph-new-content))
    ("journal" (call-interactively #'heurigraph-new-journal))
    ("weeknote" (call-interactively #'heurigraph-new-weeknote))
    (_ (user-error "Unknown page kind: %s" kind))))

(defun heurigraph--create-page (title kind &optional extra-args)
  "Create TITLE as page KIND with EXTRA-ARGS, then visit it."
  (let* ((args (append (list "new" "--page" "--kind" kind "--json")
                       extra-args
                       (list title)))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph new --page failed: %s" (string-trim output)))
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

;;;###autoload
(defun heurigraph-new-content (title)
  "Create a content page named TITLE with the next project-wide id."
  (interactive
   (list (heurigraph--read-page-title "Content title (blank = today): ")))
  (heurigraph--create-page title "content"))

;;;###autoload
(defun heurigraph-new-journal (title)
  "Create a journal post named TITLE with the next project-wide id."
  (interactive
   (list (heurigraph--read-page-title "Journal title (blank = today): ")))
  (heurigraph--create-page title "journal"))

;;;###autoload
(defun heurigraph-new-weeknote (year week)
  "Create a weeknote for ISO YEAR and WEEK.
Both prompts default to the current ISO week, but either value can be edited
manually.  The resulting stable id and default title are `YYYY-WXX`."
  (interactive
   (list (read-number "ISO year: "
                      (string-to-number (format-time-string "%G")))
         (read-number "ISO week: "
                      (string-to-number (format-time-string "%V")))))
  (unless (and (integerp year) (<= 1 year 9999))
    (user-error "ISO year must be between 1 and 9999"))
  (unless (and (integerp week) (<= 1 week 53))
    (user-error "ISO week must be between 1 and 53"))
  (let ((id (format "%04d-W%02d" year week)))
    (heurigraph--create-page
     (format "Weeknotes %s" id)
     "weeknote"
     (list "--year" (number-to-string year)
           "--week" (number-to-string week)))))

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
        (seq-filter
         (lambda (file)
           (string-match-p
            "\\`cetz-[0-9A-Z]\\{4\\}\\.typ\\'"
            (file-name-nondirectory file)))
         (directory-files-recursively dir "\\.typ\\'"))
        #'string<)))))

(defun heurigraph--read-diagram ()
  "Select a project diagram and return its metadata plist."
  (let ((candidates (heurigraph--diagram-candidates)))
    (unless candidates
      (user-error "No diagrams found; run M-x heurigraph-new-diagram first"))
    (cdr (assoc (completing-read "Diagram: " candidates nil t) candidates))))

;;;###autoload
(defun heurigraph-new-diagram (title)
  "Create and visit a CeTZ diagram named TITLE with the next `cetz-XXXX' id."
  (interactive (list (read-string "Diagram title: ")))
  (when (string-empty-p (string-trim title))
    (user-error "Diagram title must not be empty"))
  (let* ((default-directory (heurigraph--root))
         (result (heurigraph--call-output (list "diagram" "new" title)))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "Heurigraph diagram new failed: %s" (string-trim output)))
    (if (string-match "^created diagram \\(.+\\)$" output)
        (find-file (match-string 1 output))
      (message "Diagram created (path not reported)"))))

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
  (let* ((result (heurigraph--call-output '("image" "list" "--json")))
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
    (unless (and (stringp id)
                 (string-match-p "\\`img-[0-9A-Z]\\{4\\}\\'" id)
                 (stringp path)
                 (string-match-p
                  "\\`images/img-[0-9A-Z]\\{4\\}\\.\\(?:png\\|jpe?g\\|gif\\|svg\\)\\'"
                  path))
      (user-error "Heurigraph returned invalid image metadata"))
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
  "Copy external image FILE into `images/' with the next `img-XXXX' id."
  (interactive (list (read-file-name "Import image: " nil nil t)))
  (let* ((asset (heurigraph--image-mutation
                 (list "image" "add" (expand-file-name file))
                 "image add"))
         (id (alist-get 'id asset)))
    (message "Imported image %s" id)
    asset))

;;;###autoload
(defun heurigraph-rename-image (file)
  "Rename image FILE inside `images/' to the next available `img-XXXX' id.
The CLI refuses files outside the project image directory.  If FILE is visited,
retarget that buffer to the new filename after the filesystem rename."
  (interactive
   (let ((directory (expand-file-name "images" (heurigraph--root))))
     (unless (file-directory-p directory)
       (user-error "No images directory found; run M-x heurigraph-init"))
     (list (read-file-name "Image to assign next id: " directory nil t))))
  (let* ((expanded (expand-file-name file))
         (buffer (get-file-buffer expanded))
         (asset (heurigraph--image-mutation
                 (list "image" "rename" expanded)
                 "image rename"))
         (new-path (expand-file-name (alist-get 'path asset)
                                     (heurigraph--root))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        ;; The CLI has already moved the file; only retarget the buffer.
        (set-visited-file-name new-path t nil)))
    (message "Renamed image to %s" (alist-get 'id asset))
    asset))

;;;###autoload
(defun heurigraph-insert-image (id path &optional alt)
  "Insert the managed image identified by ID at project-relative PATH.
Interactive selection is by `img-XXXX' id.  The emitted Typst source resolves
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
  "Extract a stable note or page id from the current file name, or nil."
  (when-let ((name (and buffer-file-name
                        (file-name-nondirectory buffer-file-name))))
    (when (string-match
           "\\`\\(\\(?:[a-z0-9]+-[0-9A-Za-z]\\{4\\}\\|[0-9]\\{4\\}-W[0-9]\\{2\\}\\)\\)--"
           name)
      (match-string 1 name))))

(defun heurigraph--knowledge-node-string-field (field)
  "Return the literal string value of knowledge-node FIELD.
Signal a user error when the current buffer has no complete knowledge-node
declaration or FIELD is missing, empty, or not a string."
  (let* ((call (or (heurigraph--knowledge-node-call)
                   (user-error "No complete #knowledge-node declaration found")))
         (start (or (heurigraph--metadata-field-value-start call field)
                    (user-error "The knowledge-node has no %s field" field))))
    (unless (eq (char-after start) ?\")
      (user-error "The knowledge-node %s field is not a string" field))
    (save-excursion
      (goto-char (1+ start))
      (let ((value-start (point))
            value-end)
        (while (and (< (point) (cdr call)) (not value-end))
          (pcase (char-after)
            (?\\ (forward-char (min 2 (- (cdr call) (point)))))
            (?\" (setq value-end (point)))
            (_ (forward-char 1))))
        (unless value-end
          (user-error "The knowledge-node %s string is incomplete" field))
        (let ((value (buffer-substring-no-properties value-start value-end)))
          (when (string-empty-p value)
            (user-error "The knowledge-node %s field is empty" field))
          value)))))

(defun heurigraph--filename-slug (title)
  "Return the canonical ASCII filename slug for TITLE."
  (string-trim
   (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title))
   "-+" "-+"))

(defun heurigraph--title-filename-destination ()
  "Return the current tree's destination filename derived from its title.
The permanent id is preserved; the filename is normalized to `id--slug.typ'."
  (unless buffer-file-name
    (user-error "The current buffer is not visiting a file"))
  (when (file-remote-p buffer-file-name)
    (user-error "Title-based rename is restricted to local files"))
  (let* ((old-path (expand-file-name buffer-file-name))
         (basename (file-name-nondirectory old-path))
         (file-id (or (heurigraph--id-at-file)
                      (user-error "The filename has no canonical tree id")))
         (metadata-id (heurigraph--knowledge-node-string-field "id"))
         (title (heurigraph--knowledge-node-string-field "title"))
         (slug (heurigraph--filename-slug title)))
    (unless (string-suffix-p ".typ" basename)
      (user-error "The current knowledge-node file does not end in .typ"))
    (unless (string= file-id metadata-id)
      (user-error
       "Filename id %s does not match knowledge-node id %s; use heurigraph-rename-id"
       file-id metadata-id))
    (when (string-empty-p slug)
      (user-error "The title does not produce a usable ASCII filename slug"))
    (expand-file-name
     (format "%s--%s.typ" file-id slug)
     (file-name-directory old-path))))

;;;###autoload
(defun heurigraph-rename-file-from-title ()
  "Rename the current knowledge-node file from its metadata title.
The command preserves the permanent tree id, normalizes the filename to
`id--slug.typ', refuses destination collisions and symlinks, saves the current
buffer, and keeps the buffer attached to the renamed file.  Graph references
are not changed because they use the stable id rather than the filename slug."
  (interactive)
  (let* ((old-path (or buffer-file-name
                       (user-error "The current buffer is not visiting a file")))
         (new-path (heurigraph--title-filename-destination)))
    (cond
     ((string-equal (expand-file-name old-path) new-path)
      (message "Filename already matches the knowledge-node title"))
     ((file-symlink-p old-path)
      (user-error "Refusing to rename a symbolic link"))
     ((file-exists-p new-path)
      (user-error "Rename destination already exists: %s" new-path))
     ((find-buffer-visiting new-path)
      (user-error "Rename destination is already open: %s" new-path))
     ((yes-or-no-p
       (format "Rename %s to %s? "
               (file-name-nondirectory old-path)
               (file-name-nondirectory new-path)))
      (save-buffer)
      (unless (file-regular-p old-path)
        (user-error "The current buffer is not visiting a regular file"))
      (rename-file old-path new-path nil)
      ;; The file has already moved; retarget the live buffer without asking
      ;; `set-visited-file-name' to perform a second filesystem operation.
      (set-visited-file-name new-path t nil)
      (set-visited-file-modtime)
      (set-buffer-modified-p nil)
      (heurigraph--refresh-active-lsp)
      (message "Renamed note to %s" (file-name-nondirectory new-path))))))

;;;###autoload
(defun heurigraph-init ()
  "Initialise a Heurigraph project with explicit local and global identities."
  (interactive)
  (let* ((heurigraph-notes-directory
          (read-directory-name "Initialise Heurigraph in: " (heurigraph--root)))
         (config-path
          (expand-file-name "heurigraph.toml" heurigraph-notes-directory)))
    (make-directory heurigraph-notes-directory t)
    (if (file-exists-p config-path)
        (heurigraph--run '("init"))
      (let ((prefix
             (string-trim
              (read-string
               "Project id prefix (lowercase letters/digits, e.g. kogs): ")))
            (forest-iri
             (string-trim
              (read-string
               "Forest IRI (e.g. https://example.org/forests/research): "))))
        (when (string-empty-p prefix)
          (user-error "Project id prefix is required"))
        (when (string-empty-p forest-iri)
          (user-error "Forest IRI is required"))
        (heurigraph--run
         (list "init" "--prefix" prefix "--forest-iri" forest-iri))))))


;;; Suggestion queue ---------------------------------------------------------

;;;###autoload
(defun heurigraph-suggest-add (source predicate target confidence rationale by force
                                      &optional context)
  "Queue a semantic assertion suggestion.
SOURCE and TARGET are stable ids.  PREDICATE comes from the resolved project
ontology.  CONTEXT is an optional alist of qualified-assertion fields."
  (interactive
   (let* ((item (heurigraph--read-ontology-item
                 "Predicate: " 'predicates heurigraph-predicate-types))
          (predicate (alist-get 'id item)))
     (list (read-string "Source id: " (heurigraph--id-at-file))
           predicate
           (alist-get 'id (heurigraph--read-assertion-target item))
           (read-number "Confidence 0..1: " 0.75)
           (read-string "Rationale: ")
           (read-string "Suggested by: " user-full-name)
           current-prefix-arg
           (heurigraph--read-assertion-context item))))
  (let ((args (list "suggest" "add" source predicate target
                    "--confidence" (number-to-string confidence))))
    (dolist (pair context)
      (setq args (append args (list (concat "--" (car pair)) (cdr pair)))))
    (when (and rationale (not (string-empty-p rationale)))
      (setq args (append args (list "--rationale" rationale))))
    (when (and by (not (string-empty-p by)))
      (setq args (append args (list "--by" by))))
    (when force (setq args (append args (list "--force"))))
    (heurigraph--run args)))

;;;###autoload
(defun heurigraph-suggest-list (&optional all json)
  "List assertion suggestions.
With prefix argument ALL, include accepted/rejected suggestions.  When JSON is
non-nil, request machine-readable output."
  (interactive "P")
  (let ((args (list "suggest" "list")))
    (when all (setq args (append args (list "--all"))))
    (when json (setq args (append args (list "--json"))))
    (heurigraph--run args)))

;;;###autoload
(defun heurigraph-suggest-accept (suggestion-id)
  "Accept SUGGESTION-ID and write the assertion into source Typst."
  (interactive "sSuggestion id: ")
  (heurigraph--run (list "suggest" "accept" suggestion-id)))

;;;###autoload
(defun heurigraph-suggest-reject (suggestion-id reason)
  "Reject SUGGESTION-ID with optional REASON."
  (interactive (list (read-string "Suggestion id: ")
                     (read-string "Reason: ")))
  (let ((args (list "suggest" "reject" suggestion-id)))
    (when (and reason (not (string-empty-p reason)))
      (setq args (append args (list "--reason" reason))))
    (heurigraph--run args)))

;;; Assertion convenience commands ------------------------------------------

(defun heurigraph--insert-fixed-assertion (predicate)
  "Insert PREDICATE to a valid local or external target."
  (let ((item (heurigraph--ontology-item-by-id 'predicates predicate)))
    (heurigraph-insert-assertion
     predicate
     (heurigraph--read-assertion-target item)
     (heurigraph--read-assertion-context item))))

;;;###autoload
(defun heurigraph-refresh-completions ()
  "Refresh project ontology/title completion data, then validate the forest."
  (interactive)
  (heurigraph-ontology-refresh)
  (heurigraph-validate))

(provide 'heurigraph)

;;; heurigraph.el ends here
