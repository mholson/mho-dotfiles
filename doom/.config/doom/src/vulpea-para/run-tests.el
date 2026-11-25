;;; run-tests.el --- Run isolated Vulpea PARA tests -*- lexical-binding: t; -*-

;; Run from the Doom config: emacs --batch -Q -l src/vulpea-para/run-tests.el
;; MHO_EMACS_PACKAGE_DIR selects another straight build directory.
;; MHO_VULPEA_PARA_DIRECTORY can point to an uninstalled package checkout.
(let* ((packages (or (getenv "MHO_EMACS_PACKAGE_DIR")
                     (expand-file-name
                      (format "~/.config/emacs/.local/straight/build-%d.%d/"
                              emacs-major-version emacs-minor-version))))
       (para (getenv "MHO_VULPEA_PARA_DIRECTORY"))
       (src (expand-file-name "../" (file-name-directory load-file-name))))
  (unless (file-directory-p packages)
    (error "Set MHO_EMACS_PACKAGE_DIR to Doom's straight package build directory"))
  (dolist (path (directory-files packages t "^[^.].*"))
    (when (file-directory-p path) (add-to-list 'load-path path)))
  (when para
    (unless (file-regular-p (expand-file-name "vulpea-para.el" para))
      (error "MHO_VULPEA_PARA_DIRECTORY must contain vulpea-para.el"))
    (add-to-list 'load-path (expand-file-name para)))
  (add-to-list 'load-path src))
(require 'mho-vulpea-para-tests)
(ert-run-tests-batch-and-exit "^mho-vulpea-para-")
