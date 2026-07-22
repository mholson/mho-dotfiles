;;; heurigraph-mode.el --- Minor mode for Heurigraph Typst notes -*- lexical-binding: t; -*-

;; Version: 1.16.2
;; Package-Requires: ((emacs "30.2") (heurigraph "1.16.2"))

;;; Commentary:

;; Keybindings and buffer-local ergonomics for authoring Heurigraph notes.
;; This file intentionally depends on heurigraph.el, which contains the CLI
;; bridge.  Enable with:
;;   (add-to-list 'load-path "~/path/to/heurigraph/emacs")
;;   (require 'heurigraph-mode)
;;   (add-hook 'typst-ts-mode-hook #'heurigraph-enable-for-typst)
;;   (add-hook 'toml-ts-mode-hook #'heurigraph-enable-for-ontology)
;; or use dir-locals in a forest.

;;; Code:

(require 'heurigraph)
(require 'heurigraph-lsp nil t)

(defvar doom-leader-map)

(defvar-keymap heurigraph-note-mode-map
  :doc "Keymap for `heurigraph-note-mode'."
  "C-c h n" #'heurigraph-new
  "C-c h p" #'heurigraph-new-page
  "C-c h c" #'heurigraph-new-content
  "C-c h j" #'heurigraph-new-journal
  "C-c h W" #'heurigraph-new-weeknote
  "C-c h D" #'heurigraph-new-diagram
  "C-c h i" #'heurigraph-insert-diagram
  "C-c h A" #'heurigraph-add-subjects
  "C-c h V" #'heurigraph-toggle-public
  "C-c h f" #'heurigraph-find-node
  "C-c h l" #'heurigraph-insert-link
  "C-c h t" #'heurigraph-insert-transclusion
  "C-c h r" #'heurigraph-insert-assertion
  "C-c h R" #'heurigraph-insert-depends-on
  "C-c h u" #'heurigraph-insert-uses
  "C-c h e" #'heurigraph-insert-enables-method
  "C-c h x" #'heurigraph-insert-solution-to
  "C-c h s" #'heurigraph-insert-strategy-for
  "C-c h m" #'heurigraph-insert-addresses
  "C-c h v" #'heurigraph-validate
  "C-c h S" #'heurigraph-scan
  "C-c h b" #'heurigraph-build
  "C-c h B" #'heurigraph-build-all
  "C-c h w" #'heurigraph-watch
  "C-c h d" #'heurigraph-doctor
  "C-c h g" #'heurigraph-open-graph-page
  "C-c h o" #'heurigraph-open-site
  "C-c h P" #'heurigraph-pdf
  "C-c h a" #'heurigraph-agent-context
  "C-c h q" #'heurigraph-suggest-list
  "C-c h O" #'heurigraph-ontology-open
  "C-c h F" #'heurigraph-refresh-completions
  "C-c h L" #'heurigraph-lsp-start
  "C-c h I" #'heurigraph-lsp-refresh
  "C-c h C" #'heurigraph-book-find-containing-tree)

(defvar-keymap heurigraph-collection-mode-map
  :doc "Keymap for `heurigraph-collection-mode'."
  "C-c h c" #'heurigraph-book-check
  "C-c h b" #'heurigraph-book-build
  "C-c h p" #'heurigraph-book-preview
  "C-c h o" #'heurigraph-book-open-output
  "C-c h s" #'heurigraph-book-select-profile
  "C-c h j" #'heurigraph-book-jump-to-tree
  "C-c h e" #'heurigraph-book-insert-entry-block
  "C-c h t" #'heurigraph-book-insert-prose-block
  "C-c h x" #'heurigraph-book-insert-exercise-block
  "C-c h L" #'heurigraph-lsp-start
  "C-c h I" #'heurigraph-lsp-refresh)

(defvar-keymap heurigraph-ontology-mode-map
  :doc "Keymap for editing a Heurigraph ontology registry."
  "C-c h t" #'heurigraph-ontology-insert-taxon
  "C-c h s" #'heurigraph-ontology-insert-subject
  "C-c h p" #'heurigraph-ontology-insert-predicate
  "C-c h S" #'heurigraph-ontology-insert-structure
  "C-c h o" #'heurigraph-ontology-open
  "C-c h r" #'heurigraph-ontology-refresh
  "C-c h v" #'heurigraph-validate)

(defvar-keymap heurigraph-doom-leader-map
  :doc "Heurigraph commands installed below Doom's `SPC e' prefix."
  "n" #'heurigraph-new
  "p" #'heurigraph-new-page
  "c" #'heurigraph-new-content
  "j" #'heurigraph-new-journal
  "W" #'heurigraph-new-weeknote
  "D" #'heurigraph-new-diagram
  "i" #'heurigraph-insert-diagram
  "A" #'heurigraph-add-subjects
  "V" #'heurigraph-toggle-public
  "f" #'heurigraph-find-node
  "l" #'heurigraph-insert-link
  "t" #'heurigraph-insert-transclusion
  "r" #'heurigraph-insert-assertion
  "R" #'heurigraph-rename-id
  "v" #'heurigraph-validate
  "b" #'heurigraph-build
  "B" #'heurigraph-build-all
  "w" #'heurigraph-watch
  "g" #'heurigraph-open-graph-page
  "O" #'heurigraph-ontology-open
  "F" #'heurigraph-refresh-completions
  "P" #'heurigraph-pdf
  "L" #'heurigraph-lsp-start
  "I" #'heurigraph-lsp-refresh)

;;;###autoload
(defun heurigraph-doom-setup-keybindings ()
  "Install Heurigraph's Doom leader bindings under `SPC e'.
Call this from Doom's config.el after loading `heurigraph-mode'.  In a
non-Evil Doom session the same leader map is reached through Doom's alternate
leader key."
  (interactive)
  (if (boundp 'doom-leader-map)
      (progn
        (define-key doom-leader-map (kbd "e") heurigraph-doom-leader-map)
        (message "Heurigraph commands installed under SPC e"))
    (user-error "Doom's leader map is unavailable; run this after Doom loads")))

;;;###autoload
(define-minor-mode heurigraph-collection-mode
  "Minor mode for editing declarative Heurigraph collection manifests.
The mode exposes validation, profile selection, PDF build/preview, output
opening, tree navigation, and language-server commands under `C-c h'."
  :lighter " HeuriBook"
  :keymap heurigraph-collection-mode-map)

;;;###autoload
(define-minor-mode heurigraph-note-mode
  "Minor mode for editing Heurigraph notes.
The mode adds title-aware link/transclusion commands, validation/build
commands, PDF compilation, graph navigation, and the suggestion queue under
`C-c h'."
  :lighter " Heuri"
  :keymap heurigraph-note-mode-map)

;;;###autoload
(define-minor-mode heurigraph-ontology-mode
  "Minor mode for editing the project-owned Heurigraph ontology.
The mode provides validated TOML skeletons for taxons, subjects, predicates,
and mathematical structures, plus registry refresh and forest validation."
  :lighter " HeuriOnt"
  :keymap heurigraph-ontology-mode-map)

;;;###autoload
(defun heurigraph-enable-for-typst ()
  "Enable `heurigraph-note-mode' in Typst buffers inside a Heurigraph project."
  (when (locate-dominating-file default-directory "heurigraph.toml")
    (heurigraph-note-mode 1)))

;;;###autoload
(defun heurigraph-enable-for-collection ()
  "Enable `heurigraph-collection-mode' in project collection TOML buffers."
  (when-let* ((root (locate-dominating-file default-directory "heurigraph.toml"))
              (file buffer-file-name)
              (collections (file-name-as-directory
                            (expand-file-name "collections" root))))
    (when (string-prefix-p collections (expand-file-name file))
      (heurigraph-collection-mode 1))))

;;;###autoload
(defun heurigraph-enable-for-ontology ()
  "Enable `heurigraph-ontology-mode' in project ontology TOML buffers."
  (when-let* ((root (locate-dominating-file default-directory "heurigraph.toml"))
              (file buffer-file-name)
              (ontology (file-name-as-directory
                         (let ((heurigraph-notes-directory root))
                           (heurigraph--ontology-root-path)))))
    (when (string-prefix-p ontology (expand-file-name file))
      (heurigraph-ontology-mode 1))))

(provide 'heurigraph-mode)

;;; heurigraph-mode.el ends here
