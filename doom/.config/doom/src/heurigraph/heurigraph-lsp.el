;;; heurigraph-lsp.el --- Eglot integration for Heurigraph -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 6.4.24
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, languages, typst
;; URL: https://github.com/mholson/Heurigraph
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; Runs `heurigraph lsp' through Emacs's built-in Eglot client.  The nearest
;; heurigraph.toml is always the workspace root.  Typst syntax and preview stay
;; editor concerns; Heurigraph owns forest ids, relations, diagnostics, and
;; refactors.

;;; Code:

(require 'heurigraph)
(require 'project)

(declare-function eglot-current-server "eglot")
(declare-function jsonrpc--process "jsonrpc")
(declare-function eglot-ensure "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function jsonrpc-request "jsonrpc")
(defvar eglot-server-programs)
(defvar-local heurigraph-lsp--server nil
  "Eglot server started by Heurigraph in this buffer.")
(defvar-local heurigraph-lsp--argv nil "Exact launch command requested for this buffer.")

(defcustom heurigraph-lsp-trace nil
  "When non-nil, start `heurigraph lsp --trace'."
  :type 'boolean
  :group 'heurigraph)

(defcustom heurigraph-lsp-auto-start t
  "When non-nil, start Heurigraph Eglot support in governed Typst buffers."
  :type 'boolean
  :group 'heurigraph)

(defun heurigraph-lsp--command ()
  "Return the command used to launch the Heurigraph language server."
  (append (list (heurigraph--require-executable) "lsp")
          (when heurigraph-lsp-trace '("--trace"))))

(cl-defmethod project-root ((project (head heurigraph-forest)))
  "Return the root directory stored in Heurigraph PROJECT."
  (cdr project))

(defun heurigraph-lsp--forest-root (&optional path)
  "Return the nearest Heurigraph project containing PATH."
  (when-let* ((path (or path buffer-file-name default-directory))
              (directory (if (file-directory-p path)
                             path
                           (file-name-directory path)))
              (root (locate-dominating-file directory "heurigraph.toml")))
    (file-name-as-directory (expand-file-name root))))

(defun heurigraph-lsp--project-find (directory)
  "Return a Heurigraph project for the forest containing DIRECTORY."
  (when-let ((root (heurigraph-lsp--forest-root directory)))
    (cons 'heurigraph-forest root)))

(defun heurigraph-lsp--configure-project-root ()
  "Make the nearest Heurigraph project authoritative in this buffer."
  (unless (heurigraph-lsp--forest-root)
    (user-error "This buffer is not governed by heurigraph.toml"))
  (add-hook 'project-find-functions #'heurigraph-lsp--project-find nil t)
  (project-root (project-current nil default-directory)))

(defun heurigraph-lsp--active-p ()
  "Return non-nil for an active Heurigraph server in the current buffer."
  (and heurigraph-lsp--server
       (featurep 'eglot)
       (eglot-managed-p)
       (eq heurigraph-lsp--server (eglot-current-server))))

(defun heurigraph-lsp--remember-server ()
  "Capture the server once Eglot finishes its deferred connection."
  (when-let* ((server (and (eglot-managed-p) (eglot-current-server)))
              (process (jsonrpc--process server)))
    (when (and (processp process) heurigraph-lsp--argv
               (equal (process-command process) heurigraph-lsp--argv))
      (setq heurigraph-lsp--server server)
      (remove-hook 'eglot-managed-mode-hook #'heurigraph-lsp--remember-server t))))

;;;###autoload
(defun heurigraph-lsp-ensure ()
  "Start or reuse `heurigraph lsp' through Eglot for this buffer."
  (interactive)
  (cond
   ((heurigraph-lsp--active-p) t)
   ((not (require 'eglot nil t))
    (when (called-interactively-p 'interactive)
      (user-error "Eglot is unavailable in this Emacs installation"))
    nil)
   ((eglot-managed-p)
    (when (called-interactively-p 'interactive)
      (user-error "Another Eglot server already manages this buffer"))
    nil)
   (t
    (heurigraph-lsp--configure-project-root)
    (setq heurigraph-lsp--argv (heurigraph-lsp--command))
    (setq-local eglot-server-programs
                (cons (cons major-mode heurigraph-lsp--argv)
                      eglot-server-programs))
    (add-hook 'eglot-managed-mode-hook #'heurigraph-lsp--remember-server nil t)
    (eglot-ensure)
    (heurigraph-lsp--remember-server)
    t)))

;;;###autoload
(defun heurigraph-lsp-start ()
  "Start Heurigraph editor intelligence for the current buffer."
  (interactive)
  (heurigraph-lsp-ensure))

;;;###autoload
(defun heurigraph-lsp-status ()
  "Report whether Heurigraph Eglot support is active in this buffer."
  (interactive)
  (message "Heurigraph LSP: %s"
           (if (heurigraph-lsp--active-p) "running" "not connected"))
  (heurigraph-lsp--active-p))

;;;###autoload
(defun heurigraph-lsp-refresh ()
  "Ask the active Heurigraph server to rebuild its workspace index."
  (interactive)
  (unless (heurigraph-lsp-refresh-if-active)
    (user-error "No active Heurigraph server in this buffer")))

(defun heurigraph-lsp-refresh-if-active ()
  "Refresh the active Heurigraph workspace and return non-nil when sent."
  (when (heurigraph-lsp--active-p)
    (condition-case error
        (progn
          (jsonrpc-request heurigraph-lsp--server
                           :workspace/executeCommand
                           '(:command "heurigraph.refresh" :arguments []))
          t)
      (error
       (message "Heurigraph LSP refresh failed: %s"
                (error-message-string error))
       nil))))

(provide 'heurigraph-lsp)

;;; heurigraph-lsp.el ends here
