;;; arctic-archive-light-theme.el --- Arctic Archive light theme -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; Author: Mark Olson
;; Keywords: faces, theme
;; Package-Requires: ((emacs "27.1") (doom-themes "2.3.0"))
;;
;;; Commentary:
;;
;; A calm light Doom Emacs theme with roots in Nord and a little more
;; contrast, warmth, and punch.  The palette was created for Heurigraph.
;;
;;; Code:

(require 'doom-themes)

(defgroup arctic-archive-light-theme nil
  "Options for the `arctic-archive-light' theme."
  :group 'doom-themes)

(defcustom arctic-archive-light-padded-modeline doom-themes-padded-modeline
  "If non-nil, add padding to the mode line.
An integer specifies the padding in pixels; t uses four pixels."
  :group 'arctic-archive-light-theme
  :type '(choice integer boolean))

(def-doom-theme arctic-archive-light
  "A calm light theme with roots in Nord and a little more punch."
  :family 'arctic-archive
  :background-mode 'light

  ;; name             GUI        256       16
  ((bg               '("#F4F6F5" "#F4F6F5" nil))
   (bg-alt           '("#E9EEEC" "#E9EEEC" nil))
   (surface          '("#DCE4E1" "#DCE4E1" nil))
   (separator        '("#C8D2CF" "#C8D2CF" nil))
   (focus-wash       '("#B8C8CC" "#B8C8CC" nil))
   (fg               '("#202A2E" "#202A2E" "black"))
   (fg-alt           '("#3D4B50" "#3D4B50" "brightblack"))
   (muted            '("#526267" "#526267" "brightblack"))

   ;; Doom's base scale runs from the strongest background to the strongest
   ;; foreground.  Every value below comes from the Arctic Archive palette.
   (base0            bg)
   (base1            bg-alt)
   (base2            surface)
   (base3            separator)
   (base4            focus-wash)
   (base5            muted)
   (base6            fg-alt)
   (base7            fg)
   (base8            fg)

   (grey             muted)
   (red              '("#A13E45" "#A13E45" "red"))
   (orange           '("#A65332" "#A65332" "brightred"))
   (green            '("#49723F" "#49723F" "green"))
   (teal             '("#2E6F62" "#2E6F62" "brightgreen"))
   (yellow           '("#80601A" "#80601A" "yellow"))
   (blue             '("#315F8C" "#315F8C" "blue"))
   (dark-blue        '("#2F648F" "#2F648F" "brightblue"))
   (magenta          '("#A65332" "#A65332" "magenta"))
   (violet           '("#A65332" "#A65332" "brightmagenta"))
   (cyan             '("#277081" "#277081" "cyan"))
   (dark-cyan        '("#2E6F62" "#2E6F62" "brightcyan"))

   ;; Universal Doom syntax categories.
   (highlight        blue)
   (vertical-bar     separator)
   (selection        focus-wash)
   (builtin          cyan)
   (comments         muted)
   (doc-comments     fg-alt)
   (constants        orange)
   (functions        cyan)
   (keywords         blue)
   (methods          cyan)
   (operators        blue)
   (type             teal)
   (strings          green)
   (variables        fg-alt)
   (numbers          orange)
   (region           focus-wash)
   (error            red)
   (warning          yellow)
   (success          green)
   (vc-modified      orange)
   (vc-added         green)
   (vc-deleted       red)

   (modeline-bg             surface)
   (modeline-bg-inactive    bg-alt)
   (modeline-fg             fg)
   (modeline-fg-inactive    muted)
   (-modeline-pad
    (when arctic-archive-light-padded-modeline
      (if (integerp arctic-archive-light-padded-modeline)
          arctic-archive-light-padded-modeline
        4))))

  (;; Core UI
   ((default &override) :background bg :foreground fg)
   (cursor :background blue)
   (fringe :background bg :foreground separator)
   (hl-line :background bg-alt)
   ((line-number &override) :foreground focus-wash :background bg)
   ((line-number-current-line &override) :foreground blue :background surface :weight 'bold)
   ((region &override) :background focus-wash :foreground fg :extend t)
   (secondary-selection :background separator :extend t)
   (vertical-border :foreground separator)
   (window-divider :foreground separator)
   (window-divider-first-pixel :foreground separator)
   (window-divider-last-pixel :foreground separator)
   (shadow :foreground muted)
   (link :foreground dark-blue :underline t)
   (link-visited :foreground cyan :underline t)
   (button :foreground dark-blue :underline t)
   (minibuffer-prompt :foreground blue :weight 'bold)
   (header-line :background bg-alt :foreground fg-alt :box nil)
   (tooltip :background surface :foreground fg)
   (highlight :background focus-wash :foreground fg)
   (match :background focus-wash :foreground fg :weight 'bold)
   (isearch :background yellow :foreground bg :weight 'bold)
   (lazy-highlight :background separator :foreground fg)
   (show-paren-match :background focus-wash :foreground fg :weight 'bold)
   (show-paren-mismatch :background red :foreground bg :weight 'bold)
   (trailing-whitespace :background red)

   ;; Mode line and doom-modeline
   (mode-line
    :background modeline-bg :foreground modeline-fg
    :box (if -modeline-pad
             `(:line-width ,-modeline-pad :color ,modeline-bg)))
   (mode-line-inactive
    :background modeline-bg-inactive :foreground modeline-fg-inactive
    :box (if -modeline-pad
             `(:line-width ,-modeline-pad :color ,modeline-bg-inactive)))
   (mode-line-emphasis :foreground blue :weight 'bold)
   (mode-line-buffer-id :foreground fg :weight 'bold)
   (doom-modeline-bar :background blue)
   (doom-modeline-bar-inactive :background separator)
   (doom-modeline-buffer-file :foreground fg :weight 'bold)
   (doom-modeline-buffer-path :foreground fg-alt)
   (doom-modeline-buffer-modified :foreground orange :weight 'bold)
   (doom-modeline-project-dir :foreground teal :weight 'bold)
   (doom-modeline-project-root-dir :foreground teal :weight 'bold)
   (doom-modeline-urgent :foreground red :weight 'bold)
   (doom-modeline-warning :foreground yellow :weight 'bold)
   (doom-modeline-info :foreground cyan)

   ;; Font lock
   ((font-lock-comment-face &override) :foreground comments :slant 'italic)
   ((font-lock-doc-face &override) :foreground doc-comments :slant 'italic)
   ((font-lock-keyword-face &override) :foreground keywords :weight 'semi-bold)
   ((font-lock-function-name-face &override) :foreground functions)
   ((font-lock-type-face &override) :foreground type)
   ((font-lock-string-face &override) :foreground strings)
   ((font-lock-constant-face &override) :foreground constants)
   ((font-lock-variable-name-face &override) :foreground variables)
   ((font-lock-builtin-face &override) :foreground builtin)
   ((font-lock-warning-face &override) :foreground warning :weight 'bold)

   ;; Org
   ((org-document-title &override) :foreground fg :weight 'bold :height 1.35)
   ((org-document-info &override) :foreground fg-alt)
   ((org-level-1 &override) :foreground blue :weight 'bold :height 1.20)
   ((org-level-2 &override) :foreground teal :weight 'bold :height 1.12)
   ((org-level-3 &override) :foreground cyan :weight 'bold :height 1.06)
   ((org-level-4 &override) :foreground orange :weight 'bold)
   ((org-level-5 &override) :foreground blue :weight 'semi-bold)
   ((org-level-6 &override) :foreground teal :weight 'semi-bold)
   ((org-block &override) :background bg-alt :foreground fg-alt :extend t)
   ((org-block-begin-line &override) :background surface :foreground muted :extend t)
   ((org-block-end-line &override) :background surface :foreground muted :extend t)
   ((org-code &override) :foreground cyan)
   ((org-verbatim &override) :foreground orange)
   ((org-quote &override) :background surface :foreground fg-alt :slant 'italic :extend t)
   ((org-table &override) :foreground cyan)
   ((org-link &override) :foreground dark-blue :underline t)
   ((org-date &override) :foreground cyan)
   ((org-tag &override) :foreground muted :weight 'normal)
   ((org-todo &override) :foreground yellow :weight 'bold)
   ((org-done &override) :foreground green :weight 'bold)
   ((org-checkbox &override) :foreground teal :weight 'bold)
   ((org-special-keyword &override) :foreground muted)
   ((org-meta-line &override) :foreground muted)
   ((org-hide &override) :foreground bg)
   ((org-agenda-date &override) :foreground blue :weight 'bold)
   ((org-agenda-date-today &override) :foreground orange :weight 'bold)

   ;; Markdown
   ((markdown-header-face &override) :foreground blue :weight 'bold)
   (markdown-header-face-1 :foreground blue :weight 'bold :height 1.20)
   (markdown-header-face-2 :foreground teal :weight 'bold :height 1.12)
   (markdown-header-face-3 :foreground cyan :weight 'bold :height 1.06)
   (markdown-header-face-4 :foreground orange :weight 'bold)
   (markdown-header-face-5 :foreground blue :weight 'semi-bold)
   (markdown-header-face-6 :foreground teal :weight 'semi-bold)
   ((markdown-code-face &override) :background bg-alt :foreground cyan)
   (markdown-inline-code-face :background surface :foreground cyan)
   (markdown-blockquote-face :foreground fg-alt :slant 'italic)
   (markdown-link-face :foreground dark-blue)
   (markdown-url-face :foreground muted :underline t)
   (markdown-list-face :foreground orange)
   (markdown-markup-face :foreground muted)
   (markdown-language-keyword-face :foreground teal)

   ;; Diff and Ediff
   (diff-header :background bg-alt :foreground fg-alt)
   (diff-file-header :background surface :foreground blue :weight 'bold)
   (diff-hunk-header :background surface :foreground cyan)
   (diff-context :foreground muted)
   (diff-added :background (doom-blend green bg 0.09) :foreground green :extend t)
   (diff-removed :background (doom-blend red bg 0.09) :foreground red :extend t)
   (diff-changed :background (doom-blend orange bg 0.09) :foreground orange :extend t)
   (diff-refine-added :background (doom-blend green bg 0.20) :foreground fg :weight 'bold)
   (diff-refine-removed :background (doom-blend red bg 0.20) :foreground fg :weight 'bold)
   (ediff-current-diff-A :background (doom-blend red bg 0.12))
   (ediff-current-diff-B :background (doom-blend green bg 0.12))
   (ediff-current-diff-C :background (doom-blend orange bg 0.12))
   (ediff-fine-diff-A :background (doom-blend red bg 0.25) :weight 'bold)
   (ediff-fine-diff-B :background (doom-blend green bg 0.25) :weight 'bold)
   (ediff-fine-diff-C :background (doom-blend orange bg 0.25) :weight 'bold)

   ;; Diagnostics
   (error :foreground red :weight 'bold)
   (warning :foreground yellow :weight 'bold)
   (success :foreground green :weight 'bold)
   (flycheck-error :underline `(:style wave :color ,red))
   (flycheck-warning :underline `(:style wave :color ,yellow))
   (flycheck-info :underline `(:style wave :color ,cyan))
   (flymake-error :underline `(:style wave :color ,red))
   (flymake-warning :underline `(:style wave :color ,yellow))
   (flymake-note :underline `(:style wave :color ,cyan))
   (lsp-face-highlight-read :background surface)
   (lsp-face-highlight-write :background focus-wash :weight 'bold)
   (lsp-face-highlight-textual :background surface)

   ;; Magit
   (magit-section-heading :foreground blue :weight 'bold)
   (magit-section-highlight :background bg-alt)
   (magit-branch-local :foreground teal)
   (magit-branch-remote :foreground green)
   (magit-branch-current :foreground blue :weight 'bold :box t)
   (magit-hash :foreground muted)
   (magit-tag :foreground yellow)
   (magit-diff-file-heading :foreground fg :weight 'bold)
   (magit-diff-file-heading-highlight :background surface :foreground fg :weight 'bold)
   (magit-diff-hunk-heading :background bg-alt :foreground muted)
   (magit-diff-hunk-heading-highlight :background separator :foreground fg)
   (magit-diff-context :foreground muted)
   (magit-diff-context-highlight :background bg-alt :foreground fg-alt)
   (magit-diff-added :background (doom-blend green bg 0.07) :foreground green)
   (magit-diff-added-highlight :background (doom-blend green bg 0.13) :foreground green)
   (magit-diff-removed :background (doom-blend red bg 0.07) :foreground red)
   (magit-diff-removed-highlight :background (doom-blend red bg 0.13) :foreground red)
   (magit-process-ok :foreground green :weight 'bold)
   (magit-process-ng :foreground red :weight 'bold)

   ;; Company and Corfu completion popups
   (company-tooltip :background surface :foreground fg)
   (company-tooltip-selection :background focus-wash :foreground fg)
   (company-tooltip-common :foreground blue :weight 'bold)
   (company-tooltip-common-selection :foreground dark-blue :weight 'bold)
   (company-tooltip-annotation :foreground cyan)
   (company-tooltip-annotation-selection :foreground cyan)
   (company-scrollbar-bg :background separator)
   (company-scrollbar-fg :background blue)
   (company-preview :foreground muted)
   (company-preview-common :foreground blue)
   (corfu-default :background surface :foreground fg)
   (corfu-current :background focus-wash :foreground fg :weight 'bold)
   (corfu-border :background separator)
   (corfu-annotations :foreground cyan :slant 'italic)
   (corfu-deprecated :foreground muted :strike-through t)

   ;; Vertico and completion matching
   (vertico-current :background focus-wash :foreground fg :extend t)
   (vertico-group-title :foreground blue :weight 'bold)
   (vertico-group-separator :foreground separator :strike-through t)
   (vertico-multiform-unobtrusive :foreground muted)
   (completions-common-part :foreground blue :weight 'bold)
   (completions-first-difference :foreground orange)
   (orderless-match-face-0 :foreground blue :weight 'bold)
   (orderless-match-face-1 :foreground teal :weight 'bold)
   (orderless-match-face-2 :foreground cyan :weight 'bold)
   (orderless-match-face-3 :foreground orange :weight 'bold)

   ;; A few common Doom surfaces
   (which-key-key-face :foreground blue :weight 'bold)
   (which-key-group-description-face :foreground teal)
   (which-key-command-description-face :foreground fg-alt)
   (dired-directory :foreground blue :weight 'bold)
   (dired-symlink :foreground cyan)
   (dired-marked :foreground orange :weight 'bold)
   (solaire-default-face :background bg-alt)
   (solaire-hl-line-face :background surface))

  ;; No variable overrides are required.
  ())

;;; arctic-archive-light-theme.el ends here
