;;; heurigraph-lsp.el --- LSP integration for Heurigraph -*- lexical-binding: t; -*-

;; Author: Heurigraph
;; Version: 1.16.3
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, languages, typst

;;; Commentary:

;; Registers `heurigraph lsp' as a project-semantic add-on for Typst buffers.
;; With lsp-mode it can run beside Tinymist or another Typst language server:
;; Tinymist owns Typst syntax and Heurigraph owns forest ids, relations,
;; collections, navigation, and refactors.
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
(declare-function lsp-deferred "lsp-mode")
(declare-function lsp-register-client "lsp-mode")
(declare-function lsp-send-execute-command "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(defvar eglot-server-programs)
(defvar heurigraph-lsp--registered nil)

(defcustom heurigraph-lsp-trace nil
  "When non-nil, start `heurigraph lsp --trace'.
Protocol traffic is written to stderr, never the JSON-RPC stdout stream."
  :type 'boolean
  :group 'heurigraph)

(defun heurigraph-lsp--command ()
  "Return the command used to launch the Heurigraph language server."
  (append (list (heurigraph--require-executable) "lsp")
          (when heurigraph-lsp-trace (list "--trace"))))

(defun heurigraph-lsp--project-p (filename mode)
  "Return non-nil when FILENAME in MODE is a Heurigraph authoring file."
  (when (and filename
             (locate-dominating-file (file-name-directory filename)
                                     "heurigraph.toml"))
    (let* ((root (locate-dominating-file (file-name-directory filename)
                                         "heurigraph.toml"))
           (collections (file-name-as-directory
                         (expand-file-name "collections" root))))
      (or (memq mode '(typst-mode typst-ts-mode))
          (and (memq mode '(toml-mode toml-ts-mode conf-toml-mode))
               (string-prefix-p collections (expand-file-name filename)))))))

(defun heurigraph-lsp-register-lsp-mode ()
  "Register Heurigraph as an add-on client with lsp-mode.
This is safe to call repeatedly.  The client activates only in Typst buffers
inside a directory governed by `heurigraph.toml'."
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
  (message "Heurigraph registered as an lsp-mode add-on"))

(with-eval-after-load 'lsp-mode
  (heurigraph-lsp-register-lsp-mode))

;;;###autoload
(defun heurigraph-lsp-start ()
  "Start editor intelligence for the current Heurigraph buffer.
With lsp-mode installed, start it as an add-on beside the Typst server.  When
only Eglot is available, explain how to select the Heurigraph server."
  (interactive)
  (cond
   ((require 'lsp-mode nil t)
    (heurigraph-lsp-register-lsp-mode)
    (lsp-deferred))
   ((require 'eglot nil t)
    (user-error "Eglot runs one server per buffer; use M-x heurigraph-eglot-enable"))
   (t
    (user-error "Install lsp-mode, or use the built-in Eglot"))))

;;;###autoload
(defun heurigraph-eglot-enable ()
  "Use `heurigraph lsp' as Eglot's server for Typst in this session.
Eglot normally runs one server per buffer, so this may replace Tinymist or a
TOML server in the current buffer.  lsp-mode is preferred when both servers
are wanted."
  (interactive)
  (require 'eglot)
  (let ((entry `((typst-ts-mode typst-mode toml-ts-mode toml-mode conf-toml-mode)
                 . ,(heurigraph-lsp--command))))
    (setq eglot-server-programs
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
  (message "Eglot is using Heurigraph for this Typst buffer"))

;;;###autoload
(defun heurigraph-lsp-refresh ()
  "Ask the active Heurigraph language server to rebuild its workspace index."
  (interactive)
  (cond
   ((and (featurep 'lsp-mode) (bound-and-true-p lsp-mode))
    (lsp-send-execute-command "heurigraph.refresh" []))
   ((and (featurep 'eglot) (eglot-current-server))
    (jsonrpc-request (eglot-current-server)
                     :workspace/executeCommand
                     '(:command "heurigraph.refresh" :arguments [])))
   (t (user-error "No active language server in this buffer"))))

(provide 'heurigraph-lsp)

;;; heurigraph-lsp.el ends here
