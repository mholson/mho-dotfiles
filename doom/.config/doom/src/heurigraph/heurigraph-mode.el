;;; heurigraph-mode.el --- Minor mode for Heurigraph Typst notes -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 6.4.24
;; Package-Requires: ((emacs "30.2") (heurigraph "6.4.24"))
;; Keywords: tools, languages, typst
;; URL: https://github.com/mholson/Heurigraph
;; SPDX-License-Identifier: MIT OR Apache-2.0

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
  "C-c h e" #'heurigraph-edit
  "C-c h g" #'heurigraph-generate
  "C-c h p" #'heurigraph-problems
  "C-c h f" #'heurigraph-find-node
  "C-c h l" #'heurigraph-insert-link
  "C-c h t" #'heurigraph-insert-transclusion
  "C-c h r" #'heurigraph-insert-assertion
  "C-c h L" #'heurigraph-lsp-start)

(defvar-keymap heurigraph-ontology-mode-map
  :doc "Keymap for editing a Heurigraph ontology registry."
  "C-c h t" #'heurigraph-ontology-insert-taxon
  "C-c h s" #'heurigraph-ontology-insert-subject
  "C-c h p" #'heurigraph-ontology-insert-predicate
  "C-c h S" #'heurigraph-ontology-insert-structure
  "C-c h o" #'heurigraph-ontology-open
  "C-c h e" #'heurigraph-edit
  "C-c h g" #'heurigraph-generate
  "C-c h P" #'heurigraph-problems
  "C-c h L" #'heurigraph-lsp-start)

(defvar-keymap heurigraph-doom-leader-map
  :doc "Heurigraph commands installed below Doom's `SPC e' prefix."
  "e" #'heurigraph-edit
  "g" #'heurigraph-generate
  "p" #'heurigraph-problems
  "f" #'heurigraph-find-node
  "l" #'heurigraph-insert-link
  "t" #'heurigraph-insert-transclusion
  "r" #'heurigraph-insert-assertion
  "L" #'heurigraph-lsp-start)

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
(define-minor-mode heurigraph-note-mode
  "Minor mode for editing Heurigraph notes.
The mode adds title-aware links, transclusion, relationships, validation,
project ontology editing, and language-server commands under `C-c h'."
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
  "Enable Heurigraph authoring and LSP support in governed Typst buffers."
  (when (locate-dominating-file default-directory "heurigraph.toml")
    (heurigraph-note-mode 1)
    (when (and (bound-and-true-p heurigraph-lsp-auto-start)
               (fboundp 'heurigraph-lsp-ensure))
      (heurigraph-lsp-ensure))))

;;;###autoload
(defun heurigraph-enable-for-ontology ()
  "Enable `heurigraph-ontology-mode' in project ontology TOML buffers."
  (when-let* ((root (locate-dominating-file default-directory "heurigraph.toml"))
              (file buffer-file-name)
              (ontology (file-name-as-directory
                         (let ((heurigraph-notes-directory root))
                           (heurigraph--ontology-root-path)))))
    (when (file-in-directory-p (expand-file-name file) ontology)
      (heurigraph-ontology-mode 1))))

(provide 'heurigraph-mode)

;;; heurigraph-mode.el ends here
