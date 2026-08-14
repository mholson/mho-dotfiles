;;; heurigraph-lsp.el --- LSP integration for Heurigraph -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 4.2.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, languages, typst
;; URL: https://github.com/mholson/Heurigraph
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; Registers `heurigraph lsp' as a persistent project-semantic add-on for Typst
;; buffers.  With lsp-mode it runs beside Tinymist: Tinymist owns Typst syntax,
;; formatting, and preview while Heurigraph owns forest ids, relations,
;; ontology-aware navigation, and refactors.
;;
;; Eglot generally manages one server per buffer.  `heurigraph-eglot-enable'
;; therefore selects Heurigraph as the Typst server for the current session;
;; use it when forest semantics matter more than a separate Typst server.

;;; Code:

(require 'heurigraph)
(require 'jsonrpc)
(require 'seq)
(require 'subr-x)

(declare-function eglot-current-server "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function lsp-deferred "lsp-mode")
(declare-function lsp-register-client "lsp-mode")
(declare-function lsp-send-execute-command "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function lsp--client-server-id "lsp-mode")
(declare-function lsp--workspace-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(defvar eglot-server-programs)
(defvar lsp--cur-workspace)
(defvar lsp-enabled-clients)
(defvar lsp-keep-workspace-alive)
(defvar lsp-mode)
(defvar heurigraph-lsp--registered nil)
(defvar-local heurigraph-eglot--server nil)
(defvar heurigraph-lsp-extra-project-file-functions nil
  "Functions that recognize module-owned project files.
Each function receives FILE, MODE, and project ROOT and should return non-nil
when the language server should manage that file.")

(defcustom heurigraph-lsp-trace nil
  "When non-nil, start `heurigraph lsp --trace'.
Protocol traffic is written to stderr, never the JSON-RPC stdout stream."
  :type 'boolean
  :group 'heurigraph)

(defcustom heurigraph-lsp-auto-start t
  "When non-nil, start persistent lsp-mode clients in Heurigraph buffers.
Typst buffers enable both Tinymist and Heurigraph.  Other supported buffers
enable Heurigraph alone when LSP startup is requested.  The clients remain
alive while other buffers in the same repository are visited."
  :type 'boolean
  :group 'heurigraph)

(defun heurigraph-lsp--command ()
  "Return the command used to launch the Heurigraph language server."
  (append (list (heurigraph--require-executable) "lsp")
          (when heurigraph-lsp-trace (list "--trace"))))

(defun heurigraph-lsp--project-p (filename mode)
  "Return non-nil when FILENAME in MODE is a Heurigraph authoring file."
  (when-let* ((filename filename)
              (root (locate-dominating-file (file-name-directory filename)
                                            "heurigraph.toml")))
    (let ((file (expand-file-name filename)))
      (or (memq mode '(typst-mode typst-ts-mode))
          (run-hook-with-args-until-success
           'heurigraph-lsp-extra-project-file-functions file mode root)))))

(defun heurigraph-lsp-register-lsp-mode ()
  "Register Heurigraph as an add-on client with lsp-mode.
This is safe to call repeatedly.  The client activates only in Typst and
module-recognized buffers governed by `heurigraph.toml'."
  (interactive)
  (require 'lsp-mode)
  (unless heurigraph-lsp--registered
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection #'heurigraph-lsp--command)
      :activation-fn #'heurigraph-lsp--project-p
      :server-id 'heurigraph
      :priority -1
      :add-on? t
      :multi-root nil))
    (setq heurigraph-lsp--registered t))
  (when (called-interactively-p 'interactive)
    (message "Heurigraph registered as an lsp-mode add-on")))

(with-eval-after-load 'lsp-mode
  (heurigraph-lsp-register-lsp-mode))

(defun heurigraph-lsp--eglot-managed-p ()
  "Return non-nil when Eglot already manages the current buffer."
  (and (featurep 'eglot)
       (fboundp 'eglot-managed-p)
       (eglot-managed-p)))

(defun heurigraph-lsp--requested-clients ()
  "Return lsp-mode client ids required by the current buffer."
  (if (memq major-mode '(typst-mode typst-ts-mode))
      '(tinymist heurigraph)
    '(heurigraph)))

;;;###autoload
(defun heurigraph-lsp-ensure ()
  "Ensure the appropriate persistent Heurigraph lsp-mode clients are running.
In Typst buffers this explicitly enables both Tinymist and the Heurigraph
add-on.  Existing workspaces for the repository are reused rather than
restarted."
  (interactive)
  (cond
   ((heurigraph-lsp--eglot-managed-p)
    (if (called-interactively-p 'interactive)
        (user-error
         "Eglot already manages this buffer; use lsp-mode for concurrent Tinymist and Heurigraph")
      (message
       "Heurigraph LSP not started: Eglot owns this buffer; use lsp-mode for both servers")
      nil))
   ((not (require 'lsp-mode nil t))
    (when (called-interactively-p 'interactive)
      (user-error "Install lsp-mode to run Tinymist and Heurigraph together"))
    nil)
   (t
    ;; Loading the built-in lsp-mode Typst client here makes the two-client
    ;; contract explicit instead of depending on package autoload order.
    (when (memq major-mode '(typst-mode typst-ts-mode))
      (require 'lsp-typst nil t))
    (heurigraph-lsp-register-lsp-mode)
    (setq-local lsp-enabled-clients
                (delete-dups
                 (append (heurigraph-lsp--requested-clients)
                         (and (boundp 'lsp-enabled-clients)
                              lsp-enabled-clients))))
    (setq-local lsp-keep-workspace-alive t)
    (lsp-deferred)
    t)))

;;;###autoload
(defun heurigraph-lsp-start ()
  "Start persistent editor intelligence for the current Heurigraph buffer.
Typst buffers start Tinymist and Heurigraph together through lsp-mode."
  (interactive)
  (heurigraph-lsp-ensure))

;;;###autoload
(defun heurigraph-eglot-enable ()
  "Use `heurigraph lsp' as Eglot's server for Typst in this session.
The command is limited to Typst buffers governed by `heurigraph.toml'.  Eglot
normally runs one server per buffer, so stop an existing server first when
switching from Tinymist.  lsp-mode is preferred when both servers are wanted."
  (interactive)
  (require 'eglot)
  (unless (memq major-mode '(typst-mode typst-ts-mode))
    (user-error "Heurigraph's Eglot helper is only for Typst buffers"))
  (unless (and buffer-file-name
               (locate-dominating-file (file-name-directory buffer-file-name)
                                       "heurigraph.toml"))
    (user-error "This Typst buffer is not governed by heurigraph.toml"))
  (when (bound-and-true-p lsp-mode)
    (user-error "LSP mode already manages this buffer; do not combine it with Eglot"))
  (when (eglot-managed-p)
    (user-error "Eglot already manages this buffer; stop it before selecting Heurigraph"))
  (let ((entry `((typst-ts-mode typst-mode)
                 . ,(heurigraph-lsp--command))))
    (setq-local eglot-server-programs
          (cons entry
                (seq-remove
                 (lambda (candidate)
                   (let ((key (car-safe candidate)))
                     (or (eq key 'typst-mode)
                         (eq key 'typst-ts-mode)
                         (and (listp key)
                              (or (memq 'typst-ts-mode key)
                                  (memq 'typst-mode key))))))
                 eglot-server-programs))))
  (eglot-ensure)
  (setq heurigraph-eglot--server (eglot-current-server))
  (message "Eglot is using Heurigraph for this Typst buffer"))

(defun heurigraph-lsp--eglot-server-active-p ()
  "Return non-nil when Eglot still has the server selected by Heurigraph."
  (and heurigraph-eglot--server
       (featurep 'eglot)
       (eq heurigraph-eglot--server (eglot-current-server))))

(defun heurigraph-lsp--workspace-by-server-id (server-id)
  "Return the current lsp-mode workspace belonging to SERVER-ID."
  (when (and (featurep 'lsp-mode) (fboundp 'lsp-workspaces))
    (seq-find
     (lambda (workspace)
       (eq (lsp--client-server-id (lsp--workspace-client workspace))
           server-id))
     (lsp-workspaces))))

;;;###autoload
(defun heurigraph-lsp-status ()
  "Report whether Tinymist and Heurigraph are active in the current buffer."
  (interactive)
  (let ((tinymist (heurigraph-lsp--workspace-by-server-id 'tinymist))
        (heurigraph (heurigraph-lsp--workspace-by-server-id 'heurigraph))
        (eglot (heurigraph-lsp--eglot-server-active-p)))
    (message "Tinymist: %s; Heurigraph: %s"
             (if tinymist "running" "not connected")
             (cond (heurigraph "running (lsp-mode)")
                   (eglot "running (Eglot)")
                   (t "not connected")))
    (or heurigraph eglot)))

;;;###autoload
(defun heurigraph-lsp-refresh ()
  "Ask the active Heurigraph language server to rebuild its workspace index."
  (interactive)
  (unless (heurigraph-lsp-refresh-if-active)
    (user-error "No active language server in this buffer")))

(defun heurigraph-lsp-refresh-if-active ()
  "Refresh the active Heurigraph workspace, returning non-nil when sent.
Unlike `heurigraph-lsp-refresh', this is safe for creation helpers to call when
the language server integration is installed but inactive in the current
buffer."
  (condition-case error
      (cond
       ((and (featurep 'lsp-mode)
             (bound-and-true-p lsp-mode)
             (heurigraph-lsp--workspace-by-server-id 'heurigraph))
        (let ((lsp--cur-workspace
               (heurigraph-lsp--workspace-by-server-id 'heurigraph)))
          (lsp-send-execute-command "heurigraph.refresh" []))
        t)
       ((heurigraph-lsp--eglot-server-active-p)
        (jsonrpc-request heurigraph-eglot--server
                         :workspace/executeCommand
                         '(:command "heurigraph.refresh" :arguments []))
        t)
       (t nil))
    (error
     (message "Heurigraph created the file, but LSP refresh failed: %s"
              (error-message-string error))
     nil)))

(provide 'heurigraph-lsp)

;;; heurigraph-lsp.el ends here
