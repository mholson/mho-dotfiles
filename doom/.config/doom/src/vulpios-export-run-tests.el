;;; vulpios-export-run-tests.el --- Run isolated exporter tests -*- lexical-binding: t; -*-

;;; Commentary:
;; From the Doom config: emacs --batch -Q -l src/vulpios-export-run-tests.el
;; MHO_EMACS_PACKAGE_DIR can select another straight build directory.
;; VULPEA_REPOS_ROOT can select a straight repos directory containing vulpea/.
;; MHO_VULPIOS_COMPANION_DIRECTORY selects the canonical companion checkout.
;; VULPIOS_EMACS_LOAD_PATH supplies explicit dependency paths (no layout assumptions).
;; VULPIOS_FIXTURE_DIRECTORY optionally receives a real API-generated fixture.
;; Nothing loads the user's Doom configuration or reads their live database.

;;; Code:
(let* ((packages (or (getenv "MHO_EMACS_PACKAGE_DIR")
                     (expand-file-name
                      (format "~/.config/emacs/.local/straight/build-%d.%d/"
                              emacs-major-version emacs-minor-version))))
       (repos (or (getenv "VULPEA_REPOS_ROOT")
                  (expand-file-name "~/.config/emacs/.local/straight/repos/")))
       (vulpea (expand-file-name "vulpea/" repos))
       (paths (getenv "VULPIOS_EMACS_LOAD_PATH")))
  (when (and (null paths) (file-directory-p packages))
    (dolist (path (directory-files packages t "^[^.].*"))
      (when (file-directory-p path) (add-to-list 'load-path path))))
  ;; Prefer the selected Vulpea source checkout so a stale build does not
  ;; silently hide new public API features such as the committed-update hook.
  (when (and (null paths) (file-directory-p repos))
    (dolist (package '("emacsql" "compat" "dash" "s" "f"))
      (let ((path (expand-file-name package repos)))
        (when (file-directory-p path) (add-to-list 'load-path path)))))
  (when (and (null paths) (file-regular-p (expand-file-name "vulpea.el" vulpea)))
    (add-to-list 'load-path vulpea))
  (when paths
    (dolist (path (reverse (split-string paths path-separator t)))
      (unless (file-directory-p path) (error "Missing dependency directory: %s" path))
      (add-to-list 'load-path (expand-file-name path))))
  (unless (locate-library "vulpea-db-query")
    (error "Set VULPEA_REPOS_ROOT or MHO_EMACS_PACKAGE_DIR to installed Vulpea dependencies")))

(add-to-list 'load-path
             (expand-file-name (or (getenv "MHO_VULPIOS_COMPANION_DIRECTORY")
                                   "~/GitHub/vulpios/Companion/Emacs/")))
(require 'vulpios-export)
(require 'vulpios-export-tests)
(when-let* ((directory (getenv "VULPIOS_FIXTURE_DIRECTORY")))
  (vulpios-export-check-capabilities)
  (vulpios-export-test-write-fixture (expand-file-name directory)))
(if (vulpios-export--missing-capabilities)
    (progn
      (message "Unsupported Vulpea: running capability refusal tests only.")
      (ert-run-tests-batch-and-exit "^vulpios-export-capability-"))
  (ert-run-tests-batch-and-exit "^vulpios-export-"))

;;; vulpios-export-run-tests.el ends here
