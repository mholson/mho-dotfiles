;;; heurigraph-tests.el --- Tests for Heurigraph Emacs helpers -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'heurigraph)
(require 'heurigraph-lsp)
(require 'heurigraph-mode)

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
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--run)
               (lambda (args)
                 (setq captured args)
                 1)))
      (heurigraph-new "A Concept" "" "math:concept" "math:algebra" "algebra"))
    (should (equal captured
                   '("new" "A Concept"
                     "--taxon" "math:concept"
                     "--subject" "math:algebra"
                     "--keywords" "algebra")))
    (should-not (member "--prefix" captured))))

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
    (insert "#note-meta(id: \"0001\", title: \"Journal\", kind: \"journal\", date: \"2026-07-14\")\n")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
      (heurigraph-toggle-public))
    (should (string-match-p "public: true" (buffer-string)))
    (heurigraph-toggle-public)
    (should (string-match-p "public: false" (buffer-string)))
    (should (string-match-p "title: \"Journal\"" (buffer-string)))
    (should (= (how-many "public:" (point-min) (point-max)) 1))))

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
          (outside (expand-file-name "elsewhere.toml" root)))
      (should (heurigraph-lsp--project-p note 'typst-mode))
      (should (heurigraph-lsp--project-p manifest 'toml-mode))
      (should-not (heurigraph-lsp--project-p outside 'toml-mode)))))

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
              #'heurigraph-insert-diagram)))

(ert-deftest heurigraph-weeknote-forwards-manual-iso-year-and-week ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--create-page)
               (lambda (&rest args) (setq captured args))))
      (heurigraph-new-weeknote 2026 7)
      (should
       (equal captured
              '("Weeknotes 2026-W07" "weeknote" ""
                ("--year" "2026" "--week" "7")))))))

(ert-deftest heurigraph-id-at-file-supports-tree-and-weeknote-ids ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/mho-0001--quadratics.typ")
    (should (equal (heurigraph--id-at-file) "mho-0001"))
    (setq buffer-file-name "/tmp/2026-W07--weeknotes.typ")
    (should (equal (heurigraph--id-at-file) "2026-W07"))))

(ert-deftest heurigraph-next-id-uses-structured-process-call ()
  (let (captured)
    (cl-letf (((symbol-function 'heurigraph--call-output)
               (lambda (args)
                 (setq captured args)
                 (cons 0 "mho-0042\n"))))
      (should (equal (heurigraph-next-id "mho") "Next id: mho-0042"))
      (should (equal captured '("next-id" "mho"))))))

(ert-deftest heurigraph-book-rows-reports-invalid-json ()
  (cl-letf (((symbol-function 'heurigraph--call-output)
             (lambda (_args) (cons 0 "not json"))))
    (should-error (heurigraph--book-rows) :type 'user-error)))

(ert-deftest heurigraph-nodes-reports-invalid-json ()
  (cl-letf (((symbol-function 'heurigraph--call-output)
             (lambda (_args) (cons 0 "not json"))))
    (should-error (heurigraph--nodes) :type 'user-error)))

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
     "dia-0001" "A dependency graph" "65%" "Graph structure")
    (should
     (equal (buffer-string)
            "#cetz-diagram(\n  \"dia-0001\",\n  alt: \"A dependency graph\",\n  width: 65%,\n  caption: \"Graph structure\",\n)"))))

(ert-deftest heurigraph-insert-diagram-omits-an-empty-caption ()
  (with-temp-buffer
    (heurigraph-insert-diagram "dia-0002" "Two nodes" "70%" "")
    (should (string-match-p "width: 70%" (buffer-string)))
    (should-not (string-match-p "caption:" (buffer-string)))))

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

(ert-deftest heurigraph-assertion-target-allows-registered-external-identities ()
  (cl-letf (((symbol-function 'heurigraph--node-candidates)
             (lambda (&optional _kind) nil))
            ((symbol-function 'completing-read)
             (lambda (&rest _args) "Mathlib.Algebra.Group.Basic")))
    (should
     (equal (alist-get 'id
                       (heurigraph--read-assertion-target
                        '((external_targets . t))))
            "Mathlib.Algebra.Group.Basic"))))

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
