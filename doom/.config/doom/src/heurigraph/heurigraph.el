;;; heurigraph.el --- Authoring layer for Heurigraph  -*- lexical-binding: t; -*-

;; Author: Heurigraph
;; Version: 1.16.2
;; Keywords: tools, tex, outlines
;; Package-Requires: ((emacs "30.2"))

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
When nil, the current `default-directory' / project root is used."
  :type '(choice (const :tag "Auto-detect" nil) directory)
  :group 'heurigraph)

(defcustom heurigraph-default-subject "math:mathematics"
  "Default ontology subject passed to \\[heurigraph-new]."
  :type '(choice (const :tag "None" nil) string)
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
  "Plist describing the most recent book preview (:book :profile :path).")

;; Used only for completion prompts; the ontology registry remains authoritative.
(defcustom heurigraph-taxons
  '("math:concept" "math:object" "math:structure" "math:operation"
    "math:relation" "math:property" "math:definition" "math:notation"
    "math:statement" "math:theorem" "math:lemma" "math:proposition"
    "math:corollary" "math:law" "math:identity" "math:proof"
    "math:counterexample" "math:method" "math:algorithm"
    "math:transformation" "edu:learning-objective" "edu:task"
    "edu:exercise" "edu:problem" "edu:assessment-item"
    "edu:worked-example" "edu:solution" "edu:explanation"
    "edu:representation" "edu:misconception" "edu:error-pattern"
    "edu:learning-strategy" "edu:teaching-strategy"
    "edu:instructional-move" "edu:diagnostic" "edu:rubric-criterion"
    "curriculum:framework" "curriculum:standard" "curriculum:strand"
    "curriculum:course" "curriculum:stage" "curriculum:objective"
    "curriculum:competency" "curriculum:sequence" "curriculum:unit")
  "Fallback taxon ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

;;; Internals ----------------------------------------------------------------

(defcustom heurigraph-subjects
  '("math:mathematics" "math:algebra" "math:equations" "math:operations"
    "math:number" "math:factorisation" "math:quadratics"
    "math:zero-products")
  "Fallback subject ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

(defcustom heurigraph-predicate-types
  '("math:depends_on" "math:uses" "math:defines" "math:proves"
    "math:refutes" "math:generalizes" "math:specializes"
    "math:equivalent_to" "math:transforms_to" "math:has_example"
    "math:has_counterexample" "math:enables_method"
    "edu:has_learning_prerequisite" "edu:teaches" "edu:illustrates"
    "edu:explains" "edu:addresses" "edu:about" "edu:elicits"
    "edu:scaffolds" "edu:strategy_for" "edu:assesses"
    "edu:solution_to" "curriculum:aligns_to" "curriculum:part_of"
    "curriculum:precedes" "formal:formalized_as" "document:mentions"
    "document:transcludes")
  "Fallback predicate ids used when no resolved project ontology is available."
  :type '(repeat string)
  :group 'heurigraph)

(defun heurigraph--root ()
  "Return the Heurigraph project root as an absolute directory."
  (expand-file-name
   (or heurigraph-notes-directory
       (when-let ((pr (project-current)))
         (project-root pr))
       default-directory)))

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

(defun heurigraph--run (args &optional buffer-name)
  "Run the heurigraph binary with ARGS (a list of strings) in the project root.
Output goes to BUFFER-NAME (default *heurigraph*).  Returns the exit code."
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
      (json-parse-string output :object-type 'alist :array-type 'list)
    (json-parse-error
     (user-error "Heurigraph returned invalid JSON for %s: %s"
                 description (error-message-string error)))))

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
    (user-error "Structure id must be namespaced, for example math:field"))
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

(defun heurigraph--metadata-call ()
  "Return (OPEN-END . CALL-END) for the first metadata call, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "#\\(knowledge-node\\|note-meta\\)(" nil t)
      (let* ((open-end (point))
             (call-end (heurigraph--typst-call-end (1- open-end))))
        (when call-end (cons open-end call-end))))))

(defun heurigraph--knowledge-node-call ()
  "Return (OPEN-END . CALL-END) for the first knowledge-node call, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "#knowledge-node(" nil t)
      (let* ((open-end (point))
             (call-end (heurigraph--typst-call-end (1- open-end))))
        (when call-end (cons open-end call-end))))))

(defun heurigraph--metadata-field-value-start (bounds field)
  "Return the value start for top-level FIELD within metadata BOUNDS.
Strings, content blocks, line comments, nested block comments, and nested
parenthesized values are skipped while looking for the field name."
  (save-excursion
    (goto-char (car bounds))
    (let ((depth 1)
          (content-depth 0)
          (state 'code)
          (block-depth 0)
          (field-rx (concat "\\_<" (regexp-quote field)
                            "\\_>[[:space:]]*:")))
      (catch 'found
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
                 (throw 'found (point)))
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
        nil))))

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
          (let (ids)
            (save-excursion
              (goto-char (1+ start))
              (while (re-search-forward "\"\\([^\"\n]+\\)\"" (1- end) t)
                (push (match-string-no-properties 1) ids)))
            (list :call call :tuple (cons start end) :ids (nreverse ids))))))))

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

;;;###autoload
(defalias 'heurigraph-add-subject #'heurigraph-add-subjects)

(defun heurigraph--metadata-public-value ()
  "Return the current buffer's explicit publication value, or nil."
  (when-let ((bounds (heurigraph--metadata-call)))
    (save-excursion
      (goto-char (car bounds))
      (when (re-search-forward
             "public:[[:space:]]*\\(true\\|false\\)" (cdr bounds) t)
        (string= (match-string-no-properties 1) "true")))))

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
             (call-end (cdr bounds))
             (match (save-excursion
                      (goto-char open-end)
                      (when (re-search-forward
                             "public:[[:space:]]*\\(true\\|false\\)"
                             call-end t)
                        (list (match-string-no-properties 1)
                              (match-beginning 1)
                              (match-end 1)))))
             (current (car match))
             (next (if (string= current "true") "false" "true")))
        (when (and (string= next "true")
                   (not (yes-or-no-p "Mark this item PUBLIC for generated publications? ")))
          (user-error "Publication unchanged"))
        (if current
            (progn
              (delete-region (nth 1 match) (nth 2 match))
              (goto-char (nth 1 match))
              (insert next))
          (goto-char open-end)
          (insert (format "\n  public: %s," next)))
        (message "Heurigraph: this item is now %s"
                 (if (string= next "true") "PUBLIC" "private"))))))

;;; Commands -----------------------------------------------------------------

;;;###autoload
(defun heurigraph-new (title id taxon subject keywords)
  "Create a new note titled TITLE with TAXON.
Leave ID blank to auto-allocate the next free base-36 id (Forester
style) from `[ids].default_prefix'; give an explicit id like
mho-0X4B to choose one — the CLI refuses collisions. SUBJECT and
KEYWORDS are optional. Delegates to `heurigraph new', then visits the
created file if it can be located."
  (interactive
   (list (read-string "Title: ")
         (read-string "Id (blank = auto-allocate): ")
         (heurigraph--read-ontology-id
          "Taxon: " 'taxons heurigraph-taxons)
         (heurigraph--read-ontology-id
          "Subject: " 'subjects heurigraph-subjects
          heurigraph-default-subject)
         (read-string "Keywords (comma-separated): ")))
  (let ((args (list "new" title "--taxon" taxon)))
    (if (and id (not (string-empty-p id)))
        (setq args (append args (list "--id" id))))
    (when (and subject (not (string-empty-p subject)))
      (setq args (append args (list "--subject" subject))))
    (when (and keywords (not (string-empty-p keywords)))
      (setq args (append args (list "--keywords" keywords))))
    (when (zerop (heurigraph--run args))
      ;; Best-effort open: newest note file matching `<id>--` at the start.
      (let* ((root (heurigraph--root))
             (rx (if (and id (not (string-empty-p id)))
                     (concat "^" (regexp-quote id) "--")
                   "--"))
             (hits (directory-files-recursively root (concat rx ".*\\.typ$")))
             (hit (car (sort hits #'file-newer-than-file-p))))
        (when hit (find-file hit))))))

;;;###autoload
(defun heurigraph-next-id (&optional prefix)
  "Show the next free tree id without creating anything.
Use `[ids].default_prefix' unless optional PREFIX is supplied."
  (interactive)
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output
                (append '("next-id") (when prefix (list prefix))))))
    (unless (zerop code)
      (user-error "heurigraph next-id failed: %s" (string-trim output)))
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
  "Render the static web site (`heurigraph build --web')."
  (interactive)
  (heurigraph--run '("build" "--web")))

(defvar heurigraph--serve-process nil
  "Running `heurigraph serve' process, if any.")

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
  (if (process-live-p heurigraph--serve-process)
      (progn
        (kill-process heurigraph--serve-process)
        (setq heurigraph--serve-process nil)
        (message "Heurigraph: server stopped"))
    (let ((default-directory (heurigraph--root))
          (executable (heurigraph--require-executable))
          (port (or port 8383)))
      (setq heurigraph--serve-process
            (start-process "heurigraph-serve" "*heurigraph-serve*"
                           executable
                           "serve" "--port" (number-to-string port)))
      (heurigraph--browse-when-server-ready
       heurigraph--serve-process (format "http://127.0.0.1:%d/" port) port)
      (message "Heurigraph: serving on port %d (M-x heurigraph-serve to stop)" port))))

;;;###autoload
(defun heurigraph-suggestions ()
  "List pending relation suggestions (`heurigraph suggest list')."
  (interactive)
  (heurigraph--run '("suggest" "list")))

;;;###autoload

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
non-nil. ROLE is optional editorial metadata such as `transition'."
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
      (user-error "heurigraph book list failed: %s" (string-trim output)))
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
            (list :book book :profile profile :path path))
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
         (path (if (and (equal (plist-get heurigraph--last-book-output :book) book)
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
  "Build both the static web site and all PDFs."
  (interactive)
  (heurigraph--run '("build" "--web" "--pdf")))

(defvar heurigraph--watch-process nil
  "Running `heurigraph watch' process, if any.")

;;;###autoload
(defun heurigraph-watch (&optional no-serve port)
  "Watch the forest and rebuild on save.
With prefix argument NO-SERVE, run without the local server.  PORT defaults to
8383.  Calling this command while a watcher is active stops it."
  (interactive "P")
  (if (process-live-p heurigraph--watch-process)
      (progn
        (kill-process heurigraph--watch-process)
        (setq heurigraph--watch-process nil)
        (message "Heurigraph: watcher stopped"))
    (let* ((default-directory (heurigraph--root))
           (executable (heurigraph--require-executable))
           (port (or port 8383))
           (args (append (list "watch" "--port" (number-to-string port))
                         (when no-serve (list "--no-serve")))))
      (setq heurigraph--watch-process
            (apply #'start-process "heurigraph-watch" "*heurigraph-watch*"
                   executable args))
      (unless no-serve
        (heurigraph--browse-when-server-ready
         heurigraph--watch-process (format "http://127.0.0.1:%d/" port) port))
      (message "Heurigraph: watching%s" (if no-serve "" (format " on port %d" port))))))

;;;###autoload
(defun heurigraph-open-site ()
  "Open the generated web site index in a browser."
  (interactive)
  (browse-url (concat "file://" (expand-file-name "build/web/index.html" (heurigraph--root)))))

;;;###autoload
(defun heurigraph-open-graph-page ()
  "Open the generated interactive graph page in a browser."
  (interactive)
  (browse-url (concat "file://" (expand-file-name "build/web/graph/index.html" (heurigraph--root)))))

;;;###autoload
(defun heurigraph-agent-context ()
  "Write build/agent-context.json for LLM/agent workflows."
  (interactive)
  (heurigraph--run '("agent" "context")))

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
      (user-error "heurigraph find failed (exit %s): %s"
                  code (string-trim output)))
    (append (heurigraph--parse-json-output output "node completion") nil)))

(defcustom heurigraph-completion-title-first t
  "When non-nil, show note titles before ids in completion candidates.
The inserted text still uses the stable Heurigraph id, so you can search by
\"Null Factor Law\" and insert #link-to(\"mho-0001\") or #transclude(\"mho-0001\")."
  :type 'boolean
  :group 'heurigraph)

(defun heurigraph--node-label (node)
  "Return a completion label for NODE.
The label intentionally contains title, id, taxon, subjects, and keywords so
ordinary Emacs completion can narrow by any of those fields."
  (let* ((id (alist-get 'id node))
         (title (or (alist-get 'title node) "Untitled"))
         (taxon (or (alist-get 'taxon node) (alist-get 'kind node) ""))
         (subjects (alist-get 'subjects node))
         (keywords (alist-get 'keywords node))
         (kw (when keywords (string-join keywords ", "))))
    (if heurigraph-completion-title-first
        (string-join
         (delq nil (list title (format "— %s" id)
                         (unless (string-empty-p taxon) (format "[%s]" taxon))
                         (when subjects (format "{%s}" (string-join subjects ",")))
                         (when (and kw (not (string-empty-p kw))) (format "#%s" kw))))
         " ")
      (string-join
       (delq nil (list (format "%-16s" id) title
                       (unless (string-empty-p taxon) (format "[%s]" taxon))
                       (when subjects (format "{%s}" (string-join subjects ",")))
                       (when (and kw (not (string-empty-p kw))) (format "#%s" kw))))
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
  "Pick a node by title/id/subject/taxon/keyword with completion; return alist.
Type what you remember (\"Null Factor\", \"mho-0001\", \"factoring\") and
completion narrows over the displayed title-rich candidate."
  (let* ((cands (heurigraph--node-candidates kind))
         (choice (completing-read prompt cands nil t)))
    (cdr (assoc choice cands))))

(defun heurigraph--target-id (node)
  "Return the stable target string for NODE."
  (alist-get 'id node))

(defun heurigraph--typst-string (s)
  "Escape S for use as a Typst string literal body."
  (replace-regexp-in-string
   "\"" "\\\""
   (replace-regexp-in-string "\\\\" "\\\\" (or s "") t t)
   t t))

;;;###autoload
(defun heurigraph-insert-link-to (node text)
  "Insert a #link-to mention at point, selecting NODE by title.
Unlike typed semantic relations, #link-to is an inline navigational mention;
it may target either an id-bearing tree or a non-mathematical page.
Completion is title-first by default, but the inserted target remains the
stable id."
  (interactive
   (let* ((node (heurigraph--read-node "Link to title/id: "))
          (default (alist-get 'title node)))
     (list node (read-string "Link text: " default))))
  (let ((target (heurigraph--target-id node))
        (label (heurigraph--typst-string text)))
    (insert (format "#link-to(\"%s\", text: \"%s\")" target label))
    (message "Inserted link to %s (%s)" target (alist-get 'title node))))

;;;###autoload
(defalias 'heurigraph-insert-link #'heurigraph-insert-link-to)

;;;###autoload
(defun heurigraph-insert-transclusion (node)
  "Insert #transclude for a tree selected by title.
Pages are excluded because transclusion must expand an id-bearing tree."
  (interactive (list (heurigraph--read-node "Transclude title/id: " "tree")))
  (let ((target (heurigraph--target-id node)))
    (unless (bolp) (insert "\n"))
    (insert (format "#transclude(\"%s\")" target))
    (message "Inserted transclusion of %s (%s)" target (alist-get 'title node))))

;;;###autoload
(defalias 'heurigraph-include #'heurigraph-insert-transclusion)

(defun heurigraph--ontology-item-by-id (kind id)
  "Return the ontology KIND entry identified by ID, or nil."
  (seq-find (lambda (item) (equal (alist-get 'id item) id))
            (heurigraph--ontology-items kind)))

(defun heurigraph--read-assertion-context (predicate-item)
  "Prompt for fields required by PREDICATE-ITEM and return an alist."
  (mapcar
   (lambda (field)
     (let ((value (read-string (format "%s (required): "
                                      (capitalize field)))))
       (when (string-empty-p (string-trim value))
         (user-error "%s is required by this predicate" field))
       (cons field value)))
   (alist-get 'required_context predicate-item)))

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
     "\n)")))

;;;###autoload
(defun heurigraph-insert-assertion (predicate node &optional context)
  "Insert a typed ontology assertion at point, picking the target by name.
PREDICATE completion comes from the resolved project registry.  Target NODE
is searched by title, id, subject, taxon, and keyword; predicates which permit
external targets also accept a manually entered external identity.  When the
predicate requires framework, stage, audience, jurisdiction, or language,
prompt for those fields and include them in the inserted `#rel'.  Optional
CONTEXT is an alist of field-name strings to values."
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
  "Jump to a tree's note by searching titles, ids, and keywords."
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

(defun heurigraph--create-page (title kind keywords &optional extra-args)
  "Create TITLE as page KIND with KEYWORDS and EXTRA-ARGS, then visit it."
  (let* ((args (append (list "new" "--page" "--kind" kind)
                       extra-args
                       (list title)
                       (unless (string-empty-p keywords)
                         (list "--keywords" keywords))))
         (result (heurigraph--call-output args))
         (code (car result))
         (output (cdr result))
         (path (when (string-match "^created page \\(.*\\)$" output)
                 (match-string 1 output))))
    (unless (zerop code)
      (user-error "heurigraph new --page failed: %s" (string-trim output)))
    (if path
        (find-file path)
      (message "page created (path not reported)"))))

(defun heurigraph--read-page-title (prompt)
  "Read a page title using PROMPT; blank means today's date."
  (let ((title (read-string prompt)))
    (if (string-empty-p (string-trim title))
        (format-time-string "%Y-%m-%d")
      title)))

;;;###autoload
(defun heurigraph-new-content (title keywords)
  "Create a content page with the next project-wide `prefix-XXXX` id."
  (interactive
   (list (heurigraph--read-page-title "Content title (blank = today): ")
         (read-string "Keywords (comma-separated): ")))
  (heurigraph--create-page title "content" keywords))

;;;###autoload
(defun heurigraph-new-journal (title keywords)
  "Create a journal post with the next project-wide `prefix-XXXX` id."
  (interactive
   (list (heurigraph--read-page-title "Journal title (blank = today): ")
         (read-string "Keywords (comma-separated): ")))
  (heurigraph--create-page title "journal" keywords))

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
     ""
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
       (sort (directory-files-recursively dir "\\.typ\\'") #'string<)))))

(defun heurigraph--read-diagram ()
  "Select a project diagram and return its metadata plist."
  (let ((candidates (heurigraph--diagram-candidates)))
    (unless candidates
      (user-error "No diagrams found; run M-x heurigraph-new-diagram first"))
    (cdr (assoc (completing-read "Diagram: " candidates nil t) candidates))))

;;;###autoload
(defun heurigraph-new-diagram (title)
  "Create and visit the next `dia-XXXX' CeTZ diagram from the template."
  (interactive (list (read-string "Diagram title: ")))
  (when (string-empty-p (string-trim title))
    (user-error "Diagram title must not be empty"))
  (let* ((default-directory (heurigraph--root))
         (result (heurigraph--call-output (list "diagram" "new" title)))
         (code (car result))
         (output (cdr result)))
    (unless (zerop code)
      (user-error "heurigraph diagram new failed: %s" (string-trim output)))
    (if (string-match "^created diagram \\(.+\\)$" output)
        (find-file (match-string 1 output))
      (message "diagram created (path not reported)"))))

;;;###autoload
(defun heurigraph-insert-diagram (name alt width caption)
  "Insert a CeTZ diagram reference with editable parameters.
NAME is relative to `diagrams/' without `.typ'. ALT is the accessible image
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

;;;###autoload
(defalias 'heurigraph-insert-image #'heurigraph-insert-diagram)

(defun heurigraph--id-at-file ()
  "Extract a stable note or page id from the current file name, or nil."
  (when-let ((name (and buffer-file-name
                        (file-name-nondirectory buffer-file-name))))
    (when (string-match
           "\\`\\(\\(?:[a-z0-9]+-[0-9A-Za-z]\\{4\\}\\|[0-9]\\{4\\}-W[0-9]\\{2\\}\\)\\)--"
           name)
      (match-string 1 name))))

;;;###autoload
(defun heurigraph-init ()
  "Initialise a Heurigraph project in the chosen directory (`heurigraph init')."
  (interactive)
  (let ((heurigraph-notes-directory
         (read-directory-name "Initialise Heurigraph in: " (heurigraph--root))))
    (make-directory heurigraph-notes-directory t)
    (heurigraph--run '("init"))))


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
With prefix argument ALL, include accepted/rejected suggestions."
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
(defun heurigraph-insert-depends-on () "Insert math:depends_on." (interactive) (heurigraph--insert-fixed-assertion "math:depends_on"))
;;;###autoload
(defun heurigraph-insert-uses () "Insert math:uses." (interactive) (heurigraph--insert-fixed-assertion "math:uses"))
;;;###autoload
(defun heurigraph-insert-enables-method () "Insert math:enables_method." (interactive) (heurigraph--insert-fixed-assertion "math:enables_method"))
;;;###autoload
(defun heurigraph-insert-solution-to () "Insert edu:solution_to." (interactive) (heurigraph--insert-fixed-assertion "edu:solution_to"))
;;;###autoload
(defun heurigraph-insert-strategy-for () "Insert edu:strategy_for." (interactive) (heurigraph--insert-fixed-assertion "edu:strategy_for"))
;;;###autoload
(defun heurigraph-insert-addresses () "Insert edu:addresses." (interactive) (heurigraph--insert-fixed-assertion "edu:addresses"))

;;;###autoload
(defun heurigraph-refresh-completions ()
  "Refresh project ontology/title completion data, then validate the forest."
  (interactive)
  (heurigraph-ontology-refresh)
  (heurigraph-validate))

(provide 'heurigraph)

;;; heurigraph.el ends here
