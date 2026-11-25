;;; run-tests.el --- Run isolated website tests with Doom's packages -*- lexical-binding: t; -*-

;; Run from the Doom config: emacs --batch -Q -l src/vulpea-site/run-tests.el
;; Override MHO_EMACS_PACKAGE_DIR if your straight build directory differs.
(let* ((packages (or (getenv "MHO_EMACS_PACKAGE_DIR")
                     (expand-file-name
                      (format "~/.config/emacs/.local/straight/build-%d.%d/"
                              emacs-major-version emacs-minor-version))))
       (src (expand-file-name "../" (file-name-directory load-file-name))))
  (unless (file-directory-p packages)
    (error "Set MHO_EMACS_PACKAGE_DIR to Doom's straight package build directory"))
  (dolist (path (directory-files packages t "^[^.].*"))
    (when (file-directory-p path) (add-to-list 'load-path path)))
  (add-to-list 'load-path src))
(dolist (path (split-string (or (getenv "MHO_SITE_EXTRA_LOAD_PATH") "") path-separator t))
  (add-to-list 'load-path path))
(require 'mho-vulpea-site-tests)
(require 'mho-vulpea-site-export-tests)
(ert-run-tests-batch-and-exit)
