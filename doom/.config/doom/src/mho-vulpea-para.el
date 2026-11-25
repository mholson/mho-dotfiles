;;; mho-vulpea-para.el --- PARA for Mark's Vulpea library -*- lexical-binding: t; -*-

;;; Commentary:
;; Preserve the existing agenda and task vocabulary while using PARA's
;; database-backed selection, capture targets, refiling, and archiving.

;;; Code:
(require 'vulpea-para)
(require 'subr-x)

(defun mho-vulpea-para--area-body (file-name)
  "Build an area skeleton, including capture targets for FILE-NAME.
Structural headings get IDs so database-backed refiling can offer them."
  (mapconcat
   (lambda (heading)
     (format "* %s%s\n:PROPERTIES:\n:ID: %s\n:END:\n"
             heading
             (cond ((equal heading "Archive") " :ARCHIVE:")
                   ((equal heading "Inbox") " :inbox:")
                   (t ""))
             (org-id-new)))
   (if (member file-name '("work.org" "home.org"))
       '("Notes" "Inbox" "Tasks" "Actions" "Meetings" "Archive")
     '("Notes" "Tasks" "Archive"))
   "\n"))

(defun mho-vulpea-para-capture-area (title &optional file-name)
  "Create and visit a private area named TITLE.
Optional FILE-NAME supports the existing work.org and home.org captures."
  (interactive (list (read-string "Area: ")))
  (setq title (string-trim title))
  (when (string-empty-p title) (user-error "Area name cannot be empty"))
  (when (and file-name
             (file-exists-p (expand-file-name file-name vulpea-default-notes-directory)))
    (user-error "Area file already exists: %s" file-name))
  (let ((note (vulpea-create
               title (or file-name vulpea-para-capture-area-file-name)
               :tags (list vulpea-para-area-tag "private")
               :body (mho-vulpea-para--area-body file-name))))
    (vulpea-visit note)
    note))

(defun mho-vulpea-para-project-template ()
  "Use PARA's project target and metadata with the existing PROJ state."
  (replace-regexp-in-string
   "\\`\\* TODO " "* PROJ "
   (vulpea-para-capture-project-template) t t))

(defun mho-vulpea-para-capture-project ()
  "Capture a PROJ heading under a selected area's Tasks heading."
  (interactive)
  (org-capture nil "p"))

(defun mho-vulpea-para-refile-note-p (note)
  "Keep NOTE as a task destination unless it is marked public."
  (not (vulpea-note-tagged-any-p note "public")))

(defun mho-vulpea-para--pinned-file-p ()
  "Apply the documented open-work file policy without a private PARA API."
  (when buffer-file-name
    (let ((path (expand-file-name buffer-file-name)))
      (seq-some (lambda (entry)
                  (cond ((functionp entry) (funcall entry path))
                        ((file-name-absolute-p entry) (equal (expand-file-name entry) path))
                        (t (equal entry (file-name-nondirectory path)))))
                vulpea-para-open-work-files))))

(defun mho-vulpea-para--update-agenda-tag ()
  "Use PARA's public updater and documented scope for already-open buffers."
  (when (and vulpea-para-agenda-mode (funcall vulpea-para-agenda-tag-scope))
    (vulpea-para-update-agenda-tag)))

(defun mho-vulpea-para--open-work-p ()
  "Detect live work without counting archived or commented subtrees.
The pinned PARA version counts unfinished tasks inside archives.  Keep
its task, tag, and timestamp rules, but match Org's active agenda scope."
  (or
   (mho-vulpea-para--pinned-file-p)
   (org-with-wide-buffer
    (org-element-map (org-element-parse-buffer 'headline) 'headline
      (lambda (heading)
        (save-excursion
          (goto-char (org-element-property :begin heading))
          (unless (or (org-in-archived-heading-p)
                      (org-in-commented-heading-p)
                      (org-entry-get nil "ARCHIVE_TIME" 'inherit))
            (let ((state (org-element-property :todo-type heading)))
              (or (eq state 'todo)
                  (seq-intersection (org-element-property :tags heading)
                                    vulpea-para-open-work-tags)
                  (and (not (eq state 'done))
                       (org-element-property :contents-begin heading)
                       (let ((end (org-entry-end-position)))
                         (goto-char (org-element-property :contents-begin heading))
                         (re-search-forward org-ts-regexp end t))))))))
      nil 'first-match))))

(defun mho-vulpea-para-setup ()
  "Connect PARA to the existing captures and Strategic Overview."
  ;; A task beneath a project must not itself become a PARA project.
  (add-to-list 'org-tags-exclude-from-inheritance "project")
  (setq vulpea-para-capture-area-file-name "${id}--${slug}.org"
        vulpea-para-agenda-main-key "o"
        vulpea-para-done-keywords '("DONE" "XOUT")
        vulpea-para-open-work-files
        (mapcar (lambda (name) (expand-file-name name org-directory))
                '("work.org" "home.org"))
        vulpea-para-refile-files-filter #'mho-vulpea-para-refile-note-p
        org-refile-targets '((vulpea-para-refile-files :maxlevel . 3))
        org-refile-use-outline-path 'title
        org-outline-path-complete-in-steps nil
        org-refile-allow-creating-parent-nodes 'confirm
        org-refile-target-verify-function #'vulpea-para-refile-verify-target
        org-agenda-prefix-format
        '((agenda . " %(vulpea-para-agenda-category 36) %?-12t %12s")
          (todo . " %(vulpea-para-agenda-category 36) ")
          (tags . " %(vulpea-para-agenda-category 36) ")
          (search . " %(vulpea-para-agenda-category 36) ")))
  ;; Re-evaluation updates our one entry without duplicating other captures.
  (setf (alist-get "p" org-capture-templates nil nil #'equal)
        '("PARA project" entry
          (function vulpea-para-capture-project-target)
          (function mho-vulpea-para-project-template)
          :empty-lines 1 :jump-to-captured t))
  (advice-add 'vulpea-para-buffer-open-work-p :override #'mho-vulpea-para--open-work-p)
  (vulpea-para-agenda-mode 1)
  ;; Re-evaluating this setup should also cover notes already being edited.
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (add-hook 'before-save-hook #'mho-vulpea-para--update-agenda-tag nil t))))
  (vulpea-para-refile-mode 1))

(provide 'mho-vulpea-para)
;;; mho-vulpea-para.el ends here
