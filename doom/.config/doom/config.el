;;; config.el -*- lexical-binding: t; -*-

;; Generated from config.org.

(setq user-full-name "Mark Olson"
      user-mail-address "41911657+mholson@users.noreply.github.com")

(setq epa-file-select-keys nil) ;; disable selection prompt
(setq epa-file-encrypt-to '("AA439838FBBF10FC"))

(setq-default x-stretch-cursor t)

(setq delete-by-moving-to-trash t)

(setq undo-limit 80000000)

(setq evil-want-fine-undo t)

(setq org-directory (expand-file-name "~/Library/Mobile Documents/com~apple~CloudDocs/org/")
      org-agenda-files (list org-directory
                             (expand-file-name "journal/" org-directory)))

(setq display-line-numbers-type 'relative)

(setq password-cache-expiry nil)

(setq scroll-preserve-screen-position 'always
      scroll-margin 4)

(setq-default window-combination-resize t)

(add-to-list 'default-frame-alist '(height . 34))
(add-to-list 'default-frame-alist '(width  . 80))

(setq doom-font (font-spec :family "Iosevka Nerd Font Mono" :size 18))

(setq truncate-string-ellipsis "…")

(setq doom-variable-pitch-font (font-spec :family "Iosevka Nerd Font Mono" :size 16))

(setq doom-big-font (font-spec :family "Iosevka Nerd Font Mono" :size 32 ))

(setq doom-theme 'arctic-archive-dark)

(after! time
  (setq display-time-format "%H:%M  Wk%V"
        display-time-default-load-average nil)
  (display-time-mode 1))

(setq which-key-idle-delay 0.5)

(setq mac-option-modifier nil
      mac-command-modifier 'meta
      mac-right-command-modifier 'control
      mac-control-modifier 'super
      mac-function-modifier 'hyper)

(map! :n "C-å" #'sp-wrap-curly
      :n "M-o" #'sp-up-sexp
      :n "M-b" #'sp-down-sexp)

(define-key key-translation-map (kbd "§") (kbd "\\"))
(map! :i "C-<" (cmd! (insert "{")))

(map! :leader
      (:prefix ("l" . "link")
       :desc "Clipboard" "c" #'org-cliplink
       :desc "File"      "f" #'mho/org-insert-file-link))

(map! :n "C-c a" #'org-agenda
      :n "C-c c" #'org-capture)

(map! :leader
      (:prefix ("å" . "org")
       :desc "Agenda" "å" #'org-agenda
       :desc "Capture" "c" #'org-capture))

(map! :leader
      (:prefix ("v" . "Vulpea")
       :desc "Find or create note" "f" #'vulpea-find
       :desc "New note"            "n" #'mho/vulpea-new-note
       :desc "Insert note link"    "i" #'vulpea-insert
       :desc "Find backlink"       "b" #'vulpea-find-backlink
       :desc "Heading ID"          "h" #'org-id-get-create
       :desc "Toggle sidebar"      "s" #'vulpea-ui-sidebar-toggle
       :desc "Note collection"     "c" #'vulpea-ui-collection
       :desc "Today's journal"     "j" #'vulpea-journal-today
       :desc "Journal for date"    "J" #'vulpea-journal-date
       :desc "Previous journal"    "[" #'vulpea-journal-previous
       :desc "Next journal"        "]" #'vulpea-journal-next
       :desc "Propagate title change" "r" #'vulpea-propagate-title-change
       (:prefix ("T" . "Journal templates")
        :desc "Focus"         "f" #'mho-vulpea-journal-focus
        :desc "Reflection"    "r" #'mho-vulpea-journal-reflection
        :desc "Weekly review" "w" #'mho-vulpea-journal-weekly-review)
       (:prefix ("N" . "New library")
        :desc "Preview"    "p" #'mho-vulpea-library-preview
        :desc "Initialize empty folder" "i" #'mho-vulpea-library-initialize)
       (:prefix ("P" . "PARA")
        :desc "New private area" "A" #'mho-vulpea-para-capture-area
        :desc "New project"      "p" #'mho-vulpea-para-capture-project
        :desc "Find area"        "a" #'vulpea-para-find-area
        :desc "Find project"     "f" #'vulpea-para-find-project
        :desc "Find resource"    "r" #'vulpea-para-find-resource
        :desc "Overview"         "g" #'vulpea-para-agenda-main
        :desc "Area tasks"       "G" #'vulpea-para-agenda-area
        :desc "Archive project"  "x" #'mho-vulpea-project-archive
        :desc "Diagnose PARA"    "d" #'vulpea-para-doctor
        :desc "Backfill agenda"  "b" #'vulpea-para-agenda-backfill)
       (:prefix ("p" . "website")
        :desc "New public note" "n" #'mho-vulpea-site-new
        :desc "Build"           "b" #'mho-vulpea-site-build
        :desc "Preview"         "p" #'mho-vulpea-site-preview
        :desc "Export to site"  "e" #'mho-vulpea-site-export)
       (:prefix ("m" . "metadata")
        :desc "Add"    "a" #'vulpea-meta-add
        :desc "Remove" "r" #'vulpea-meta-remove)
       (:prefix ("a" . "aliases")
        :desc "Add"    "a" #'vulpea-buffer-alias-add
        :desc "Remove" "r" #'vulpea-buffer-alias-remove)
       (:prefix ("t" . "tags")
        :desc "Add"    "a" #'vulpea-buffer-tags-add
        :desc "Remove" "r" #'vulpea-buffer-tags-remove)
       :desc "Scan library"        "u" #'vulpea-db-sync-full-scan
       :desc "Diagnose setup"      "d" #'vulpea-doctor))

(map! :n "C-ö r" #'org-transclusion-remove-all
      :n "C-ö a" #'org-transclusion-add)

(map! :map org-mode-map
      :localleader
      :desc "Org Transclusion Mode"
      "C" #'org-transclusion-mode)

(add-to-list 'load-path (expand-file-name "src/" doom-user-dir))

(defun mho/yaml-outline-indent-setup ()
  "Enable outline-indent with 2-space YAML-friendly defaults."
  (setq-local outline-indent-default-offset 2)
  (setq-local outline-indent-shift-width 2)
  (outline-indent-minor-mode 1))

(defun mho/org-insert-file-link ()
  "Insert an org file link using org's file completion."
  (interactive)
  (org-insert-link nil (org-link-complete-file)))

(defun mho/task-archives-to-datetree ()
  "Archive all completed tasks in the current Org file into a date tree."
  (interactive)
  (org-map-entries
   (lambda ()
     (setq org-map-continue-from (point))
     (org-archive-subtree))
   "/DONE|XOUT" 'file))

(defun mho/vulpea-new-note (title)
  "Create a Vulpea note with TITLE and visit it."
  (interactive "sNote title: ")
  (require 'vulpea)
  (setq title (string-trim title))
  (when (string-empty-p title)
    (user-error "A note needs a title"))
  (vulpea-visit (vulpea-create title)))

(add-hook 'yaml-mode-hook    #'mho/yaml-outline-indent-setup)
(add-hook 'yaml-ts-mode-hook #'mho/yaml-outline-indent-setup)

(setq org-startup-folded t)

(setq org-image-actual-width (list 550))

(setq org-hide-emphasis-markers t)

(after! org-capture
  (require 'mho-vulpea-workflow)
  (mho-vulpea-workflow-setup-captures))

(setq calendar-week-start-day 1)
(copy-face 'font-lock-constant-face 'calendar-iso-week-face)
(set-face-attribute 'calendar-iso-week-face nil
                    :height 1.0
                    :foreground "#D08770")

(setq calendar-intermonth-text
      '(propertize
        (format "%2d"
                (car
                 (calendar-iso-from-absolute
                  (calendar-absolute-from-gregorian (list month day year)))))
        'font-lock-face 'calendar-iso-week-face))

(setq calendar-intermonth-header
      (propertize "Wk" 'font-lock-face 'calendar-iso-week-header-face))

(after! org
  (require 'mho-vulpea-workflow)
  (setq org-todo-keywords mho-vulpea-workflow-keywords)

  (setq org-todo-keyword-faces
        '(("TODO" . "#88C0D0")
          ("PROJ" . "#81A1C1")
          ("NEXT" . "#D08770")
          ("LIVE" . "#A3BE8C")
          ("WAIT" . "#EBCB8B")
          ("SOME" . "#8FBCBB")
          ("DONE" . "#D8DEE9")
          ("XOUT" . "#4C566A"))))

(after! org
  (setq org-priority-lowest ?F
        org-priority-faces
        '((?A . (:foreground "#2ECC71" :weight bold))  ;; (Acute): High Value :: Low Cost
          (?B . (:foreground "#3498DB" :weight bold))  ;; (Build): High Value :: High Cost
          (?C . (:foreground "#F1C40F"))               ;; (Core): Low Value :: Low Cost
          (?D . (:foreground "#E74C3C" :slant italic)) ;; (Drain): avoid
          (?E . (:foreground "#9B59B6"))               ;; (Expand learn)
          (?F . (:foreground "#95A5A6")))))            ;; (Fluff & Finish)

(setq org-agenda-skip-deadline-if-done t
      org-agenda-skip-scheduled-if-done t)

(setq org-log-done 'time
      org-log-into-drawer t)

(setq org-archive-location "%s_archive::datetree/")

(use-package! org-super-agenda
  :after org-agenda
  :config
  (org-super-agenda-mode 1)

  ;; Keep it reliable: one custom command that won't explode on parens
  (setq org-agenda-custom-commands
        '(("o" "Strategic Overview"
           ((agenda ""
                    ((org-agenda-span 'day)
                     (org-agenda-overriding-header "")
                     (org-super-agenda-groups
                      '((:name "Today's Schedule" :time-grid t :order 1)))))

            (alltodo ""
                     ((org-agenda-overriding-header "")
                      (org-super-agenda-groups
                       '((:name "🚀 LIVE" :todo "LIVE" :order 1)
                         (:name "💎 QUICK WINS (A)" :priority "A" :order 2)
                         (:name "🏗️ DEEP WORK (B)" :priority "B" :order 3)
                         (:name "📅 DUE TODAY" :deadline today :order 4)
                         (:name "⌛ OVERDUE" :deadline past :order 5)
                         (:name "📂 PROJECTS" :todo "PROJ" :order 6)
                         (:name "📥 INBOX" :tag "inbox" :order 7)
                         (:discard (:todo ("DONE" "XOUT" "SOME"))))))))))))

(use-package! ob-mermaid :after org)
(use-package! ob-swift   :after org)
(use-package! ox-typst   :after org)

(after! org
  (setq ob-mermaid-cli-path "/opt/homebrew/bin/mmdc")
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((mermaid . t)
     (scheme  . t)
     (swift   . t)
     (python  . t))))

(after! ox-typst
  (defun org-typst-template (contents info)
    "Return CONTENTS unchanged (no extra template wrapper)."
    contents))

(setq org-latex-pdf-process
      '("LC_ALL=en_US.UTF-8 latexmk -f -pdf -%latex -shell-escape -interaction=nonstopmode -output-directory=%o %f"))

(use-package! anki-editor
  :after org)

(use-package! org-transclusion
  :after org)

(autoload 'mho/vulpios-habit-pomodoro "mho-vulpios-habit-focus" nil t)
(autoload 'mho/vulpios-habit-stop "mho-vulpios-habit-focus" nil t)
(autoload 'mho/vulpios-habit-break "mho-vulpios-habit-focus" nil t)

(use-package! vulpea
  :after org
  :demand t
  :init
  (setq vulpea-db-sync-directories (list org-directory)
        vulpea-default-notes-directory org-directory
        vulpea-db-location (expand-file-name "vulpea/icloud-org.db" doom-data-dir)
        vulpea-create-default-template
        '(:file-name "${id}--${slug}.org"
          :tags ("inbox")
          :properties (("CREATED" . "%<[%Y-%m-%d %a]>"))))
  :config
  (require 'mho-vulpea-workflow)
  ;; The companion is optional; missing checkout or invalid opt-in must not
  ;; stop ordinary Vulpea indexing. Identity and enablement remain local.
  (mho-vulpea-workflow-start-exporter
   (expand-file-name "vulpios-export-icloud-org/" doom-data-dir))
  (setq vulpios-export-use-catalog-changes t)
  (vulpea-db-autosync-mode +1))

(use-package! vulpea-para
  :after vulpea
  :demand t
  :config
  (require 'mho-vulpea-para)
  (mho-vulpea-para-setup)
  (require 'mho-vulpea-projects)
  (mho-vulpea-projects-setup)
  (require 'mho-vulpea-library))

(use-package! vulpea-ui
  :after vulpea
  :demand t)

(use-package! vulpea-journal
  :after vulpea-ui
  :demand t
  :config
  (require 'mho-vulpea-journal)
  (mho-vulpea-journal-setup))

(after! vulpea
  (setq mho-vulpea-site-build-directory
        (expand-file-name "vulpea-site/" doom-cache-dir)
        mho-vulpea-site-repository (expand-file-name "~/GitHub/mholson/"))
  (require 'mho-vulpea-site))

(after! yasnippet
  (setq yas-snippet-dirs (list +snippets-dir)
        yas-triggers-in-field t)
  (yas-reload-all)

  ;; Only active inside an expanded snippet
  (define-key yas-keymap (kbd "TAB")       #'yas-next-field)
  (define-key yas-keymap (kbd "<tab>")     #'yas-next-field)
  (define-key yas-keymap (kbd "<backtab>") #'yas-prev-field))

(use-package laas
  :hook (LaTeX-mode . laas-mode)
  :config
  (aas-set-snippets 'laas-mode
                    "jf" (lambda () (interactive)
                           (yas-expand-snippet "\\\\( $1 \\\\) $0"))
                    "jg" "\\\\"
                    :cond #'texmathp
                    "==" "&="
                    "dx" "\\dl x"
                    "dy" "\\dl y"))

(setq TeX-show-compilation t)

(setq TeX-command-extra-options "-shell-escape")

(after! latex
  (add-to-list 'TeX-command-list '("XeLaTeX" "%`xelatex%(mode)%' %t" TeX-run-TeX nil t)))

(setq +latex-viewers '(skim))

(setq TeX-view-program-list
      '(("Preview" "/usr/bin/open -a Preview.app %o")
        ("Skim" "/Applications/Skim.app/Contents/SharedSupport/displayline -r -b %n %o %b")))

(setq TeX-view-program-selection
      '((output-dvi "Skim")
        (output-pdf "Skim")
        (output-html "open")))

(setq TeX-source-correlate-start-server t)
