(setq-default window-combination-resize t)

(add-to-list 'default-frame-alist '(height . 34))
(add-to-list 'default-frame-alist '(width  . 80))

(setq display-line-numbers-type 'relative)

(setq scroll-preserve-screen-position 'always)
(setq scroll-margin 4)

(setq-default x-stretch-cursor t)

(setq-default delete-by-moving-to-trash t)
(setq auto-save-default t)

(setq undo-limit 80000000)

(setq evil-want-fine-undo t)



(setq doom-font (font-spec :family "SF Mono" :size 21 ))

(setq truncate-string-ellipsis "…")

;;(setq doom-variable-pitch-font (font-spec :family "Source Code Pro" :size 13))

(setq doom-big-font (font-spec :family "SF Mono" :size 42 ))

(set-fontset-font t nil "SF Pro Display" nil 'append)
(load! "lisp/sf.el")

(setq mac-option-modifier nil
      mac-command-modifier 'meta
      mac-right-command-modifier 'control
      mac-control-modifier 'super
      mac-function-modifier 'hyper)

(setq password-cache-expiry nil)

(setq doom-theme 'doom-nord-aurora)

(display-time-mode 1)

(unless (string-match-p "^Power N/A" (battery))
  (display-battery-mode 1))

(setq which-key-idle-delay 0.5)

;;(setq browse-url-browser-function 'browse-url-chrome)
;;(setq browse-url-chrome-program "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

(global-set-key (kbd "C-å") 'sp-wrap-curly)
;;(global-set-key (kbd "C-ä") 'sp-up-sexp)
(global-set-key (kbd "M-o") 'sp-up-sexp)
(global-set-key (kbd "M-b") 'sp-down-sexp)
(global-set-key (kbd "M-w") 'save-buffer)
;;(global-set-key (kbd "C-<") "{")
(define-key key-translation-map (kbd "§") (kbd "\\"))

(map! :leader
      :desc "Run mho/gen-id"
      "j" #'mho/gen-id
      )

(map! :leader
      (:prefix ("l" . "link")
      :desc "File"
      "f" #'mho/org-insert-file-link
      ))

(map! :leader
      (:prefix ("l" . "link")
      :desc "Clipboard"
      "c" #'org-cliplink
      ))



(use-package! anki-editor
  :after org
  ;;:config
  )

(use-package! calctex
  :commands calctex-mode
  :init
  (add-hook 'calc-mode-hook #'calctex-mode)
  :config
  (setq calctex-additional-latex-packages "
\\usepackage[usenames]{xcolor}
\\usepackage{soul}
\\usepackage{adjustbox}
\\usepackage{amsmath}
\\usepackage{amssymb}
\\usepackage{siunitx}
\\usepackage{cancel}
\\usepackage{mathtools}
\\usepackage{mathalpha}
\\usepackage{xparse}
\\usepackage{arevmath}"
        calctex-additional-latex-macros
        (concat calctex-additional-latex-macros
                "\n\\let\\evalto\\Rightarrow"))
  (defadvice! no-messaging-a (orig-fn &rest args)
    :around #'calctex-default-dispatching-render-process
    (let ((inhibit-message t) message-log-max)
      (apply orig-fn args)))
  ;; Fix hardcoded dvichop path (whyyyyyyy)
  (let ((vendor-folder (concat (file-truename doom-local-dir)
                               "straight/"
                               (format "build-%s" emacs-version)
                               "/calctex/vendor/")))
    (setq calctex-dvichop-sty (concat vendor-folder "texd/dvichop")
          calctex-dvichop-bin (concat vendor-folder "texd/dvichop")))
  (unless (file-exists-p calctex-dvichop-bin)
    (message "CalcTeX: Building dvichop binary")
    (let ((default-directory (file-name-directory calctex-dvichop-bin)))
      (call-process "make" nil nil nil))))

(setq calc-angle-mode 'rad  ; radians are rad
      calc-symbolic-mode t) ; keeps expressions like \sqrt{2} irrational for as long as possible

(global-set-key (kbd "C-c e") #'calc-embedded)
(map! :after calc
      :map calc-mode-map
      :localleader
      :desc "Embedded calc (toggle)" "e" #'calc-embedded)
(map! :after org
      :map org-mode-map
      :localleader
      :desc "Embedded calc (toggle)" "E" #'calc-embedded)
(map! :after latex
      :localleader
      :map latex-mode-map
      :desc "Embedded calc (toggle)" "e" #'calc-embedded)

(defvar calc-embedded-trail-window nil)
(defvar calc-embedded-calculator-window nil)

(defadvice! calc-embedded-with-side-pannel (&rest _)
  :after #'calc-do-embedded
  (when calc-embedded-trail-window
    (ignore-errors
      (delete-window calc-embedded-trail-window))
    (setq calc-embedded-trail-window nil))
  (when calc-embedded-calculator-window
    (ignore-errors
      (delete-window calc-embedded-calculator-window))
    (setq calc-embedded-calculator-window nil))
  (when (and calc-embedded-info
             (> (* (window-width) (window-height)) 1200))
    (let ((main-window (selected-window))
          (vertical-p (> (window-width) 80)))
      (select-window
       (setq calc-embedded-trail-window
             (if vertical-p
                 (split-window-horizontally (- (max 30 (/ (window-width) 3))))
               (split-window-vertically (- (max 8 (/ (window-height) 4)))))))
      (switch-to-buffer "*Calc Trail*")
      (select-window
       (setq calc-embedded-calculator-window
             (if vertical-p
                 (split-window-vertically -6)
               (split-window-horizontally (- (/ (window-width) 2))))))
      (switch-to-buffer "*Calculator*")
      (select-window main-window))))



;;(use-package! forester)

(defun mho/forester--date ()
  "Insert the current date in Typst \\date{...} format at point.
Example: \\date{2025-07-25T09:10:46+02:00}"
  (interactive)
  (let ((raw (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
    (insert (format "\\date{%s:%s}"
                    (substring raw 0 -2)
                    (substring raw -2)))))

(defun mho/forester--create-weeknote-file ()
  "Create a weeknotes .tree file named YYYY-Www.tree without using a generated ID."
  (interactive)
  (let* ((target-dir "~/GitHub/mho-forest/trees/weeknotes/")
         (current-time (current-time))
         (week-id (format-time-string "%Y-W%V" current-time))
         (filename (expand-file-name (concat week-id ".tree") target-dir))
         (title (format "Weeknotes %s" week-id))
         (iso-datetime
          (let* ((raw (format-time-string "%Y-%m-%dT%H:%M:%S%z" current-time)))
            (concat (substring raw 0 -2) ":" (substring raw -2))))
         (author "markholson")
         (template (format "\\title{%s}
\\date{%s}
\\author{%s}
" title iso-datetime author)))
    (if (file-exists-p filename)
        (user-error "File already exists: %s" filename)
      (find-file filename)
      (insert template)
      (save-buffer)
      (message "Created weeknotes file: %s" filename))))

(defun mho/forester--create-tree-file ()
  "Create a new .tree file using a generated ID and a user-provided title."
  (interactive)
  (let* ((id-file "~/Documents/mho-roam/resources/code/shell/TAGS-tagids.txt")
         (target-dir "~/GitHub/mho-forest/trees/")
         (buffer (find-file-noselect id-file))
         full-id)
    ;; Step 1: Get next available ID
    (with-current-buffer buffer
      (goto-char (point-min))
      (let ((first-id (string-trim (buffer-substring-no-properties (point) (line-end-position)))))
        (setq full-id first-id)
        (if (yes-or-no-p (format "Use and remove ID: %s?" full-id))
            (progn
              (delete-region (point) (1+ (line-end-position)))
              (save-buffer)
              (kill-buffer))
          (user-error "Aborted by user"))))

    ;; Step 2: Prompt for title
    (let* ((title (read-string "Enter title: "))
           (filename (expand-file-name (concat full-id ".tree") target-dir))
           (iso-datetime
            (let* ((raw (format-time-string "%Y-%m-%dT%H:%M:%S%z" (current-time))))
              (concat (substring raw 0 -2) ":" (substring raw -2))))
           (author "markholson")
           (template (format "\\title{%s}
\\date{%s}
\\author{%s}
" title iso-datetime author)))
      (find-file filename)
      (insert template)
      (save-buffer)
      (message "Created tree file: %s" filename))))

(defun mho/forester--get-title-from-file (filepath)
  "Extract \\title{...} from the first line of FILEPATH."
  (with-temp-buffer
    (insert-file-contents-literally filepath nil 0 200)
    (goto-char (point-min))
    (let ((line (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))))
      (if (string-match "\\\\title{\\([^}]+\\)}" line)
          (string-trim (match-string 1 line))
        "Untitled"))))

(defun mho/forester--collect-tree-files (root)
  "Return an alist of (display . full-path) for all .tree files under ROOT.
If the filename is longer than 4 characters, display '####' as the ID prefix.
Display format: ID | Title"
(let ((files (directory-files-recursively root "\\.tree\\'")))
    (mapcar (lambda (file)
              (let* ((basename (file-name-base (file-name-nondirectory file)))
                     (id (if (= (length basename) 4)
                             basename
                           "####"))
                     (title (mho/forester--get-title-from-file file))
                     (display (format "%s | %s" id title)))
                (cons display file)))
            files)))
(defun mho/forester--insert-link (&optional style)
  "Fuzzy-select a Forester .tree file and insert a link at point.
If STYLE is 'transclude, insert \\transclude{ID}.
If STYLE is 'markdown, insert [Title](ID).
If STYLE is nil, prompt the user."
  (interactive)
  (let* ((style (or style
                    (intern (completing-read "Link style: "
                                             '("transclude" "markdown")
                                             nil t))))
         (root (or (project-root (project-current))
                   (read-directory-name "Forester root: ")))
         (candidates (mho/forester--collect-tree-files root))
         (selection (consult--read (mapcar #'car candidates)
                                   :prompt "Link to: "
                                   :require-match t)))
    (when selection
      (let* ((filepath (cdr (assoc selection candidates)))
             (basename (file-name-base (file-name-nondirectory filepath)))
             (id (if (= (length basename) 4) basename basename)) ;; Always use full ID
             (title (mho/forester--get-title-from-file filepath)))
        (insert
         (pcase style
           ('transclude (format "\\transclude{%s}" id))
           ('markdown   (format "[%s](%s)" title id))
           (_ (user-error "Unknown link style: %s" style))))))))
;;;###autoload

(defun mho/forester--find-node ()
  "Fuzzy-find a Forester .tree file by title or filename using consult."
  (interactive)
  (require 'consult)
  (let* ((root (or (project-root (project-current))
                   (read-directory-name "Forester root: ")))
         (candidates (mho/forester--collect-tree-files root))
         (selection (consult--read (mapcar #'car candidates)
                                   :prompt "Forester Node: "
                                   :require-match t)))
    (when selection
      (find-file (cdr (assoc selection candidates))))))

(defun mho/insert-subtree ()
  "Insert a \\subtree[ID]{\\title{...}} block using a generated 4-character ID and a user-provided title."
  (interactive)
  (let* ((id-file "~/Documents/mho-roam/resources/code/shell/TAGS-tagids.txt")
         (buffer (find-file-noselect id-file))
         full-id)
    ;; Step 1: Get and confirm use of next available ID
    (with-current-buffer buffer
      (goto-char (point-min))
      (let ((first-id (string-trim (buffer-substring-no-properties (point) (line-end-position)))))
        (setq full-id first-id)
        (if (yes-or-no-p (format "Use and remove ID: %s for subtree?" full-id))
            (progn
              (delete-region (point) (1+ (line-end-position)))
              (save-buffer)
              (kill-buffer))
          (user-error "Aborted by user"))))

    ;; Step 2: Prompt for title
    (let ((title (read-string "Subtree title: ")))
      ;; Step 3: Insert the subtree block
      (insert (format "\\subtree[%s]{\n  \\title{%s}\n\n}\n" full-id title)))))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Find Tree"
      "f" #'mho/forester--find-node
      ))

(map! :leader
      (:prefix ("f")
      :desc "Forester find node"
      "n" #'mho/forester--find-node
      ))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Date Insert"
      "d" #'mho/forester--date
      ))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Link Insert"
      "l" #'mho/forester--insert-link
      ))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Tree Insert"
      "n" #'mho/forester--create-tree-file
      ))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Subtree Insert"
      "s" #'mho/insert-subtree
      ))

(map! :leader
      (:prefix ("d" . "Forester")
      :desc "Weeknote"
      "w" #'mho/forester--create-weeknote-file
      ))

;;; --- Rename Org file/buffer based on :ID: and #+title ------------------------

(defun mho/org--slugify-underscore (s)
  "Convert S to a lowercase underscore_slug for filenames."
  (let* ((s (downcase (string-trim (or s ""))))
         ;; Replace anything not alnum with underscores
         (s (replace-regexp-in-string "[^a-z0-9]+" "_" s))
         ;; Collapse runs of underscores
         (s (replace-regexp-in-string "_\\{2,\\}" "_" s))
         ;; Trim underscores at ends
         (s (replace-regexp-in-string "\\`_+\\|_+\\'" "" s)))
    s))

(defun mho/org--read-file-preamble (file)
  "Return a plist (:id ID :title TITLE) by scanning FILE quickly."
  (with-temp-buffer
    (insert-file-contents file)
    (let (id title)
      (goto-char (point-min))
      (when (re-search-forward "^:ID:\\s-*\$begin:math:text$\.\+\\$end:math:text$$" nil t)
        (setq id (string-trim (match-string 1))))
      (goto-char (point-min))
      (when (re-search-forward "^#\\+title:\\s-*\$begin:math:text$\.\*\\$end:math:text$$" nil t)
        (setq title (string-trim (match-string 1))))
      (list :id id :title title))))

(defun mho/org--extract-id-and-title ()
  "Extract file-level :ID: and #+title: from the current buffer.
Returns a plist (:id ID :title TITLE)."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) ;; makes #+TITLE/# +title match
          id title)
      ;; ID: tolerate alignment whitespace, capture token only (your style)
      (when (re-search-forward "^[ \t]*:ID:\\s-+\\([A-Za-z0-9-]+\\)" nil t)
        (setq id (match-string 1)))

      ;; TITLE: tolerate lowercase + extra spaces
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*#\\+TITLE:\\s-*\\(.+\\S-\\)\\s-*$" nil t)
        (setq title (match-string 1)))

      (list :id id :title title))))

(defun mho/org--make-new-basename (id title)
  "Build base filename: ID or ID--slug_title (underscored) if title exists."
  (unless (and id (not (string-empty-p (string-trim id))))
    (error "No :ID: found"))
  (let* ((title (string-trim (or title "")))
         (slug  (mho/org--slugify-underscore title)))
    (if (string-empty-p slug)
        id
      (format "%s--%s" id slug))))

(defun mho/org--unique-path (path)
  "If PATH exists, append _2, _3, ... before extension until unique."
  (if (not (file-exists-p path))
      path
    (let* ((dir (file-name-directory path))
           (base (file-name-base path))
           (ext  (file-name-extension path t))
           (n 2)
           candidate)
      (while (progn
               (setq candidate (expand-file-name (format "%s_%d%s" base n ext) dir))
               (file-exists-p candidate))
        (setq n (1+ n)))
      candidate)))

(defun mho/rename-org-file-based-on-id (&optional file)
  "Rename an Org FILE (or current Org buffer file) using :ID: and #+title.
New base name:
  - ID--title_with_underscores  (if title exists)
  - ID                         (if title missing/empty)
Works in Dired (file at point) or Org buffers (visited file + buffer)."
  (interactive)
  (let* ((in-dired (derived-mode-p 'dired-mode))
         (file (or file
                   (when in-dired (dired-get-file-for-visit))
                   (buffer-file-name))))
    (unless (and file (file-exists-p file))
      (error "No file to rename"))
    (unless (string-match-p "\\.org\\'" file)
      (error "Not an .org file: %s" file))

    (let* ((meta (if (and (not in-dired) (derived-mode-p 'org-mode))
                     (mho/org--extract-id-and-title)
                   (mho/org--read-file-preamble file)))
           (id (plist-get meta :id))
           (title (plist-get meta :title))
           (new-base (mho/org--make-new-basename id title))
           (dir (file-name-directory file))
           (new-path (expand-file-name (concat new-base ".org") dir))
           (new-path (mho/org--unique-path new-path))
           (old-path file))

      (rename-file old-path new-path 1)

      (cond
       (in-dired
        (revert-buffer)
        (dired-goto-file new-path)
        (message "Renamed: %s → %s" old-path new-path))

       ((derived-mode-p 'org-mode)
        (set-visited-file-name new-path t t)
        (rename-buffer (file-name-nondirectory new-path) t)
        (save-buffer)
        (message "Renamed buffer+file: %s" (file-name-nondirectory new-path)))

       (t
        (message "Renamed file: %s" new-path))))))

(global-set-key (kbd "C-c r") #'mho/rename-org-file-based-on-id)

(defun mho/gen-id ()
  "Generate a full_id composed of a date stamp and the first available ID from a
   file, prompt the user before deleting the line, and save the ID to the kill
   ring."
  (interactive)
  (let* ((id-file "~/Documents/mho-roam/resources/code/shell/TAGS-tagids.txt")  ; Adjust the path as needed
         ;;(date-str (format-time-string "%y%m%d"))
         (buffer (find-file-noselect id-file))
         full_id)
    (with-current-buffer buffer
      (goto-char (point-min))
      (let ((first-id (buffer-substring-no-properties (point) (line-end-position))))
        ;;(setq full_id (concat date-str "--" first-id))  ; Changed format for clarity
        (setq full_id first-id)  ; Changed format for clarity
        (if (yes-or-no-p (format "Delete the first line containing ID: %s?" first-id))
            (progn
              (delete-region (point) (1+ (line-end-position)))
              (save-buffer)
              (kill-buffer)
              (kill-new full_id)
              (message "ID %s saved to kill ring" full_id))
          (message "ID generation aborted"))))))

(defvar mho/org-roam-last-id nil "Cache the last generated ID for reuse in the same capture session.")

(defun get-and-update-full-id ()
  ;; "Generate a full_id composed of a date stamp and the first available ID from a file."
  (unless mho/org-roam-last-id
    (setq mho/org-roam-last-id
          (let* ((id-file "~/Documents/mho-roam/resources/code/shell/TAGS-tagids.txt")  ; Adjust the path as needed
                 ;;(date-str (format-time-string "%y%m%d"))
                 (buffer (find-file-noselect id-file))
                 full_id)
            (with-current-buffer buffer
              (goto-char (point-min))
              (let ((first-id (buffer-substring-no-properties (point) (line-end-position))))
                ;;(setq full_id (concat date-str "--" first-id))  ; Changed format for clarity
                (setq full_id first-id)  ; Changed format for clarity
                (delete-region (point) (1+ (line-end-position)))
                (save-buffer)
                (kill-buffer))
              full_id))))
    (message "Using ID: %s" mho/org-roam-last-id)  ; Debug output
  mho/org-roam-last-id)
  (add-hook 'org-capture-after-finalize-hook (lambda () (setq mho/org-roam-last-id nil)))

(setq org-roam-directory "~/Documents/mho-roam")


(use-package! org-roam
  :config
  (cl-defmethod org-roam-node-slug ((node org-roam-node))
    "Return the slug of NODE."
    (let ((title (org-roam-node-title node))
          (slug-trim-chars '(;; Combining Diacritical Marks https://www.unicode.org/charts/PDF/U0300.pdf
                             768 ; U+0300 COMBINING GRAVE ACCENT
                             769 ; U+0301 COMBINING ACUTE ACCENT
                             770 ; U+0302 COMBINING CIRCUMFLEX ACCENT
                             771 ; U+0303 COMBINING TILDE
                             772 ; U+0304 COMBINING MACRON
                             774 ; U+0306 COMBINING BREVE
                             775 ; U+0307 COMBINING DOT ABOVE
                             776 ; U+0308 COMBINING DIAERESIS
                             777 ; U+0309 COMBINING HOOK ABOVE
                             778 ; U+030A COMBINING RING ABOVE
                             779 ; U+030B COMBINING DOUBLE ACUTE ACCENT
                             780 ; U+030C COMBINING CARON
                             795 ; U+031B COMBINING HORN
                             803 ; U+0323 COMBINING DOT BELOW
                             804 ; U+0324 COMBINING DIAERESIS BELOW
                             805 ; U+0325 COMBINING RING BELOW
                             807 ; U+0327 COMBINING CEDILLA
                             813 ; U+032D COMBINING CIRCUMFLEX ACCENT BELOW
                             814 ; U+032E COMBINING BREVE BELOW
                             816 ; U+0330 COMBINING TILDE BELOW
                             817 ; U+0331 COMBINING MACRON BELOW
                             )))
      (cl-flet* ((nonspacing-mark-p (char) (memq char slug-trim-chars))
                 (strip-nonspacing-marks (s) (string-glyph-compose
                                              (apply #'string
                                                     (seq-remove #'nonspacing-mark-p
                                                                 (string-glyph-decompose s)))))
                 (cl-replace (title pair) (replace-regexp-in-string (car pair) (cdr pair) title)))
        (let* ((pairs `(("[^[:alnum:][:digit:]-]" . "-") ;; convert anything not alphanumeric
                        ))                   ;; remove ending underscore
               (slug (-reduce-from #'cl-replace (strip-nonspacing-marks title) pairs)))(downcase slug)))))
  (setq org-roam-node-display-template
        (concat "${id:4}" " " "${title:*} " (propertize "${tags:10}" 'face 'org-tag)))
  (setq org-roam-capture-templates
        '(("d" "default" plain "%?"
           :target (file+head "%(get-and-update-full-id)-${slug}.org" ":PROPERTIES:\n:ID: %(get-and-update-full-id)\n:END:\n#+title: ${title}\n#+date: [%<%Y-%m-%d %a %H:%S>]\n#+filetags:\n\n") :immediate-finish t
           :unnarrowed t)))
  (setq org-roam-dailies-capture-templates
        '(("d" "default" plain "%?"
           :target (file+head "%<%Y-%m-%d>.org" ":PROPERTIES:\n:ID: %<%Y-%m-%d>\n:END:\n#+title: Daily for %<%Y-%m-%d>\n\n")
           :immediate-finish t
           :unnarrowed t)))
(setq org-roam-file-ignore-regexp (rx (or "resources" "typst" "daily" "anki" ".pdf" ".typ"))))
(use-package! websocket
  :after org-roam)
(use-package! org-roam-ui
  :after org-roam ;; or :after org
  ;;         normally we'd recommend hooking orui after org-roam, but since org-roam does not have
  ;;         a hookable mode anymore, you're advised to pick something yourself
  ;;         if you don't care about startup time, use
  ;;  :hook (after-init . org-roam-ui-mode)
  :config
  (setq org-roam-ui-sync-theme t
        org-roam-ui-follow t
        org-roam-ui-update-on-save t
        org-roam-ui-open-on-start t))

(use-package! org-transclusion
  :after org
  :init
  (map!
   :map global-map "C-ö C-h" #'org-transclusion-remove-all
   :map global-map "C-ö C-v" #'org-transclusion-add
   :leader
   :prefix "n"
   :desc "Org Transclusion Mode" "t" #'org-transclusion-mode))

(add-hook 'yaml-mode-hook #'outline-indent-minor-mode)
(add-hook 'yaml-ts-mode-hook #'outline-indent-minor-mode)

;; YAML
(dolist (hook '(yaml-mode yaml-ts-mode-hook))
  (add-hook hook #'(lambda()
                     (setq-local outline-indent-default-offset 2)
                     (setq-local outline-indent-shift-width 2))))

(setq vulpea-db-sync-directories '("~/org/"))
(setq vulpea-create-default-template
      '(:file-name "%(org-id-new)--${slug}.org"
        :tags ("inbox")
        :head "#+created: %<[%Y-%m-%d]>"
        :properties (("CREATED" . "%<[%Y-%m-%d]>"))))
(vulpea-db-autosync-mode +1)

(defcustom mho/id-pool-file
  (expand-file-name "TAGS-tagids.txt" "~/Documents/mho-roam/resources/code/shell/")
  "File containing one unused ID per line (e.g., 4 chars)."
  :type 'file)

(defun mho/id--normalize (s)
  "Trim and normalize an ID string."
  (string-trim (or s "")))

(defun mho/id--valid-p (id)
  "Validate a 4-char ID. Adjust regex if you only want lowercase, etc."
  (string-match-p "\\`[A-Za-z0-9]\\{4\\}\\'" id))

(defun mho/id-pool-pop ()
  "Pop the first available ID from `mho/id-pool-file` and remove it from the file."
  (unless (file-readable-p mho/id-pool-file)
    (error "ID pool file not readable: %s" mho/id-pool-file))
  (let* ((lines (with-temp-buffer
                  (insert-file-contents mho/id-pool-file)
                  (split-string (buffer-string) "\n" t)))
         (next (mho/id--normalize (car lines)))
         (rest (cdr lines)))
    (unless (and next (not (string-empty-p next)))
      (error "ID pool is empty: %s" mho/id-pool-file))
    (unless (mho/id--valid-p next)
      (error "Invalid ID in pool (expected 4 chars): %S" next))
    ;; Rewrite file without the first line
    (with-temp-file mho/id-pool-file
      (insert (mapconcat #'identity rest "\n"))
      (when rest (insert "\n")))
    next))

;;;; --- Unified org-id-new session cache (Vulpea + org-capture) ---------------

(defvar mho/use-short-ids t
  "When non-nil, generate IDs from `mho/id-pool-file` instead of UUIDs.")

(defvar mho/org-id-new--session-active nil
  "Non-nil when we want org-id-new to reuse a single ID across the note-creation session.")

(defvar mho/org-id-new--session-cache nil
  "Alist cache for org-id-new during an active session. Key is PREFIX string, value is ID.")

(defun mho/org-id-new--session-begin ()
  "Begin a new ID session (clears cache)."
  (setq mho/org-id-new--session-active t
        mho/org-id-new--session-cache nil))

(defun mho/org-id-new--session-end ()
  "End the current ID session (clears cache)."
  (setq mho/org-id-new--session-active nil
        mho/org-id-new--session-cache nil))

(defun mho/org-id-new-around (orig-fn &optional prefix)
  "Use pool IDs when enabled. If a session is active, reuse the same ID."
  (if (not mho/use-short-ids)
      (funcall orig-fn prefix)
    (let* ((pfx (or prefix "")))
      (if mho/org-id-new--session-active
          (or (cdr (assoc pfx mho/org-id-new--session-cache))
              (let ((id (mho/id-pool-pop)))
                (when (and prefix (not (string-empty-p prefix)))
                  (setq id (concat prefix id)))
                (push (cons pfx id) mho/org-id-new--session-cache)
                id))
        ;; No session: pop fresh every call
        (let ((id (mho/id-pool-pop)))
          (if (and prefix (not (string-empty-p prefix)))
              (concat prefix id)
            id))))))

(with-eval-after-load 'org-id
  ;; Ensure we don't stack multiple advices
  (advice-remove 'org-id-new #'mho/org-id-new-around)
  (advice-add 'org-id-new :around #'mho/org-id-new-around))

;; Make sure the session ends when capture ends (finalize OR abort)
(with-eval-after-load 'org-capture
  (add-hook 'org-capture-after-finalize-hook #'mho/org-id-new--session-end)
  (add-hook 'org-capture-kill-hook           #'mho/org-id-new--session-end))

;; Start the session *before* Vulpea computes the file name (critical)
(with-eval-after-load 'vulpea
  (defun mho/vulpea-create-around (orig-fn &rest args)
    (mho/org-id-new--session-begin)
    (condition-case err
        (apply orig-fn args)
      (error
       ;; If Vulpea errors before capture starts, don't leave session on
       (mho/org-id-new--session-end)
       (signal (car err) (cdr err)))))

  (advice-add 'vulpea-create :around #'mho/vulpea-create-around))

(defun mho/vulpea-describe-with-id (note)
  "Show ID in a fixed left column, then the title."
  (let ((id (or (vulpea-note-id note) "----"))
        (title (vulpea-note-title note)))
    ;; 6 gives you: 'ABCD␠␠' then title; tweak to taste
    (format "%-6s%s" id title)))

(with-eval-after-load 'vulpea
  (setq vulpea-select-describe-fn #'mho/vulpea-describe-with-id))

(after! yasnippet
  (setq yas-snippet-dirs '("~/.config/doom/snippets"))
(setq yas-triggers-in-field t))

(after! nxml-mode
  (map! :map nxml-mode-map
        :i "TAB" #'yas-next-field
        :i "<tab>" #'yas-next-field))

(defun mho/org-tab-conditional ()
  (interactive)
  (if (yas-active-snippets)
      (yas-next-field-or-maybe-expand)
    (org-cycle)))

(map! :after evil-org
      :map evil-org-mode-map
      :i "<tab>" #'mho/org-tab-conditional)

(defun mho/gen-id-snippet ()
  "Generate a full_id composed of a date stamp and the first available ID from a
   file, prompt the user before deleting the line, and save the ID to the kill
   ring."
  (interactive)
  (let* ((id-file "~/Documents/mho-roam/resources/code/shell/TAGS-tagids.txt")  ; Adjust the path as needed
         ;;(date-str (format-time-string "%y%m%d"))
         (buffer (find-file-noselect id-file))
         full_id)
    (with-current-buffer buffer
      (goto-char (point-min))
      (let ((first-id (buffer-substring-no-properties (point) (line-end-position))))
        ;;(setq full_id (concat date-str "--" first-id))  ; Changed format for clarity
        (setq full_id first-id)  ; Changed format for clarity
        (if (yes-or-no-p (format "Delete the first line containing ID: %s?" first-id))
            (progn
              (delete-region (point) (1+ (line-end-position)))
              (save-buffer)
              (kill-buffer)
              (kill-new full_id)
              (message full_id))
          (message "ID generation aborted"))))))

(use-package laas
  :hook (LaTeX-mode . laas-mode)
  :config ; do whatever here
  (aas-set-snippets 'laas-mode
    "jf" (lambda () (interactive)
           (yas-expand-snippet "\\\\( $1 \\\\) $0"))
    "ägp" (lambda () (interactive)
            (yas-expand-snippet "\\graphicspath{{\\string~/Library/CloudStorage/Dropbox/assets/}}"))
    "ääm" (lambda () (interactive)
            (yas-expand-snippet "\\inputminted{python}{0-tex/py_code-${1:tagID}.py}"))
    ;; set condition!
    :cond #'texmathp ; expand only while in math
    "==" "&="
    "bfb" "\\framebreak%"
    "d1" "\\diff{y}{x}"
    "d2" "\\diff[2]{y}{x}"
    "dx" "\\dl x"
    "dy" "\\dl y"
    "ee" "^"
    "fx" "f(x)"
    "fp" "\\fprime"
    "ffp" "\\fprime (x)"
    "fffp" "\\fprime\\fprime (x)"
    "gx" "g(x)"
    "gp" "g'(x)"
    "ggp" "g''(x)"
    "hx" "h(x)"
    "jg" "\\\\"
    "lg" "\\lg"
    "lc" "\\$0"
    "mst" "\\suchthat"
    "nn" "\\oneg"
    "xx" "\\cdot"
    ;; bind to functions!
    "cr" (lambda () (interactive)
           (yas-expand-snippet "\\cRed{${1:arg}}$0"))
    "sv" (lambda () (interactive)
           (yas-expand-snippet "\\farg{${1:arg}}$0"))
    "ssv" (lambda () (interactive)
            (yas-expand-snippet "\\fargpass{${1:arg}}$0"))
    "sssv" (lambda () (interactive)
             (yas-expand-snippet "\\fargr{${1:arg}}$0"))
    "sit" (lambda () (interactive)
            (yas-expand-snippet "\\shortintertext{$1}$0"))
    "uu" (lambda () (interactive)
           (yas-expand-snippet "\\qty{${1:num}}{${2:unit}}$0"))
    "äf" (lambda () (interactive)
           (yas-expand-snippet "\\dfrac{${1:num}}{${2:den}}$0"))
    "ääf" (lambda () (interactive)
            (yas-expand-snippet "\\rfrac{${1:num}}{${2:den}}$0"))
    "äääf" (lambda () (interactive)
             (yas-expand-snippet "\\frac{${1:num}}{${2:den}}$0"))
    "åå" (lambda () (interactive)
           (yas-expand-snippet "\\mpar{${1:arg}}$0"))
    "åä" (lambda () (interactive)
           (yas-expand-snippet "\\sqpar{${1:terms}}$0"))
    "äa" (lambda () (interactive)
           (yas-expand-snippet "\\abs{${1:arg}}$0"))
    "äb" (lambda () (interactive)
           (yas-expand-snippet "\\set{${1:terms}}$0"))
    "äi" (lambda () (interactive)
           (yas-expand-snippet "\\ds\\int {${1:integrand}}, \\dl{${2:x}}$0"))
    "ääi" (lambda () (interactive)
            (yas-expand-snippet "\\defint{${1:integrand}}{${2:lower lim}}{${3:upper lim}} \\, \\dl{${2:x}}$0"))
    "äääi" (lambda () (interactive)
             (yas-expand-snippet "\\ieval{${1:integrand}}{${2:lower lim}}{${3:upper lim}}$0"))
    "äl" (lambda () (interactive)
           (yas-expand-snippet "\\dstylim{${1:var}}{${2:to}}{${3:expression}}$0"))
    "äs" (lambda () (interactive)
           (yas-expand-snippet "\\sqrt{${1:arg}}$0"))
    "ääs" (lambda () (interactive)
            (yas-expand-snippet "\\sqrt[${1:root}]{${2:arg}}$0"))
    "äääs" (lambda () (interactive)
             (yas-expand-snippet "\\set{${1:terms}}$0"))
    "ät" (lambda () (interactive)
           (yas-expand-snippet "\\text{${1:text}}$0"))
    ;; add accent snippets
    :cond #'laas-object-on-left-condition
    ;; ";sr" (lambda () (interactive) (laas-wrap-previous-object "sqrt"))
    ))

(require 'lorem-ipsum)

(setenv "PATH" "/usr/local/bin:/Library/TeX/texbin/:$PATH" t)

(setq TeX-save-query nil)

(setq TeX-show-compilation t)

(setq TeX-command-extra-options "-shell-escape")

(after! latex
  (add-to-list 'TeX-command-list '("XeLaTeX" "%`xelatex%(mode)%' %t" TeX-run-TeX nil t)))

(setq +latex-viewers '(skim preview))
(setq TeX-view-program-list
      '(("Preview" "/usr/bin/open -a Preview.app %o")
        ("Skim" "/Applications/Skim.app/Contents/SharedSupport/displayline -r -b %n %o %b")))
(setq TeX-view-program-selection
      '((output-dvi "Skim") (output-pdf "Skim") (output-html "open")));;

(setq TeX-source-correlate-mode t)
(setq TeX-source-correlate-start-server t)
(setq TeX-source-correlate-method 'synctex)

(setq org-latex-pdf-process '("LC_ALL=en_US.UTF-8 latexmk -f -pdf -%latex -shell-escape -interaction=nonstopmode -output-directory=%o %f"))

(setq org-directory "~/Documents/mho-roam/")

(use-package! org
  :config
  (setq org-image-actual-width 400)
  ;; Set Org-ID method to use the custom function
  (defun mho/org-id-new ()
    "Generate a new custom ID for Org mode using the custom full ID generator."
    (let ((new-id (get-and-update-full-id)))
      (setq mho/org-roam-last-id new-id)
      new-id))

  ;; Ensure org-id-get-create uses the custom ID generation method
  (defun org-id-get-create (&optional where force)
    "Create an ID for the entry at WHERE and return it. If FORCE is non-nil,
    recreate the ID if one already exists."
    (interactive)
    (let ((id (org-id-get where force)))
      (unless id
        (setq id (mho/org-id-new))
        (org-entry-put where "ID" id))
      id)
    (setq mho/org-roam-last-id nil))

  (setq org-id-method 'org)
  )

(defun mho/org-insert-file-link ()
  "Insert a file link.  At the prompt, enter the filename."
  (interactive)
  (org-insert-link nil (org-link-complete-file)))

(map! :after org
      :map org-mode-map
      :localleader
      "l f" #'mho/org-insert-file-link
)

(use-package! ob-mermaid
  :after org)
(setq ob-mermaid-cli-path "/opt/homebrew/bin/mmdc")
(org-babel-do-load-languages
    'org-babel-load-languages
    '((mermaid . t)
      (scheme . t)
      (swift . t)
      (python . t)
      (your-other-langs . t)))

(use-package! ob-swift
  :after org)

(use-package! ox-typst
  :after org
  :config
  (defun org-typst-template (contents info)
  ;; Always return an empty string
  contents)
  )

(after! org
  ;; C-c c is for capture, it’s good enough for me
  (global-set-key (kbd "C-c a") #'org-agenda)
  (global-set-key (kbd "C-c c") #'org-capture)

  ;; Org Capture Templates
  ;; (setq org-capture-templates
  ;;       (quote (("h" "home" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Home")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_home.org"))
  ;;               ("w" "work" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_work.org"))
  ;;               ("f" "task from [f]ile into inbox" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_file.org"))
  ;;               ("p" "[p]roject" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_project.org"))
  ;;               ("l" "web link" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_weblink.org"))
  ;;               ("e" "exam" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_exam.org"))
  ;;               ("g" "gmail" entry (file+headline "~/Library/CloudStorage/Dropbox/org/gtd.org" "Work")
  ;;                (file "~/Library/CloudStorage/Dropbox/org/template_gmail.org"))
  ;;               )))

  ;; Skip finished items
  (setq org-agenda-todo-ignore-scheduled t)
  (setq org-agenda-todo-ignore-deadlines t)
  (setq org-agenda-skip-deadline-if-done t)
  (setq org-agenda-skip-scheduled-if-done t)

  ;; TODOs Keywords
  (setq org-todo-keywords
        '((sequence "TODO(t)" "NEXT(n)" "ONGOING(o)" "MEET(m)" "PROJ(p)" "|" "DONE(d)")
          (sequence "WAIT(w)"  "|" "CANCEL(c)"))
        )

  ;; Add Week numbers to Agenda Calendar
  ;; (setq calendar-week-start-day 1)
  ;; (copy-face font-lock-constant-face 'calendar-iso-week-face)
  ;; (set-face-attribute 'calendar-iso-week-face nil
  ;;                     :height 1.0
  ;;                     :foreground "#D08770")
  ;; (setq calendar-intermonth-text
  ;;       '(propertize
  ;;         (format "%2d"
  ;;                 (car
  ;;                  (calendar-iso-from-absolute
  ;;                   (calendar-absolute-from-gregorian (list month day year)))))
  ;;         'font-lock-face 'calendar-iso-week-face))
  ;; (setq calendar-intermonth-header
  ;;       (propertize "Wk"                  ; or e.g. "KW" in Germany
  ;;                   'font-lock-face 'calendar-iso-week-header-face)
  ;;       )
  ;; Set default org image to 550
  ;;(setq org-image-actual-width (list 550))

  ;; Add timestamp to completed tasks
  (setq org-log-done 'time
        org-log-into-drawer t
        org-log-state-notes-insert-after-drawers nil)
  ;; Hide emphasis markers on formatted text
  (setq org-hide-emphasis-markers t)
  )
;; Load org-faces to make sure we can set appropriate faces
;;(require 'org-faces)

;; Make sure certain org faces use the fixed-pitch face when variable-pitch-mode is on
;; (set-face-attribute 'org-block nil :foreground nil :inherit 'fixed-pitch)
;; (set-face-attribute 'org-table nil :inherit 'fixed-pitch)
;; (set-face-attribute 'org-formula nil :inherit 'fixed-pitch)
;; (set-face-attribute 'org-code nil :inherit '(shadow fixed-pitch))
;; (set-face-attribute 'org-verbatim nil :inherit '(shadow fixed-pitch))
;; (set-face-attribute 'org-special-keyword nil :inherit '(font-lock-comment-face fixed-pitch))
;; (set-face-attribute 'org-meta-line nil :inherit '(font-lock-comment-face fixed-pitch))
;; (set-face-attribute 'org-checkbox nil :inherit 'fixed-pitch)

(after! hl-todo
  (setq hl-todo-keyword-faces
        `(("MEET" . "#81A1C1")
          ("NEXT" . "#D08770")
          ("ONGOING" . "#A3BE8C")
          ("TODO" . "#88C0D0")
          ("PROJ" . "#EBCB8B")
          ("WAIT" . "#8FBCBB")
          ("CANCEL" . "#BF616A")
          ))
  )

;; ORG-SUPER AGENDA
;; (after! org-agenda
;;   (let ((inhibit-message t))
;;     (org-super-agenda-mode)))

;; (setq org-agenda-skip-scheduled-if-done t
;;       org-agenda-skip-deadline-if-done t
;;       org-agenda-include-deadlines t
;;       org-agenda-block-separator nil
;;       org-agenda-tags-column -80 ;; from testing this seems to be a good value
;;       org-agenda-compact-blocks t)

;; (setq org-agenda-custom-commands
;;       '(("o" "Overview"
;;          ((agenda "" ((org-agenda-span 'day)
;;                       (org-super-agenda-groups
;;                        '((:name "Today"
;;                           :time-grid t
;;                           :date today
;;                           :todo "TODAY"
;;                           :scheduled today
;;                           :order 1)))))
;;           (alltodo "" ((org-agenda-overriding-header "")
;;                        (org-super-agenda-groups
;;                         '((:name "Ongoing"
;;                            :todo "ONGOING"
;;                            :order 0)
;;                           (:name "Important"
;;                            :tag "Important"
;;                            :priority "A"
;;                            :order 1)
;;                           (:name "Due Today"
;;                            :deadline today
;;                            :order 2)
;;                           (:name "Due Soon"
;;                            :deadline future
;;                            :order 3)
;;                           (:name "Overdue"
;;                            :deadline past
;;                            :face error
;;                            :order 4)
;;                           (:name "Projects"
;;                            :todo "PROJ"
;;                            :auto-parent t
;;                            :order 10
;;                            :not (:todo "TODO"))
;;                           (:name "Work"
;;                            :tag "work"
;;                            :auto-parent t
;;                            :order 12)
;;                           (:name "Home"
;;                            :tag "home"
;;                            :order 13)
;;                           (:discard (:todo "DONE"))))))))))
;;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; ORG-POMODORO Sounds
;;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
;; (after! org-pomodoro
;;   (setq org-pomodoro-start-sound "/System/Library/Sounds/Glass.aiff")
;;   (setq org-pomodoro-finished-sound "/System/Library/Sounds/Blow.aiff")
;;   (setq org-pomodoro-short-break-sound "/System/Library/Sounds/Bottle.aiff")
;;   (setq org-pomodoro-long-break-sound "/System/Library/Sounds/Bottle.aiff")
;;   )
;; Function to play the start sound
;; (defun my/org-pomodoro-start-sound ()
;;   (start-process-shell-command
;;    "org-pomodoro-start-sound" nil "afplay /System/Library/Sounds/Glass.aiff"))

;; ;; Function to play the finish sound
;; (defun my/org-pomodoro-finished-sound ()
;;   (start-process-shell-command
;;    "org-pomodoro-finished-sound" nil "afplay /System/Library/Sounds/Blow.aiff"))

;; ;; Function to play the break sound
;; (defun my/org-pomodoro-break-sound ()
;;   (start-process-shell-command
;;    "org-pomodoro-break-sound" nil "afplay /System/Library/Sounds/Bottle.aiff"))

;; ;; Attach custom sounds to org-pomodoro hooks
;; (add-hook 'org-pomodoro-started-hook 'my/org-pomodoro-start-sound)
;; (add-hook 'org-pomodoro-finished-hook 'my/org-pomodoro-finished-sound)
;; (add-hook 'org-pomodoro-break-finished-hook 'my/org-pomodoro-break-sound))

(setq org-archive-location "%s_archive::datetree/")

(after! org-pomodoro
  (setq org-pomodoro-start-sound "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/head_gestures_double_nod.caf")
  (setq org-pomodoro-finished-sound "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/payment_success.aif")
  (setq org-pomodoro-short-break-sound "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/media_handoff.caf")
  (setq org-pomodoro-long-break-sound "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/media_handoff.caf")

;; Function to play the start sound
(defun my/org-pomodoro-start-sound ()
  (start-process-shell-command
   "org-pomodoro-start-sound" nil "afplay /System/Library/Sounds/Glass.aiff"))

;; Function to play the finish sound
(defun my/org-pomodoro-finished-sound ()
  (start-process-shell-command
   "org-pomodoro-finished-sound" nil "afplay /System/Library/Sounds/Blow.aiff"))

;; Function to play the break sound
(defun my/org-pomodoro-break-sound ()
  (start-process-shell-command
   "org-pomodoro-break-sound" nil "afplay /System/Library/Sounds/Bottle.aiff"))

;; Attach custom sounds to org-pomodoro hooks
(add-hook 'org-pomodoro-started-hook 'my/org-pomodoro-start-sound)
(add-hook 'org-pomodoro-finished-hook 'my/org-pomodoro-finished-sound)
(add-hook 'org-pomodoro-break-finished-hook 'my/org-pomodoro-break-sound))

(setq org-startup-folded t)

;;(setq org-babel-python-command "~/anaconda3/bin/python")
;;(after! python
;;  (setq python-shell-interpreter "~/anaconda3/bin/python"))

(with-eval-after-load 'eglot
  (with-eval-after-load 'typst-ts-mode
    (add-to-list 'eglot-server-programs
                 `((typst-ts-mode) .
                   ,(eglot-alternatives `(,typst-ts-lsp-download-path
                                          "tinymist"
                                          "typst-lsp"))))))

;; (use-package! typst-ts-mode
;;   :defer t
;;   :custom (progn
;;   (typst-ts-mode-watch-options "--open")
;;   ;; experimental settings (from the main dev)
;;   (typst-ts-mode-enable-raw-blocks-highlight t)
;;   (typst-ts-mode-highlight-raw-blocks-at-startup t))

;; :config

;; Functions
;; (defun mho/typstfmt-current-buffer ()
;;   "Formats the current typst document using the typstfmt binary."
;;   (interactive)
;;   (if (buffer-file-name)
;;       (shell-command (concat "typstfmt " (shell-quote-argument (buffer-file-name))))
;;     (message "Buffer is not associated with a file.")))

;; ;; Keybindings
;; (map! :map typst-ts-mode-map

;;       :localleader

;;       :desc "View" "v"     #'typst-ts-mode-preview
;;       :desc "Watch" "w"     #'typst-ts-mode-watch-toggle
;;       :desc "Compile" "c"     #'typst-ts-mode-compile-and-preview
;;       :desc "Format" ","    #'mho/typstfmt-current-buffer
;;       )
;; Add typst to list
;; (add-to-list 'treesit-language-source-alist
;;              '(typst "https://github.com/uben0/tree-sitter-typst"))

;; Necessary or else localleader is not detected
;; (add-hook 'typst-ts-mode-hook #'evil-normalize-keymaps))
