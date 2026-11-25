;;; check-workflow.el --- Isolated cross-editor workflow suite -*- lexical-binding: t; -*-
(let* ((packages (or (getenv "MHO_EMACS_PACKAGE_DIR")
                     (expand-file-name (format "~/.config/emacs/.local/straight/build-%d.%d/" emacs-major-version emacs-minor-version))))
       (paths (getenv "VULPIOS_EMACS_LOAD_PATH")))
  (when (and (null paths) (file-directory-p packages))
    (dolist (path (directory-files packages t "^[^.].*"))
      (when (file-directory-p path) (add-to-list 'load-path path))))
  (when paths
    (dolist (path (reverse (split-string paths path-separator t))) (add-to-list 'load-path path)))
  (add-to-list 'load-path (expand-file-name "../" (file-name-directory load-file-name))))
(require 'mho-vulpea-workflow-tests)
(ert-run-tests-batch-and-exit "^mho-vulpea-\\(?:workflow\\|para\\)-")
