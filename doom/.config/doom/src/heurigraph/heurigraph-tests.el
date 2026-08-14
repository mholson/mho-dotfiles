;;; heurigraph-tests.el --- Tests for Heurigraph Emacs helpers -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'heurigraph)
(require 'heurigraph-lsp)
(require 'heurigraph-mode)
(require 'heurigraph-education)

(defmacro heurigraph-test--with-project (manifest &rest body)
  "Create a temporary Heurigraph project containing MANIFEST, then run BODY."
  (declare (indent 1))
  `(let* ((root (make-temp-file "heurigraph-emacs-test-" t))
          (collections (expand-file-name "collections" root))
          (heurigraph-notes-directory root))
     (unwind-protect
         (progn
           (make-directory collections t)
           (with-temp-file (expand-file-name "heurigraph.toml" root)
             (insert "[project]\nname = \"Test\"\n"))
           (with-temp-file (expand-file-name "sample.toml" collections)
             (insert ,manifest))
           ,@body)
       (delete-directory root t))))

(ert-deftest heurigraph-package-descriptor-starts-with-define-package ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "heurigraph-pkg.el"
                       (file-name-directory
                        (or (locate-library "heurigraph-tests")
                            "emacs/heurigraph-tests.el"))))
    (let ((form (read (current-buffer))))
      (should (eq (car form) 'define-package))
      (should (equal (nth 1 form) "heurigraph"))
      (should (stringp (nth 2 form))))))

(ert-deftest heurigraph-education-module-preview-is-read-only-cli-delegation ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args &optional buffer)
                 (setq captured (list args buffer))
                 0)))
      (heurigraph-education-module-preview)
      (should
       (equal captured
              '(("module" "preview") "*heurigraph-module-migration*"))))))

(ert-deftest heurigraph-education-module-migrate-passes-the-reviewed-digest ()
  (let ((digest (concat "sha256:" (make-string 64 ?a)))
        captured
        refreshed)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'heurigraph--run)
               (lambda (args &optional buffer)
                 (setq captured (list args buffer))
                 0))
              ((symbol-function 'heurigraph--refresh-active-lsp)
               (lambda () (setq refreshed t))))
      (heurigraph-education-module-migrate digest)
      (should
       (equal captured
              `(("module" "migrate" "--plan" ,digest)
                "*heurigraph-module-migration*")))
      (should refreshed))))

(ert-deftest heurigraph-root-prefers-nearest-forest-over-editor-project ()
  (let* ((outer (make-temp-file "heurigraph-outer-project-" t))
         (forest (expand-file-name "nested/forest" outer))
         (note (expand-file-name "notes/test-0001.typ" forest))
         (heurigraph-notes-directory nil)
         (heurigraph-executable "heurigraph")
         captured-directory)
    (unwind-protect
        (progn
          (make-directory (file-name-directory note) t)
          (with-temp-file (expand-file-name "heurigraph.toml" forest)
            (insert "[project]\nname = \"Nested\"\n"))
          (with-temp-buffer
            (setq buffer-file-name note
                  default-directory (file-name-directory note))
            (cl-letf (((symbol-function 'project-current) (lambda (&rest _) 'outer))
                      ((symbol-function 'project-root) (lambda (_) outer))
                      ((symbol-function 'executable-find) (lambda (_) "/bin/true"))
                      ((symbol-function 'call-process)
                       (lambda (&rest _)
                         (setq captured-directory default-directory)
                         0)))
              (should (file-equal-p (heurigraph--root) forest))
              (heurigraph--call-output '("validate"))
              (should (file-equal-p captured-directory forest)))))
      (delete-directory outer t))))

(ert-deftest heurigraph-book-output-name-defaults-by-profile ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (should (equal (heurigraph--book-output-name "sample" "teacher")
                   "sample-teacher.pdf"))))

(ert-deftest heurigraph-book-output-name-honours-manifest ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\noutput = \"course.pdf\"\n"
    (should (equal (heurigraph--book-output-name "sample" "student")
                   "course.pdf"))))

(ert-deftest heurigraph-book-profile-names-include-custom-profiles ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n\n[profiles.handout]\ninherits = \"student\"\n"
    (should (equal (heurigraph--book-profile-names "sample")
                   '("student" "teacher" "compact" "handout")))))

(ert-deftest heurigraph-quoted-value-at-point-finds-explicit-pair-id ()
  (with-temp-buffer
    (insert "[[section.block]]\nkind = \"exercise\"\nid = \"alg-0009\"\nsolution = \"alg-0010\"\n")
    (goto-char (point-min))
    (search-forward "alg-0009")
    (should (equal (heurigraph--quoted-value-at-point) "alg-0009"))))

(ert-deftest heurigraph-toml-string-escapes-literal-body-once ()
  (should (equal (heurigraph--toml-string "\\") "\\\\"))
  (should (equal (heurigraph--toml-string "\"") "\\\""))
  (should (equal (heurigraph--toml-string "a\\b\"c")
                 "a\\\\b\\\"c")))

(ert-deftest heurigraph-typst-string-escapes-literal-body-once ()
  (should (equal (heurigraph--typst-string "\\") "\\\\"))
  (should (equal (heurigraph--typst-string "\"") "\\\""))
  (should (equal (heurigraph--typst-string "a\\b\"c")
                 "a\\\\b\\\"c")))

(ert-deftest heurigraph-normalizes-prompted-string-lists ()
  (should
   (equal (heurigraph--normalize-string-list '("  Ruler " "" " Formula booklet"))
          '("Ruler" "Formula booklet"))))

(ert-deftest heurigraph-inserts-structured-assessment-data ()
  (with-temp-buffer
    (heurigraph-insert-assessment-data
     2 "b" 3 "false" "short-response" "familiar" '("explore" "generalise"))
    (should
     (equal
      (buffer-string)
      "#assessment-data(\n  order: 2,\n  label: \"b\",\n  marks: 3,\n  calculator: false,\n  response-format: \"short-response\",\n  cognitive-demand: \"familiar\",\n  inquiry-stages: (\"explore\", \"generalise\"),\n)"))))

(ert-deftest heurigraph-inserts-assessment-scheme-and-component-data ()
  (with-temp-buffer
    (heurigraph-insert-assessment-scheme-data "complete" nil 180)
    (insert "\n")
    (heurigraph-insert-assessment-component-data "external" 40 90 nil)
    (should
     (equal
      (buffer-string)
      "#assessment-scheme-data(\n  completeness: \"complete\",\n  declared-external-duration-minutes: 180,\n)\n#assessment-component-data(\n  mode: \"external\",\n  weighting-percent: 40,\n  duration-minutes: 90,\n)"))))

(ert-deftest heurigraph-inserts-mark-scheme-point ()
  (with-temp-buffer
    (heurigraph-insert-mark-scheme-point 1 "M1" 1 "Forms an equation.")
    (should
     (equal
      (buffer-string)
      "#mark-scheme-point(\n  order: 1,\n  code: \"M1\",\n  marks: 1,\n  description: \"Forms an equation.\",\n)"))))

(ert-deftest heurigraph-inserts-external-id ()
  (with-temp-buffer
    (heurigraph-insert-external-id
     "question-bank" "QB-48291" "https://example.org/QB-48291" "question" "7")
    (should
     (equal
      (buffer-string)
      "#external-id(\n  system: \"question-bank\",\n  value: \"QB-48291\",\n  url: \"https://example.org/QB-48291\",\n  record-type: \"question\",\n  revision: \"7\",\n)"))))

(ert-deftest heurigraph-inserts-exam-administration ()
  (with-temp-buffer
    (heurigraph-insert-exam-administration
     "International Baccalaureate"
     "Diploma Programme"
     "Mathematics: Analysis and Approaches HL"
     2026 "May" "TZ2" "Paper 1" "1" "en-GB" "2"
     90 80 "complete" "official" '("Formula booklet" "Ruler"))
    (should
     (equal
      (buffer-string)
      "#exam-administration(\n  authority: \"International Baccalaureate\",\n  course: \"Mathematics: Analysis and Approaches HL\",\n  year: 2026,\n  programme: \"Diploma Programme\",\n  session: \"May\",\n  time-zone: \"TZ2\",\n  paper: \"Paper 1\",\n  component: \"1\",\n  language: \"en-GB\",\n  version: \"2\",\n  duration-minutes: 90,\n  declared-total-marks: 80,\n  coverage: \"complete\",\n  status: \"official\",\n  permitted-materials: (\"Formula booklet\", \"Ruler\"),\n)"))))

(ert-deftest heurigraph-inserts-rights ()
  (with-temp-buffer
    (heurigraph-insert-rights
     "licensed" "Example Press" "Classroom licence"
     '("classroom" "internal assessment") '("no redistribution")
     "Used with permission." "https://example.org/licence")
    (should
     (equal
      (buffer-string)
      "#rights(\n  status: \"licensed\",\n  holder: \"Example Press\",\n  license: \"Classroom licence\",\n  permitted-uses: (\"classroom\", \"internal assessment\"),\n  restrictions: (\"no redistribution\"),\n  attribution: \"Used with permission.\",\n  source: \"https://example.org/licence\",\n)"))))

(ert-deftest heurigraph-inserts-publication-reference ()
  (with-temp-buffer
    (heurigraph-insert-publication-reference
     "artin1991" "adapted-from" "Chapter 2, Exercise 14" "2" 87)
    (should
     (equal
      (buffer-string)
      "#publication-reference(\n  citation: \"artin1991\",\n  role: \"adapted-from\",\n  locator: \"Chapter 2, Exercise 14\",\n  edition: \"2\",\n  page: 87,\n)"))))

(ert-deftest heurigraph-typst-call-end-skips-content-block-parentheses ()
  (with-temp-buffer
    (insert "#knowledge-node(id: \"mho-0001\", title: [Text \\] ) and [nested (]], public: false)\nAFTER")
    (goto-char (point-min))
    (search-forward "(")
    (let ((end (heurigraph--typst-call-end (1- (point)))))
      (should end)
      (goto-char end)
      (should (looking-at "\nAFTER")))))

(ert-deftest heurigraph-require-executable-reports-actionable-error ()
  (let ((heurigraph-executable "definitely-missing-heurigraph"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
      (should-error (heurigraph--require-executable) :type 'user-error))))

(ert-deftest heurigraph-compacts-command-output-for-the-minibuffer ()
  (should
   (equal (heurigraph--compact-output "  created page\n  notes/example.typ \n")
          "created page notes/example.typ")))

(ert-deftest heurigraph-auto-output-uses-minibuffer-for-short-successes ()
  (let ((heurigraph-output-display 'auto)
        (heurigraph-minibuffer-output-max-length 40))
    (should (heurigraph--output-in-minibuffer-p
             0 "created page\nnotes/example.typ\n"))
    (should-not (heurigraph--output-in-minibuffer-p
                 0 (make-string 41 ?x)))))

(ert-deftest heurigraph-output-modes-never-hide-failures ()
  (dolist (mode '(auto minibuffer buffer))
    (let ((heurigraph-output-display mode))
      (should-not
       (heurigraph--output-in-minibuffer-p 1 "validation failed"))
      (should-not
       (heurigraph--output-in-minibuffer-p "killed" "process terminated")))))

(ert-deftest heurigraph-minibuffer-mode-compacts-long-successes ()
  (let ((heurigraph-output-display 'minibuffer)
        (heurigraph-minibuffer-output-max-length 12))
    (should
     (heurigraph--output-in-minibuffer-p 0 (make-string 100 ?x)))
    (should
     (<= (string-width
          (heurigraph--minibuffer-summary '("scan") (make-string 100 ?x)))
         (+ (string-width "Heurigraph scan: ")
            heurigraph-minibuffer-output-max-length)))))

(ert-deftest heurigraph-run-keeps-full-output-while-messaging-short-result ()
  (let ((buffer-name "*heurigraph-output-test*")
        (heurigraph-output-display 'auto)
        (heurigraph-minibuffer-output-max-length 80)
        displayed
        status)
    (unwind-protect
        (cl-letf (((symbol-function 'heurigraph--require-executable)
                   (lambda () "heurigraph"))
                  ((symbol-function 'call-process)
                   (lambda (_program _infile destination _display &rest _args)
                     (with-current-buffer destination
                       (insert "scanned 4 trees\n"))
                     0))
                  ((symbol-function 'display-buffer)
                   (lambda (buffer &rest _args)
                     (setq displayed buffer)))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq status (apply #'format format-string args)))))
          (should (zerop (heurigraph--run '("scan") buffer-name)))
          (should-not displayed)
          (should (equal status "Heurigraph scan: scanned 4 trees"))
          (with-current-buffer buffer-name
            (should (string-match-p
                     (regexp-quote
                      "$ heurigraph scan\n\nscanned 4 trees\n\n[exit 0]\n")
                     (buffer-string)))
            (should (derived-mode-p 'special-mode))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest heurigraph-book-inserts-ordered-schema-three-blocks ()
  (with-temp-buffer
    (insert "[[section]]\nkind = \"chapter\"\ntitle = \"One\"\n")
    (heurigraph-book-insert-entry-block '((id . "mho-0001")))
    (heurigraph-book-insert-prose-block "Now compare the cases." nil "transition")
    (heurigraph-book-insert-exercise-block
     '((id . "mho-0009")) '((id . "mho-0010")))
    (should
     (equal
      (buffer-string)
      (concat
       "[[section]]\nkind = \"chapter\"\ntitle = \"One\"\n\n"
       "[[section.block]]\nkind = \"entry\"\nid = \"mho-0001\"\n\n"
       "[[section.block]]\nkind = \"prose\"\nrole = \"transition\"\n"
       "text = \"Now compare the cases.\"\n\n"
       "[[section.block]]\nkind = \"exercise\"\nid = \"mho-0009\"\n"
       "solution = \"mho-0010\"\n\n")))))

(ert-deftest heurigraph-book-prose-prefix-inserts-source-block ()
  (with-temp-buffer
    (heurigraph-book-insert-prose-block "fragments/bridge.typ" t "")
    (should (equal (buffer-string)
                   "[[section.block]]\nkind = \"prose\"\nsource = \"fragments/bridge.typ\"\n\n"))))

(ert-deftest heurigraph-new-delegates-namespace-allocation-to-project-config ()
  (let (captured
        (heurigraph-new-public-by-default nil))
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "{\"path\":\"/tmp/heurigraph-new.typ\"}")))
              ((symbol-function 'file-exists-p) (lambda (_path) t))
              ((symbol-function 'find-file) #'ignore))
      (heurigraph-new
       "A Concept" "" "math:concept" "math:algebra"
       "zero product property,null factor law"))
    (should (equal captured
                   '("new" "A Concept"
                     "--taxon" "math:concept" "--json"
                     "--subject" "math:algebra"
                     "--aliases" "zero product property,null factor law")))))

(ert-deftest heurigraph-new-can-publish-by-default ()
  (let (captured
        (heurigraph-new-public-by-default t))
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "{\"path\":\"/tmp/heurigraph-new.typ\"}")))
              ((symbol-function 'file-exists-p) (lambda (_path) t))
              ((symbol-function 'find-file) #'ignore))
      (heurigraph-new "A Concept" "" "math:concept" nil ""))
    (should (equal captured
                   '("new" "A Concept"
                     "--taxon" "math:concept" "--json"
                     "--public")))))

(ert-deftest heurigraph-new-omits-an-optional-subject ()
  (let (captured
        (heurigraph-new-public-by-default nil))
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "{\"path\":\"/tmp/heurigraph-new.typ\"}")))
              ((symbol-function 'file-exists-p) (lambda (_path) t))
              ((symbol-function 'find-file) #'ignore))
      (heurigraph-new "A Curriculum" "" "curriculum:framework" nil ""))
    (should (equal captured
                   '("new" "A Curriculum"
                     "--taxon" "curriculum:framework" "--json")))))

(ert-deftest heurigraph-init-supplies-explicit-project-identities ()
  (let ((root (make-temp-file "heurigraph-emacs-init-" t))
        captured
        (answers '("kogs" "https://example.org/forests/ib-mathematics")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _args) root))
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) (pop answers)))
                    ((symbol-function 'heurigraph--run)
                     (lambda (args) (setq captured args) 0)))
            (heurigraph-init))
          (should
           (equal
            captured
            '("init" "--prefix" "kogs"
              "--forest-iri" "https://example.org/forests/ib-mathematics"))))
      (delete-directory root t))))

(ert-deftest heurigraph-new-refreshes-lsp-before-visiting-created-note ()
  (let* ((root (make-temp-file "heurigraph-new-refresh-test-" t))
         (note (expand-file-name "notes/kogs-0001--authority.typ" root))
         events)
    (unwind-protect
        (progn
          (make-directory (file-name-directory note) t)
          (with-temp-file note
            (insert "#knowledge-node(id: \"kogs-0001\", taxon: \"curriculum:authority\")\n"))
          (cl-letf (((symbol-function 'heurigraph--call-output)
                     (lambda (_args)
                       (cons 0 (format "{\"path\":%S}" note))))
                    ((symbol-function 'heurigraph--root) (lambda () root))
                    ((symbol-function 'heurigraph-lsp-refresh-if-active)
                     (lambda () (push 'refresh events) t))
                    ((symbol-function 'find-file)
                     (lambda (path) (push (list 'visit path) events))))
            (heurigraph-new
             "International Baccalaureate Organization"
             "kogs-0001"
             "curriculum:authority"
             nil
             "")
            (should
             (equal (nreverse events)
                    (list 'refresh (list 'visit note))))))
      (delete-directory root t))))

(ert-deftest heurigraph-read-optional-subject-allows-none ()
  (cl-letf (((symbol-function 'heurigraph--ontology-candidates)
             (lambda (&rest _args)
               '(("Mathematics — math:mathematics"
                  (id . "math:mathematics")))))
            ((symbol-function 'completing-read)
             (lambda (_prompt _collection _predicate _require-match
                      _initial-input _history default)
               default)))
    (should-not
     (heurigraph--read-optional-subject
      "Subject (optional): " heurigraph-subjects nil))
    (should
     (equal
      (heurigraph--read-optional-subject
       "Subject (optional): " heurigraph-subjects
       "math:mathematics")
      "math:mathematics"))))

(ert-deftest heurigraph-public-toggle-round-trips-tree-metadata ()
  (with-temp-buffer
    ;; Reproduce a tree-sitter mode whose syntax table does not make generic
    ;; sexp navigation responsible for Typst parentheses.
    (let ((table (make-syntax-table)))
      (modify-syntax-entry ?\( "." table)
      (modify-syntax-entry ?\) "." table)
      (set-syntax-table table))
    (insert "#knowledge-node(\n  id: \"mat-0001\",\n  title: \"Null Factor Law\",\n  taxon: \"math:law\",\n  subjects: (\"math:mathematics\",),\n)\n")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
      (heurigraph-toggle-public))
    (should (string-match-p "public: true" (buffer-string)))
    (should (= (how-many "public:" (point-min) (point-max)) 1))
    (should (string-match-p "title: \"Null Factor Law\"" (buffer-string)))
    (should (string-match-p "taxon: \"math:law\"" (buffer-string)))
    (heurigraph-toggle-public)
    (should (string-match-p "public: false" (buffer-string)))
    (should (= (how-many "public:" (point-min) (point-max)) 1))
    (should (string-match-p "taxon: \"math:law\"" (buffer-string)))))

(ert-deftest heurigraph-public-toggle-round-trips-page-metadata ()
  (with-temp-buffer
    (insert "#note-meta(id: \"mho-0001\", title: \"Journal\", kind: \"journal\", date: \"2026-07-14\")\n")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
      (heurigraph-toggle-public))
    (should (string-match-p "public: true" (buffer-string)))
    (heurigraph-toggle-public)
    (should (string-match-p "public: false" (buffer-string)))
    (should (string-match-p "title: \"Journal\"" (buffer-string)))
    (should (= (how-many "public:" (point-min) (point-max)) 1))))

(ert-deftest heurigraph-public-toggle-ignores-comments-strings-and-content ()
  (with-temp-buffer
    (insert (concat
             "// #note-meta(public: true)\n"
             "#let sample = \"#knowledge-node(public: true)\"\n"
             "[#note-meta(public: true)]\n"
             "#knowledge-node(id: \"mho-0001\", public: false)\n"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
      (heurigraph-toggle-public))
    (should (= (how-many "public: true" (point-min) (point-max)) 4))
    (should-not (string-match-p
                 "#knowledge-node(id: \"mho-0001\", public: false)"
                 (buffer-string)))))

(ert-deftest heurigraph-public-toggle-edits-only-the-top-level-field ()
  (with-temp-buffer
    (insert (concat
             "#knowledge-node(\n"
             "  details: (public: false,),\n"
             "  body: [public: false],\n"
             "  // legacy public: false\n"
             "  public: true,\n"
             ")\n"))
    (heurigraph-toggle-public)
    (should (string-match-p "  public: false," (buffer-string)))
    (should (= (how-many "public: false" (point-min) (point-max)) 4))))

(ert-deftest heurigraph-public-toggle-rejects-duplicate-or-non-boolean-fields ()
  (dolist (body '("#knowledge-node(public: true, public: false)"
                  "#knowledge-node(public: \"yes\")"))
    (with-temp-buffer
      (insert body)
      (should-error (heurigraph-toggle-public) :type 'user-error)
      (should (equal (buffer-string) body)))))

(ert-deftest heurigraph-add-subjects-appends-without-duplicates ()
  (with-temp-buffer
    (insert "#knowledge-node(\n  id: \"mat-0001\",\n  title: \"Null Factor Law\",\n  taxon: \"math:law\",\n  subjects: (\"math:algebra\",),\n)\n")
    (heurigraph-add-subjects '("math:algebra" "math:number" "math:operations"))
    (should (string-match-p
             (regexp-quote
              "subjects: (\"math:algebra\", \"math:number\", \"math:operations\",)")
             (buffer-string)))
    (should (= (how-many "math:algebra" (point-min) (point-max)) 1))))

(ert-deftest heurigraph-add-subjects-preserves-multiline-metadata ()
  (with-temp-buffer
    (insert (concat
             "#knowledge-node(\n"
             "  id: \"mat-0001\",\n"
             "  title: \"Null Factor Law\",\n"
             "  taxon: \"math:law\",\n"
             "  subjects: (\n"
             "    \"math:algebra\",\n"
             "    // Keep this ontology note.\n"
             "  ),\n"
             ")\n"))
    (heurigraph-add-subjects '("math:number"))
    (should (string-match-p "// Keep this ontology note" (buffer-string)))
    (should (string-match-p "    \"math:number\",\n  )" (buffer-string)))))

(ert-deftest heurigraph-add-subjects-creates-a-missing-field ()
  (with-temp-buffer
    (insert "#knowledge-node(id: \"mat-0001\", title: \"A\", taxon: \"math:concept\")\n")
    (heurigraph-add-subjects '("math:number"))
    (should (string-match-p
             (regexp-quote "subjects: (\"math:number\",)")
             (buffer-string)))))

(ert-deftest heurigraph-add-subjects-looks-up-labels-and-excludes-existing-ids ()
  (with-temp-buffer
    (insert "#knowledge-node(id: \"mat-0001\", subjects: (\"math:algebra\",))\n")
    (cl-letf (((symbol-function 'heurigraph--ontology-candidates)
               (lambda (&rest _args)
                 '(("Algebra — math:algebra" . ((id . "math:algebra")))
                   ("Number — math:number" . ((id . "math:number"))))))
              ((symbol-function 'completing-read-multiple)
               (lambda (_prompt candidates &rest _args)
                 (should (equal (mapcar #'car candidates)
                                '("Number — math:number")))
                 '("Number — math:number"))))
      (should (equal (heurigraph--read-additional-subjects)
                     '("math:number"))))))

(ert-deftest heurigraph-subject-metadata-ignores-ids-inside-comments ()
  (with-temp-buffer
    (insert (concat
             "#knowledge-node(\n"
             "  id: \"mat-0001\",\n"
             "  subjects: (\n"
             "    \"math:algebra\",\n"
             "    // see also \"math:number\"\n"
             "    /* \"math:calculus\" is deferred */\n"
             "  ),\n"
             ")\n"))
    ;; Only the real entry counts; quoted ids in line and block comments must
    ;; not be reported as present, or they would be silently un-completable.
    (should (equal (plist-get (heurigraph--subject-metadata) :ids)
                   '("math:algebra")))))

(ert-deftest heurigraph-add-subjects-adds-an-id-mentioned-only-in-a-comment ()
  (with-temp-buffer
    (insert (concat
             "#knowledge-node(\n"
             "  id: \"mat-0001\",\n"
             "  subjects: (\n"
             "    \"math:algebra\",\n"
             "    // \"math:number\" was considered\n"
             "  ),\n"
             ")\n"))
    (heurigraph-add-subjects '("math:number"))
    (should (string-match-p "    \"math:number\",\n  )" (buffer-string)))
    (should (= (how-many "\"math:number\"" (point-min) (point-max)) 2))))

(ert-deftest heurigraph-collection-mode-enables-only-for-manifests ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let ((manifest-path (expand-file-name "collections/sample.toml" root)))
      (with-temp-buffer
        (setq buffer-file-name manifest-path
              default-directory root)
        (heurigraph-enable-for-collection)
        (should heurigraph-collection-mode)))))

(ert-deftest heurigraph-book-commands-forward-profile ()
  (let (calls)
    (cl-letf (((symbol-function 'heurigraph--compile)
               (lambda (args buffer)
                 (push (list args buffer) calls))))
      (heurigraph-book-check "sample" "teacher")
      (heurigraph-book-build "sample" "compact"))
    (should (equal (nreverse calls)
                   '((("book" "check" "sample" "--profile" "teacher")
                      "*heurigraph-book-check*")
                     (("book" "build" "sample" "--profile" "compact")
                      "*heurigraph-book-build*"))))))

(ert-deftest heurigraph-site-build-commands-run-asynchronously ()
  (let (calls)
    (cl-letf (((symbol-function 'heurigraph--compile)
               (lambda (args buffer)
                 (push (list args buffer) calls))))
      (heurigraph-build)
      (heurigraph-build-all))
    (should
     (equal (nreverse calls)
            '((("build" "--web") "*heurigraph-build*")
              (("build" "--web" "--pdf")
               "*heurigraph-build-all*"))))))

(ert-deftest heurigraph-manuscript-build-forwards-profile-and-force ()
  (let (call)
    (cl-letf (((symbol-function 'heurigraph--compile)
               (lambda (args buffer)
                 (setq call (list args buffer)))))
      (heurigraph-manuscript-build "sample" "release" t))
    (should
     (equal call
            '(("manuscript" "build" "sample"
               "--profile" "release" "--force")
              "*heurigraph-manuscript-build*")))))

(ert-deftest heurigraph-book-preview-opens-reported-output ()
  (let* ((root (make-temp-file "heurigraph-preview-test-" t))
         (pdf (expand-file-name "build/books/sample-teacher.pdf" root))
         opened)
    (unwind-protect
        (progn
          (make-directory (file-name-directory pdf) t)
          (with-temp-file pdf (insert "%PDF-test"))
          (cl-letf (((symbol-function 'heurigraph--root) (lambda () root))
                    ((symbol-function 'heurigraph--call-output)
                     (lambda (_args)
                       (cons 0 "book: sample [teacher] -> build/books/sample-teacher.pdf\n")))
                    ((symbol-function 'heurigraph--show-command-output)
                     (lambda (&rest _args)))
                    ((symbol-function 'browse-url-of-file)
                     (lambda (path) (setq opened path))))
            (heurigraph-book-preview "sample" "teacher")
            (should (equal opened pdf))
            (should (equal (plist-get heurigraph--last-book-output :profile)
                           "teacher"))))
      (delete-directory root t))))

(ert-deftest heurigraph-lsp-command-honours-trace ()
  (let ((heurigraph-executable "hg")
        (heurigraph-lsp-trace t))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) "/tmp/hg")))
      (should (equal (heurigraph-lsp--command) '("hg" "lsp" "--trace"))))))

(ert-deftest heurigraph-lsp-project-activation-is-scoped ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let ((note (expand-file-name "notes/a-0001.typ" root))
          (manifest (expand-file-name "collections/sample.toml" root))
          (manuscript
           (expand-file-name "manuscripts/sample/manuscript.toml" root))
          (outside (expand-file-name "elsewhere.toml" root)))
      (make-directory (file-name-directory manuscript) t)
      (with-temp-file manuscript (insert "[manuscript]\n"))
      (should (heurigraph-lsp--project-p note 'typst-mode))
      (should (heurigraph-lsp--project-p manifest 'toml-mode))
      (should (heurigraph-lsp--project-p manuscript 'toml-ts-mode))
      (should-not (heurigraph-lsp--project-p outside 'toml-mode)))))

(ert-deftest heurigraph-eglot-enable-registers-only-typst-modes ()
  (require 'eglot)
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let ((note (expand-file-name "notes/a-0001.typ" root))
          (server (list 'heurigraph-test-server))
          (eglot-server-programs nil)
          (heurigraph-executable "heurigraph"))
      (make-directory (file-name-directory note) t)
      (with-temp-file note (insert "#knowledge-node()\n"))
      (with-temp-buffer
        (setq buffer-file-name note
              default-directory root
              major-mode 'typst-ts-mode)
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (_name) "/usr/local/bin/heurigraph"))
                  ((symbol-function 'eglot-managed-p) (lambda () nil))
                  ((symbol-function 'eglot-ensure) #'ignore)
                  ((symbol-function 'eglot-current-server) (lambda () server)))
          (heurigraph-eglot-enable)
          (should (local-variable-p 'eglot-server-programs))
          (should (equal (caar eglot-server-programs)
                         '(typst-ts-mode typst-mode)))
          (should (eq heurigraph-eglot--server server)))))))

(ert-deftest heurigraph-eglot-status-rejects-a-stale-server-marker ()
  (require 'eglot)
  (with-temp-buffer
    (let ((selected (list 'selected))
          (current (list 'current)))
      (setq-local heurigraph-eglot--server selected)
      (cl-letf (((symbol-function 'eglot-current-server)
                 (lambda () current)))
        (should-not (heurigraph-lsp--eglot-server-active-p)))
      (cl-letf (((symbol-function 'eglot-current-server)
                 (lambda () selected)))
        (should (heurigraph-lsp--eglot-server-active-p))))))

(ert-deftest heurigraph-lsp-ensure-keeps-tinymist-and-heurigraph-alive ()
  (with-temp-buffer
    (setq major-mode 'typst-ts-mode)
    (setq-local lsp-enabled-clients '(other-client))
    (setq-local lsp-keep-workspace-alive nil)
    (let (registered
          deferred)
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &rest _args)
                   (memq feature '(lsp-mode lsp-typst))))
                ((symbol-function 'heurigraph-lsp-register-lsp-mode)
                 (lambda () (setq registered t)))
                ((symbol-function 'lsp-deferred)
                 (lambda () (setq deferred t))))
        (should (heurigraph-lsp-ensure))
        (should registered)
        (should deferred)
        (should lsp-keep-workspace-alive)
        (should (equal lsp-enabled-clients
                       '(tinymist heurigraph other-client)))))))

(ert-deftest heurigraph-lsp-refresh-targets-the-heurigraph-workspace ()
  (with-temp-buffer
    (setq-local lsp-mode t)
    (let ((workspace 'heurigraph-workspace)
          sent-to
          (original-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feature)
                   (or (eq feature 'lsp-mode)
                       (funcall original-featurep feature))))
                ((symbol-function 'heurigraph-lsp--workspace-by-server-id)
                 (lambda (server-id)
                   (and (eq server-id 'heurigraph) workspace)))
                ((symbol-function 'lsp-send-execute-command)
                 (lambda (command arguments)
                   (setq sent-to
                         (list lsp--cur-workspace command arguments)))))
        (should (heurigraph-lsp-refresh-if-active))
        (should (equal sent-to
                       '(heurigraph-workspace "heurigraph.refresh" [])))))))

(ert-deftest heurigraph-rename-id-plan-parses-cli-report ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0
                       "{\"old_id\":\"alg-0001\",\"new_id\":\"alg-0002\",\"dry_run\":true,\"files\":[{\"path\":\"notes/a.typ\",\"edits\":2}],\"rename_file\":null}"))))
      (let ((report (heurigraph--rename-id-plan "alg-0001" "alg-0002")))
        (should (equal captured
                       '("rename-id" "alg-0001" "alg-0002" "--dry-run" "--json")))
        (should (equal (alist-get 'new_id report) "alg-0002"))
        (should (= (alist-get 'edits (car (alist-get 'files report))) 2))))))

(ert-deftest heurigraph-rename-id-applies-confirmed-plan ()
  (let (applied)
    (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
               (lambda (&rest _args)
                 '((files . (((path . "notes/a.typ") (edits . 2))))
                   (rename_file . nil))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
              ((symbol-function 'heurigraph--run)
               (lambda (args) (setq applied args) 0)))
      (heurigraph-rename-id "alg-0001" "alg-0002")
      (should (equal applied '("rename-id" "alg-0001" "alg-0002"))))))

(ert-deftest heurigraph-rename-id-applies-file-only-rename ()
  (let (applied refreshed)
    (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
               (lambda (&rest _args)
                 '((files . nil)
                   (rename_file
                    . ("notes/alg-0001--one.typ"
                       "notes/alg-0002--one.typ")))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
              ((symbol-function 'heurigraph--rename-id-prepare-buffers)
               (lambda (&rest _args) nil))
              ((symbol-function 'heurigraph--run)
               (lambda (args) (setq applied args) 0))
              ((symbol-function 'heurigraph--rename-id-refresh-buffers)
               (lambda (&rest _args) (setq refreshed t))))
      (heurigraph-rename-id "alg-0001" "alg-0002")
      (should (equal applied '("rename-id" "alg-0001" "alg-0002")))
      (should refreshed))))

(ert-deftest heurigraph-rename-id-rejects-modified-affected-buffers ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let* ((notes (expand-file-name "notes" root))
           (path (expand-file-name "alg-0001--one.typ" notes))
           (buffer nil)
           applied)
      (make-directory notes t)
      (with-temp-file path (insert "alg-0001\n"))
      (setq buffer (find-file-noselect path))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "unsaved"))
            (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
                       (lambda (&rest _args)
                         '((files . (((path . "notes/alg-0001--one.typ")
                                      (edits . 1))))
                           (rename_file . nil))))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                      ((symbol-function 'heurigraph--run)
                       (lambda (&rest _args) (setq applied t) 0)))
              (should-error (heurigraph-rename-id "alg-0001" "alg-0002")
                            :type 'user-error)
              (should-not applied)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest heurigraph-rename-id-rejects-unsaved-unreported-references ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let* ((notes (expand-file-name "notes" root))
           (path (expand-file-name "draft.typ" notes))
           (buffer nil)
           applied)
      (make-directory notes t)
      (with-temp-file path (insert "draft\n"))
      (setq buffer (find-file-noselect path))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "#rel(\"math:depends_on\", \"alg-0001\")\n"))
            (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
                       (lambda (&rest _args)
                         '((files . (((path . "notes/other.typ")
                                      (edits . 1))))
                           (rename_file . nil))))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                      ((symbol-function 'heurigraph--run)
                       (lambda (&rest _args) (setq applied t) 0)))
              (should-error (heurigraph-rename-id "alg-0001" "alg-0002")
                            :type 'user-error)
              (should-not applied)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest heurigraph-rename-id-rejects-an-open-destination-buffer ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let* ((notes (expand-file-name "notes" root))
           (destination (expand-file-name "alg-0002--one.typ" notes))
           (buffer nil))
      (make-directory notes t)
      (setq buffer (find-file-noselect destination))
      (unwind-protect
          (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
                     (lambda (&rest _args)
                       '((files . (((path . "notes/alg-0001--one.typ")
                                    (edits . 1))))
                         (rename_file
                          . ("notes/alg-0001--one.typ"
                             "notes/alg-0002--one.typ")))))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
            (should-error (heurigraph-rename-id "alg-0001" "alg-0002")
                          :type 'user-error))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest heurigraph-rename-id-retargets-and-refreshes-open-buffer ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let* ((notes (expand-file-name "notes" root))
           (old-path (expand-file-name "alg-0001--one.typ" notes))
           (new-path (expand-file-name "alg-0002--one.typ" notes))
           (buffer nil))
      (make-directory notes t)
      (with-temp-file old-path (insert "alg-0001\n"))
      (setq buffer (find-file-noselect old-path))
      (unwind-protect
          (cl-letf (((symbol-function 'heurigraph--rename-id-plan)
                     (lambda (&rest _args)
                       '((files . (((path . "notes/alg-0001--one.typ")
                                    (edits . 1))))
                         (rename_file
                          . ("notes/alg-0001--one.typ"
                             "notes/alg-0002--one.typ")))))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                    ((symbol-function 'heurigraph--run)
                     (lambda (&rest _args)
                       (rename-file old-path new-path)
                       (with-temp-file new-path (insert "alg-0002\n"))
                       0)))
            (heurigraph-rename-id "alg-0001" "alg-0002")
            (with-current-buffer buffer
              (should (string-equal (file-truename buffer-file-name)
                                    (file-truename new-path)))
              (should (equal (buffer-string) "alg-0002\n"))
              (should-not (buffer-modified-p))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest heurigraph-doom-leader-map-exposes-core-commands ()
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "n"))
              #'heurigraph-new))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "R"))
              #'heurigraph-rename-id))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "N"))
              #'heurigraph-rename-file-from-title))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "L"))
              #'heurigraph-lsp-start))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "c"))
              #'heurigraph-new-content))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "j"))
              #'heurigraph-new-journal))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "W"))
              #'heurigraph-new-weeknote))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "D"))
              #'heurigraph-new-diagram))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "i"))
              #'heurigraph-insert-diagram))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "M"))
              #'heurigraph-insert-image))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "?"))
              #'heurigraph-ai-workflow))
  (should (eq (lookup-key heurigraph-doom-leader-map (kbd "Q"))
              #'heurigraph-insert-rights)))

(ert-deftest heurigraph-education-map-keeps-domain-and-core-commands-distinct ()
  (should-not (lookup-key heurigraph-note-mode-map (kbd "C-c h H")))
  (should (eq (lookup-key heurigraph-education-note-mode-map (kbd "C-c h H"))
              #'heurigraph-insert-assessment-component-data))
  (should (eq (lookup-key heurigraph-note-mode-map (kbd "C-c h ?"))
              #'heurigraph-ai-workflow))
  (should (eq (lookup-key heurigraph-note-mode-map (kbd "C-c h C"))
              #'heurigraph-book-find-containing-tree)))

(ert-deftest heurigraph-weeknote-forwards-manual-iso-year-and-week ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--create-page)
               (lambda (&rest args) (setq captured args))))
      (heurigraph-new-weeknote 2026 7)
      (should
       (equal captured
              '("Weeknotes 2026-W07" "weeknote"
                ("--year" "2026" "--week" "7")))))))

(ert-deftest heurigraph-id-at-file-supports-tree-and-weeknote-ids ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/mho-0001--quadratics.typ")
    (should (equal (heurigraph--id-at-file) "mho-0001"))
    (setq buffer-file-name "/tmp/2026-W07--weeknotes.typ")
    (should (equal (heurigraph--id-at-file) "2026-W07"))))

(ert-deftest heurigraph-filename-slug-matches-cli-rules ()
  (should
   (equal (heurigraph--filename-slug
           "AA A1.03 (FA2029) — Sum of an Arithmetic Sequence")
          "aa-a1-03-fa2029-sum-of-an-arithmetic-sequence"))
  (should (equal (heurigraph--filename-slug "  Difference of Squares!  ")
                 "difference-of-squares")))

(ert-deftest heurigraph-renames-current-file-from-knowledge-node-title ()
  (let* ((root (make-temp-file "heurigraph-title-rename-" t))
         (old-path
          (expand-file-name "kogs-000G--a1-03.typ" root))
         (new-path
          (expand-file-name
           "kogs-000G--aa-a1-03-fa2029-sum-of-an-arithmetic-sequence.typ"
           root))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file old-path
            (insert
             "#knowledge-node(\n"
             "  id: \"kogs-000G\",\n"
             "  title: \"AA A1.03 (FA2029) — Sum of an Arithmetic Sequence\",\n"
             "  taxon: \"ibdp:learning-statement\",\n"
             ")\n"))
          (setq buffer (find-file-noselect old-path))
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _args) t))
                      ((symbol-function 'heurigraph--refresh-active-lsp)
                       #'ignore))
              (heurigraph-rename-file-from-title))
            (should (string-equal buffer-file-name new-path))
            (should-not (buffer-modified-p)))
          (should-not (file-exists-p old-path))
          (should (file-regular-p new-path)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest heurigraph-title-rename-refuses-an-existing-destination ()
  (let* ((root (make-temp-file "heurigraph-title-collision-" t))
         (old-path (expand-file-name "kogs-000G--old.typ" root))
         (new-path (expand-file-name "kogs-000G--new-title.typ" root))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file old-path
            (insert
             "#knowledge-node(\n"
             "  id: \"kogs-000G\",\n"
             "  title: \"New Title\",\n"
             "  taxon: \"ibdp:learning-statement\",\n"
             ")\n"))
          (with-temp-file new-path (insert "existing\n"))
          (setq buffer (find-file-noselect old-path))
          (with-current-buffer buffer
            (should-error (heurigraph-rename-file-from-title)
                          :type 'user-error))
          (should (file-regular-p old-path))
          (should (file-regular-p new-path)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest heurigraph-next-id-uses-structured-process-call ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "mho-0042\n"))))
      (should (equal (heurigraph-next-id) "Next id: mho-0042"))
      (should (equal captured '("next-id"))))))

(ert-deftest heurigraph-mcp-args-grant-only-the-exact-project-root ()
  (heurigraph-test--with-project ""
    (should
     (equal (heurigraph--mcp-args)
            (list "mcp" "serve" "--stdio" "--root"
                  (directory-file-name (file-truename root)))))))

(ert-deftest heurigraph-mcp-inspect-reports-the-proposal-aware-authority ()
  (heurigraph-test--with-project ""
    (let (captured shown message)
      (cl-letf (((symbol-function 'heurigraph--call-output)
                 (lambda (args)
                   (setq captured args)
                   (cons 0
                         "{\"server\":{\"version\":\"3.5.3\",\"canonical_sources_read_only\":true,\"proposal_queue_write\":true}}")))
                ((symbol-function 'heurigraph--show-command-output)
                 (lambda (&rest args) (setq shown args)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq message (apply #'format format-string args)))))
        (heurigraph-mcp-inspect)
        (should
         (equal captured
                (list "mcp" "inspect" "--root"
                      (directory-file-name (file-truename root)) "--json")))
        (should shown)
        (should (string-match-p "canonical sources read-only" message))
        (should (string-match-p "proposal queues append-only writable" message))))))

(ert-deftest heurigraph-mcp-inspection-rejects-malformed-capabilities ()
  (cl-letf (((symbol-function 'heurigraph--call-output)
             (lambda (_args) (cons 0 "{\"schema\":3}"))))
    (should-error (heurigraph--mcp-inspection) :type 'user-error)))

(ert-deftest heurigraph-ai-workflow-dispatches-bounded-actions ()
  (let (called)
    (cl-letf (((symbol-function 'heurigraph-mcp-inspect)
               (lambda () (setq called 'inspect)))
              ((symbol-function 'heurigraph-review-center)
               (lambda () (setq called 'review)))
              ((symbol-function 'heurigraph-suggest-list)
               (lambda (&rest _args) (setq called 'suggestions)))
              ((symbol-function 'heurigraph-validate)
               (lambda () (setq called 'validate))))
      (heurigraph-ai-workflow "Inspect connector authority")
      (should (eq called 'inspect))
      (heurigraph-ai-workflow "Open proposal review center")
      (should (eq called 'review))
      (heurigraph-ai-workflow "Review semantic suggestions")
      (should (eq called 'suggestions))
      (heurigraph-ai-workflow "Validate forest")
      (should (eq called 'validate)))))

(ert-deftest heurigraph-review-center-opens-the-structured-cli-path ()
  (let* ((root (make-temp-file "heurigraph-review-center-" t))
         (page (expand-file-name "build/review/index.html" root))
         opened)
    (unwind-protect
        (progn
          (make-directory (file-name-directory page) t)
          (with-temp-file page (insert "<!doctype html>"))
          (cl-letf (((symbol-function 'heurigraph--call-output)
                     (lambda (args)
                       (should (equal args '("review" "build" "--json")))
                       (cons 0 (format "{\"path\":%S}" page))))
                    ((symbol-function 'browse-url-of-file)
                     (lambda (path) (setq opened path))))
            (heurigraph-review-center)
            (should (equal opened page))))
      (delete-directory root t))))

(ert-deftest heurigraph-mcp-configuration-uses-absolute-executable-and-root ()
  (heurigraph-test--with-project ""
    (let (copied)
      (cl-letf (((symbol-function 'heurigraph--mcp-command)
                 (lambda () "/opt/heurigraph/bin/heurigraph"))
                ((symbol-function 'kill-new)
                 (lambda (value) (setq copied value))))
        (heurigraph-mcp-copy-configuration)
        (let* ((configuration
                (json-parse-string copied :object-type 'alist :array-type 'list))
               (servers (alist-get 'mcpServers configuration))
               (server (alist-get 'heurigraph servers)))
          (should
           (equal (alist-get 'command server)
                  "/opt/heurigraph/bin/heurigraph"))
          (should
           (equal (alist-get 'args server)
                  (list "mcp" "serve" "--stdio" "--root"
                        (directory-file-name (file-truename root))))))))))

(ert-deftest heurigraph-mcp-interactive-configuration-confirms-authority ()
  (heurigraph-test--with-project ""
    (let (inspected prompt copied)
      (cl-letf (((symbol-function 'heurigraph--mcp-inspection)
                 (lambda (&optional _display-output)
                   (setq inspected t)
                   '((server
                      (version . "3.5.3")
                      (canonical_sources_read_only . t)
                      (proposal_queue_write . t)))))
                ((symbol-function 'called-interactively-p) (lambda (&rest _args) t))
                ((symbol-function 'heurigraph--mcp-command)
                 (lambda () "/opt/heurigraph/bin/heurigraph"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (question) (setq prompt question) t))
                ((symbol-function 'kill-new)
                 (lambda (value) (setq copied value))))
        (call-interactively #'heurigraph-mcp-copy-configuration)
        (should inspected)
        (should copied)
        (should (string-match-p "canonical sources read-only" prompt))
        (should (string-match-p "proposal queues append-only writable" prompt))))))

(ert-deftest heurigraph-book-rows-reports-invalid-json ()
  (cl-letf (((symbol-function 'heurigraph--call-output)
             (lambda (_args) (cons 0 "not json"))))
    (should-error (heurigraph--book-rows) :type 'user-error)))

(ert-deftest heurigraph-nodes-reports-invalid-json ()
  (cl-letf (((symbol-function 'heurigraph--call-output)
             (lambda (_args) (cons 0 "not json"))))
    (should-error (heurigraph--nodes) :type 'user-error)))

(ert-deftest heurigraph-new-title-allows-free-input-with-fuzzy-completion ()
  (let (seen-styles seen-require-match)
    (cl-letf (((symbol-function 'heurigraph--node-candidates)
               (lambda (&optional _kind)
                 '(("Null Factor Law — mho-0001 [math:law]"
                    (id . "mho-0001")
                    (title . "Null Factor Law")
                    (taxon . "math:law")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection _predicate require-match
                        &rest _args)
                 (setq seen-styles completion-styles
                       seen-require-match require-match)
                 "  Arithmetic Sequences  ")))
      (should
       (equal (heurigraph--read-new-node-title)
              "Arithmetic Sequences"))
      (should (equal seen-styles '(flex basic)))
      (should-not seen-require-match))))

(ert-deftest heurigraph-new-title-confirms-an-existing-title ()
  (let* ((node '((id . "mho-0001")
                 (title . "Null Factor Law")
                 (taxon . "math:law")))
         (candidate (cons "Null Factor Law — mho-0001 [math:law]" node))
         confirmation)
    (cl-letf (((symbol-function 'heurigraph--node-candidates)
               (lambda (&optional _kind) (list candidate)))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) (car candidate)))
              ((symbol-function 'yes-or-no-p)
               (lambda (prompt)
                 (setq confirmation prompt)
                 t)))
      (should
       (equal (heurigraph--read-new-node-title) "Null Factor Law"))
      (should (string-match-p "mho-0001, math:law" confirmation)))))

(ert-deftest heurigraph-new-title-can-refuse-a-case-insensitive-duplicate ()
  (let* ((node '((id . "mho-0001")
                 (title . "Null Factor Law")
                 (taxon . "math:law")))
         (candidate (cons "Null Factor Law — mho-0001 [math:law]" node)))
    (cl-letf (((symbol-function 'heurigraph--node-candidates)
               (lambda (&optional _kind) (list candidate)))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "null factor law"))
              ((symbol-function 'yes-or-no-p)
               (lambda (_prompt) nil)))
      (should-error (heurigraph--read-new-node-title)
                    :type 'user-error))))

(ert-deftest heurigraph-browser-opens-only-after-server-is-ready ()
  (let (opened probe-deleted scheduled)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'open-network-stream)
               (lambda (&rest _args) 'probe))
              ((symbol-function 'delete-process)
               (lambda (process) (setq probe-deleted process)))
              ((symbol-function 'browse-url)
               (lambda (url) (setq opened url)))
              ((symbol-function 'run-at-time)
               (lambda (&rest _args) (setq scheduled t))))
      (heurigraph--browse-when-server-ready
       'server "http://127.0.0.1:8383/" 8383)
      (should (equal opened "http://127.0.0.1:8383/"))
      (should (eq probe-deleted 'probe))
      (should-not scheduled))))

(ert-deftest heurigraph-insert-diagram-emits-editable-parameters ()
  (with-temp-buffer
    (heurigraph-insert-diagram
     "cetz-0001" "A dependency graph" "65%" "Graph structure")
    (should
     (equal (buffer-string)
            "#cetz-diagram(\n  \"cetz-0001\",\n  alt: \"A dependency graph\",\n  width: 65%,\n  caption: \"Graph structure\",\n)"))))

(ert-deftest heurigraph-insert-diagram-omits-an-empty-caption ()
  (with-temp-buffer
    (heurigraph-insert-diagram "cetz-0002" "Two nodes" "70%" "")
    (should (string-match-p "width: 70%" (buffer-string)))
    (should-not (string-match-p "caption:" (buffer-string)))))

(ert-deftest heurigraph-diagram-completion-only-lists-canonical-cetz-assets ()
  (heurigraph-test--with-project ""
    (let ((directory (expand-file-name "diagrams" root)))
      (make-directory directory t)
      (with-temp-file (expand-file-name "cetz-0001.typ" directory)
        (insert "// Title: Canonical\n"))
      (with-temp-file (expand-file-name "dia-0001.typ" directory)
        (insert "// Title: Old namespace\n"))
      (with-temp-file (expand-file-name "sketch.typ" directory)
        (insert "// Title: Unmanaged\n"))
      (let ((candidates (heurigraph--diagram-candidates)))
        (should (= (length candidates) 1))
        (should (equal (plist-get (cdar candidates) :name) "cetz-0001"))))))

(ert-deftest heurigraph-insert-image-resolves-a-managed-id-to-its-path ()
  (with-temp-buffer
    (heurigraph-insert-image "img-000A" "images/img-000A.png")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/img-000A.png\", alt: none)"))))

(ert-deftest heurigraph-insert-image-carries-the-use-site-accessibility-choice ()
  (with-temp-buffer
    (heurigraph-insert-image
     "img-000A" "images/img-000A.png" "A plot crossing at two points")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/img-000A.png\", alt: \"A plot crossing at two points\")")))
  (with-temp-buffer
    (heurigraph-insert-image "img-000A" "images/img-000A.png" "")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/img-000A.png\", alt: \"\")"))))

(ert-deftest heurigraph-import-image-uses-structured-cli-json ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0
                       "{\"id\":\"img-0001\",\"path\":\"images/img-0001.png\",\"extension\":\"png\"}"))))
      (let ((asset (heurigraph-import-image "/tmp/source.png")))
        (should (equal (alist-get 'id asset) "img-0001"))
        (should (equal captured
                       '("image" "add" "/tmp/source.png" "--json")))))))

(ert-deftest heurigraph-rename-image-requests-the-next-managed-id ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0
                       "{\"id\":\"img-000B\",\"path\":\"images/img-000B.jpg\",\"extension\":\"jpg\"}"))))
      (let ((asset (heurigraph-rename-image "/tmp/project/images/photo.jpg")))
        (should (equal (alist-get 'id asset) "img-000B"))
        (should (equal captured
                       '("image" "rename" "/tmp/project/images/photo.jpg" "--json")))))))

(ert-deftest heurigraph-rename-image-retargets-a-visited-buffer-after-cli-move ()
  (heurigraph-test--with-project ""
    (let* ((directory (expand-file-name "images" root))
           (source (expand-file-name "photo.jpg" directory))
           (destination (expand-file-name "img-0001.jpg" directory))
           buffer)
      (make-directory directory t)
      (with-temp-file source (insert "image"))
      ;; Avoid asking a headless batch display to initialize image-mode; this
      ;; test exercises buffer retargeting, not image rendering.
      (let ((auto-mode-alist nil))
        (setq buffer (find-file-noselect source)))
      (unwind-protect
          (cl-letf (((symbol-function 'heurigraph--call-output)
                     (lambda (_args)
                       (rename-file source destination)
                       (cons 0
                             "{\"id\":\"img-0001\",\"path\":\"images/img-0001.jpg\",\"extension\":\"jpg\"}"))))
            (with-current-buffer buffer
              (heurigraph-rename-image source)
              (should (equal buffer-file-name destination))
              (should (file-exists-p destination))
              (should-not (file-exists-p source))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest heurigraph-doom-setup-installs-spc-e-prefix ()
  (unwind-protect
      (progn
        (setq doom-leader-map (make-sparse-keymap))
        (heurigraph-doom-setup-keybindings)
        (should (eq (lookup-key doom-leader-map (kbd "e n"))
                    #'heurigraph-new))
        (should (eq (lookup-key doom-leader-map (kbd "e v"))
                    #'heurigraph-validate)))
    (makunbound 'doom-leader-map)))

(ert-deftest heurigraph-reads-project-owned-ontology-completions ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let ((build (expand-file-name "build" root))
          (heurigraph-ontology-auto-refresh nil))
      (make-directory build t)
      (with-temp-file (expand-file-name "ontology.json" build)
        (insert
         "{\"version\":\"1.0.0\",\"ontology_version\":\"2.0.0\","
         "\"taxons\":[{\"id\":\"prob:distribution\",\"label\":\"Distribution\",\"description\":\"A probability distribution.\"}],"
         "\"subjects\":[],\"predicates\":[{\"id\":\"prob:approximates\",\"label\":\"approximates\",\"external_targets\":false}],\"structures\":[]}"))
      (let* ((candidates (heurigraph--ontology-candidates 'taxons '("fallback:item")))
             (item (cdar candidates)))
        (should (equal (alist-get 'id item) "prob:distribution"))
        (should (string-match-p "Distribution" (caar candidates)))
        (should-not (equal (alist-get 'id item) "fallback:item")))
      (should-not
       (alist-get 'external_targets
                  (car (heurigraph--ontology-items 'predicates)))))))

(ert-deftest heurigraph-ontology-paths-follow-project-configuration ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (with-temp-file (expand-file-name "heurigraph.toml" root)
      (insert
       "[project]\nname = \"Test\"\nbuild_dir = \"artifacts\"\n\n"
       "[ontology]\nroot = \"vocabulary\"\nmanifest = \"manifest.toml\"\n"))
    (should (equal (heurigraph--ontology-json-path)
                   (expand-file-name "artifacts/ontology.json" root)))
    (should (equal (heurigraph--ontology-root-path)
                   (expand-file-name "vocabulary" root)))))

(ert-deftest heurigraph-formats-required-assertion-context ()
  (should
   (equal
    (heurigraph--format-assertion
     "edu:has_learning_prerequisite" "mho-0003"
     '(("framework" . "se-lgr22") ("stage" . "7-9")))
    (concat
     "#rel(\n"
     "  \"edu:has_learning_prerequisite\",\n"
     "  \"mho-0003\",\n"
     "  framework: \"se-lgr22\",\n"
     "  stage: \"7-9\",\n"
     ")"))))

(ert-deftest heurigraph-format-assertion-escapes-external-identities ()
  (should
   (equal (heurigraph--format-assertion "external:\"kind" "urn:\\target" nil)
          "#rel(\"external:\\\"kind\", \"urn:\\\\target\")")))

(ert-deftest heurigraph-reads-required-and-selected-optional-assertion-context ()
  (let (prompts)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _args) '("stage")))
              ((symbol-function 'heurigraph--read-assertion-context-value)
               (lambda (field required)
                 (push (cons field required) prompts)
                 (pcase field
                   ("framework" "kogs-0004")
                   ("stage" "kogs-0006")))))
      (should
       (equal
        (heurigraph--read-assertion-context
         '((required_context . ("framework"))))
        '(("framework" . "kogs-0004")
          ("stage" . "kogs-0006"))))
      (should (equal (nreverse prompts)
                     '(("framework" . t) ("stage")))))))

(ert-deftest heurigraph-context-node-completion-filters-frameworks-and-stages ()
  (cl-letf (((symbol-function 'heurigraph--node-candidates)
             (lambda (&optional _kind)
               '(("Framework" (id . "kogs-0004")
                  (taxon . "curriculum:framework"))
                 ("AA HL" (id . "kogs-0006")
                  (taxon . "curriculum:course"))
                 ("Algebra" (id . "kogs-0010")
                  (taxon . "ibdp:topic"))))))
    (should
     (equal
      (mapcar (lambda (candidate) (alist-get 'id (cdr candidate)))
              (heurigraph--assertion-context-node-candidates "framework"))
      '("kogs-0004")))
    (should
     (equal
      (mapcar (lambda (candidate) (alist-get 'id (cdr candidate)))
              (heurigraph--assertion-context-node-candidates "stage"))
      '("kogs-0006")))))

(ert-deftest heurigraph-assertion-target-allows-registered-external-identities ()
  (cl-letf (((symbol-function 'heurigraph--node-candidates)
            (lambda (&optional _kind) nil))
            ((symbol-function 'completing-read)
             (lambda (&rest _args) "External.Algebra.Group.Basic")))
    (should
     (equal (alist-get 'id
                       (heurigraph--read-assertion-target
                        '((external_targets . t))))
            "External.Algebra.Group.Basic"))))

(ert-deftest heurigraph-inserts-ontology-subject-skeleton ()
  (with-temp-buffer
    (insert "# Subject vocabulary\n")
    (heurigraph-ontology-insert-subject
     "prob:bayesian-inference" "Bayesian inference" "prob:statistics"
     '("Bayes") "Inference using posterior distributions.")
    (should
     (string-match-p
      (regexp-quote
       (concat
        "[[subjects]]\n"
        "id = \"prob:bayesian-inference\"\n"
        "label = \"Bayesian inference\"\n"
        "broader = \"prob:statistics\"\n"
        "aliases = [\"Bayes\"]\n"
        "description = \"Inference using posterior distributions.\""))
      (buffer-string)))))

(ert-deftest heurigraph-suggestion-forwards-qualified-context ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args) (setq captured args) 0)))
      (heurigraph-suggest-add
       "mho-0002" "curriculum:aligns_to" "ib:objective-1"
       0.8 "Explicit mapping" "Reviewer" nil
       '(("framework" . "ibdp-2029") ("language" . "en"))))
    (should
     (equal captured
            '("suggest" "add" "mho-0002" "curriculum:aligns_to"
              "ib:objective-1" "--confidence" "0.8"
              "--framework" "ibdp-2029" "--language" "en"
              "--rationale" "Explicit mapping" "--by" "Reviewer")))))

(ert-deftest heurigraph-ontology-mode-enables-only-for-registry-files ()
  (heurigraph-test--with-project
      "schema = 3\n[book]\nid = \"sample\"\ntitle = \"Sample\"\n"
    (let* ((ontology (expand-file-name "ontology" root))
           (registry (expand-file-name "subjects/probability.toml" ontology)))
      (make-directory (file-name-directory registry) t)
      (with-temp-file registry (insert "subjects = []\n"))
      (with-temp-buffer
        (setq buffer-file-name registry
              default-directory root)
        (heurigraph-enable-for-ontology)
        (should heurigraph-ontology-mode)))))

(provide 'heurigraph-tests)
;;; heurigraph-tests.el ends here
