;;; mho-vulpea-site-publicatorg.el --- Publicatorg HTML compiler -*- lexical-binding: t; -*-

;; Publicatorg receives rendered jobs made from sanitized public snapshots.
;; Each build has a fresh staging root, so a compiler failure cannot replace
;; the last complete preview or the publishing checkout.

(require 'cl-lib)
(defvar porg--projects)
(defvar porg-sync-vulpea-db)
(defvar porg-enable-cleanup)
(defvar porg-async-max-jobs)
(defvar porg-detect-output-clashes)
(defvar porg-cache-backend)

(defun mho-vulpea-site-publicatorg-publish (jobs directory writer)
  "Compile sanitized HTML JOBS into DIRECTORY through Publicatorg.
Each job contains :id, :route, and :html. WRITER records and writes the
managed output. No Org source is read by this compiler."
  (unless (require 'publicatorg nil t)
    (user-error "Publicatorg is not installed; run doom sync for the declared website packages"))
  (let ((porg--projects nil)
        ;; The source has already been selected and validated. Compilation
        ;; does not require catch-up support from the installed Vulpea revision.
        (porg-sync-vulpea-db nil)
        (porg-enable-cleanup nil)
        (porg-async-max-jobs nil)
        (porg-detect-output-clashes t)
        (porg-cache-backend 'file))
    (porg-define
     :name "nordic-archive" :root directory :cache-file ".publicatorg-cache"
     :input (lambda () jobs)
     :describe (lambda (value)
                 (cond ((porg-item-p value) (porg-item-target-rel value))
                       ((porg-rule-output-p value) (porg-rule-output-file value))
                       (t (plist-get value :route))))
     :rules
     (list (porg-rule
            :name "public-pages" :match (lambda (_job) t)
            :outputs (lambda (job)
                       (list (porg-rule-output
                              :id (plist-get job :id) :type "nordic-html"
                              :item job :file (plist-get job :route))))))
     :compilers
     (list (porg-compiler
            :name "nordic-html"
            :match (lambda (output)
                     (equal (porg-rule-output-type output) "nordic-html"))
            :hash (lambda (output)
                    (secure-hash 'sha256
                                 (plist-get (porg-rule-output-item output) :html)))
            :build (lambda (item _items _cache)
                     (funcall writer (porg-item-target-rel item)
                              (plist-get (porg-item-item item) :html))))))
    (porg-run "nordic-archive")))

(provide 'mho-vulpea-site-publicatorg)
;;; mho-vulpea-site-publicatorg.el ends here
