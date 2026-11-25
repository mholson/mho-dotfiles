;;; mho-vulpea-site-export-tests.el --- Local export tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'mho-vulpea-site-export)
(defvar mho-vulpea-site-repository)

(defun mho-vulpea-site-export-test--write (root route content)
  (let ((path (expand-file-name route root)))
    (make-directory (file-name-directory path) t)
    (write-region content nil path nil 'silent)))

(defun mho-vulpea-site-export-test--read (root route)
  (with-temp-buffer
    (insert-file-contents (expand-file-name route root))
    (buffer-string)))

(defun mho-vulpea-site-export-test--manifest (root files)
  (mho-vulpea-site-export-test--write
   root ".vulpea-site-manifest.json"
   (json-serialize (list :version 1 :files (vconcat files)))))

(defmacro mho-vulpea-site-export-test--workspace (&rest body)
  (declare (indent 0))
  `(let* ((parent (file-truename (make-temp-file "vulpea-export-" t)))
          (stage (expand-file-name "stage/" parent))
          (target (expand-file-name "repository/" parent))
          (mho-vulpea-site-repository target)
          git-before)
     (unwind-protect
         (progn
           (make-directory stage)
           (make-directory target)
           (should (zerop (call-process "git" nil nil nil "init" "--quiet" target)))
           (setq git-before (mho-vulpea-site-export-test--read target ".git/config"))
           (cl-letf (((symbol-function 'mho-vulpea-site-build) (lambda () stage)))
             ,@body))
       (delete-directory parent t))))

(ert-deftest mho-vulpea-site-export-preserves-existing-site ()
  (mho-vulpea-site-export-test--workspace
    (dolist (file '("mho-0002.html" "assets/existing.webp" "CNAME" ".nojekyll"))
      (mho-vulpea-site-export-test--write target file (concat "original " file)))
    (mho-vulpea-site-export-test--write target "index.html" "old archive")
    (let ((files (list "index.html" "feed.xml" "notes/1234-abcd.html" "assets/vulpea-site.css"
                       "assets/vulpea-site-logo.svg" "assets/vulpea-site-mark.svg"
                       (concat "media/" (make-string 64 ?a) ".png"))))
      (dolist (file files) (mho-vulpea-site-export-test--write stage file (concat "new " file)))
      (mho-vulpea-site-export-test--manifest stage files)
      (should (equal (mho-vulpea-site-export) target))
      (should (equal (mho-vulpea-site-export-test--read target "index.html") "new index.html"))
      (should (equal (mho-vulpea-site-export-test--read target "assets/vulpea-site-mark.svg")
                     "new assets/vulpea-site-mark.svg"))
      (should (equal (mho-vulpea-site-export--read-manifest target) files)))
    (dolist (file '("mho-0002.html" "assets/existing.webp" "CNAME" ".nojekyll"))
      (should (equal (mho-vulpea-site-export-test--read target file) (concat "original " file))))
    (should (equal (mho-vulpea-site-export-test--read target ".git/config") git-before))))

(ert-deftest mho-vulpea-site-export-withdraws-only-previously-managed-files ()
  (mho-vulpea-site-export-test--workspace
    (let ((old '("index.html" "notes/withdrawn.html" "assets/vulpios.icns"))
          (new '("index.html" "notes/new.html")))
      (dolist (file old) (mho-vulpea-site-export-test--write target file "old"))
      (mho-vulpea-site-export-test--write target "notes/unmanaged.html" "keep")
      (mho-vulpea-site-export-test--manifest target old)
      (dolist (file new) (mho-vulpea-site-export-test--write stage file "new"))
      (mho-vulpea-site-export-test--manifest stage new)
      (mho-vulpea-site-export)
      (should-not (file-exists-p (expand-file-name "notes/withdrawn.html" target)))
      (should-not (file-exists-p (expand-file-name "assets/vulpios.icns" target)))
      (should (equal (mho-vulpea-site-export-test--read target "notes/unmanaged.html") "keep"))
      (should (equal (mho-vulpea-site-export-test--read target "index.html") "new"))
      (should (equal (mho-vulpea-site-export--read-manifest target) new)))))

(ert-deftest mho-vulpea-site-export-rejects-unmanaged-collision-before-writing ()
  (mho-vulpea-site-export-test--workspace
    (mho-vulpea-site-export-test--write target "index.html" "old archive")
    (mho-vulpea-site-export-test--write target "notes/new.html" "unmanaged")
    (dolist (file '("index.html" "notes/new.html"))
      (mho-vulpea-site-export-test--write stage file "new"))
    (mho-vulpea-site-export-test--manifest stage '("index.html" "notes/new.html"))
    (should-error (mho-vulpea-site-export) :type 'user-error)
    (should (equal (mho-vulpea-site-export-test--read target "index.html") "old archive"))
    (should (equal (mho-vulpea-site-export-test--read target "notes/new.html") "unmanaged"))
    (should-not (file-exists-p (expand-file-name ".vulpea-site-manifest.json" target)))))

(ert-deftest mho-vulpea-site-export-validates-manifest-schema-and-routes ()
  (mho-vulpea-site-export-test--workspace
    (mho-vulpea-site-export-test--write target "index.html" "unchanged")
    (dolist (manifest '("{}" "null" "[]" "{\"version\":2,\"files\":[]}"
                        "{\"version\":1,\"files\":null}"
                        "{\"version\":1,\"files\":\"index.html\"}"
                        "{\"version\":1,\"files\":[\"index.html\",\"index.html\"]}"
                        "{\"version\":1,\"files\":[\"../outside\"]}"
                        "{\"version\":1,\"files\":[\"notes/../../outside.html\"]}"
                        "{\"version\":1,\"files\":[\"/tmp/outside\"]}"
                        "{\"version\":1,\"files\":[\".git/config\"]}"
                        "{\"version\":1,\"files\":[\"CNAME\"]}"
                        "{\"version\":1,\"files\":[\"assets/existing.webp\"]}"
                        "{\"version\":1,\"files\":[\"assets/vulpios.icns\"]}"))
      (mho-vulpea-site-export-test--write stage ".vulpea-site-manifest.json" manifest)
      (should-error (mho-vulpea-site-export) :type 'user-error)
      (should (equal (mho-vulpea-site-export-test--read target "index.html") "unchanged")))
    (mho-vulpea-site-export-test--manifest stage nil)
    (mho-vulpea-site-export-test--manifest target '(".git/config"))
    (should-error (mho-vulpea-site-export) :type 'user-error)
    (should (equal (mho-vulpea-site-export-test--read target ".git/config") git-before))))

(ert-deftest mho-vulpea-site-export-rejects-symlinks-before-writing ()
  (mho-vulpea-site-export-test--workspace
    (let ((outside (expand-file-name "outside/" parent)))
      (make-directory outside)
      (mho-vulpea-site-export-test--write outside "note.html" "outside")
      (mho-vulpea-site-export-test--write target "index.html" "unchanged")
      (mho-vulpea-site-export-test--write stage "index.html" "new")
      (mho-vulpea-site-export-test--write stage "notes/note.html" "new note")
      (mho-vulpea-site-export-test--manifest stage '("index.html" "notes/note.html"))
      (make-symbolic-link outside (expand-file-name "notes" target))
      (should-error (mho-vulpea-site-export) :type 'user-error)
      (should (equal (mho-vulpea-site-export-test--read target "index.html") "unchanged"))
      (should (equal (mho-vulpea-site-export-test--read outside "note.html") "outside"))
      (delete-file (expand-file-name "notes" target))
      (delete-file (expand-file-name "notes/note.html" stage))
      (make-symbolic-link (expand-file-name "note.html" outside)
                          (expand-file-name "notes/note.html" stage))
      (should-error (mho-vulpea-site-export) :type 'user-error)
      (should (equal (mho-vulpea-site-export-test--read target "index.html") "unchanged"))
      (let ((alias (expand-file-name "repository-link" parent)))
        (make-symbolic-link target alias)
        (let ((mho-vulpea-site-repository alias))
          (should-error (mho-vulpea-site-export) :type 'user-error))))))

(ert-deftest mho-vulpea-site-export-validates-all-sources-before-writing ()
  (mho-vulpea-site-export-test--workspace
    (mho-vulpea-site-export-test--write target "index.html" "unchanged")
    (mho-vulpea-site-export-test--write stage "index.html" "new")
    (mho-vulpea-site-export-test--manifest stage '("index.html" "notes/missing.html"))
    (should-error (mho-vulpea-site-export) :type 'user-error)
    (should (equal (mho-vulpea-site-export-test--read target "index.html") "unchanged"))))

(ert-deftest mho-vulpea-site-export-rejects-overlapping-directories ()
  (mho-vulpea-site-export-test--workspace
    (let ((mho-vulpea-site-repository stage))
      (should-error (mho-vulpea-site-export) :type 'user-error))
    (let ((mho-vulpea-site-repository parent))
      (should-error (mho-vulpea-site-export) :type 'user-error))))

(provide 'mho-vulpea-site-export-tests)
;;; mho-vulpea-site-export-tests.el ends here

(ert-deftest mho-site-export-adopts-only-authorized-product-route ()
  (mho-vulpea-site-export-test--workspace
    (let ((mho-vulpea-site-export-adopt-routes '("mho-0002.html")))
      (mho-vulpea-site-export-test--write target "mho-0002.html" "old product")
      (mho-vulpea-site-export-test--write target "other-product.html" "keep other")
      (mho-vulpea-site-export-test--write stage "mho-0002.html" "new product")
      (mho-vulpea-site-export-test--manifest stage '("mho-0002.html"))
      (mho-vulpea-site-export)
      (should (equal (mho-vulpea-site-export-test--read target "mho-0002.html") "new product"))
      (mho-vulpea-site-export-test--write stage "other-product.html" "collision")
      (mho-vulpea-site-export-test--manifest stage '("mho-0002.html" "other-product.html"))
      (should-error (mho-vulpea-site-export) :type 'user-error)
      (should (equal (mho-vulpea-site-export-test--read target "other-product.html") "keep other"))
      (mho-vulpea-site-export-test--manifest stage nil)
      (mho-vulpea-site-export)
      (should-not (file-exists-p (expand-file-name "mho-0002.html" target)))
      (should (equal (mho-vulpea-site-export-test--read target "other-product.html") "keep other")))))
