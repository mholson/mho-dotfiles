;;; mho-vulpea-site.el --- Build mholson.com from public Vulpea notes -*- lexical-binding: t; -*-

;; Notes remain ordinary Org files.  This module owns only generated output;
;; it never rewrites the notes or deploys the website.

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'ox-html)
(require 'json)
(require 'vulpea)
(require 'mho-vulpea-site-theme)
(require 'mho-vulpea-site-publicatorg)

(defgroup mho-vulpea-site nil "A public website from Vulpea notes." :group 'org)
(defcustom mho-vulpea-site-directory nil
  "Note library to publish.  Nil uses `org-directory'."
  :type '(choice (const nil) directory))
(defcustom mho-vulpea-site-notes-directory "01 Projects/Website/"
  "Directory for new website notes, relative to the note library.
This does not restrict publication of eligible notes elsewhere in the library."
  :type 'directory)
(defcustom mho-vulpea-site-build-directory
  (expand-file-name "vulpea-site/" user-emacs-directory)
  "Dedicated generated preview directory, outside the note library."
  :type 'directory)
(defcustom mho-vulpea-site-repository (expand-file-name "~/GitHub/mholson/")
  "Existing static website checkout to receive an explicit export."
  :type 'directory)
(defcustom mho-vulpea-site-url "https://mholson.com/"
  "Public website root, used in the subscription feed."
  :type 'string)
(defcustom mho-vulpea-site-page-routes
  '(("731f6e16-3bf2-4ea6-a370-dfe671ce53c1" . "mho-0002.html")
    ("914bbecd-c37f-44f9-b25a-32b40b2a2207" . "vulpios.html")
    ("2aacd35e-c330-4c6f-85a7-4a01643196f0" . "stillvaro-guide.html")
    ("7d683987-61e0-4b20-9b7d-91f05c9f6d9b" . "stillvaro-metrics.html")
    ("bc699739-d209-470d-9f57-3f15b7910bcc" . "stillvaro-privacy.html")
    ("0b231c18-4f09-4a9b-9cdf-e1eb94f9986a" . "stillvaro-security.html")
    ("cda7ddf9-359a-4b74-a098-ee1e2359e7dc" . "stillvaro-terms.html"))
  "Stable root routes for selected note IDs.
Routes do not make a note public. Saved public tags are still required.
A mapped retained route is never copied from an older website checkout."
  :type '(alist :key-type string :value-type string))
(defcustom mho-vulpea-site-existing-pages
  '(("Stillvaro" "mho-0002.html" "A quieter way to practise the digits of π."
     "assets/beebf038ec31106eb4dc2a6f10e0b4248b06094d015af6439ef70927c2048a5e.png"))
  "Existing website pages to retain in the Pages archive.
Each entry is (TITLE RELATIVE-HTML-FILE DESCRIPTION), optionally followed
by a relative image path inside the website's assets directory."
  :type '(repeat (list string string string (repeat :inline t file))))
(defconst mho-vulpea-site--assets
  (expand-file-name "vulpea-site/assets/"
                    (file-name-directory (or load-file-name buffer-file-name))))

(require 'mho-vulpea-site-export)

;; Dynamically scoped export state; every build binds fresh tables.
(defvar mho-vulpea-site--ids)
(defvar mho-vulpea-site--paths)
(defvar mho-vulpea-site--current)
(defvar mho-vulpea-site--root)
(defvar mho-vulpea-site--stage)
(defvar mho-vulpea-site--files)
(defvar mho-vulpea-site--backlinks)

(defun mho-vulpea-site--escape (text)
  "Escape TEXT for HTML text or a quoted attribute."
  (org-html-encode-plain-text (or text "")))

(defun mho-vulpea-site--safe-id-p (id)
  "Whether ID can be used as a single route or anchor component."
  (and (stringp id) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" id)))

(defun mho-vulpea-site--valid-aliases-p (value)
  "Validate file alias quoting and escapes using Vulpios metadata rules."
  (let ((index 0) (length (length value)))
    (cl-labels ((spacep (character)
                  (or (memq character '(9 10 11 12 13 32 #x85))
                      (memq (get-char-code-property character 'general-category) '(Zs Zl Zp)))))
      (catch 'invalid
        (while (< index length)
          (while (and (< index length) (spacep (aref value index))) (cl-incf index))
          (when (< index length)
            (let* ((quoted (= (aref value index) ?\"))
                   (closed (not quoted)) ended)
              (when quoted (cl-incf index))
              (while (and (< index length) (not ended))
                (let ((character (aref value index)))
                  (cond
                   ((and quoted (= character ?\"))
                    (setq closed t ended t) (cl-incf index))
                   ((and (not quoted) (spacep character)) (setq ended t))
                   ((and (not quoted) (= character ?\")) (throw 'invalid nil))
                   ((= character ?\\)
                    (cl-incf index)
                    (unless (< index length) (throw 'invalid nil))
                    (cl-incf index))
                   (t (cl-incf index)))))
              (unless (and closed (or (= index length) (spacep (aref value index))))
                (throw 'invalid nil)))))
        t))))

(defun mho-vulpea-site--protect-opaque-headings ()
  "Escape literal headings in this temp buffer; return nil for ambiguous Org.
Source files are never changed. Every source selected for publication must
pass this validation before a note or journal entry is projected."
  (save-excursion
    (goto-char (point-min))
    (let (blocks drawer keys seen-title seen-tags heading preamble-content invalid)
      (while (not (eobp))
        (let* ((text (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
               (upper (upcase (string-trim text))))
          (cond
           (blocks
            (cond
             ((and (seq-every-p (lambda (name) (member name '("QUOTE" "VERSE" "CENTER"))) blocks)
                   (string-match "\\`#\\+BEGIN_\\([^ \t]+\\)" upper))
              (push (match-string 1 upper) blocks))
             ((equal upper (concat "#+END_" (car blocks))) (pop blocks))
             ((looking-at "\\*+[ \t]") (insert ","))))
           (drawer
            (cond
             ((equal upper ":END:") (setq drawer nil))
             ((equal drawer "PROPERTIES")
              (if (string-match "\\`[ \t]*:\\([^: \t]+\\):[ \t]*\\(.*\\)\\'" text)
                  (let ((key (upcase (match-string 1 text)))
                        (value (string-trim (match-string 2 text))))
                    (when (or (member key keys)
                              (and (not heading)
                                   (or (and (member key '("ALIASES" "ROAM_ALIASES"))
                                            (not (mho-vulpea-site--valid-aliases-p value)))
                                       (member key '("ID+" "CREATED+" "ALIASES+" "ROAM_ALIASES+"))
                                       (and (member key '("ALIASES" "ROAM_ALIASES"))
                                            (cl-intersection '("ALIASES" "ROAM_ALIASES") keys :test #'equal)))))
                      (setq invalid t))
                    (push key keys))
                (setq invalid t))
              (when (looking-at "\\*+[ \t]") (insert ",")))
             ((looking-at "\\*+[ \t]") (insert ","))))
           ((string-match "\\`#\\+BEGIN_\\([^ \t]+\\)" upper)
            (push (match-string 1 upper) blocks)
            (setq preamble-content t))
           ((string-match "\\`:\\([A-Z][A-Z0-9_-]*\\):\\'" upper)
            (setq drawer (match-string 1 upper) keys nil)
            (when (or (equal drawer "END")
                      (and (not heading) preamble-content (equal drawer "PROPERTIES")))
              (setq invalid t))
            (setq preamble-content t))
           ((looking-at "\\*+[ \t]") (setq heading t))
           ((not heading)
            (cond
             ((string-match-p "\\`#\\+TITLE:" upper)
              (when seen-title (setq invalid t)) (setq seen-title t))
             ((string-match-p "\\`#\\+FILETAGS:" upper)
              (when seen-tags (setq invalid t)) (setq seen-tags t)))
            (unless (string-match-p "\\`#\\(?:[ \t]\\|\\'\\)" upper)
              (setq preamble-content t)))))
        (forward-line 1))
      (not (or invalid blocks drawer)))))

(defun mho-vulpea-site--validate-source-ids (path)
  "Reject ambiguous source IDs before choosing public content from PATH."
  (let (ids)
    (goto-char (point-min))
    (when-let* ((id (org-entry-get nil "ID"))) (push (downcase id) ids))
    (org-element-map (org-element-parse-buffer) 'headline
      (lambda (heading)
        (goto-char (org-element-property :begin heading))
        (when-let* ((id (org-entry-get nil "ID")))
          (when (member (downcase id) ids)
            (user-error "Duplicate source ID in %s" path))
          (push (downcase id) ids))))))

(defun mho-vulpea-site--strip-directives ()
  "Keep content keywords but remove export settings before Org sees them.
In particular SETUPFILE must be removed before `org-mode' can read it.
Parse without activating Org mode, so literal directives in source and
example blocks remain content and cannot affect the export settings."
  ;; Org's parser requires eight-column tabs even before `org-mode' runs.
  ;; Temporary buffers otherwise inherit Doom's four-column default.
  (setq-local tab-width 8)
  (let ((org-element-use-cache nil)
        ranges)
    (org-element-map (org-element-parse-buffer) 'keyword
      (lambda (keyword)
        (unless (member (org-element-property :key keyword)
                        '("TITLE" "DATE" "DESCRIPTION" "FILETAGS"
                          "CAPTION" "NAME" "ATTR_HTML"))
          (push (cons (org-element-property :begin keyword)
                      (org-element-property :end keyword)) ranges))))
    (dolist (range ranges) (delete-region (car range) (cdr range)))))

(defun mho-vulpea-site--prune ()
  "Remove private, noexport, and commented subtrees from this temp buffer."
  (let (ranges end)
    (org-element-map (org-element-parse-buffer) 'headline
      (lambda (heading)
        (when (or (org-element-property :commentedp heading)
                  (cl-intersection '("private" "noexport")
                                   (org-element-property :tags heading)
                                   :test #'equal))
          (push (cons (org-element-property :begin heading)
                      (org-element-property :end heading)) ranges))))
    ;; Keep only outer ranges, then delete from the end to preserve positions.
    (setq ranges (sort ranges (lambda (a b) (< (car a) (car b)))))
    (let (outer)
      (dolist (range ranges)
        (unless (and end (< (car range) end))
          (setq end (cdr range))
          (push range outer)))
      (dolist (range outer) (delete-region (car range) (cdr range))))))

(defun mho-vulpea-site--keyword (name)
  "Read file-level keyword NAME without matching literal block contents.
Combine all FILETAGS lines so any private marker takes precedence."
  (let* ((tree (org-element-parse-buffer))
         (limit (or (org-element-map tree 'headline
                      (lambda (heading) (org-element-property :begin heading))
                      nil t)
                    (point-max)))
         (values (org-element-map tree 'keyword
                   (lambda (keyword)
                     (when (and (< (org-element-property :begin keyword) limit)
                                (equal (org-element-property :key keyword) name))
                       (string-trim (org-element-property :value keyword)))))))
    (if (equal name "FILETAGS") (string-join values " ") (car values))))

(defun mho-vulpea-site--date (value)
  "Extract a sortable day from VALUE without consulting surrounding content."
  (if (and value (string-match "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" value))
      (match-string 0 value) ""))

(defun mho-vulpea-site--headings (path)
  "Assign public anchors in this sanitized buffer, checking IDs against PATH."
  (let (headings)
    (org-map-entries
     (lambda ()
       (when-let* ((id (org-entry-get nil "ID")))
         (unless (mho-vulpea-site--safe-id-p id)
           (user-error "Unsafe heading ID in %s" path))
         (org-entry-put nil "CUSTOM_ID" (concat "id-" id))
         (push (list id (org-get-heading t t t t)) headings))))
    headings))

(defun mho-vulpea-site--file-page (path tags)
  "Create one public page from the current ordinary note with PATH and TAGS."
  (goto-char (point-min))
  (let* ((id (org-entry-get nil "ID"))
         (title (or (mho-vulpea-site--keyword "TITLE") "Untitled"))
         (description (mho-vulpea-site--keyword "DESCRIPTION"))
         (date (mho-vulpea-site--date
                (or (mho-vulpea-site--keyword "DATE") (org-entry-get nil "CREATED"))))
         (kind (cond ((member "blog" tags) 'blog)
                     ((member "weeknote" tags) 'week)
                     (t 'page))))
    (unless (mho-vulpea-site--safe-id-p id)
      (user-error "Public note needs a safe file ID: %s" path))
    (mho-vulpea-site--prune)
    (let ((headings (mho-vulpea-site--headings path)))
      (list :id id :title title :description description :date date :kind kind
            :layout (cond ((member "product" tags) 'product)
                          ((member "documentation" tags) 'documentation))
            :path (file-truename path) :headings headings
            :source (buffer-string) :body nil))))

(defun mho-vulpea-site--note-pages (path tags)
  "Project a public note at PATH into its main page and explicit subpages.
Only a top-level heading with SITE_PAGE set to page, product, or
documentation becomes a separate page.  It keeps its own ID, title,
PUBLISH_DATE and DESCRIPTION.  File-level privacy is checked by the caller;
private, noexport and commented subtrees are removed before selection."
  (mho-vulpea-site--prune)
  (let (pages ranges)
    (org-element-map (org-element-parse-buffer) 'headline
      (lambda (heading)
        (goto-char (org-element-property :begin heading))
        (when-let* ((layout (org-entry-get nil "SITE_PAGE")))
          (unless (and (= 1 (org-element-property :level heading))
                       (member layout '("page" "product" "documentation")))
            (user-error "SITE_PAGE must be page, product or documentation on a top-level heading: %s" path))
          (let* ((begin (org-element-property :begin heading))
                 (end (org-element-property :end heading))
                 (id (org-entry-get nil "ID"))
                 (title (org-get-heading t t t t))
                 (date (or (org-entry-get nil "PUBLISH_DATE")
                           (org-entry-get nil "CREATED")))
                 (description (org-entry-get nil "DESCRIPTION"))
                 (source (buffer-substring-no-properties
                          (line-beginning-position 2) end)))
            (unless (mho-vulpea-site--safe-id-p id)
              (user-error "A SITE_PAGE heading needs its own safe ID: %s" path))
            (push (cons begin end) ranges)
            (push
             (with-temp-buffer
               ;; Removing the selected heading promotes its properties to
               ;; file properties. Promote child headings by one level for
               ;; ordinary pages, without touching literal block text.
               (insert source)
               (delay-mode-hooks (org-mode))
               (let (positions)
                 (org-element-map (org-element-parse-buffer) 'headline
                   (lambda (child) (push (org-element-property :begin child) positions)))
                 (dolist (position positions)
                   (goto-char position) (delete-char 1)))
               (goto-char (point-min))
               (unless (re-search-forward "^:END:[ \t]*$" nil t)
                 (user-error "A SITE_PAGE heading needs a property drawer: %s" path))
               (end-of-line)
               (insert (format "\n#+TITLE: %s\n#+DATE: %s\n#+DESCRIPTION: %s\n"
                               title (or date "") (or description "")))
               (plist-put (mho-vulpea-site--file-page path (list "public" "page" layout))
                          :subtree-page t))
             pages)))))
    ;; Subpages do not also appear in the main page's body or heading index.
    (dolist (range ranges) (delete-region (car range) (cdr range)))
    (cons (mho-vulpea-site--file-page path tags) (nreverse pages))))

(defun mho-vulpea-site--day-key (value)
  "Return VALUE's leading valid Org day, otherwise nil."
  (when (and value (string-match
                    "\\`[ \t]*[<[]?\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[] >]\\|\\'\\)" value))
    (let ((year (string-to-number (match-string 1 value)))
          (month (string-to-number (match-string 2 value)))
          (day (string-to-number (match-string 3 value))))
      (when (and (> year 0) (calendar-date-is-valid-p (list month day year)))
        (format "%04d-%02d-%02d" year month day)))))

(defun mho-vulpea-site--journal-title-day (title)
  "Return a valid leading YYYY-MM-DD in TITLE, matching Vulpios journals."
  (when (and title (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" title))
    (mho-vulpea-site--day-key (substring title 0 10))))

(defun mho-vulpea-site--journal-month (path)
  "Return the journal month identified by its title or canonical filename."
  (let* ((title (mho-vulpea-site--keyword "TITLE"))
         (pattern "\\`[0-9]\\{4\\}-[0-9]\\{2\\}\\'")
         (month (if (and title (string-match-p pattern title)) title
                  (unless (mho-vulpea-site--journal-title-day title)
                    (let ((stem (file-name-base path)))
                      (and (string-match-p pattern stem) stem))))))
    (when (and month (not (mho-vulpea-site--day-key (concat month "-01"))))
      (user-error "The journal has an invalid month"))
    month))

(defun mho-vulpea-site--heading-day (title month)
  "Read the current heading's own day identity for MONTH.
CREATED is authoritative; aliases and conventional day titles are fallbacks."
  (let* ((created (org-entry-get nil "CREATED"))
         (aliases (org-entry-get nil "ALIASES"))
         (key (if created
                  (or (mho-vulpea-site--day-key created)
                      (user-error "A journal day has an invalid CREATED date"))
                (or (seq-some #'mho-vulpea-site--day-key
                              (and aliases (split-string-and-unquote aliases)))
                    (mho-vulpea-site--day-key title)))))
    (when (and (not key) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?:[ \t]\\|\\'\\)" title))
      (user-error "A journal day has an invalid date"))
    (or key
        (when (and month
                   (string-match "\\`\\([0-9]\\{1,2\\}\\)[ \t]+\\(.+\\)\\'" title))
          (let ((day (string-to-number (match-string 1 title)))
                (weekday (downcase (match-string 2 title))))
            (when (member weekday
                          (mapcar #'downcase
                                  (append calendar-day-name-array
                                          calendar-day-abbrev-array nil)))
              (or (mho-vulpea-site--day-key (format "%s-%02d" month day))
                  (user-error "A journal day has an invalid date"))))))))

(defun mho-vulpea-site--task-heading-p (heading)
  "Recognize Org and Vulpios task states without relying on user settings."
  (or (org-element-property :todo-keyword heading)
      (string-match-p
       "\\`\\(?:TODO\\|NEXT\\|LIVE\\|WAIT\\|SOME\\|DONE\\|XOUT\\|PROJ\\)\\(?:[ \t]\\|\\'\\)"
       (org-element-property :raw-value heading))))

(defun mho-vulpea-site--journal-entry-positions (path)
  "Return direct entry positions in the journal at PATH, excluding structure.
Monthly entries belong directly to a validated day. Daily entries belong to
the file or a Work/Personal/Weekend root. Task subtrees never become entries."
  (let* ((month (mho-vulpea-site--journal-month path))
         (daily (and (not month)
                     (or (mho-vulpea-site--journal-title-day (mho-vulpea-site--keyword "TITLE"))
                         (let ((stem (file-name-base path)))
                           (and (= (length stem) 10) (mho-vulpea-site--journal-title-day stem))))))
         (file-archived (save-excursion (goto-char (point-min)) (org-entry-get nil "ARCHIVE_TIME")))
         parents entries days weeks flat-days grouped-days)
    (when (or month daily)
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (heading)
          (let* ((level (org-element-property :level heading))
                 (begin (org-element-property :begin heading))
                 (title (string-trim (org-element-property :raw-value heading)))
                 (lower (downcase title))
                 kind day week)
            (while (and parents (>= (plist-get (car parents) :level) level))
              (pop parents))
            (goto-char begin)
            (cond
             ((or file-archived (org-element-property :commentedp heading)
                  (member "ARCHIVE" (org-element-property :tags heading))
                  (org-entry-get nil "ARCHIVE_TIME")
                  (seq-some (lambda (parent) (eq (plist-get parent :kind) 'archive)) parents))
              (setq kind 'archive))
             ((or (mho-vulpea-site--task-heading-p heading)
                  (member lower '("task" "tasks"))
                  (seq-some (lambda (parent) (eq (plist-get parent :kind) 'task)) parents))
              (setq kind 'task))
             ((and month (= level 1) (string-match "\\`week[ \t]+\\([0-9]\\{1,2\\}\\)\\'" lower))
              (setq kind 'week week (string-to-number (match-string 1 lower)))
              (when (or (member week weeks)
                        (not (cl-loop for number from 1 to 31
                                      for key = (mho-vulpea-site--day-key (format "%s-%02d" month number))
                                      thereis (and key (= week (string-to-number
                                                                (format-time-string "%V" (date-to-time (concat key " 12:00:00 +0000")) t)))))))
                (user-error "The journal has an invalid or duplicate week"))
              (push week weeks))
             ((and month (<= level 2)
                   (not (seq-some (lambda (parent) (eq (plist-get parent :kind) 'day)) parents))
                   (setq day (mho-vulpea-site--heading-day title month)))
              (unless (and (string-prefix-p (concat month "-") day)
                           (not (member day days))
                           (or (= level 1)
                               (and (eq (plist-get (car parents) :kind) 'week)
                                    (= (plist-get (car parents) :week)
                                       (string-to-number
                                        (format-time-string "%V" (date-to-time (concat day " 12:00:00 +0000")) t))))))
                (user-error "The journal has an ambiguous day or an incorrect week"))
              (setq kind 'day)
              (if (= level 1) (setq flat-days t) (setq grouped-days t))
              (push day days))
             ((and daily (= level 1) (member lower '("work" "personal" "weekend")))
              (setq kind 'daily-group))
             ((or (and month (eq (plist-get (car parents) :kind) 'day)
                       (= level (1+ (plist-get (car parents) :level))))
                  (and daily (or (= level 1)
                                 (and (= level 2) (eq (plist-get (car parents) :kind) 'daily-group)))))
              (setq kind 'entry)
              (push begin entries)))
            (push (list :kind kind :level level :week week) parents)))))
    (when (and flat-days (or weeks grouped-days))
      (user-error "The journal mixes grouped and ungrouped days"))
    (nreverse entries)))

(defun mho-vulpea-site--journal-pages (path)
  "Project only explicitly public entry subtrees from the journal at PATH.
Private, noexport and COMMENT ancestors veto publication before selection.
Calendar containers and unmarked siblings never contribute source or metadata."
  (mho-vulpea-site--journal-entry-positions path)
  (mho-vulpea-site--prune)
  (let ((eligible (mho-vulpea-site--journal-entry-positions path))
        entries selected-end)
    (org-element-map (org-element-parse-buffer) 'headline
      (lambda (heading)
        (let ((begin (org-element-property :begin heading)))
          (when (and (or (null selected-end) (>= begin selected-end))
                     (member "public" (org-element-property :tags heading))
                     (memq begin eligible))
            (setq selected-end (org-element-property :end heading))
            (goto-char begin)
            (let ((id (org-entry-get nil "ID")))
              (unless (mho-vulpea-site--safe-id-p id)
                (user-error "Public journal entry needs a safe own ID: %s" path))
              (push (list :id id :title (org-get-heading t t t t)
                          :description (org-entry-get nil "DESCRIPTION")
                          :date (mho-vulpea-site--date (org-entry-get nil "CREATED"))
                          :kind (if (member "weeknote" (org-element-property :tags heading)) 'week 'blog)
                          :path (file-truename path) :journal-entry t :body nil
                          ;; The entry title belongs to the page shell. Retain
                          ;; only its own section/subtree, without its heading.
                          :source (buffer-substring-no-properties
                                   (line-beginning-position 2) selected-end))
                    entries))))))
    (mapcar
     (lambda (entry)
       (with-temp-buffer
         (insert (plist-get entry :source))
         (delay-mode-hooks (org-mode))
         (setf (plist-get entry :headings) (mho-vulpea-site--headings path)
               (plist-get entry :source) (buffer-string))
         entry))
     (nreverse entries))))

(defun mho-vulpea-site--read-pages (note)
  "Read NOTE's saved source, returning sanitized public page plists.
Journal files always use explicit entry selection, even with legacy public
file tags. An explicit private/noexport file tag remains a whole-file veto."
  (let ((path (vulpea-note-path note)))
    (when (and (not (file-remote-p path))
               (= (or (vulpea-note-level note) -1) 0)
               (file-regular-p path)
               (file-in-directory-p (file-truename path) mho-vulpea-site--root))
      (with-temp-buffer
        (insert-file-contents path)
        (let ((valid-structure (mho-vulpea-site--protect-opaque-headings)))
          (mho-vulpea-site--strip-directives)
          (delay-mode-hooks (org-mode))
          (let ((tags (split-string (or (mho-vulpea-site--keyword "FILETAGS") "")
                                    "[: \t]+" t)))
            (unless (cl-intersection '("private" "noexport") tags :test #'equal)
              (when (or (member "journal" tags) (member "public" tags))
                (unless valid-structure (user-error "Ambiguous or unfinished publication source: %s" path))
                (mho-vulpea-site--validate-source-ids path))
              (cond
               ((member "journal" tags) (mho-vulpea-site--journal-pages path))
               ;; A journal path without metadata must not fall back to whole-file
               ;; publication. The app also keeps this container private.
               ((string-prefix-p "journal/" (file-relative-name (file-truename path) mho-vulpea-site--root)) nil)
               ((member "public" tags) (mho-vulpea-site--note-pages path tags))))))))))

(defun mho-vulpea-site--register-id (id page &optional anchor title)
  "Register ID as PAGE with optional ANCHOR and heading TITLE."
  (when (gethash id mho-vulpea-site--ids)
    (user-error "Duplicate public ID: %s" id))
  (puthash id (list :page page :anchor anchor
                    :title (or title (plist-get page :title)))
           mho-vulpea-site--ids))

(defun mho-vulpea-site--target-link (target description)
  "Render TARGET with DESCRIPTION and record a public backlink."
  (let* ((page (plist-get target :page))
         (id (plist-get page :id))
         (source (plist-get mho-vulpea-site--current :id))
         (anchor (plist-get target :anchor)))
    (unless (equal source id)
      (cl-pushnew source (gethash id mho-vulpea-site--backlinks) :test #'equal))
    (format "<a href=\"%s%s\">%s</a>"
            (mho-vulpea-site--relative-route page mho-vulpea-site--current)
            (if anchor (concat "#" anchor) "")
            (or description (mho-vulpea-site--escape (plist-get target :title))))))

(defun mho-vulpea-site--route (page)
  "Return PAGE's route relative to the website root."
  (or (plist-get page :url) (format "notes/%s.html" (plist-get page :id))))

(defun mho-vulpea-site--relative-route (target source)
  "Return a link from SOURCE to TARGET within the generated website."
  (file-relative-name
   (expand-file-name (mho-vulpea-site--route target) mho-vulpea-site--stage)
   (file-name-directory
    (expand-file-name (mho-vulpea-site--route source) mho-vulpea-site--stage))))

(defun mho-vulpea-site--page-root (page)
  "Return the relative website root for PAGE."
  (if (plist-get page :url) "" "../"))

(defun mho-vulpea-site--assign-routes (pages)
  "Validate configured root routes, then assign them to public PAGES."
  (let (ids routes)
    (dolist (entry mho-vulpea-site-page-routes)
      (unless (and (mho-vulpea-site--safe-id-p (car entry))
                   (stringp (cdr entry))
                   (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\.html\\'" (cdr entry))
                   (not (member (cdr entry) '("index.html" "blog.html" "weeks.html" "pages.html")))
                   (not (member (car entry) ids)) (not (member (cdr entry) routes)))
        (user-error "Invalid or duplicate configured page route: %S" entry))
      (push (car entry) ids) (push (cdr entry) routes))
    (mapcar (lambda (page)
              (if-let* ((route (cdr (assoc (plist-get page :id) mho-vulpea-site-page-routes))))
                  (plist-put page :url route)
                page))
            pages)))

(defun mho-vulpea-site--media (path)
  "Copy a supported local PATH inside the library and return its public URL."
  (unless (file-remote-p path)
    (let* ((absolute (expand-file-name path
                                     (file-name-directory
                                      (plist-get mho-vulpea-site--current :path))))
           (extension (downcase (or (file-name-extension absolute) ""))))
      (when (and (not (file-remote-p absolute))
                 (member extension '("png" "jpg" "jpeg" "gif" "webp" "avif" "svg" "pdf"))
                 (file-regular-p absolute)
                 (file-in-directory-p (file-truename absolute) mho-vulpea-site--root))
        (let* ((hash (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally absolute)
                       (secure-hash 'sha256 (current-buffer))))
               (relative (format "media/%s.%s" hash extension)))
          (copy-file absolute (expand-file-name relative mho-vulpea-site--stage) t)
          (cl-pushnew relative mho-vulpea-site--files :test #'equal)
          (concat (mho-vulpea-site--page-root mho-vulpea-site--current) relative))))))

(defun mho-vulpea-site--link (link description info)
  "Export LINK without exposing private notes or arbitrary local files."
  (let* ((type (org-element-property :type link))
         (path (org-element-property :path link)))
    (cond
     ((equal type "id")
      (if-let* ((target (gethash path mho-vulpea-site--ids)))
          (mho-vulpea-site--target-link target description)
        (or description "Unpublished note")))
     ((and (equal type "file") (file-remote-p path))
      (or description "Unpublished file"))
     ((equal type "file")
      (let* ((absolute (expand-file-name path
                                       (file-name-directory
                                        (plist-get mho-vulpea-site--current :path))))
             (page (gethash (file-truename absolute) mho-vulpea-site--paths)))
        (cond
         ((and page (not (org-element-property :search-option link)))
          (mho-vulpea-site--target-link (list :page page :title (plist-get page :title))
                                       description))
         ((let ((media (mho-vulpea-site--media path)))
            (when media
              (let ((copy (org-element-copy link)))
                (org-element-put-property copy :path media)
                ;; A copied link is not the original paragraph's first link.
                ;; Carry its image attributes explicitly so hashing the URL
                ;; preserves alt text, intrinsic size and lazy loading.
                (when-let* ((parent (org-element-parent-element link))
                            (_ (eq link (org-element-map parent 'link #'identity info t))))
                  (org-element-put-property copy :attr_html
                                            (org-element-property :attr_html parent)))
                (org-html-link copy description info)))))
         (t (or description "Unpublished file")))))
     ((equal type "custom-id")
      ;; A #anchor belongs to this exported page, never an external Org file
      ;; from Org's ID cache (which can also contain unpublished notes).
      (org-html-link link description (org-combine-plists info '(:id-alist nil))))
     ((and (equal type "https")
           (equal path "//apps.apple.com/app/id6759560223")
           (eq (plist-get mho-vulpea-site--current :layout) 'product)
           (equal (org-element-property
                   :type (org-element-lineage link '(special-block)))
                  "sv-actions"))
      (format (concat "<a class=\"sv-app-store-badge\" href=\"https://apps.apple.com/app/id6759560223\""
                      " aria-label=\"Download Stillvaro on the App Store\">"
                      "<img src=\"%sassets/app-store-badge.svg\""
                      " alt=\"Download on the App Store\" width=\"144\" height=\"48\"></a>")
              (mho-vulpea-site--page-root mho-vulpea-site--current)))
     ((member type '("http" "https" "mailto" "fuzzy" "radio" "coderef"))
      (org-html-link link description info))
     (t (or description (mho-vulpea-site--escape path))))))

(defun mho-vulpea-site--latex (element _contents _info)
  "Render a LaTeX ELEMENT as native MathML using sandboxed Pandoc."
  (unless (executable-find "pandoc")
    (user-error "Math export needs pandoc on Emacs' exec-path"))
  (with-temp-buffer
    (insert (org-element-property :value element))
    (let ((errors (make-temp-file "vulpea-math-")))
      (unwind-protect
          (let ((status (call-process-region
                         (point-min) (point-max) "pandoc" t (list t errors) nil
                         "--sandbox" "--from=latex" "--to=html5" "--math-method=mathml")))
            (unless (and (integerp status) (zerop status))
              (user-error "Math export failed: %s"
                          (with-temp-buffer (insert-file-contents errors) (buffer-string))))
            ;; The surrounding Org paragraph already supplies the inline wrapper.
            (string-trim
             (replace-regexp-in-string
              "</p>[ \n]*\\'" ""
              (replace-regexp-in-string "\\`<p>" "" (buffer-string)))))
        (delete-file errors)))))

(defun mho-vulpea-site--paragraph (paragraph contents info)
  "Render PARAGRAPH, leaving inline CONTENTS in semantic layout blocks.
INFO is the Org export state.  Ordinary paragraphs retain Org's attributes,
captions and image handling."
  (let ((parent (org-element-parent paragraph)))
    (if (and (eq (org-element-type parent) 'special-block)
             (member (org-element-property :type parent)
                '("sv-title" "product-title" "sv-actions" "sv-nav")))
        contents
      (org-html-paragraph paragraph contents info))))

(defun mho-vulpea-site--special-block (block contents info)
  "Render authored Org BLOCK with its semantic website presentation.
CONTENTS is exported Org.  Captions use the same exporter and link privacy
checks as the rest of the page, with INFO as the export state."
  (pcase (org-element-property :type block)
    ((or "sv-title" "product-title")
     (unless (and (= 1 (length (org-element-contents block)))
                  (eq (org-element-type (car (org-element-contents block)))
                      'paragraph))
       (user-error "A product title block needs one text paragraph"))
     (format "<h1 id=\"page-title\">%s</h1>" (string-trim contents)))
    ("sv-nav"
     (format "<nav class=\"sv-nav\" aria-label=\"Stillvaro page\">\n%s</nav>"
             contents))
    ("sv-question"
     (let ((question (org-export-data (org-export-get-caption block) info)))
       (unless (org-string-nw-p question)
         (user-error "An sv-question block needs its question in #+caption"))
       (format "<details><summary>%s</summary>\n%s</details>" question contents)))
    (_ (org-html-special-block block contents info))))

(org-export-define-derived-backend 'mho-vulpea-site 'html
  :translate-alist '((link . mho-vulpea-site--link)
                    (paragraph . mho-vulpea-site--paragraph)
                    (special-block . mho-vulpea-site--special-block)
                    (latex-fragment . mho-vulpea-site--latex)
                    (latex-environment . mho-vulpea-site--latex)))

(defun mho-vulpea-site--body (page)
  "Export sanitized PAGE without executing source blocks or macros."
  (with-temp-buffer
    (insert (plist-get page :source))
    (delay-mode-hooks (org-mode))
    (let ((mho-vulpea-site--current page)
          (org-export-use-babel nil)
          (org-export-replace-macros nil)
          (org-export-allow-bind-keywords nil)
          (org-export-with-broken-links t)
          (org-html-htmlize-output-type nil)
          (org-export-before-processing-functions nil)
          (org-export-before-parsing-functions nil)
          (reference 0))
      ;; Org's random fallback anchors otherwise change Git diffs on every
      ;; rebuild.  Explicit note/heading IDs still take precedence.
      (cl-letf (((symbol-function 'org-export-new-reference)
                 (lambda (references)
                   (while (rassq (cl-incf reference) references))
                   reference)))
        (org-export-as 'mho-vulpea-site nil nil t
                       '(:with-toc nil :section-numbers nil :with-title nil
                         :with-author nil :with-date nil :with-tags nil :with-latex t
                         :with-properties nil :with-drawers nil
                         :select-tags nil :exclude-tags ("private" "noexport")
                         :html-prefer-user-labels t :html-link-org-files-as-html nil))))))

(defun mho-vulpea-site--stylesheet ()
  "Return the theme CSS with self-contained Duo screen masks.
External CSS masks are blocked when a preview is opened via file://.
Embed the two trusted theme assets so both file and web previews preserve
the supplied screen apertures without hiding the screenshots."
  (let ((css (with-temp-buffer
               (insert-file-contents (expand-file-name "vulpea-site.css" mho-vulpea-site--assets))
               (buffer-string))))
    (dolist (asset '(("stillvaro-duo-outer-screen-mask.png" . "image/png")
                     ("stillvaro-duo-outer-screen-mask-landscape.svg" . "image/svg+xml")))
      (let ((data (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally (expand-file-name (car asset) mho-vulpea-site--assets))
                    (base64-encode-string (buffer-string) t))))
        (setq css (replace-regexp-in-string
                   (regexp-quote (format "url(\"%s\")" (car asset)))
                   (format "url(\"data:%s;base64,%s\")" (cdr asset) data)
                   css t t))))
    css))

(defun mho-vulpea-site--write (relative content)
  "Write CONTENT to a managed RELATIVE path in the staging directory."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region content nil (expand-file-name relative mho-vulpea-site--stage) nil 'silent))
  (cl-pushnew relative mho-vulpea-site--files :test #'equal))

(defun mho-vulpea-site--feed (pages)
  "Render an RSS feed from explicitly public writing in PAGES."
  (let ((escape #'mho-vulpea-site--escape)
        (root (file-name-as-directory mho-vulpea-site-url)))
    (concat
     "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\"><channel>\n"
     "<title>mholson</title><link>" (funcall escape root) "</link>\n"
     "<description>Writing and weeknotes by Mark Olson.</description><language>en</language>\n"
     (mapconcat
      (lambda (page)
        (let ((url (concat root (mho-vulpea-site--route page)))
              (date (plist-get page :date)))
          (concat "<item><title>" (funcall escape (plist-get page :title)) "</title>"
                  "<link>" (funcall escape url) "</link>"
                  "<guid isPermaLink=\"true\">" (funcall escape url) "</guid>"
                  (when (and date (not (string-empty-p date)))
                    (concat "<pubDate>"
                            (let ((system-time-locale "C"))
                              (format-time-string
                               "%a, %d %b %Y %H:%M:%S +0000"
                               (date-to-time (concat date " 12:00:00 +0000")) t))
                            "</pubDate>"))
                  "<description>" (funcall escape (plist-get page :description))
                  "</description></item>")))
      (seq-take (seq-filter (lambda (page) (memq (plist-get page :kind) '(blog week))) pages) 30)
      "\n")
     "\n</channel></rss>\n")))

(defun mho-vulpea-site--page-job (page)
  "Return a Publicatorg job for an already sanitized, exported PAGE."
  (let ((backlinks (sort (copy-sequence (gethash (plist-get page :id)
                                               mho-vulpea-site--backlinks))
                         #'string-lessp)))
    (list :id (plist-get page :id)
          :route (mho-vulpea-site--route page)
          :html
          (mho-vulpea-site-theme-page
           (plist-get page :title)
           (concat (plist-get page :body)
                   (when (and backlinks (not (eq (plist-get page :layout) 'product)))
                     (concat "<aside class=\"backlinks\"><h2>Linked from</h2><ul>"
                             (mapconcat
                              (lambda (id)
                                (let ((target (plist-get (gethash id mho-vulpea-site--ids) :page)))
                                  (format "<li><a href=\"%s\">%s</a></li>"
                                          (mho-vulpea-site--relative-route target page)
                                          (mho-vulpea-site--escape (plist-get target :title)))))
                              backlinks "") "</ul></aside>")))
           (plist-get page :description) (mho-vulpea-site--page-root page) page))))

(defun mho-vulpea-site--legacy-pages ()
  "Stage retained pages for local preview and return their display metadata."
  (let (entries)
    (dolist (entry mho-vulpea-site-existing-pages)
      (let ((title (nth 0 entry)) (route (nth 1 entry))
            (description (nth 2 entry)) (image (nth 3 entry)))
        (unless (string-match-p "\\`[A-Za-z0-9_-]+\\.html\\'" route)
          (user-error "Invalid existing page route: %s" route))
        (let ((source (expand-file-name route mho-vulpea-site-repository)))
          (when (and (file-regular-p source)
                     (not (rassoc route mho-vulpea-site-page-routes)))
            (copy-file source (expand-file-name route mho-vulpea-site--stage))
            (push (list :title title :url route :description description
                        :image (when (and image (string-prefix-p "assets/" image)
                                          (file-regular-p (expand-file-name image mho-vulpea-site-repository))
                                          (file-in-directory-p
                                           (file-truename (expand-file-name image mho-vulpea-site-repository))
                                           (file-truename (expand-file-name "assets/" mho-vulpea-site-repository))))
                                 image))
                  entries)))))
    ;; These are preview copies only and deliberately absent from our manifest.
    (let ((assets (expand-file-name "assets/" mho-vulpea-site-repository)))
      (when (file-directory-p assets)
        (dolist (path (directory-files-recursively assets "."))
          (when (and (file-regular-p path)
                     (file-in-directory-p (file-truename path)
                                          (file-truename mho-vulpea-site-repository)))
            (let ((target (expand-file-name (file-relative-name path mho-vulpea-site-repository)
                                            mho-vulpea-site--stage)))
              (make-directory (file-name-directory target) t)
              (copy-file path target t))))))
    (nreverse entries)))

;;;###autoload
(defun mho-vulpea-site-build ()
  "Build a local preview from saved, indexed notes explicitly tagged public.
The source is rechecked even when the index is stale.  No source files or
website checkout files are changed.  Return the generated directory."
  (interactive)
  (let* ((mho-vulpea-site--root
          (file-name-as-directory (file-truename (or mho-vulpea-site-directory org-directory))))
         (output (directory-file-name (expand-file-name mho-vulpea-site-build-directory)))
         (repository (file-truename mho-vulpea-site-repository))
         (mho-vulpea-site--ids (make-hash-table :test #'equal))
         (mho-vulpea-site--paths (make-hash-table :test #'equal))
         (mho-vulpea-site--backlinks (make-hash-table :test #'equal))
         (mho-vulpea-site--files nil)
         (seen (make-hash-table :test #'equal))
         pages)
    (when (or (file-symlink-p output)
              (equal (file-truename output) (directory-file-name mho-vulpea-site--root))
              (equal (file-truename output) (directory-file-name repository))
              (file-in-directory-p output mho-vulpea-site--root)
              (file-in-directory-p output repository)
              (file-in-directory-p mho-vulpea-site--root output)
              (file-in-directory-p repository output))
      (user-error "Build directory must be separate from notes and website checkout"))
    (when (and (file-exists-p output)
               (not (file-exists-p (expand-file-name ".vulpea-site-build" output))))
      (user-error "Refusing to replace an unowned build directory: %s" output))
    (dolist (note (vulpea-db-query))
      (when (and (= (or (vulpea-note-level note) -1) 0)
                 (not (gethash (vulpea-note-path note) seen)))
        (puthash (vulpea-note-path note) t seen)
        (dolist (page (mho-vulpea-site--read-pages note)) (push page pages))))
    (setq pages (sort pages (lambda (a b)
                             (if (equal (plist-get a :date) (plist-get b :date))
                                 (string-lessp (plist-get a :title) (plist-get b :title))
                               (string-lessp (plist-get b :date) (plist-get a :date))))))
    (setq pages (mho-vulpea-site--assign-routes pages))
    (dolist (page pages)
      (mho-vulpea-site--register-id (plist-get page :id) page)
      ;; A file link targets its main page, never an arbitrary subpage or
      ;; journal entry. ID links identify each separate page unambiguously.
      (unless (or (plist-get page :journal-entry) (plist-get page :subtree-page))
        (puthash (plist-get page :path) page mho-vulpea-site--paths))
      (dolist (heading (plist-get page :headings))
        (mho-vulpea-site--register-id (car heading) page
                                    (concat "id-" (car heading)) (cadr heading))))
    (make-directory (file-name-directory output) t)
    (let ((mho-vulpea-site--stage (make-temp-file (concat output ".staging-") t)))
      (unwind-protect
          (progn
            (dolist (directory '("notes" "media" "assets"))
              (make-directory (expand-file-name directory mho-vulpea-site--stage)))
            (let ((legacy (mho-vulpea-site--legacy-pages)))
              (dolist (route mho-vulpea-site-export--assets)
                (copy-file (expand-file-name (file-name-nondirectory route) mho-vulpea-site--assets)
                           (expand-file-name route mho-vulpea-site--stage) t)
                (push route mho-vulpea-site--files))
              (mho-vulpea-site--write "assets/vulpea-site.css" (mho-vulpea-site--stylesheet))
              ;; Export every body before rendering backlinks.
              (dolist (page pages)
                (setf (plist-get page :body) (mho-vulpea-site--body page)))
              (mho-vulpea-site-publicatorg-publish
               (mapcar #'mho-vulpea-site--page-job pages)
               mho-vulpea-site--stage #'mho-vulpea-site--write)
              (mho-vulpea-site--write "index.html" (mho-vulpea-site-theme-home pages legacy))
              (mho-vulpea-site--write "feed.xml" (mho-vulpea-site--feed pages))
              (dolist (archive '(("blog.html" "Writing" blog)
                                 ("weeks.html" "Weeknotes" week)
                                 ("pages.html" "Pages" page)))
                (mho-vulpea-site--write
                 (car archive)
                 (mho-vulpea-site-theme-archive
                  (cadr archive)
                  (cl-remove-if-not (lambda (page) (eq (plist-get page :kind) (caddr archive))) pages)
                  (when (equal (car archive) "pages.html") legacy)))))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-encode `((version . 1) (files . ,(vconcat (sort mho-vulpea-site--files #'string-lessp)))))
                            nil (expand-file-name ".vulpea-site-manifest.json" mho-vulpea-site--stage) nil 'silent)
              (write-region "Vulpea site build\n" nil
                            (expand-file-name ".vulpea-site-build" mho-vulpea-site--stage) nil 'silent))
            (when (file-exists-p output) (delete-directory output t))
            (rename-file mho-vulpea-site--stage output)
            (message "Built %d public notes in %s" (length pages) output)
            output)
        (when (file-directory-p mho-vulpea-site--stage)
          (delete-directory mho-vulpea-site--stage t))))))

;;;###autoload
(defun mho-vulpea-site-preview ()
  "Build and open the local website in a browser."
  (interactive)
  (browse-url-of-file (expand-file-name "index.html" (mho-vulpea-site-build))))

;;;###autoload
(defun mho-vulpea-site-new (title kind)
  "Create a public note with TITLE and KIND (page, blog, or weeknote)."
  (interactive (list (read-string "Public note title: ")
                     (completing-read "Kind: " '("page" "blog" "weeknote") nil t)))
  (setq title (string-trim title))
  (when (string-empty-p title) (user-error "A note needs a title"))
  (let ((vulpea-default-notes-directory
         (expand-file-name mho-vulpea-site-notes-directory
                           (or mho-vulpea-site-directory org-directory))))
    (vulpea-visit (vulpea-create title nil :tags (list "public" kind)
                                :head (concat "#+date: " (format-time-string "%Y-%m-%d")
                                              "\n#+description: \n")))))

(provide 'mho-vulpea-site)
;;; mho-vulpea-site.el ends here
