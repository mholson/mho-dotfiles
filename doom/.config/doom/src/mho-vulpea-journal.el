;;; mho-vulpea-journal.el --- Source-verified cross-editor journals -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-element)
(require 'vulpea-journal)
(require 'vulpea-db-extract)
(require 'mho-vulpea-workflow)

(defvar mho-vulpea-journal-prefix nil
  "Filename prefix of the selected additional journal, or nil for the default.")

(defun mho-vulpea-journal--valid-prefix-p (prefix)
  "Return non-nil if PREFIX can be used in a shared journal filename."
  (let ((case-fold-search nil))
    (and (stringp prefix) (<= (string-bytes prefix) 240)
         (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" prefix))))

(defun mho-vulpea-journal--date-key (value)
  "Return the valid ISO date at the start of VALUE, or nil."
  (when (and (stringp value)
             (string-match "\\`[<[]?\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[] >]\\|\\'\\)" value))
    (let* ((key (format "%s-%s-%s" (match-string 1 value) (match-string 2 value) (match-string 3 value)))
           (date (encode-time 0 0 12 (string-to-number (match-string 3 value))
                              (string-to-number (match-string 2 value))
                              (string-to-number (match-string 1 value)))))
      (when (equal key (format-time-string "%Y-%m-%d" date)) key))))

(defun mho-vulpea-journal--files (directory)
  "List ordinary Org files under DIRECTORY without hidden or symlink traversal.
This read-only discovery runs only for an explicit journal command.  It avoids
assuming the asynchronous Vulpea index has already seen another device's file."
  (cl-loop for file in (directory-files directory t directory-files-no-dot-files-regexp)
           unless (string-prefix-p "." (file-name-nondirectory file))
           append (cond ((file-symlink-p file) nil)
                        ((file-directory-p file) (mho-vulpea-journal--files file))
                        ((and (file-regular-p file) (string-suffix-p ".org" (downcase file))) (list file)))))

(defun mho-vulpea-journal--named-file (file root)
  "Return (PREFIX . DATE) for a dated additional journal file under ROOT."
  (let ((relative (file-relative-name file root))
        (case-fold-search nil))
    (when (string-prefix-p "journal/" relative)
      (let ((basename (downcase (substring relative (length "journal/")))))
        (when (string-match "\\`\\([a-z0-9-]+\\)-\\([0-9]\\{4\\}-[0-9]\\{2\\}\\(?:-[0-9]\\{2\\}\\)?\\)\\.org\\'" basename)
          (let* ((prefix (match-string 1 basename))
                 (date (match-string 2 basename))
                 (day (if (= 7 (length date)) (concat date "-01") date)))
            (when (and (mho-vulpea-journal--valid-prefix-p prefix)
                       (not (string-prefix-p "0000-" day))
                       (mho-vulpea-journal--date-key day))
              (cons prefix date))))))))

(defun mho-vulpea-journal--keyword (key)
  "Return the first file-level KEY before any heading."
  (save-excursion
    (goto-char (point-min))
    (let ((end (save-excursion (if (re-search-forward org-heading-regexp nil t) (line-beginning-position) (point-max))))
          (case-fold-search t))
      (when (re-search-forward (concat "^#\\+" (regexp-quote key) ":[ \t]*\\(.*\\)$") end t)
        (string-trim (match-string-no-properties 1))))))

(defun mho-vulpea-journal--validate-source ()
  "Refuse incomplete drawers/blocks and ambiguous IDs in the current source."
  (mho-vulpea-workflow-validate-source)
  (mho-vulpea-workflow-mask-literals)
  (org-element-parse-buffer))

(defun mho-vulpea-journal--source (file)
  "Read FILE's journal identity from saved source, never from stale DB fields."
  (let ((org-mode-hook nil) (enable-local-variables nil) (enable-local-eval nil))
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((source (buffer-string))
             (buffer (find-buffer-visiting file))
             (root (file-truename org-directory))
             (journal-path (string-prefix-p "journal/" (file-relative-name file root))))
        (org-mode)
        (let* ((tags (split-string (or (mho-vulpea-journal--keyword "filetags") "") "[: \t]" t))
               (title (mho-vulpea-journal--keyword "title"))
               (base (or (cdr (mho-vulpea-journal--named-file file root)) (file-name-base file)))
               (monthly-name (and (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}\\'" base) base)))
          (when (and buffer (buffer-modified-p buffer)
                     (or journal-path (member "journal" tags)
                         (with-current-buffer buffer
                           (save-excursion (goto-char (point-min))
                             (re-search-forward "^#\\+filetags:.*:journal:" nil t)))))
            (user-error "Save or discard the open journal buffer first: %s" file))
          (when (or journal-path (member "journal" tags))
            (unless (member "journal" tags)
              (user-error "Journal file lacks its journal tag; review %s" file))
            (let* ((ids (mho-vulpea-workflow-validate-source))
                   (tree (mho-vulpea-journal--validate-source))
                   (file-id (org-entry-get (point-min) "ID"))
                   (file-created (org-entry-get (point-min) "CREATED"))
                   (month (or monthly-name
                              (and title (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}\\'" title) title)))
                   (file-day (or (mho-vulpea-journal--date-key base)
                                 (and (null month) (mho-vulpea-journal--date-key file-created))))
                   days dated-stack levels)
              (unless file-id (user-error "Journal file has no ID; review %s" file))
              (when (and file-created (not (mho-vulpea-journal--date-key file-created)))
                (user-error "Invalid file CREATED in %s" file))
              (when file-day
                (push (list :id file-id :date file-day :level 0 :position 1) days))
              (unless file-day
                (org-element-map tree 'headline
                  (lambda (heading)
                    (let* ((position (org-element-property :begin heading))
                           (level (org-element-property :level heading))
                           (title (org-element-property :raw-value heading)))
                      (while (and dated-stack (>= (caar dated-stack) level)) (pop dated-stack))
                      (goto-char position)
                      (unless (or (org-in-commented-heading-p) (org-in-archived-heading-p)
                                  (org-entry-get nil "ARCHIVE_TIME" 'inherit))
                        (let* ((created (org-entry-get nil "CREATED"))
                               (key (or (mho-vulpea-journal--date-key created)
                                        (and (null created) month
                                             (string-match "\\`\\([0-9]\\{1,2\\}\\) +" title)
                                             (mho-vulpea-journal--date-key
                                              (format "%s-%02d" month (string-to-number (match-string 1 title))))))))
                          (when (and created (not (mho-vulpea-journal--date-key created)))
                            (user-error "Invalid CREATED at %s:%d" file (line-number-at-pos)))
                          (when (and key (null dated-stack))
                            (let ((id (org-entry-get nil "ID")))
                              (unless id (user-error "Journal day has no ID at %s:%d" file (line-number-at-pos)))
                              (push (list :id id :date key :level level :position position) days)
                              (push level levels)
                              (push (cons level key) dated-stack)))))))))
              (when (and (null month) days)
                (let ((months (delete-dups (mapcar (lambda (day) (substring (plist-get day :date) 0 7)) days))))
                  (when (= 1 (length months)) (setq month (car months)))))
              (list :file file :source source :id file-id :ids ids :tags tags :month month
                    :days (nreverse days) :levels (delete-dups levels) :daily file-day))))))))

(defun mho-vulpea-journal--assert-current (records)
  "Refuse if any journal source in RECORDS changed during resolution."
  (dolist (record records)
    (let ((file (plist-get record :file)))
      (unless (and (file-exists-p file)
                   (equal (plist-get record :source)
                          (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (user-error "Journal changed while resolving the date; retry: %s" file))
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (when (or (buffer-modified-p) (not (verify-visited-file-modtime buffer)))
            (user-error "Journal buffer is modified or stale; revert/save it first: %s" file)))))))

(defun mho-vulpea-journal--notes-in-file (file &optional level)
  "Query FILE through public APIs across canonical/configured path spellings.
Vulpea revisions may store a configured root alias instead of its truename,
including macOS /var versus /private/var. All candidates name the same file."
  (let* ((physical (file-truename file))
         (logical (expand-file-name (file-relative-name physical (file-truename org-directory))
                                    (expand-file-name org-directory)))
         (paths (delete-dups (list file physical logical (abbreviate-file-name physical)
                                   (abbreviate-file-name logical))))
         notes)
    (dolist (path paths)
      (setq notes (append notes (vulpea-db-query-by-file-path path level))))
    ;; A database may predate the current root spelling. Resolve those rows by
    ;; physical identity only when its current spellings produced no candidates.
    (unless notes
      (setq notes (seq-filter (lambda (note)
                                (and (equal physical (file-truename (vulpea-note-path note)))
                                     (or (null level) (= level (vulpea-note-level note)))))
                              (vulpea-db-query))))
    (cl-delete-duplicates notes :key #'vulpea-note-id :test #'equal)))

(defun mho-vulpea-journal--index-file (record)
  "Refresh RECORD through the stored root spelling when it is the same file."
  (let* ((file (plist-get record :file))
         (known (vulpea-db-get-by-id (plist-get record :id)))
         (stored (and known (vulpea-note-path known))))
    (vulpea-db-update-file
     (if (and stored (equal (file-truename file) (file-truename stored))) stored file))))

(defun mho-vulpea-journal--indexed-day (record day)
  "Refresh RECORD and return DAY's verified public Vulpea note."
  (mho-vulpea-journal--index-file record)
  (let ((note (vulpea-db-get-by-id (plist-get day :id))))
    (unless (and note
                 (equal (file-truename (plist-get record :file)) (file-truename (vulpea-note-path note)))
                 (= (plist-get day :level) (vulpea-note-level note)))
      (user-error "Journal day could not be indexed; inspect its ID and tags"))
    note))

(defun mho-vulpea-journal--check-layout (record grouped)
  "Validate RECORD before adding a day; return its recognized week groups.
Existing dates remain readable in custom structures. New dates are added only
when every top-level section has a known daily or ISO-week role."
  (let ((file (plist-get record :file)) (month (plist-get record :month))
        (days (plist-get record :days)) (org-mode-hook nil) groups names)
    (with-temp-buffer
      (insert (plist-get record :source)) (org-mode)
      (mho-vulpea-workflow-mask-literals)
      (goto-char (point-min))
      (while (re-search-forward "^\\* " nil t)
        (beginning-of-line)
        (if (not grouped)
            (unless (seq-some (lambda (day) (= (point) (plist-get day :position))) days)
              (user-error "Unknown top-level monthly section; add this date in source: %s" file))
          (let* ((title (org-get-heading t t t t)) (id (org-entry-get nil "ID"))
                 (week (and (string-match "\\`week \\([0-9][0-9]\\)\\'" title) (match-string 1 title)))
                 (week-key (and week
                                (cl-loop for day from 1 to 31
                                         for date = (encode-time 0 0 12 day
                                                                 (string-to-number (substring month 5 7))
                                                                 (string-to-number (substring month 0 4)))
                                         when (and (equal month (format-time-string "%Y-%m" date))
                                                   (equal week (format-time-string "%V" date)))
                                         return (format-time-string "%G-%V" date)))))
            (unless (and id week-key (not (member title names)))
              (user-error "Ambiguous or unsupported week section; add this date in source: %s" file))
            (push title names) (push (list id title week-key) groups)))
        (forward-line 1))
      (dolist (day days)
        (unless (string-prefix-p (concat month "-") (plist-get day :date))
          (user-error "Day falls outside its month; review %s" file))
        (when grouped
          (goto-char (plist-get day :position))
          (unless (and (= 2 (org-outline-level)) (org-up-heading-safe)
                       (equal (org-get-heading t t t t)
                              (format-time-string "week %V" (org-read-date nil t (plist-get day :date)))))
            (user-error "Day falls outside its ISO week group; review %s" file)))))
    groups))

(defun mho-vulpea-journal--prepare-week (record date)
  "Create a missing ISO week group in date order using the public create API.
Upstream inserts a new group at an edge. A source-verified predecessor lets
backdated weeks land between their neighbors without moving existing subtrees."
  (let* ((file (plist-get record :file)) (title (format-time-string "week %V" date))
         (target-key (format-time-string "%G-%V" date))
         (groups (mho-vulpea-journal--check-layout record t)))
    (unless (seq-some (lambda (group) (equal title (nth 1 group))) groups)
      (let* ((newer (sort (seq-filter (lambda (group) (string> (nth 2 group) target-key)) groups)
                          (lambda (a b) (string< (nth 2 a) (nth 2 b)))))
             (container (car (mho-vulpea-journal--notes-in-file file 0))))
        (unless container (user-error "Monthly journal container could not be indexed"))
        (vulpea-create title nil :parent container :after (caar newer))))))

(defun mho-vulpea-journal--resolve (original date)
  "Resolve DATE from source before ORIGINAL may create anything.
Existing daily/custom/monthly days win over the current template.  A new day
uses an existing month's simple/week layout; ambiguous structures fail closed."
  (when (and mho-vulpea-journal-prefix
             (not (mho-vulpea-journal--valid-prefix-p mho-vulpea-journal-prefix)))
    (user-error "Use lowercase letters, numbers, and single hyphens for the journal prefix"))
  (let* ((date (or date (current-time)))
         (key (format-time-string "%Y-%m-%d" date))
         (month (substring key 0 7))
         (root (file-name-as-directory (file-truename org-directory)))
         (records (cl-loop for file in (mho-vulpea-journal--files root)
                           for record = (when (equal mho-vulpea-journal-prefix
                                                     (car (mho-vulpea-journal--named-file file root)))
                                          (mho-vulpea-journal--source file))
                           when record collect record))
         (matches (cl-loop for record in records append
                           (cl-loop for day in (plist-get record :days)
                                    when (equal key (plist-get day :date)) collect (cons record day)))))
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (record records)
        (dolist (id (plist-get record :ids))
          (when (gethash id seen) (user-error "Duplicate journal ID across files: %s" id))
          (puthash id t seen))))
    (when (> (length matches) 1)
      (user-error "More than one journal destination for %s; resolve duplicates before writing" key))
    (mho-vulpea-journal--assert-current records)
    (if matches
        (mho-vulpea-journal--indexed-day (caar matches) (cdar matches))
      (let* ((months (seq-filter (lambda (record) (and (not (plist-get record :daily))
                                                       (equal month (plist-get record :month)))) records))
             (record (car months))
             (filename (concat (when mho-vulpea-journal-prefix (concat mho-vulpea-journal-prefix "-"))
                               month ".org"))
             (file (or (plist-get record :file) (expand-file-name (concat "journal/" filename) root)))
             (levels (plist-get record :levels))
             (grouped (not (equal levels '(1)))))
        (when (> (length months) 1) (user-error "Several monthly journals could hold %s; choose a single destination in source" key))
        (when (and record levels (not (member levels '((1) (2)))))
          (user-error "Existing monthly layout is mixed or unsupported; add this day in source: %s" file))
        (when record (mho-vulpea-journal--check-layout record grouped))
        (when (and (file-exists-p file) (null record))
          (user-error "Destination exists but is not a recognized journal: %s" file))
        (let ((parent (file-name-directory file)))
          (while (and parent (not (equal (directory-file-name parent) (directory-file-name root))))
            (when (file-symlink-p (directory-file-name parent))
              (user-error "Refusing a journal destination through a symlink: %s" parent))
            (setq parent (file-name-directory (directory-file-name parent)))))
        (when (and (not (file-exists-p file)) (mho-vulpea-journal--notes-in-file file))
          (user-error "Index still contains a deleted journal; refresh Vulpea before creating %s" file))
        (when record
          (mho-vulpea-journal--index-file record)
          (when grouped (mho-vulpea-journal--prepare-week record date)))
        ;; Only the normal public journal creation path writes.  Binding a
        ;; resolved template preserves existing layout rather than converting it.
        (let ((vulpea-default-notes-directory root)
              (vulpea-journal-default-template
               (vulpea-journal-template-monthly
                :file-name file :title month :entry-title "%d %A"
                :entry-groups (and grouped '("week %V")) :entry-order 'newest-first
                :aliases '("%Y-%m-%d") :body (if grouped "*** Tasks\n\n" "** Tasks\n\n"))))
          (funcall original date))))))

(defun mho-vulpea-journal-capture (preset &optional date prefix)
  "Capture private PRESET for DATE in the journal for PREFIX.
Omit PREFIX to use the default journal."
  (interactive (list (completing-read "Entry: " (mapcar #'car mho-vulpea-workflow-entry-presets) nil t)
                     (org-read-date nil t nil "Journal date: ")))
  (let* ((date (or date (current-time)))
         (value (assoc preset mho-vulpea-workflow-entry-presets))
         (id (org-id-new)))
    (unless value (user-error "Unknown journal entry preset"))
    (let ((org-capture-templates
           `(("j" ,(nth 1 value) entry
              (function ,(lambda ()
                           (let ((mho-vulpea-journal-prefix prefix))
                             (vulpea-journal-capture-target date))))
              ,(format "* %s :private:\n:PROPERTIES:\n:ID: %s\n:CREATED: [%s]\n:END:\n%s%%?"
                       (nth 1 value) id (format-time-string "%Y-%m-%d" date) (nth 2 value))
              :empty-lines 1 :jump-to-captured t))))
      (org-capture nil "j"))))

(defun mho-vulpea-journal-capture-in (prefix preset date)
  "Capture PRESET for DATE in the additional journal with PREFIX."
  (interactive
   (let* ((root (file-name-as-directory (file-truename org-directory)))
          (directory (expand-file-name "journal" root))
          (prefixes (when (and (file-directory-p directory) (not (file-symlink-p directory)))
                      (delete-dups
                       (cl-loop for file in (directory-files directory t directory-files-no-dot-files-regexp)
                                for prefix = (and (file-regular-p file) (not (file-symlink-p file))
                                                  (car (mho-vulpea-journal--named-file file root)))
                                when prefix collect prefix))))
          (prefix (downcase (string-trim (completing-read "Journal prefix: " prefixes)))))
     (unless (mho-vulpea-journal--valid-prefix-p prefix)
       (user-error "Use lowercase letters, numbers, and single hyphens for the journal prefix"))
     (list prefix (completing-read "Entry: " (mapcar #'car mho-vulpea-workflow-entry-presets) nil t)
           (org-read-date nil t nil "Journal date: "))))
  (mho-vulpea-journal-capture preset date prefix))

(defun mho-vulpea-journal-focus () (interactive) (mho-vulpea-journal-capture "focus"))
(defun mho-vulpea-journal-reflection () (interactive) (mho-vulpea-journal-capture "reflection"))
(defun mho-vulpea-journal-weekly-review () (interactive) (mho-vulpea-journal-capture "weeklyReview"))

(defun mho-vulpea-journal-setup ()
  "Enable source-verified date resolution without reading or changing notes."
  (setq vulpea-journal-default-template
        (vulpea-journal-template-monthly :entry-groups '("week %V") :entry-order 'newest-first
                                       :aliases '("%Y-%m-%d") :body "*** Tasks\n\n"))
  (advice-add 'vulpea-journal-note :around #'mho-vulpea-journal--resolve)
  (vulpea-journal-setup))

(provide 'mho-vulpea-journal)
;;; mho-vulpea-journal.el ends here
