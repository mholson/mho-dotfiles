;;; mho-vulpea-projects.el --- Guarded PROJ lifecycle -*- lexical-binding: t; -*-

(require 'org)
(require 'org-element)
(require 'org-clock)
(require 'vulpea-para)
(require 'cl-lib)
(require 'mho-vulpea-workflow)

(defvar mho-vulpea-projects--changing nil)
(defvar-local mho-vulpea-projects--baseline nil)

(defalias 'mho-vulpea-projects--literal-ranges #'mho-vulpea-workflow-literal-ranges)

(defun mho-vulpea-projects--literal-p (position ranges)
  (seq-some (lambda (range) (and (<= (car range) position) (< position (cdr range)))) ranges))

(defun mho-vulpea-projects--subtree-end (ranges)
  "Find the next real sibling, excluding heading-shaped block examples."
  (save-excursion
    (let ((level (org-outline-level)) end)
      (forward-line 1)
      (while (and (null end) (re-search-forward org-heading-regexp nil t))
        (beginning-of-line)
        (unless (mho-vulpea-projects--literal-p (point) ranges)
          (when (<= (org-outline-level) level) (setq end (point))))
        (forward-line 1))
      (or end (point-max)))))

(defun mho-vulpea-projects--in-library-p ()
  "Whether this buffer belongs to the configured local Org library."
  (and buffer-file-name (not (file-remote-p buffer-file-name))
       (file-in-directory-p buffer-file-name org-directory)))

(defun mho-vulpea-project-p ()
  "Recognize a current or legacy project at point without converting it."
  (and (org-at-heading-p)
       (or (equal (org-get-todo-state) "PROJ") (member "project" (org-get-tags nil t)))))

(defun mho-vulpea-projects--check-file ()
  "Refuse custom task declarations and ambiguous source before lifecycle writes."
  (mho-vulpea-workflow-validate-source)
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) (ranges (mho-vulpea-projects--literal-ranges)))
      (while (re-search-forward "^#\\+\\(?:TODO\\|SEQ_TODO\\|TYP_TODO\\):" nil t)
        (unless (mho-vulpea-projects--literal-p (point) ranges)
          (user-error "Project lifecycle does not support a custom file workflow"))))))

(defun mho-vulpea-project-summary ()
  "Return source-verified completion at the PROJ heading at point.
Count archived unfinished descendants as unfinished, exclude COMMENT and
literal examples, and keep empty/nested-empty projects incomplete."
  (org-back-to-heading t)
  (unless (equal (org-get-todo-state) "PROJ")
    (user-error "Legacy tagged projects remain readable; use a PROJ container for lifecycle commands"))
  (mho-vulpea-projects--check-file)
  (let* ((start (point))
         (literal-ranges (mho-vulpea-projects--literal-ranges))
         (end (mho-vulpea-projects--subtree-end literal-ranges))
         (root-level (org-outline-level))
         (archived (or (org-in-archived-heading-p) (org-in-commented-heading-p)
                       (org-entry-get nil "ARCHIVE_TIME" 'inherit)))
         (total 0) (done 0) (incomplete 0) (unsafe-clock nil)
         project-stack)
    (save-excursion
      (forward-line 1)
      (while (re-search-forward org-heading-regexp end t)
        (beginning-of-line)
        (let ((level (org-outline-level)) (state (org-get-todo-state)))
          (while (and (not (mho-vulpea-projects--literal-p (point) literal-ranges))
                      project-stack (>= (caar project-stack) level))
            (let ((project (pop project-stack)))
              (unless (and (> (- total (nth 1 project)) 0)
                           (= (- total (nth 1 project)) (- done (nth 2 project)))
                           (= incomplete (nth 3 project)))
                (cl-incf incomplete))))
          (unless (or (org-in-commented-heading-p) (mho-vulpea-projects--literal-p (point) literal-ranges)
                      (memq (org-element-type (org-element-context)) '(example-block comment-block)))
            (cond ((equal state "PROJ") (push (list level total done incomplete) project-stack))
                  ((member state '("TODO" "NEXT" "LIVE" "WAIT" "SOME" "DONE" "XOUT"))
                   (cl-incf total)
                   (when (member state '("DONE" "XOUT")) (cl-incf done))))))
        (forward-line 1))
      (while project-stack
        (let ((project (pop project-stack)))
          (unless (and (> (- total (nth 1 project)) 0)
                       (= (- total (nth 1 project)) (- done (nth 2 project)))
                       (= incomplete (nth 3 project)))
            (cl-incf incomplete))))
      (goto-char start)
      (while (re-search-forward "^[ \t]*CLOCK:[ \t]*\\(.*\\)$" end t)
        (unless (or (mho-vulpea-projects--literal-p (point) literal-ranges)
                    (memq (org-element-type (org-element-context)) '(example-block comment-block)))
          (let ((clock (match-string-no-properties 1)))
            (unless (and (string-match "\\`\\(\\[[^]\n]+\\]\\)--\\(\\[[^]\n]+\\]\\)\\(?:[ \t]*=>[ \t]*[0-9]+:[0-9][0-9]\\)?[ \t]*\\'" clock)
                         (condition-case nil
                             (not (time-less-p (org-time-string-to-time (match-string 2 clock))
                                               (org-time-string-to-time (match-string 1 clock))))
                           (error nil)))
              (setq unsafe-clock t))))))
    (when (and (markerp org-clock-marker) (eq (marker-buffer org-clock-marker) (current-buffer))
               (<= start org-clock-marker) (< org-clock-marker end))
      (setq unsafe-clock t))
    (list :total total :done done :incomplete-projects incomplete :archived archived
          :unsafe-clock unsafe-clock :level root-level
          :complete (and (> total 0) (= total done) (= incomplete 0)))))

(defun mho-vulpea-project-reconcile ()
  "Keep PROJ and reconcile CLOSED from its current descendants.
This command is explicit; normal saves reconcile only changed projects."
  (interactive)
  (save-excursion
    (org-back-to-heading t)
    (let ((summary (mho-vulpea-project-summary)))
      (when (plist-get summary :archived) (user-error "Archived/commented projects are not active lifecycle targets"))
      (if (plist-get summary :complete)
          (unless (org-entry-get nil "CLOSED")
            (org-add-planning-info 'closed (format-time-string "[%Y-%m-%d %a %H:%M]")))
        (when (org-entry-get nil "CLOSED") (org-add-planning-info nil nil 'closed)))
      summary)))

(defun mho-vulpea-projects--ancestors ()
  "Return markers for the enclosing PROJ headings, including point."
  (save-excursion
    (org-back-to-heading t)
    (let (markers)
      (when (equal (org-get-todo-state) "PROJ") (push (point-marker) markers))
      (while (org-up-heading-safe)
        (when (equal (org-get-todo-state) "PROJ") (push (point-marker) markers)))
      (nreverse markers))))

(defun mho-vulpea-projects--todo (original &rest args)
  "Keep project type stable across ORIGINAL and reconcile affected ancestors."
  (if (or mho-vulpea-projects--changing (not (derived-mode-p 'org-mode))
          (not (mho-vulpea-projects--in-library-p)) (org-before-first-heading-p))
      (apply original args)
    (let ((markers (mho-vulpea-projects--ancestors))
          (project (equal (org-get-todo-state) "PROJ"))
          (mho-vulpea-projects--changing t))
      (unwind-protect
          (atomic-change-group
            (prog1 (let ((org-inhibit-logging (or project org-inhibit-logging)))
                     (apply original args))
              (when project
                (unless (equal (org-get-todo-state) "PROJ")
                  (let ((org-inhibit-logging t)) (funcall original "PROJ")))
                (unless (plist-get (mho-vulpea-project-summary) :complete)
                  (user-error "A project completes when every child task completes; PROJ is retained")))
              (dolist (marker markers)
                (save-excursion (goto-char marker) (mho-vulpea-project-reconcile)))))
        (mapc (lambda (marker) (set-marker marker nil)) markers)))))

(defun mho-vulpea-projects--snapshots ()
  "Return ID-keyed descendant signatures, without writing source."
  (org-with-wide-buffer
   (save-excursion
     (goto-char (point-min))
     (let ((literal-ranges (mho-vulpea-projects--literal-ranges)) result)
       (while (re-search-forward org-heading-regexp nil t)
         (beginning-of-line)
         (when (and (equal (org-get-todo-state) "PROJ") (not (mho-vulpea-projects--literal-p (point) literal-ranges))
                    (not (org-in-archived-heading-p)) (not (org-in-commented-heading-p)))
           (when-let* ((id (org-entry-get nil "ID")))
             (let ((start (point)) (end (mho-vulpea-projects--subtree-end literal-ranges)) children)
               (save-excursion
                 (forward-line 1)
                 (while (re-search-forward org-heading-regexp end t)
                   (beginning-of-line)
                   (unless (mho-vulpea-projects--literal-p (point) literal-ranges)
                     (push (list (org-outline-level) (org-get-todo-state) (org-entry-get nil "ID")
                                 (and (org-in-commented-heading-p) t)) children))
                   (forward-line 1)))
               (push (list id children start) result))))
         (forward-line 1))
       result))))

(defun mho-vulpea-projects--remember ()
  "Record a baseline after visiting/saving; never complete historical work."
  (when (mho-vulpea-projects--in-library-p)
    (setq mho-vulpea-projects--baseline
          (condition-case nil (mho-vulpea-projects--snapshots)
            ;; Visiting malformed historical source must remain possible.
            ;; Explicit lifecycle commands still refuse an unsafe edit.
            (user-error nil)))))

(defun mho-vulpea-projects--before-save ()
  "Reconcile changed projects when safe, keeping source editable."
  (when (and (mho-vulpea-projects--in-library-p) mho-vulpea-projects--baseline)
    (condition-case err
        (let ((current (mho-vulpea-projects--snapshots)))
          (atomic-change-group
            ;; Bottom-to-top keeps positions valid as planning lines change.
            (dolist (project current)
              (when-let* ((old (assoc (car project) mho-vulpea-projects--baseline)))
                (unless (equal (nth 1 old) (nth 1 project))
                  (save-excursion (goto-char (nth 2 project)) (mho-vulpea-project-reconcile)))))))
      (user-error
       (display-warning 'vulpios
                        (concat "Project lifecycle was not reconciled: " (error-message-string err))
                        :warning)))))

(defun mho-vulpea-projects-install ()
  "Install buffer-local lifecycle hooks with a nonmutating baseline."
  (when (and (derived-mode-p 'org-mode) (mho-vulpea-projects--in-library-p))
    (add-hook 'before-save-hook #'mho-vulpea-projects--before-save nil t)
    (add-hook 'after-save-hook #'mho-vulpea-projects--remember nil t)
    (mho-vulpea-projects--remember)))

(defun mho-vulpea-project-archive (&optional note)
  "Archive NOTE (or the project at point) in place after source checks.
No subtree is moved; IDs, descendants, history and PROJ survive."
  (interactive (list (vulpea-select-from "Project" (vulpea-para-projects) :require-match t)))
  (let ((buffer (if note (find-file-noselect (vulpea-note-path note)) (current-buffer))))
    (with-current-buffer buffer
      (unless (verify-visited-file-modtime buffer) (user-error "Project file changed outside Emacs; revert/reconcile first"))
      (save-excursion
        (when note
          (goto-char (point-min))
          (unless (org-find-entry-with-id (vulpea-note-id note)) (user-error "Project ID no longer exists"))
          (goto-char (org-find-entry-with-id (vulpea-note-id note))))
        (org-back-to-heading t)
        (atomic-change-group
          (let ((summary (mho-vulpea-project-summary)))
            (when (plist-get summary :archived) (user-error "Project is already archived or commented"))
            (unless (plist-get summary :complete) (user-error "Complete every child task before archiving this project"))
            (when (plist-get summary :unsafe-clock) (user-error "Close or repair every clock before archiving this project"))
            (mho-vulpea-project-reconcile)
            (org-set-tags (append (org-get-tags nil t) '("ARCHIVE")))))
        (save-buffer)))))

(defun mho-vulpea-projects-setup ()
  "Enable guarded commands without rewriting any existing source."
  (advice-add 'org-todo :around #'mho-vulpea-projects--todo)
  (advice-add 'vulpea-para-archive-project :override #'mho-vulpea-project-archive)
  (add-hook 'org-mode-hook #'mho-vulpea-projects-install)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer (mho-vulpea-projects-install))))

(provide 'mho-vulpea-projects)
;;; mho-vulpea-projects.el ends here
