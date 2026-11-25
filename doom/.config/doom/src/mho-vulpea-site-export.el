;;; mho-vulpea-site-export.el --- Install a Vulpea website locally -*- lexical-binding: t; -*-

;;; Commentary:
;; Install only the routes owned by the Vulpea site builder.  Existing pages,
;; assets and Git metadata stay outside this publisher's ownership.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar mho-vulpea-site-repository)
(declare-function mho-vulpea-site-build "mho-vulpea-site")

(defconst mho-vulpea-site-export--manifest ".vulpea-site-manifest.json")
(defconst mho-vulpea-site-export--archives
  '("index.html" "blog.html" "weeks.html" "pages.html"))
(defconst mho-vulpea-site-export--assets
  '("assets/vulpea-site.css" "assets/vulpea-site-logo.svg" "assets/vulpea-site-mark.svg"
    "assets/vulpios.css"
    "assets/app-store-badge.svg"
    "assets/stillvaro-iphone-enclosure.png" "assets/stillvaro-ipad-enclosure.png"
    "assets/stillvaro-duo-outer-enclosure.png"
    "assets/stillvaro-duo-outer-screen-mask.png"
    "assets/stillvaro-duo-outer-screen-mask-landscape.svg")
  "Theme asset routes shared by the builder and manifest validation.
Keep this list explicit so unrelated assets cannot become publisher-owned.")
(defcustom mho-vulpea-site-export-adopt-routes '("mho-0002.html")
  "Existing pages explicitly approved for migration into this publisher.
Only listed root HTML routes may be adopted on their first managed export."
  :type '(repeat string) :group 'mho-vulpea-site)

(defun mho-vulpea-site-export--route-p (route)
  "Return non-nil if ROUTE is a route owned by this publisher."
  (and (stringp route)
       (or (member route mho-vulpea-site-export--archives)
           (equal route "feed.xml")
           (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\.html\\'" route)
           (member route mho-vulpea-site-export--assets)
           (string-match-p "\\`notes/[A-Za-z0-9][A-Za-z0-9_-]*\\.html\\'" route)
           (string-match-p "\\`media/[0-9a-f]\\{64\\}\\.[a-z0-9]+\\'" route))))

(defun mho-vulpea-site-export--directory (directory)
  "Return the canonical existing DIRECTORY, rejecting a symlink itself."
  (let ((path (directory-file-name (expand-file-name directory))))
    (when (file-symlink-p path)
      (user-error "Website directory must not be a symlink: %s" path))
    (unless (file-directory-p path)
      (user-error "Website directory does not exist: %s" path))
    (file-name-as-directory (file-truename path))))

(defun mho-vulpea-site-export--check-target-parents (directory)
  "Reject any symlink component in the configured target DIRECTORY."
  (let ((path (directory-file-name (expand-file-name directory))))
    (while path
      (when (file-symlink-p path)
        (user-error "Publishing path contains a symlink: %s" path))
      (let ((parent (file-name-directory path)))
        (setq parent (and parent (directory-file-name parent)))
        (setq path (unless (equal path parent) parent))))))

(defun mho-vulpea-site-export--path (root route &optional required)
  "Validate ROUTE below canonical ROOT and return its absolute path.
Reject symlinks and non-directory parents.  With REQUIRED, the leaf must
be an existing readable regular file; otherwise it may be absent."
  (let ((parts (split-string route "/"))
        (path (directory-file-name root)))
    (while parts
      (setq path (expand-file-name (pop parts) path))
      (when (file-symlink-p path)
        (user-error "Website path must not be a symlink: %s" path))
      (if parts
          (when (and (file-exists-p path) (not (file-directory-p path)))
            (user-error "Website path parent is not a directory: %s" path))
        (when (and (file-exists-p path) (not (file-regular-p path)))
          (user-error "Website route is not a regular file: %s" path))
        (when (and required
                   (not (and (file-regular-p path) (file-readable-p path))))
          (user-error "Website build file is missing or unreadable: %s" path))))
    path))

(defun mho-vulpea-site-export--read-manifest (root &optional previous)
  "Read and validate the manifest in ROOT.
With PREVIOUS, accept an absent manifest and allow retired routes for removal."
  (let ((path (mho-vulpea-site-export--path
               root mho-vulpea-site-export--manifest (not previous))))
    (when (file-exists-p path)
      (let* ((data (condition-case err
                      (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string))
                       :object-type 'hash-table :array-type 'array
                       :null-object nil :false-object :json-false)
                    (error (user-error "Invalid website manifest %s: %s"
                                       path (error-message-string err)))))
             (files (and (hash-table-p data) (gethash "files" data))))
        (unless (and (hash-table-p data)
                     (= (hash-table-count data) 2)
                     (eql (gethash "version" data) 1)
                     (vectorp files))
          (user-error "Invalid website manifest schema: %s" path))
        (let ((seen (make-hash-table :test #'equal)))
          (seq-doseq (route files)
            (unless (or (mho-vulpea-site-export--route-p route)
                        (and previous (equal route "assets/vulpios.icns")))
              (user-error "Invalid website manifest route: %S" route))
            (when (gethash route seen)
              (user-error "Duplicate website manifest route: %s" route))
            (puthash route t seen)))
        (append files nil)))))

(defun mho-vulpea-site-export--copy-file (source destination)
  "Copy SOURCE into DESTINATION using a temporary sibling and atomic rename."
  (let* ((directory (file-name-directory destination))
         (temporary (progn
                      (make-directory directory t)
                      (make-temp-file (expand-file-name ".vulpea-site-copy-" directory)))))
    (unwind-protect
        (progn
          (copy-file source temporary t)
          (rename-file temporary destination t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun mho-vulpea-site-export--write-manifest (root files)
  "Atomically save ROOT's ownership manifest for FILES."
  (let ((temporary (make-temp-file (expand-file-name ".vulpea-site-manifest-" root))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region
             (concat (json-serialize (list :version 1 :files (vconcat files))) "\n")
             nil temporary nil 'silent))
          (rename-file temporary
                       (expand-file-name mho-vulpea-site-export--manifest root) t))
      (when (file-exists-p temporary) (delete-file temporary)))))

;;;###autoload
(defun mho-vulpea-site-export ()
  "Build the public Vulpea site and install its files in the local repository.
The first export may replace the four archive pages.  Other existing files
must already be owned by this publisher's manifest.  Unmanaged files are
preserved.  This command does not stage, commit, push, or deploy anything.
Return the absolute publishing repository directory."
  (interactive)
  (let* ((stage (mho-vulpea-site-export--directory (mho-vulpea-site-build)))
         (_ (mho-vulpea-site-export--check-target-parents mho-vulpea-site-repository))
         (target (mho-vulpea-site-export--directory mho-vulpea-site-repository)))
    (when (or (equal stage target)
              (file-in-directory-p stage target)
              (file-in-directory-p target stage))
      (user-error "Build and publishing directories must be separate"))
    (let* ((files (mho-vulpea-site-export--read-manifest stage))
           (previous (mho-vulpea-site-export--read-manifest target t))
           (first-export (not (file-exists-p
                               (expand-file-name mho-vulpea-site-export--manifest target))))
           (obsolete (cl-set-difference previous files :test #'equal))
           copies removals)
      ;; Finish every route, source and collision check before changing the checkout.
      (dolist (route files)
        (let ((source (mho-vulpea-site-export--path stage route t))
              (destination (mho-vulpea-site-export--path target route)))
          (when (and (file-exists-p destination)
                     (not (member route previous))
                     (not (and first-export
                               (member route mho-vulpea-site-export--archives)))
                     (not (member route mho-vulpea-site-export-adopt-routes)))
            (user-error "Website export would overwrite an unmanaged file: %s" destination))
          (push (cons source destination) copies)))
      (dolist (route obsolete)
        (let ((path (mho-vulpea-site-export--path target route)))
          (when (file-exists-p path) (push path removals))))
      (dolist (copy (nreverse copies))
        (mho-vulpea-site-export--copy-file (car copy) (cdr copy)))
      (dolist (path removals) (delete-file path))
      (mho-vulpea-site-export--write-manifest target files)
      (message "Vulpea website exported to %s (%d files); review the local changes"
               target (length files))
      target)))

(provide 'mho-vulpea-site-export)
;;; mho-vulpea-site-export.el ends here
