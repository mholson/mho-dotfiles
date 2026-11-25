;;; init.el -*- lexical-binding: t; -*-

;; Run `doom sync` after changing the enabled modules.

(doom! :completion
       (corfu +icons +orderless)
       (vertico +icons)

       :ui
       doom
       dashboard
       (emoji +unicode)
       modeline
       (popup +defaults)
       unicode
       (vc-gutter +pretty)
       vi-tilde-fringe
       workspaces
       zen

       :editor
       (evil +everywhere)
       file-templates
       fold
       multiple-cursors
       snippets

       :emacs
       (dired +icons)
       electric
       ibuffer
       undo

       :term
       eshell

       :checkers
       syntax
       (spell +aspell)

       :tools
       (lookup +dictionary)
       (lsp +peek)
       (magit +forge)
       pdf
       tree-sitter

       :os
       (:if (featurep :system 'macos) macos)

       :lang
       data
       emacs-lisp
       json
       (latex +fold)
       lua
       markdown
       (org +dragndrop +jupyter +present)
       (python +tree-sitter)
       (rust +lsp)
       sh
       swift
       web
       yaml

       :app
       everywhere

       :config
       literate
       (default +bindings +smartparens))
