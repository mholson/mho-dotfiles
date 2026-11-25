;;; check-doom-tangle.el --- Verify the literate source without changing it -*- lexical-binding: t; -*-
(require 'org)
(require 'ob-tangle)
(let* ((root (expand-file-name "../" (file-name-directory (or load-file-name buffer-file-name))))
       (scratch (make-temp-file "vulpios-tangle-" t))
       (source (expand-file-name "config.org" scratch))
       (generated (expand-file-name "config.el" scratch))
       (expected (expand-file-name "config.el" root)))
  (unwind-protect
      (progn
        (copy-file (expand-file-name "config.org" root) source)
        (let ((org-mode-hook nil) (enable-local-variables nil) (enable-local-eval nil)
              (org-confirm-babel-evaluate nil))
          (org-babel-tangle-file source generated "emacs-lisp"))
        (unless (equal (with-temp-buffer (insert-file-contents generated) (buffer-string))
                       (with-temp-buffer (insert-file-contents expected) (buffer-string)))
          (error "config.el differs from config.org; regenerate it with org-babel-tangle-file"))
        (message "PASS: config.org tangles exactly to config.el (%s)" root))
    (delete-directory scratch t)))
