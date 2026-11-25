;;; mho-vulpea-workflow-tests.el --- Cross-editor contract regressions -*- lexical-binding: t; -*-
(require 'mho-vulpea-para-tests)
(require 'mho-vulpea-journal)
(require 'mho-vulpea-projects)
(require 'mho-vulpea-library)

(defmacro mho-vulpea-workflow-test--vault (&rest body)
  (declare (indent 0))
  `(mho-vulpea-para-test--with-vault
     (let ((vulpea-journal-default-template (vulpea-journal-template-monthly :entry-groups '("week %V")))
           (vulpea-journal-tag "journal"))
       (unwind-protect (progn ,@body)
         (advice-remove 'org-todo #'mho-vulpea-projects--todo)
         (advice-remove 'vulpea-journal-note #'mho-vulpea-journal--resolve)
         (advice-remove 'vulpea-para-archive-project #'mho-vulpea-project-archive)
         (remove-hook 'org-mode-hook #'mho-vulpea-projects-install)))))

(defun mho-vulpea-workflow-test--write (name body)
  "Write an external file without Emacs save hooks or indexing."
  (let ((file (expand-file-name name org-directory)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert body))
    file))

(defun mho-vulpea-workflow-test--journal (name day &optional level)
  (mho-vulpea-workflow-test--write
   name
   (concat ":PROPERTIES:\n:ID: month\n:END:\n#+title: 2026-10\n#+filetags: :journal:\n"
           (if (= (or level 2) 2) "* week 44\n:PROPERTIES:\n:ID: week\n:END:\n" "")
           (make-string (or level 2) ?*) " Custom day\n:PROPERTIES:\n:ID: " day "\n:CREATED: [2026-10-27]\n:END:\n")))

(defun mho-vulpea-workflow-test--resolve (day)
  (mho-vulpea-journal--resolve #'vulpea-journal-note (org-read-date nil t day)))

(ert-deftest mho-vulpea-workflow-resolves-unindexed-monthly-with-custom-title ()
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "phone-day"))
           (before (mho-vulpea-para-test--read file)))
      (should (equal "phone-day" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
      (should (equal before (mho-vulpea-para-test--read file)))
      (should-not (file-exists-p (expand-file-name "journal/2026-10-27.org" org-directory))))))

(ert-deftest mho-vulpea-workflow-preserves-old-daily-and-custom-daily ()
  (dolist (name '("journal/2026-10-27.org" "custom/daily-memory.org"))
    (mho-vulpea-workflow-test--vault
      (let* ((file (mho-vulpea-workflow-test--write name ":PROPERTIES:\n:ID: daily\n:CREATED: [2026-10-27 Tue]\n:END:\n#+title: A remembered day\n#+filetags: :journal:\n* Work\n"))
             (before (mho-vulpea-para-test--read file)))
        (should (equal "daily" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
        (should (equal before (mho-vulpea-para-test--read file)))
        (should-not (file-exists-p (expand-file-name "journal/2026-10.org" org-directory)))))))

(ert-deftest mho-vulpea-workflow-named-journal-keeps-same-day-independent ()
  (mho-vulpea-workflow-test--vault
    (let* ((default-file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "default-day"))
           (default-source (mho-vulpea-para-test--read default-file))
           (work-file (mho-vulpea-workflow-test--write
                       "journal/work-2026-10-27.org"
                       ":PROPERTIES:\n:ID: work-day\n:END:\n#+title: Work notes\n#+filetags: :journal:\n")))
      (should (equal "default-day" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
      (advice-add 'vulpea-journal-note :around #'mho-vulpea-journal--resolve)
      (mho-vulpea-journal-capture-in "work" "reflection" (org-read-date nil t "2026-10-27"))
      (should (bound-and-true-p org-capture-mode))
      (org-capture-finalize)
      (should (string-match-p "What changed today?" (mho-vulpea-para-test--read work-file)))
      (should (equal default-source (mho-vulpea-para-test--read default-file)))
      (let* ((mho-vulpea-journal-prefix "work")
             (note (vulpea-journal-note (org-read-date nil t "2026-10-28"))))
        (should (string-suffix-p "journal/work-2026-10.org" (vulpea-note-path note)))))))

(ert-deftest mho-vulpea-workflow-refuses-duplicate-dates-without-writes ()
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "custom/month.org" "monthly-day"))
           (before (mho-vulpea-para-test--read file)))
      (mho-vulpea-workflow-test--write "journal/2026-10-27.org" ":PROPERTIES:\n:ID: daily\n:END:\n#+title: 2026-10-27\n#+filetags: :journal:\n")
      (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error)
      (should (equal before (mho-vulpea-para-test--read file))))))

(ert-deftest mho-vulpea-workflow-refuses-dirty-or-malformed-journal ()
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "day"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer (goto-char (point-max)) (insert "Unsaved\n"))
      (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (with-temp-file file (insert ":PROPERTIES:\n:ID: month\n:END:\n#+filetags: :journal:\n* day\n:PROPERTIES:\n:ID: broken\n"))
      (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error))))

(ert-deftest mho-vulpea-workflow-keeps-plain-monthly-layout-on-new-day ()
  (mho-vulpea-workflow-test--vault
    (let ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "day" 1)))
      (should (= 1 (vulpea-note-level (mho-vulpea-workflow-test--resolve "2026-10-28"))))
      (let ((source (mho-vulpea-para-test--read file)))
        (should (string-match-p "^\\* 28 Wednesday" source))
        (should (string-match-p "^\\*\\* Tasks" source))
        (should-not (string-match-p "^\\* week" source))))))

(ert-deftest mho-vulpea-workflow-new-day-profile-and-selected-date ()
  (mho-vulpea-workflow-test--vault
    (let* ((note (mho-vulpea-workflow-test--resolve "2027-01-01"))
           (file (vulpea-note-path note)) (source (mho-vulpea-para-test--read file)))
      (should (string-suffix-p "journal/2027-01.org" file))
      (should (= 2 (vulpea-note-level note)))
      (should (string-match-p "^\\* week 53" source))
      (should (string-match-p ":CREATED:.*2027-01-01" source))
      (should (string-match-p "^\\*\\*\\* Tasks" source))
      (should (equal (vulpea-note-id note) (vulpea-note-id (mho-vulpea-workflow-test--resolve "2027-01-01")))))))

(ert-deftest mho-vulpea-workflow-capture-presets-have-private-stable-id ()
  (mho-vulpea-workflow-test--vault
    (advice-add 'vulpea-journal-note :around #'mho-vulpea-journal--resolve)
    (mho-vulpea-journal-capture "reflection" (org-read-date nil t "2026-10-27"))
    (should (bound-and-true-p org-capture-mode))
    (let ((id (org-entry-get nil "ID")))
      (should id)
      (should (member "private" (org-get-tags nil t)))
      (org-capture-finalize)
      (let ((source (mho-vulpea-para-test--read (expand-file-name "journal/2026-10.org" org-directory))))
        (should (string-match-p (regexp-quote id) source))
        (should (string-match-p "What changed today?" source))))))

(defmacro mho-vulpea-workflow-test--project (body &rest forms)
  (declare (indent 1))
  `(mho-vulpea-workflow-test--vault
     (let* ((file (mho-vulpea-workflow-test--write "area.org" ,body))
            (buffer (find-file-noselect file)))
       (with-current-buffer buffer
         (mho-vulpea-projects-install)
         (goto-char (point-min))
         ,@forms))))

(ert-deftest mho-vulpea-workflow-project-child-completion-and-reopen ()
  (mho-vulpea-workflow-test--project
      "* PROJ Project :project:\n:PROPERTIES:\n:ID: project\n:END:\n** TODO Task\n:PROPERTIES:\n:ID: task\n:END:\n"
    (advice-add 'org-todo :around #'mho-vulpea-projects--todo)
    (re-search-forward "^\\*\\* TODO") (beginning-of-line)
    (org-todo "DONE")
    (goto-char (point-min))
    (should (equal "PROJ" (org-get-todo-state)))
    (should (org-entry-get nil "CLOSED"))
    (re-search-forward "^\\*\\* DONE") (beginning-of-line)
    (org-todo "TODO")
    (goto-char (point-min))
    (should-not (org-entry-get nil "CLOSED"))))

(ert-deftest mho-vulpea-workflow-project-cycle-does-not-destroy-role ()
  (dolist (state '("TODO" "DONE"))
    (mho-vulpea-workflow-test--project (concat "* PROJ Project :project:\n** " state " Task\n")
      (advice-add 'org-todo :around #'mho-vulpea-projects--todo)
      (if (equal state "TODO") (should-error (org-todo "DONE") :type 'user-error) (org-todo "DONE"))
      (goto-char (point-min))
      (should (equal "PROJ" (org-get-todo-state)))
      (should (eq (equal state "DONE") (and (org-entry-get nil "CLOSED") t))))))

(ert-deftest mho-vulpea-workflow-source-child-insertion-reopens-on-save ()
  (mho-vulpea-workflow-test--project
      "* PROJ Project\nCLOSED: [2026-10-27 Tue 10:00]\n:PROPERTIES:\n:ID: project\n:END:\n** DONE First\n"
    (goto-char (point-max)) (insert "** TODO New child\n")
    (save-buffer)
    (goto-char (point-min))
    (should-not (org-entry-get nil "CLOSED"))))

(ert-deftest mho-vulpea-workflow-unrelated-save-does-not-stamp-old-project ()
  (mho-vulpea-workflow-test--project
      "* PROJ Project\n:PROPERTIES:\n:ID: project\n:END:\n** DONE First\n* Notes\n"
    (goto-char (point-max)) (insert "Unrelated prose\n") (save-buffer)
    (goto-char (point-min)) (should-not (org-entry-get nil "CLOSED"))))

(ert-deftest mho-vulpea-workflow-project-completion-boundaries ()
  (dolist (body '("* PROJ Empty\n" "* PROJ Parent\n** DONE Work\n** PROJ Empty\n"
                  "* PROJ Parent\n** DONE Work\n** TODO Hidden :ARCHIVE:\n"))
    (mho-vulpea-workflow-test--project body
      (should-not (plist-get (mho-vulpea-project-summary) :complete))
      (should-error (mho-vulpea-project-archive) :type 'user-error))))

(ert-deftest mho-vulpea-workflow-project-ignores-comment-and-literal-tasks ()
  (mho-vulpea-workflow-test--project
      "* PROJ Parent\n#+begin_src org\n** TODO Literal\n#+end_src\n** COMMENT Ignored\n*** TODO Not work\n** DONE Real\n"
    (should (plist-get (mho-vulpea-project-summary) :complete))))

(ert-deftest mho-vulpea-workflow-archive-checks-clocks-and-keeps-proj ()
  (dolist (clock '("CLOCK: [2026-10-27 Tue 10:00]" "CLOCK: broken"))
    (mho-vulpea-workflow-test--project (concat "* PROJ Parent :project:\n** DONE Task\n:LOGBOOK:\n" clock "\n:END:\n")
      (should-error (mho-vulpea-project-archive) :type 'user-error)
      (should-not (member "ARCHIVE" (org-get-tags nil t)))))
  (mho-vulpea-workflow-test--project "* PROJ Parent :project:\n** DONE Task\n"
    (mho-vulpea-project-archive)
    (goto-char (point-min))
    (should (equal "PROJ" (org-get-todo-state)))
    (should (member "ARCHIVE" (org-get-tags nil t)))
    (should (org-entry-get nil "CLOSED"))))

(ert-deftest mho-vulpea-workflow-legacy-project-is-recognized-without-migration ()
  (mho-vulpea-workflow-test--project "* DONE Legacy :project:\n** DONE Task\n"
    (should (mho-vulpea-project-p))
    (should-error (mho-vulpea-project-reconcile) :type 'user-error)
    (should (equal "DONE" (org-get-todo-state)))))

(ert-deftest mho-vulpea-workflow-capture-extraction-keeps-aliases-and-foreign-keys ()
  (let ((org-capture-templates '(("z" "Other" entry (file "other.org") "* %?"))))
    (mho-vulpea-workflow-setup-captures)
    (mho-vulpea-workflow-setup-captures)
    (should (assoc "z" org-capture-templates))
    (should (equal (cdr (assoc "wp" org-capture-templates)) (cdr (assoc "wP" org-capture-templates))))
    (should (= 15 (length org-capture-templates)))))

(ert-deftest mho-vulpea-workflow-missing-exporter-does-not-stop-index-setup ()
  (let ((warned nil))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) (error "missing companion")))
              ((symbol-function 'display-warning) (lambda (&rest _) (setq warned t))))
      (mho-vulpea-workflow-start-exporter "/unused/state/")
      (should warned))))

(ert-deftest mho-vulpea-workflow-new-library-refuses-existing-content ()
  (let ((root (make-temp-file "vulpios-library-test-" t)))
    (unwind-protect
        (let ((target (expand-file-name "new" root)))
          (should (equal target (mho-vulpea-library-initialize target)))
          (should (file-exists-p (expand-file-name ".vulpios/template-profile.json" target)))
          (let ((before (with-temp-buffer (insert-file-contents (expand-file-name "work.org" target)) (buffer-string))))
            (should-error (mho-vulpea-library-initialize target) :type 'user-error)
            (should (equal before (with-temp-buffer (insert-file-contents (expand-file-name "work.org" target)) (buffer-string))))))
      (delete-directory root t))))

(ert-deftest mho-vulpea-workflow-new-library-links-indexed-resource ()
  (mho-vulpea-workflow-test--vault
    (mho-vulpea-library-initialize org-directory)
    (dolist (file (directory-files org-directory t "\\.org\\'"))
      (vulpea-db-update-file file))
    (let ((resources (vulpea-db-query #'vulpea-para-resource-p)))
      ;; Resources are live file-level notes; Work/Home overlap with areas.
      ;; The linked checklist needs no invented classification tag.
      (should (= 3 (length resources)))
      (let* ((resource (seq-find (lambda (note) (equal "Review checklist" (vulpea-note-title note))) resources))
             (id (vulpea-note-id resource)))
        (should (equal "Review checklist" (vulpea-note-title resource)))
        (should (vulpea-para-resource-p resource))
        (should (member "private" (vulpea-note-tags resource)))
        (should-not (member "public" (vulpea-note-tags resource)))
        (dolist (file '("work.org" "home.org"))
          (should (string-match-p
                   (regexp-quote (format "[[id:%s][Review checklist]]" id))
                   (mho-vulpea-para-test--read (expand-file-name file org-directory)))))))))

(ert-deftest mho-vulpea-workflow-canonical-profile-parity ()
  (let ((file (getenv "VULPIOS_TEMPLATE_PROFILE")))
    (skip-unless file)
    (let ((json-object-type 'alist) (json-array-type 'vector) (json-false :json-false))
      (should (equal (json-read-file file) (mho-vulpea-workflow-profile))))))

(ert-deftest mho-vulpea-workflow-journal-ignores-backups-and-literal-days ()
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "day"))
           (before (mho-vulpea-para-test--read file)))
      (copy-file file (concat file "~"))
      (with-temp-file file
        (insert before "\n#+begin_src org\n* Literal example\n:PROPERTIES:\n:ID: literal-day\n:CREATED: [2026-10-27]\n:END:\n#+end_src\n"))
      (let ((source (mho-vulpea-para-test--read file)))
        (should (equal "day" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
        (should (equal source (mho-vulpea-para-test--read file)))))))

(ert-deftest mho-vulpea-workflow-journal-refuses-cross-file-ids-and-invalid-date ()
  (mho-vulpea-workflow-test--vault
    (dolist (date '("2026-10-26" "2026-10-27"))
      (mho-vulpea-workflow-test--write (concat "journal/" date ".org")
                                      (format ":PROPERTIES:\n:ID: duplicate\n:END:\n#+title: %s\n#+filetags: :journal:\n" date)))
    (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error))
  (mho-vulpea-workflow-test--vault
    (mho-vulpea-workflow-test--write "journal/2026-10-27.org"
                                    ":PROPERTIES:\n:ID: bad-date\n:CREATED: [2026-02-30]\n:END:\n#+title: 2026-10-27\n#+filetags: :journal:\n")
    (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error)))

(ert-deftest mho-vulpea-workflow-journal-backdates-between-weeks ()
  (mho-vulpea-workflow-test--vault
    (dolist (date '("2026-10-30" "2026-10-10" "2026-10-20"))
      (mho-vulpea-workflow-test--resolve date))
    (let ((source (mho-vulpea-para-test--read (expand-file-name "journal/2026-10.org" org-directory))))
      (should (< (string-match "^\\* week 44" source) (string-match "^\\* week 43" source)))
      (should (< (string-match "^\\* week 43" source) (string-match "^\\* week 41" source))))))

(ert-deftest mho-vulpea-workflow-journal-stale-db-and-source-change-refuse ()
  (mho-vulpea-workflow-test--vault
    (let* ((note (mho-vulpea-workflow-test--resolve "2026-10-27")) (file (vulpea-note-path note)))
      (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer))
      (delete-file file)
      (should-error (mho-vulpea-workflow-test--resolve "2026-10-28") :type 'user-error)
      (should-not (file-exists-p file))))
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "day"))
           (record (mho-vulpea-journal--source file)))
      (with-temp-file file (insert (plist-get record :source) "External edit\n"))
      (should-error (mho-vulpea-journal--assert-current (list record)) :type 'user-error))))

(ert-deftest mho-vulpea-workflow-journal-refuses-symlink-destination ()
  (mho-vulpea-workflow-test--vault
    (let ((outside (make-temp-file "vulpios-journal-outside-" t)))
      (unwind-protect
          (progn
            (make-symbolic-link outside (expand-file-name "journal" org-directory))
            (should-error (mho-vulpea-workflow-test--resolve "2026-10-27") :type 'user-error)
            (should-not (directory-files outside nil "\\.org\\'")))
        (delete-directory outside t)))))

(ert-deftest mho-vulpea-workflow-malformed-project-source-remains-visitable ()
  (mho-vulpea-workflow-test--vault
    (mho-vulpea-projects-setup)
    (let* ((file (mho-vulpea-workflow-test--write "area.org" "* PROJ Repair source\n#+begin_src org\n"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (should-not mho-vulpea-projects--baseline)
        (goto-char (point-min))
        (should-error (mho-vulpea-project-reconcile) :type 'user-error)))))

(ert-deftest mho-vulpea-workflow-journal-reuses-empty-week-and-refuses-unknown-layout ()
  (mho-vulpea-workflow-test--vault
    (let ((file (mho-vulpea-workflow-test--write "journal/2026-10.org"
                  ":PROPERTIES:\n:ID: month\n:END:\n#+title: 2026-10\n#+filetags: :journal:\n* week 44\n:PROPERTIES:\n:ID: existing-week\n:END:\n")))
      (mho-vulpea-workflow-test--resolve "2026-10-27")
      (with-temp-buffer
        (insert-file-contents file)
        (should (= 1 (how-many "^\\* week 44" (point-min) (point-max)))))))
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "journal/2026-10.org" "day"))
           (source (concat (mho-vulpea-para-test--read file) "* Custom structure\n")))
      (with-temp-file file (insert source))
      (should (equal "day" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
      (should-error (mho-vulpea-workflow-test--resolve "2026-10-28") :type 'user-error)
      (should (equal source (mho-vulpea-para-test--read file))))))

(ert-deftest mho-vulpea-workflow-project-save-keeps-unsafe-user-draft ()
  (mho-vulpea-workflow-test--project
      "* PROJ Existing\n:PROPERTIES:\n:ID: project\n:END:\n** TODO Action\n"
    (goto-char (point-max)) (insert "#+begin_src org\nDraft in progress\n")
    (let ((warning nil))
      (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warning t))))
        (save-buffer))
      (should warning)
      (should (string-match-p "Draft in progress" (mho-vulpea-para-test--read file)))
      (goto-char (point-min)) (should-not (org-entry-get nil "CLOSED")))))

(ert-deftest mho-vulpea-workflow-custom-month-created-is-container-metadata ()
  (mho-vulpea-workflow-test--vault
    (let* ((file (mho-vulpea-workflow-test--journal "custom/month.org" "custom-day"))
           (source (replace-regexp-in-string ":ID: month\n" ":ID: month\n:CREATED: [2026-10-01 Thu]\n"
                                             (mho-vulpea-para-test--read file) t t)))
      (with-temp-file file (insert source))
      (should (equal "custom-day" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27"))))
      (should (equal source (mho-vulpea-para-test--read file)))
      (let ((new-day (mho-vulpea-workflow-test--resolve "2026-10-01")))
        (should (equal (file-truename file) (file-truename (vulpea-note-path new-day))))
        (should-not (equal "month" (vulpea-note-id new-day)))))))

(ert-deftest mho-vulpea-workflow-journal-resolves-configured-root-alias ()
  (mho-vulpea-workflow-test--vault
    (let* ((alias (expand-file-name "library-link" root))
           (physical notes))
      (make-symbolic-link physical alias)
      (let* ((org-directory (file-name-as-directory alias))
             (vulpea-default-notes-directory org-directory)
             (vulpea-db-sync-directories (list org-directory)))
        (mho-vulpea-workflow-test--write "journal/2026-10-26.org"
          ":PROPERTIES:\n:ID: aliased-daily\n:END:\n#+title: 2026-10-26\n#+filetags: :journal:\n")
        (vulpea-db-update-file (expand-file-name "journal/2026-10-26.org" org-directory))
        (should (equal "aliased-daily" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-26"))))
        ;; Preserve identity when a later session changes the configured spelling.
        (let ((org-directory (file-truename physical))
              (vulpea-db-sync-directories (list (file-truename physical))))
          (should (equal "aliased-daily" (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-26")))))
        (let ((day (mho-vulpea-workflow-test--resolve "2026-10-27")))
          (should (equal (vulpea-note-id day) (vulpea-note-id (mho-vulpea-workflow-test--resolve "2026-10-27")))))
        (mho-vulpea-workflow-test--resolve "2026-10-01")
        (should-not (file-exists-p (expand-file-name "journal/2026-10-27.org" org-directory)))))))

(provide 'mho-vulpea-workflow-tests)
