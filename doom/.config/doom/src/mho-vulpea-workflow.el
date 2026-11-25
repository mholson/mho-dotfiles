;;; mho-vulpea-workflow.el --- Shared Org workflow policy -*- lexical-binding: t; -*-

(require 'org)
(require 'cl-lib)
(require 'org-id)
(require 'org-capture)
(require 'json)

(defvar mho/work-file)
(defvar mho/home-file)
(defvar vulpios-export-state-directory)
(declare-function vulpios-export-mode "vulpios-export" (&optional arg))

(defun mho-vulpea-workflow-validate-source ()
  "Refuse incomplete blocks/drawers and duplicate properties/IDs.
Scan structural delimiters before asking Org to interpret a literal example
that may itself contain unescaped heading-shaped text.  Return canonical IDs
and never alter the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) ids)
      (while (< (point) (point-max))
        (cond
         ((looking-at "[ \t]*#\\+begin_\\([[:alnum:]_-]+\\)\\b")
          (let ((kind (match-string-no-properties 1)))
            (unless (re-search-forward (concat "^[ \t]*#\\+end_" (regexp-quote kind) "[ \t]*$") nil t)
              (user-error "Unfinished %s block; review the source" kind))))
         ((looking-at "[ \t]*:PROPERTIES:[ \t]*$")
          (let (keys ended)
            (forward-line 1)
            (while (and (not ended) (< (point) (point-max)))
              (cond
               ((looking-at "[ \t]*:END:[ \t]*$") (setq ended t))
               ((looking-at "[ \t]*:\\([^: \t\n]+\\):[ \t]*\\(.*\\)$")
                (let ((key (upcase (match-string-no-properties 1)))
                      (value (string-trim (match-string-no-properties 2))))
                  (when (member key keys) (user-error "Repeated property %s; review the source" key))
                  (push key keys)
                  (when (equal key "ID")
                    (when (or (string-empty-p value) (member (downcase value) ids))
                      (user-error "Empty or duplicate ID; review the source"))
                    (push (downcase value) ids))))
               (t (user-error "Malformed or unfinished property drawer at line %d" (line-number-at-pos))))
              (unless ended (forward-line 1)))
            (unless ended (user-error "Unfinished property drawer; review the source")))))
        (forward-line 1))
      (nreverse ids))))

(defun mho-vulpea-workflow-literal-ranges ()
  "Locate complete literal blocks without parsing heading-shaped examples."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) ranges)
      (while (re-search-forward "^[ \t]*#\\+begin_\\([[:alnum:]_-]+\\)\\b" nil t)
        (let ((start (line-beginning-position)) (kind (match-string-no-properties 1)))
          (unless (re-search-forward (concat "^[ \t]*#\\+end_" (regexp-quote kind) "[ \t]*$") nil t)
            (user-error "Unfinished %s block; review the source" kind))
          (push (cons start (line-end-position)) ranges)))
      ranges)))

(defun mho-vulpea-workflow-mask-literals ()
  "Mask literal blocks in a temporary parse buffer, preserving positions.
Never call this helper in a visiting source buffer."
  (when buffer-file-name (error "Literal masking requires a temporary buffer"))
  (dolist (range (mho-vulpea-workflow-literal-ranges))
    (let ((masked (replace-regexp-in-string
                   "[^\n]+" (lambda (text) (make-string (length text) ?\s))
                   (buffer-substring-no-properties (car range) (cdr range)) t t)))
      (save-excursion
        (goto-char (car range)) (delete-region (car range) (cdr range))
        (insert masked)))))

(defconst mho-vulpea-workflow-keywords
  '((sequence "TODO(t)" "NEXT(n)" "LIVE(l)" "WAIT(w)" "SOME(s)" "|" "DONE(d)" "XOUT(x)")
    (sequence "PROJ(p)" "|" "DONE(d)" "XOUT(x)"))
  "Recognized vocabulary.  Project commands retain PROJ while reconciling CLOSED.")

(defconst mho-vulpea-workflow-entry-presets
  '(("quickNote" "Quick note" "")
    ("focus" "Focus" "Today's outcome:\n\nNext action (link to an existing task):\n")
    ("reflection" "Reflection" "What changed today?\n\nWhat is worth keeping?\n\nWhat is the next useful adjustment?\n")
    ("weeklyReview" "Weekly review" "Inboxes:\n\nProjects without a next action:\n\nWaiting work:\n\nArea standards:\n\nResources to keep:\n\nProjects ready to archive:\n"))
  "Profile v1 presets, matched to Companion/Templates/para-journal-v1.json.")

(defun mho-vulpea-workflow-profile ()
  "Return the declarative profile v1 as JSON-compatible alists."
  `((schemaVersion . 1)
    (journal . ((fileName . "journal/%Y-%m.org") (group . "week %V")
                (dayTitle . "%d %A") (order . "newest-first") (section . "Tasks")))
    (entryPresets . ,(vconcat
                     (mapcar (lambda (preset)
                               `((id . ,(nth 0 preset)) (title . ,(nth 1 preset))
                                 (body . ,(nth 2 preset)) (isPublic . :json-false)))
                             mho-vulpea-workflow-entry-presets)))))

(defun mho-vulpea-workflow-capture-templates ()
  "Build Work/Home captures, retaining the established key aliases."
  (let ((properties ":PROPERTIES:\n:ID: %(org-id-new)\n:CREATED: %u\n:END:\n"))
    (cl-loop for (key title name) in '(("w" "Work" "work.org") ("h" "Home" "home.org"))
             append
             (cons (list key title)
                   (cl-loop for (suffix heading label state tag tail) in
                            '(("i" "Inbox" "Todo" "TODO" "" "")
                              ("p" "Tasks" "Project" "PROJ" " :project:" "")
                              ("l" "Inbox" "Link" "TODO" " :link:" "Source: %a\n")
                              ("a" "Actions" "Todo" "TODO" "" "")
                              ("P" "Tasks" "Project" "PROJ" " :project:" "")
                              ("m" "Meetings" "Meeting" nil " :meet:" "%?"))
                            collect
                            (list (concat key suffix) (format "%s → %s (%s)" title heading label)
                                  'entry (list 'file+headline (expand-file-name name org-directory) heading)
                                  (if state
                                      (concat "** " state " %?" tag "\n" properties tail)
                                    (concat "** %^{Type|1:1|1:many} %^{Topic}" tag "\nSCHEDULED: %^T\n" properties tail))
                                  :prepend t :empty-lines 1))))))

(defun mho-vulpea-workflow-setup-captures ()
  "Install owned capture keys without removing other capture integrations."
  (setq mho/work-file (expand-file-name "work.org" org-directory)
        mho/home-file (expand-file-name "home.org" org-directory))
  (dolist (entry (mho-vulpea-workflow-capture-templates))
    (setf (alist-get (car entry) org-capture-templates nil nil #'equal) (cdr entry))))

(defun mho-vulpea-workflow-start-exporter (state-directory)
  "Load the optional companion and restore opt-in using STATE-DIRECTORY.
Missing checkout or incompatible APIs produce a warning, never stop indexing.
No publication is enabled or performed merely by loading this module."
  (condition-case err
      (progn
        (require 'vulpios-export
                 (expand-file-name "~/GitHub/vulpios/Companion/Emacs/vulpios-export.el"))
        (setq vulpios-export-state-directory state-directory)
        (when (file-exists-p (expand-file-name "enabled" state-directory))
          (vulpios-export-mode 1)))
    (error (display-warning 'vulpios (error-message-string err) :warning))))

(provide 'mho-vulpea-workflow)
;;; mho-vulpea-workflow.el ends here
