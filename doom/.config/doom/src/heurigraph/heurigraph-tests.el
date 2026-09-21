;;; heurigraph-tests.el --- Tests for Heurigraph Emacs helpers -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'heurigraph)
(require 'heurigraph-lsp)
(require 'heurigraph-mode)
(require 'heurigraph-education)

(defmacro heurigraph-test--with-project (_fixture &rest body)
  "Create a temporary Heurigraph project, then run BODY."
  (declare (indent 1))
  `(let* ((root (make-temp-file "heurigraph-emacs-test-" t))
          (heurigraph-notes-directory root))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "heurigraph.toml" root)
             (insert "[project]\nname = \"Test\"\n"))
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
      (should (equal (nth 2 form) heurigraph-version)))))

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
              (heurigraph--call-output '("check"))
              (should (file-equal-p captured-directory forest)))))
      (delete-directory outer t))))

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
    (heurigraph-insert-mark-scheme-point "q1-method" 1 "M" 1 "(M1)" "Forms an equation.")
    (should
     (equal
      (buffer-string)
      "#mark-scheme-point(\n  id: \"q1-method\",\n  order: 1,\n  type: \"M\",\n  value: 1,\n  source-annotation: \"(M1)\",\n  description: \"Forms an equation.\",\n)"))))

(ert-deftest heurigraph-mark-scheme-point-preserves-markup-and-rejects-incomplete-input ()
  (with-temp-buffer
    (heurigraph-insert-mark-scheme-point
     "q1-answer" 2 "A" 1 "A1ft" "Obtains $x = 2$ using #text(\"substitution\").")
    (should (string-match-p
             (regexp-quote "description: \"Obtains $x = 2$ using #text(\\\"substitution\\\").\"")
             (buffer-string))))
  (dolist (arguments '(("" 1 "M" 1 "M1" "Method")
                       ("q1 invalid" 1 "M" 1 "M1" "Method")
                       ("q1\n" 1 "M" 1 "M1" "Method")
                       ("q1" 0 "M" 1 "M1" "Method")
                       ("q1" 1 "" 1 "M1" "Method")
                       ("q1" 1 "M" 0 "M1" "Method")
                       ("q1" 1 "M" 1 "" "Method")
                       ("q1" 1 "M" 1 "M1" " ")))
    (with-temp-buffer
      (should-error (apply #'heurigraph-insert-mark-scheme-point arguments) :type 'user-error)
      (should (string-empty-p (buffer-string))))))

(ert-deftest heurigraph-mark-scheme-point-prompts-default-provider-annotation ()
  (let ((strings '("q1-method" "M" "M2" "Forms $x = 2$.")) (numbers '(1 2)) default)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional initial &rest _)
                 (when (equal prompt "Source annotation: ") (setq default initial))
                 (pop strings)))
              ((symbol-function 'read-number) (lambda (&rest _) (pop numbers))))
      (with-temp-buffer
        (call-interactively #'heurigraph-insert-mark-scheme-point)
        (should (equal default "M2"))
        (should (string-match-p "value: 2," (buffer-string)))))))

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

(ert-deftest heurigraph-require-executable-reports-actionable-error ()
  (let ((heurigraph-executable "definitely-missing-heurigraph"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
      (should-error (heurigraph--require-executable) :type 'user-error))))

(ert-deftest heurigraph-run-keeps-and-displays-full-output ()
  (let ((buffer-name "*heurigraph-output-test*") displayed)
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
                     (setq displayed buffer))))
          (should (zerop (heurigraph--run '("check") buffer-name)))
          (should (eq displayed (get-buffer buffer-name)))
          (with-current-buffer buffer-name
            (should (string-match-p
                     (regexp-quote
                      "$ heurigraph check\n\nscanned 4 trees\n\n[exit 0]\n")
                     (buffer-string)))
            (should (derived-mode-p 'special-mode))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest heurigraph-new-delegates-uuid-generation-to-the-engine ()
  (let (captured
        (heurigraph-new-public-by-default nil))
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "{\"path\":\"/tmp/heurigraph-new.typ\"}")))
              ((symbol-function 'file-exists-p) (lambda (_path) t))
              ((symbol-function 'find-file) #'ignore))
      (heurigraph-new
       "A Concept" "math:concept" "math:algebra"
       "zero product property,null factor law"))
    (should (equal captured
                   '("node" "new" "A Concept"
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
      (heurigraph-new "A Concept" "math:concept" nil ""))
    (should (equal captured
                   '("node" "new" "A Concept"
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
      (heurigraph-new "A Curriculum" "curriculum:framework" nil ""))
    (should (equal captured
                   '("node" "new" "A Curriculum"
                     "--taxon" "curriculum:framework" "--json")))))

(ert-deftest heurigraph-init-supplies-a-project-name ()
  (let ((root (make-temp-file "heurigraph-emacs-init-" t))
        captured
        (answers '("education" "https://example.org/forests/ib-mathematics")))
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
            '("init" "--name" "education"))))
      (delete-directory root t))))

(ert-deftest heurigraph-init-opens-an-existing-project-without-reinitialising ()
  (let* ((root (make-temp-file "heurigraph-emacs-existing-init-" t))
         (config-path (expand-file-name "heurigraph.toml" root))
         run-called
         visited
         feedback)
    (unwind-protect
        (progn
          (with-temp-file config-path
            (insert "schema = \"heurigraph.workspace/1\"\n"))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _args) root))
                    ((symbol-function 'heurigraph--run)
                     (lambda (_args) (setq run-called t) 0))
                    ((symbol-function 'find-file)
                     (lambda (path) (setq visited path)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq feedback (apply #'format format-string args)))))
            (heurigraph-init))
          (should-not run-called)
          (should (equal visited config-path))
          (should (string-match-p "already initialised" feedback)))
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
      "Subject (optional): "))
    (should
     (equal
      (heurigraph--read-optional-subject
       "Subject (optional): " "math:mathematics")
      "math:mathematics"))))

(ert-deftest heurigraph-lsp-command-honours-trace ()
  (let ((heurigraph-executable "hg") (heurigraph-lsp-trace t))
    (cl-letf (((symbol-function 'executable-find) (lambda (_name) "/tmp/hg")))
      (should (equal (heurigraph-lsp--command)
                     '("/tmp/hg" "lsp" "--trace"))))))

(ert-deftest heurigraph-lsp-project-root-prefers-nested-forest ()
  (let* ((outer (make-temp-file "heurigraph-lsp-outer-" t))
         (forest (expand-file-name "content/forest" outer))
         (note (expand-file-name "notes/test-0001.typ" forest)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory note) t)
          (with-temp-file (expand-file-name "heurigraph.toml" outer))
          (with-temp-file (expand-file-name "heurigraph.toml" forest))
          (with-temp-buffer
            (setq buffer-file-name note
                  default-directory (file-name-directory note)
                  project-find-functions
                  (list (lambda (_directory) (cons 'transient outer))))
            (should (file-equal-p (heurigraph-lsp--configure-project-root)
                                  forest))
            (should (file-equal-p (project-root (project-current)) forest))))
      (delete-directory outer t))))

(ert-deftest heurigraph-lsp-ensure-registers-eglot-for-current-mode ()
  (require 'eglot)
  (heurigraph-test--with-project
      ""
    (let ((server (list 'heurigraph-test-server))
          (eglot-server-programs nil)
          eglot-root)
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "notes/test-0001.typ" root)
              default-directory root
              major-mode 'typst-ts-mode)
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (_name) "/usr/local/bin/heurigraph"))
                  ((symbol-function 'eglot-managed-p) (lambda () nil))
                  ((symbol-function 'eglot-ensure)
                   (lambda () (setq eglot-root
                                    (project-root (project-current)))))
                  ((symbol-function 'eglot-current-server) (lambda () server)))
          (should (heurigraph-lsp-ensure))
          (should (equal (caar eglot-server-programs) 'typst-ts-mode))
          (should (file-equal-p eglot-root root))
          (should-not heurigraph-lsp--server))))))

(ert-deftest heurigraph-lsp-captures-deferred-eglot-connection ()
  (require 'eglot)
  (heurigraph-test--with-project
      ""
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "notes/test-0001.typ" root)
            default-directory root
            major-mode 'typst-ts-mode)
      (let ((server (list 'heurigraph-test-server))
            (command '("/tmp/tinymist")) managed sent)
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "/tmp/heurigraph"))
                  ((symbol-function 'eglot-managed-p) (lambda () managed))
                  ((symbol-function 'eglot-current-server) (lambda () (and managed server)))
                  ((symbol-function 'jsonrpc--process) (lambda (_) 'test-process))
                  ((symbol-function 'processp) (lambda (_) t))
                  ((symbol-function 'process-command) (lambda (_) command))
                  ((symbol-function 'eglot-ensure) #'ignore)
                  ((symbol-function 'jsonrpc-request) (lambda (&rest args) (setq sent args))))
          (should (heurigraph-lsp-ensure))
          (should-not (heurigraph-lsp--active-p))
          (setq managed t)
          (run-hooks 'eglot-managed-mode-hook)
          (should-not (heurigraph-lsp--active-p))
          (should-not (heurigraph-lsp-refresh-if-active))
          (should-not sent)
          (setq command '("/tmp/heurigraph" "lsp"))
          (run-hooks 'eglot-managed-mode-hook)
          (should (heurigraph-lsp--active-p))
          (should (heurigraph-lsp-refresh-if-active))
          (should (eq (car sent) server))
          (should-not (memq #'heurigraph-lsp--remember-server eglot-managed-mode-hook))
          (setq server (list 'another-server))
          (should-not (heurigraph-lsp-refresh-if-active)))))))

(ert-deftest heurigraph-lsp-refresh-targets-eglot-server ()
  (require 'eglot)
  (with-temp-buffer
    (let ((server (list 'heurigraph-test-server)) sent)
      (setq-local heurigraph-lsp--server server)
      (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
                ((symbol-function 'eglot-current-server) (lambda () server))
                ((symbol-function 'jsonrpc-request)
                 (lambda (&rest args) (setq sent args))))
        (should (heurigraph-lsp-refresh-if-active))
        (should (equal sent
                       (list server :workspace/executeCommand
                             '(:command "heurigraph.refresh"
                               :arguments []))))))))

(ert-deftest heurigraph-identities-cannot-be-renamed ()
  (should-not (fboundp 'heurigraph-rename-id))
  (should-not (lookup-key heurigraph-doom-leader-map (kbd "R"))))

(ert-deftest heurigraph-doom-leader-map-exposes-core-commands ()
  (dolist (binding '(("e" . heurigraph-edit)
                     ("g" . heurigraph-generate)
                     ("p" . heurigraph-problems)
                     ("f" . heurigraph-find-node)
                     ("l" . heurigraph-insert-link)
                     ("t" . heurigraph-insert-transclusion)
                     ("r" . heurigraph-insert-assertion)
                     ("L" . heurigraph-lsp-start)))
    (should (eq (lookup-key heurigraph-doom-leader-map (kbd (car binding)))
                (cdr binding))))
  (dolist (key '("n" "N" "c" "j" "W" "i" "M" "Q" "v" "F" "I"))
    (should-not (lookup-key heurigraph-doom-leader-map (kbd key)))))

(ert-deftest heurigraph-education-actions-live-under-the-edit-dispatcher ()
  (should-not (lookup-key heurigraph-note-mode-map (kbd "C-c h H")))
  (should (memq #'heurigraph-insert-assessment-component-data
                (mapcar #'cdr (heurigraph--edit-actions)))))

(ert-deftest heurigraph-weeknote-forwards-manual-iso-year-and-week ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--create-page)
               (lambda (&rest args) (setq captured args))))
      (heurigraph-new-page "weeknote" nil 2026 7)
      (should
       (equal captured
              '("Weeknotes 2026-W07" "weeknote"
                ("--year" "2026" "--week" "7")))))))

(ert-deftest heurigraph-generate-dispatches-without-inferring-output-paths ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args &rest _) (setq captured args) 0)))
      (heurigraph-generate #'heurigraph--generate-graph)
      (should (equal captured '("generate" "graph"))))))

(ert-deftest heurigraph-education-contributes-its-generation-actions ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args &rest _) (setq captured args) 0)))
      (heurigraph-education-generate-manuscript "coursebook")
      (should (equal captured '("generate" "manuscript" "coursebook")))
      (should (memq #'heurigraph-education-generate-assessment
                    (mapcar #'cdr (heurigraph--generate-actions)))))))

(ert-deftest heurigraph-problems-is-the-single-explicit-validation-action ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args &rest _) (setq captured args) 0)))
      (heurigraph-problems)
      (should (equal captured '("check"))))))

(ert-deftest heurigraph-id-at-file-requires-a-complete-uuid ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/abcd1234-0000-4000-8000-000000000001.typ")
    (should (equal (heurigraph--id-at-file) "abcd1234-0000-4000-8000-000000000001"))
    (dolist (file '("/tmp/abcd-1234.typ" "/tmp/mho-0001--old.typ" "/tmp/2026-W07--weeknotes.typ"))
      (setq buffer-file-name file)
      (should-not (heurigraph--id-at-file)))))

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

(ert-deftest heurigraph-insert-diagram-emits-editable-parameters ()
  (with-temp-buffer
    (heurigraph-insert-diagram
     "aaaaaaaa-0001-4000-8000-000000000001" "A dependency graph" "65%" "Graph structure")
    (should
     (equal (buffer-string)
            "#cetz-diagram(\n  \"aaaaaaaa-0001-4000-8000-000000000001\",\n  alt: \"A dependency graph\",\n  width: 65%,\n  caption: \"Graph structure\",\n)"))))

(ert-deftest heurigraph-insert-diagram-omits-an-empty-caption ()
  (with-temp-buffer
    (heurigraph-insert-diagram "aaaaaaaa-0002-4000-8000-000000000002" "Two nodes" "70%" "")
    (should (string-match-p "width: 70%" (buffer-string)))
    (should-not (string-match-p "caption:" (buffer-string)))))

(ert-deftest heurigraph-diagram-completion-only-lists-canonical-cetz-assets ()
  (heurigraph-test--with-project ""
    (let ((directory (expand-file-name "diagrams" root)))
      (make-directory directory t)
      (with-temp-file (expand-file-name "aaaaaaaa-0001-4000-8000-000000000001.typ" directory)
        (insert "// Title: Canonical\n"))
      (with-temp-file (expand-file-name "CETZ-0002.typ" directory)
        (insert "// Title: Uppercase namespace\n"))
      (with-temp-file (expand-file-name "dia-0001.typ" directory)
        (insert "// Title: Old namespace\n"))
      (with-temp-file (expand-file-name "sketch.typ" directory)
        (insert "// Title: Unmanaged\n"))
      (let ((candidates (heurigraph--diagram-candidates)))
        (should (= (length candidates) 1))
        (should (equal (plist-get (cdar candidates) :name) "aaaaaaaa-0001-4000-8000-000000000001"))))))

(ert-deftest heurigraph-insert-image-resolves-a-managed-id-to-its-path ()
  (with-temp-buffer
    (heurigraph-insert-image "bbbbbbbb-000a-4000-8000-000000000001" "images/bbbbbbbb-000a-4000-8000-000000000001.png")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/bbbbbbbb-000a-4000-8000-000000000001.png\", alt: none)"))))

(ert-deftest heurigraph-insert-image-rejects-noncanonical-namespaces ()
  (dolist (asset '(("img-000A" "images/img-000A.png")
                   ("IMGS-000A" "images/IMGS-000A.png")))
    (with-temp-buffer
      (should-error
       (heurigraph-insert-image (car asset) (cadr asset))
       :type 'user-error))))

(ert-deftest heurigraph-insert-image-carries-the-use-site-accessibility-choice ()
  (with-temp-buffer
    (heurigraph-insert-image
     "bbbbbbbb-000a-4000-8000-000000000001" "images/bbbbbbbb-000a-4000-8000-000000000001.png" "A plot crossing at two points")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/bbbbbbbb-000a-4000-8000-000000000001.png\", alt: \"A plot crossing at two points\")")))
  (with-temp-buffer
    (heurigraph-insert-image "bbbbbbbb-000a-4000-8000-000000000001" "images/bbbbbbbb-000a-4000-8000-000000000001.png" "")
    (should
     (equal
      (buffer-string)
      "#image(\"/images/bbbbbbbb-000a-4000-8000-000000000001.png\", alt: \"\")"))))

(ert-deftest heurigraph-import-image-uses-structured-cli-json ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0
                       "{\"id\":\"bbbbbbbb-0001-4000-8000-000000000001\",\"path\":\"images/bbbbbbbb-0001-4000-8000-000000000001.png\",\"extension\":\"png\"}"))))
      (let ((asset (heurigraph-import-image "/tmp/source.png")))
        (should (equal (alist-get 'id asset) "bbbbbbbb-0001-4000-8000-000000000001"))
        (should (equal captured
                       '("import" "image" "add" "/tmp/source.png"
                         "--json")))))))

(ert-deftest heurigraph-doom-setup-installs-spc-e-prefix ()
  (unwind-protect
      (progn
        (setq doom-leader-map (make-sparse-keymap))
        (heurigraph-doom-setup-keybindings)
        (should (eq (lookup-key doom-leader-map (kbd "e e"))
                    #'heurigraph-edit))
        (should (eq (lookup-key doom-leader-map (kbd "e p"))
                    #'heurigraph-problems)))
    (makunbound 'doom-leader-map)))

(ert-deftest heurigraph-reads-project-owned-ontology-completions ()
  (heurigraph-test--with-project
      ""
    (let ((payload
           "{\"version\":\"2.0.0\",\"taxons\":[{\"id\":\"prob:distribution\",\"label\":\"Distribution\",\"description\":\"A probability distribution.\"}],\"subjects\":[],\"predicates\":[{\"id\":\"prob:approximates\",\"label\":\"approximates\",\"external_targets\":false}],\"structures\":[]}"))
      (cl-letf (((symbol-function 'heurigraph--call-output)
                 (lambda (args)
                   (should (equal args '("ontology" "--json")))
                   (cons 0 payload))))
        (let* ((candidates (heurigraph--ontology-candidates 'taxons))
               (item (cdar candidates)))
          (should (equal (alist-get 'id item) "prob:distribution"))
          (should (string-match-p "Distribution" (caar candidates)))
          (should (= (length candidates) 1)))
        (should-not
         (alist-get 'external_targets
                    (car (heurigraph--ontology-items 'predicates))))))))

(ert-deftest heurigraph-ontology-has-one-project-owned-location ()
  (heurigraph-test--with-project
      ""
    (with-temp-file (expand-file-name "heurigraph.toml" root)
      (insert
       "[project]\nname = \"Test\"\n"))
    (should (equal (heurigraph--ontology-root-path)
                   (expand-file-name "ontology" root)))))

(ert-deftest heurigraph-formats-required-assertion-context ()
  (should
   (equal
    (heurigraph--format-assertion
     "edu:has_learning_prerequisite" "mho-0003"
     '(("framework" . "se-lgr22") ("level" . "7-9")))
    (concat
     "#rel(\n"
     "  \"edu:has_learning_prerequisite\",\n"
     "  \"mho-0003\",\n"
     "  framework: \"se-lgr22\",\n"
     "  level: \"7-9\",\n"
     ")"))))

(ert-deftest heurigraph-format-assertion-escapes-external-identities ()
  (should
   (equal (heurigraph--format-assertion "external:\"kind" "urn:\\target" nil)
          "#rel(\"external:\\\"kind\", \"urn:\\\\target\")")))

(ert-deftest heurigraph-reads-required-and-selected-optional-assertion-context ()
  (let (prompts)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _args) '("level")))
              ((symbol-function 'heurigraph--read-assertion-context-value)
               (lambda (field required)
                 (push (cons field required) prompts)
                 (pcase field
                   ("framework" "kogs-0004")
                   ("level" "kogs-0006")))))
      (should
       (equal
        (heurigraph--read-assertion-context
         '((required_context . ("framework"))))
        '(("framework" . "kogs-0004")
          ("level" . "kogs-0006"))))
      (should (equal (nreverse prompts)
                     '(("framework" . t) ("level")))))))

(ert-deftest heurigraph-education-activation-delegates-to-the-core-client ()
  (let (enabled)
    (cl-letf (((symbol-function 'heurigraph-enable-for-typst)
               (lambda () (setq enabled t))))
      (heurigraph-education-enable-for-typst)
      (should enabled))))

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

(ert-deftest heurigraph-ontology-mode-enables-only-for-registry-files ()
  (heurigraph-test--with-project
      ""
    (let* ((ontology (expand-file-name "ontology" root))
           (registry (expand-file-name "subjects/probability.toml" ontology)))
      (make-directory (file-name-directory registry) t)
      (with-temp-file registry (insert "subjects = []\n"))
      (with-temp-buffer
        (setq buffer-file-name registry
              default-directory root)
        (heurigraph-enable-for-ontology)
        (should heurigraph-ontology-mode)))))

(ert-deftest heurigraph-ontology-hook-preserves-fallback-toml-highlighting ()
  (require 'conf-mode)
  (heurigraph-test--with-project
      ""
    (let ((conf-toml-mode-hook '(heurigraph-enable-for-ontology)))
      (dolist (relative '("ontology/subjects/probability.toml"
                          "heurigraph.toml" "unrelated/settings.toml"))
        (let ((file (expand-file-name relative root)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "label = \"Probability\"\n"))
          (with-temp-buffer
            (setq buffer-file-name file default-directory root)
            (insert-file-contents file)
            (conf-toml-mode)
            (font-lock-ensure)
            (should (eq major-mode 'conf-toml-mode))
            (should (eq (get-text-property (point-min) 'face)
                        'font-lock-variable-name-face))
            (should (eq (and heurigraph-ontology-mode t)
                        (string-prefix-p "ontology/" relative)))))))))

(ert-deftest heurigraph-ontology-hook-cold-autoload-defines-supported-entry-point ()
  (heurigraph-test--with-project
      ""
    (let* ((library (file-name-directory (locate-library "heurigraph-mode")))
           (registry (expand-file-name "ontology/subjects/probability.toml" root))
           (form `(progn
                    (autoload 'heurigraph-enable-for-ontology "heurigraph-mode")
                    (require 'conf-mode)
                    (with-temp-buffer
                      (setq buffer-file-name ,registry default-directory ,root)
                      (let ((conf-toml-mode-hook '(heurigraph-enable-for-ontology)))
                        (conf-toml-mode))
                      (unless heurigraph-ontology-mode (error "Ontology hook did not run"))
                      (when (or (fboundp 'heurigraph-enable-for-collection)
                                (fboundp 'heurigraph-lsp-register-lsp-mode))
                        (error "Retired entry points must remain absent"))))))
      (make-directory (file-name-directory registry) t)
      (with-temp-file registry (insert "subjects = []\n"))
      (with-temp-buffer
        (should (zerop
                 (call-process (expand-file-name invocation-name invocation-directory)
                               nil t nil "--batch" "-Q" "-L" library
                               "--eval" (prin1-to-string form))))))))

(provide 'heurigraph-tests)
;;; heurigraph-tests.el ends here
