;;; mho-vulpios-habit-focus.el --- Pomodoro for Vulpios habits -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-clock)
(require 'org-element)
(require 'org-table)
(require 'org-timer)
(require 'rx)
(require 'seq)
(require 'subr-x)

(cl-defstruct (mho/vulpios-habit-focus (:constructor mho/vulpios-habit--make-focus))
  clock start deadline timer saving)

(defvar mho/vulpios-habit--focus nil
  "The Org clock and Pomodoro currently owned by this Emacs session.")

(defun mho/vulpios-habit--rows (document name)
  (let ((table (org-element-map document 'table
                 (lambda (element)
                   (when (equal (org-element-property :name element) name) element))
                 nil t)))
    (unless table (user-error "The Vulpios habit table %s is missing" name))
    (save-excursion
      (goto-char (org-element-property :post-affiliated table))
      (seq-filter #'consp (cdr (org-table-to-lisp))))))

(defun mho/vulpios-habit--active-plans (now)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (unless (re-search-forward "^# vulpios-habits-v\\([123]\\) begin$" nil t)
        (user-error "No supported Vulpios habits ledger is present"))
      (let ((start (line-beginning-position 2))
            (version (match-string-no-properties 1)))
        (unless (re-search-forward (concat "^# vulpios-habits-v" version " end$") nil t)
          (user-error "The Vulpios habits ledger is incomplete"))
        (narrow-to-region start (line-beginning-position))
        (let* ((document (org-element-parse-buffer))
               (seasons (mho/vulpios-habit--rows document "vulpios-habit-seasons-v1"))
               (plans (mho/vulpios-habit--rows document
                         (if (equal version "1") "vulpios-habit-plans-v1" "vulpios-habit-plans-v2"))))
          (cl-loop for plan in plans
                   for season = (assoc (nth 1 plan) seasons)
                   when (and season (nth 3 season)
                             (string-match-p
                              (rx string-start (= 8 hex) "-" (= 4 hex) "-" (= 4 hex) "-" (= 4 hex) "-" (= 12 hex) string-end)
                              (car plan))
                             (let* ((day (format-time-string "%F" now (nth 3 season)))
                                    (finished (nth 13 plan))
                                    (end (if (string-empty-p (or finished "")) (nth 11 plan) finished)))
                               (and (not (string-lessp day (nth 1 season)))
                                    (string-lessp day (nth 2 season))
                                    (not (string-lessp day (nth 10 plan)))
                                    (string-lessp day end))))
                   collect plan))))))

(defun mho/vulpios-habit--choose (now)
  (let* ((plans (mho/vulpios-habit--active-plans now))
         (choices
          (mapcar (lambda (plan)
                    (let ((name (nth 3 plan)))
                      (cons (if (> (cl-count name plans :key (lambda (row) (nth 3 row)) :test #'equal) 1)
                                (format "%s (slot %s)" name (nth 2 plan))
                              name)
                            plan)))
                  plans)))
    (unless choices (user-error "There are no active habits in this journey"))
    (cdr (assoc (completing-read "Focus on habit: " choices nil t) choices))))

(defun mho/vulpios-habit--visit-heading (plan)
  (let ((id (downcase (car plan))) headings)
    (org-map-entries
     (lambda ()
       (when (equal id (downcase (or (org-entry-get nil "ID") "")))
         (push (point) headings))))
    (when (> (length headings) 1)
      (user-error "The habit’s Org ID is duplicated"))
    (if-let* ((heading (car headings)))
        (progn
          (goto-char heading)
          (unless (and (equal (org-entry-get nil "VULPIOS_HABIT_FOCUS") "t")
                       (not (org-get-todo-state))
                       (not (org-in-archived-heading-p))
                       (not (org-in-commented-heading-p)))
            (user-error "The habit’s focus heading has an unexpected format")))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\n")
      (let ((heading (point)))
        (insert (format "* Focus on “%s”\n:PROPERTIES:\n:ID: %s\n:VULPIOS_HABIT_FOCUS: t\n:END:\n"
                        (nth 3 plan) id))
        (goto-char heading)))))

(defun mho/vulpios-habit--owns-clock-p (focus)
  (and (org-clocking-p)
       (equal (mho/vulpios-habit-focus-clock focus) org-clock-marker)
       (equal (mho/vulpios-habit-focus-start focus) org-clock-start-time)))

(defun mho/vulpios-habit--finish (focus at expired)
  (when (or (mho/vulpios-habit-focus-saving focus)
            (mho/vulpios-habit--owns-clock-p focus))
    (with-current-buffer (marker-buffer (mho/vulpios-habit-focus-clock focus))
      (unless (and (verify-visited-file-modtime (current-buffer))
                   (or (mho/vulpios-habit-focus-saving focus) (not (buffer-modified-p))))
        (user-error "Review the changes in habits.org, then stop the Pomodoro again"))
      (unless (mho/vulpios-habit-focus-saving focus)
        (let ((org-clock-out-switch-to-state nil)
              (org-clock-out-remove-zero-time-clocks nil)
              (org-log-note-clock-out nil))
          (org-clock-out nil nil at))
        (setf (mho/vulpios-habit-focus-saving focus) t))
      (save-buffer)))
  (setq mho/vulpios-habit--focus nil)
  (remove-hook 'org-timer-done-hook #'mho/vulpios-habit--timer-done)
  (when (and (not expired)
             (eq org-timer-countdown-timer (mho/vulpios-habit-focus-timer focus)))
    (org-timer-stop)))

(defun mho/vulpios-habit--timer-done ()
  (when-let* ((focus mho/vulpios-habit--focus))
    (when (eq org-timer-countdown-timer (mho/vulpios-habit-focus-timer focus))
      (condition-case err
          (mho/vulpios-habit--finish focus (mho/vulpios-habit-focus-deadline focus) t)
        (error (message "Habit focus time needs saving — %s" (error-message-string err)))))))

;;;###autoload
(defun mho/vulpios-habit-pomodoro (minutes)
  "Start a Pomodoro on an active habit in the library's habits.org.
Use a numeric prefix to set MINUTES. Work time is a native Org clock."
  (interactive (list (if current-prefix-arg (prefix-numeric-value current-prefix-arg) 25)))
  (unless (and (integerp minutes) (<= 1 minutes 180))
    (user-error "Choose 1–180 minutes of focus"))
  (when (or mho/vulpios-habit--focus (org-clocking-p) org-timer-start-time)
    (user-error "Finish the current Org clock or timer first"))
  (let ((file (expand-file-name "habits.org" org-directory)))
    (unless (file-readable-p file)
      (user-error "Open the shared habits.org from your library before starting focus"))
    (with-current-buffer (find-file-noselect file)
      (when (buffer-modified-p) (user-error "Save your changes to habits.org first"))
      (unless (verify-visited-file-modtime (current-buffer)) (revert-buffer t t))
      (org-with-wide-buffer
       (when (org-element-map (org-element-parse-buffer) 'clock
               (lambda (clock) (eq (org-element-property :status clock) 'running))
               nil t)
         (user-error "An Org clock is already open in habits.org"))
       (let* ((plan (mho/vulpios-habit--choose (current-time)))
              (start (current-time))
              (org-clock-into-drawer "LOGBOOK")
              (org-clock-in-resume nil)
              (org-clock-in-switch-to-state nil))
         (unless (verify-visited-file-modtime (current-buffer))
           (user-error "The habits file changed. Start again to read the latest version"))
         (atomic-change-group
           (mho/vulpios-habit--visit-heading plan)
           (unless (equal (org-clock-into-drawer) "LOGBOOK")
             (user-error "The habit heading must use the LOGBOOK drawer"))
           (org-clock-in nil start))
         (save-buffer)
         (org-timer-set-timer minutes)
         (setq mho/vulpios-habit--focus
               (mho/vulpios-habit--make-focus
                :clock (copy-marker org-clock-marker)
                :start org-clock-start-time
                :deadline (time-add start (* minutes 60))
                :timer org-timer-countdown-timer))
         (add-hook 'org-timer-done-hook #'mho/vulpios-habit--timer-done))))))

;;;###autoload
(defun mho/vulpios-habit-stop ()
  "Stop the habit Pomodoro and save the elapsed work to habits.org."
  (interactive)
  (unless mho/vulpios-habit--focus (user-error "No habit Pomodoro is running"))
  (let* ((focus mho/vulpios-habit--focus)
         (deadline (mho/vulpios-habit-focus-deadline focus))
         (now (current-time)))
    (mho/vulpios-habit--finish focus (if (time-less-p now deadline) now deadline) nil)))

;;;###autoload
(defun mho/vulpios-habit-break (minutes)
  "Start an unlogged Org countdown for MINUTES of break time."
  (interactive (list (if current-prefix-arg (prefix-numeric-value current-prefix-arg) 5)))
  (unless (and (integerp minutes) (<= 1 minutes 60))
    (user-error "Choose 1–60 minutes of break time"))
  (when (or mho/vulpios-habit--focus (org-clocking-p) org-timer-start-time)
    (user-error "Finish the current Org clock or timer first"))
  (org-timer-set-timer minutes))

(provide 'mho-vulpios-habit-focus)
;;; mho-vulpios-habit-focus.el ends here
