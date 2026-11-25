;;; mho-vulpea-site-tests.el --- Publishing regression tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with the installed Org/Vulpea packages on load-path:
;; emacs --batch -Q -L src -l src/mho-vulpea-site-tests.el \
;;   -f ert-run-tests-batch-and-exit
;; Every source note, attachment and build directory belongs to a temporary
;; fixture.  The Vulpea query is stubbed; the user's database is never opened.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xml)
(require 'mho-vulpea-site)

(defvar mho-site-test--notes nil)
(defvar mho-site-test--evaluated nil)

(defun mho-site-test--read (path)
  "Read fixture PATH as text."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun mho-site-test--write (path content)
  "Write CONTENT to fixture PATH, making its parent directory."
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content))
  path)

(defun mho-site-test--note (id title tags body &optional database-tags)
  "Create a fixture note and indexed record with ID, TITLE, TAGS and BODY.
When DATABASE-TAGS is non-nil, use those tags for the stale index record."
  (let ((path (expand-file-name (concat id ".org") mho-vulpea-site-directory)))
    (mho-site-test--write
     path
     (format ":PROPERTIES:\n:ID: %s\n:CREATED: [2025-02-03 Mon]\n:END:\n#+TITLE: %s\n#+FILETAGS: :%s:\n\n%s\n"
             id title (string-join tags ":") body))
    (push (make-vulpea-note :id id :title title :path path :level 0
                           :tags (or database-tags tags))
          mho-site-test--notes)
    path))

(defun mho-site-test--html (id)
  "Read the generated note page for ID."
  (mho-site-test--read
   (expand-file-name (concat "notes/" id ".html") mho-vulpea-site-build-directory)))

(defun mho-site-test--all-html ()
  "Return all generated HTML in the fixture as one string."
  (mapconcat #'mho-site-test--read
             (directory-files-recursively mho-vulpea-site-build-directory "\\.html\\'")
             "\n"))

(defmacro mho-site-test--workspace (&rest body)
  "Run BODY with isolated notes, assets, database responses and output."
  (declare (indent 0) (debug t))
  `(let* ((fixture (file-name-as-directory (file-truename (make-temp-file "mho-site-test-" t))))
          (mho-vulpea-site-directory (expand-file-name "notes/" fixture))
          (mho-vulpea-site-build-directory (expand-file-name "build/" fixture))
          (mho-vulpea-site-repository (expand-file-name "repository/" fixture))
          (org-directory mho-vulpea-site-directory)
          (org-id-locations-file (expand-file-name "org-id-locations" fixture))
          (org-id-locations (make-hash-table :test #'equal))
          (org-id-files nil)
          (org-agenda-files nil)
          (mho-site-test--notes nil)
          (mho-site-test--evaluated nil))
     (make-directory mho-vulpea-site-directory t)
     (unwind-protect
         (cl-letf (((symbol-function 'vulpea-db-query)
                    (lambda (&optional predicate)
                      (if predicate (seq-filter predicate mho-site-test--notes)
                        mho-site-test--notes)))
                   ((symbol-function 'vulpea-db-sync-full-scan)
                    (lambda (&rest _) nil)))
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-local-value 'buffer-file-name buffer))
                     (_ (file-in-directory-p file fixture)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory fixture t))))

(ert-deftest mho-site-public-links-headings-and-backlinks ()
  "Keep public file and heading links, and derive backlinks from public text."
  (mho-site-test--workspace
    (let ((source
           (mho-site-test--note
            "PUB1" "Public source" '("public" "page")
            "[[id:PUB2][Public target]]\n[[id:HEAD2][Public heading]]\n[[id:PRIV][Private label]]\n[[id:MISSING][Unknown label]]\n[[id:HIDDEN2][Hidden heading label]]\n* Private section :private:\nPRIVATESENTINEL\n[[id:PUB3][Hidden outgoing link]]\n* Suppressed section :noexport:\nNOEXPORTSENTINEL")))
      (mho-site-test--note
       "PUB2" "Public target" '("public" "blog")
       "* Visible heading\n:PROPERTIES:\n:ID: HEAD2\n:END:\nVisible body.\n* Hidden heading :private:\n:PROPERTIES:\n:ID: HIDDEN2\n:END:\nHIDDENHEADINGSENTINEL")
      (mho-site-test--note "PUB3" "Third public note" '("public" "week") "Third body.")
      (mho-site-test--note "PRIV" "Private title sentinel" '("private") "PRIVATEFILESENTINEL")
      (let ((before (mho-site-test--read source)))
        (mho-vulpea-site-build)
        (let ((html (mho-site-test--html "PUB1"))
              (target (mho-site-test--html "PUB2"))
              (all (mho-site-test--all-html)))
          (should (string-match-p "href=\"PUB2.html\"" html))
          (should (string-match-p "href=\"PUB2.html#id-HEAD2\"" html))
          (should (string-match-p "id=\"id-HEAD2\"" target))
          (should (string-match-p "href=\"PUB1.html\"" target))
          (should-not (string-match-p "href=\"PUB1.html\"" (mho-site-test--html "PUB3")))
          (should (string-match-p "Private label" html))
          (should (string-match-p "Unknown label" html))
          (should-not (string-match-p "href=\"[^\"]*\\(?:PRIV\\|MISSING\\|HIDDEN2\\)" html))
          (dolist (sentinel '("PRIVATESENTINEL" "NOEXPORTSENTINEL"
                              "HIDDENHEADINGSENTINEL" "PRIVATEFILESENTINEL"
                              "Private title sentinel"))
            (should-not (string-match-p sentinel all))))
        (should (equal before (mho-site-test--read source)))))))

(ert-deftest mho-site-rechecks-public-tags-against-current-source ()
  "A stale public index record must not publish a currently private file."
  (mho-site-test--workspace
    (mho-site-test--note "PUB1" "Current public" '("public") "VISIBLEBODY")
    (mho-site-test--note "STALE" "Stale private title" '("public" "private")
                         "STALEPRIVATESENTINEL" '("public"))
    (mho-site-test--note "NONE" "Unmarked title" nil "UNMARKEDSENTINEL" '("public"))
    (mho-vulpea-site-build)
    (should (file-exists-p (expand-file-name "notes/PUB1.html" mho-vulpea-site-build-directory)))
    (should-not (file-exists-p (expand-file-name "notes/STALE.html" mho-vulpea-site-build-directory)))
    (should-not (file-exists-p (expand-file-name "notes/NONE.html" mho-vulpea-site-build-directory)))
    (let ((html (mho-site-test--all-html)))
      (should-not (string-match-p "STALEPRIVATESENTINEL\\|UNMARKEDSENTINEL\\|Stale private title" html)))))

(ert-deftest mho-site-source-directives-cannot-evaluate-or-include-private-data ()
  "Disable macro/Babel execution and remove inclusion and export overrides."
  (mho-site-test--workspace
    (let ((secret (mho-site-test--write (expand-file-name "private.txt" fixture) "INCLUDESENTINEL"))
          (setup (mho-site-test--write
                  (expand-file-name "setup.org" fixture)
                  "#+TITLE: SETUPTITLESENTINEL\n#+HTML_HEAD: <meta name=\"SETUPHEADSENTINEL\">\n")))
      (mho-site-test--note
       "PUB1" "Safe page" '("public")
       (format "#+EXCLUDE_TAGS: something_else\n#+INCLUDE: %S\n#+SETUPFILE: %S\n#+BIND: org-export-use-babel t\n#+HTML_HEAD: <meta name=\"HTMLHEADSENTINEL\">\n#+MACRO: evaluate (eval (progn (setq mho-site-test--evaluated t) \"MACRORESULTSENTINEL\"))\n{{{evaluate}}}\n#+BEGIN_SRC emacs-lisp :exports results\n(setq mho-site-test--evaluated t)\n#+END_SRC\n* Hidden :private:\nOVERRIDESENTINEL\n{{{evaluate}}}\n* Public\nVisible body."
               secret setup))
      (mho-vulpea-site-build)
      (should-not mho-site-test--evaluated)
      (let ((html (mho-site-test--all-html)))
        (dolist (sentinel '("INCLUDESENTINEL" "SETUPTITLESENTINEL" "SETUPHEADSENTINEL"
                            "HTMLHEADSENTINEL" "MACRORESULTSENTINEL" "OVERRIDESENTINEL"))
          (should-not (string-match-p sentinel html)))))))

(ert-deftest mho-site-copies-only-retained-images-inside-library ()
  "Copy a visible local image; exclude hidden, escaping and symlink images."
  (mho-site-test--workspace
    (let ((image (expand-file-name "images/visible.png" mho-vulpea-site-directory))
          (hidden (expand-file-name "images/hidden.png" mho-vulpea-site-directory))
          (outside (expand-file-name "outside.png" fixture)))
      ;; The publishing boundary concerns file contents and paths, not PNG decoding.
      (mho-site-test--write image "VISIBLEIMAGEBYTES")
      (mho-site-test--write hidden "HIDDENIMAGEBYTES")
      (mho-site-test--write outside "OUTSIDEIMAGEBYTES")
      (make-symbolic-link outside (expand-file-name "escape.png" mho-vulpea-site-directory))
      (mho-site-test--note
       "PUB1" "Images" '("public")
       "[[file:images/visible.png]]\n[[file:../outside.png]]\n[[file:escape.png]]\n* Hidden :private:\n[[file:images/hidden.png]]")
      (mho-vulpea-site-build)
      (let* ((files (directory-files-recursively mho-vulpea-site-build-directory "."))
             (contents (mapcar #'mho-site-test--read files))
             (html (mho-site-test--html "PUB1")))
        (should (member "VISIBLEIMAGEBYTES" contents))
        (should-not (member "HIDDENIMAGEBYTES" contents))
        (should-not (member "OUTSIDEIMAGEBYTES" contents))
        (should (string-match-p "<img[^>]+src=\"[^\"]+\\.png\"" html))
        (should-not (string-match-p "src=\"[^\"]*\\(?:outside\\|escape\\|hidden\\)" html))))))

(ert-deftest mho-site-rebuild-removes-withdrawn-pages ()
  "Changing a public source to private removes previously generated output."
  (mho-site-test--workspace
    (let ((source (mho-site-test--note "PUB1" "Withdrawn note" '("public") "WITHDRAWNSENTINEL")))
      (mho-vulpea-site-build)
      (should (file-exists-p (expand-file-name "notes/PUB1.html" mho-vulpea-site-build-directory)))
      (mho-site-test--write
       source
       ":PROPERTIES:\n:ID: PUB1\n:END:\n#+TITLE: Withdrawn note\n#+FILETAGS: :private:\nWITHDRAWNSENTINEL\n")
      (mho-vulpea-site-build)
      (should-not (file-exists-p (expand-file-name "notes/PUB1.html" mho-vulpea-site-build-directory)))
      (should-not (string-match-p "WITHDRAWNSENTINEL\\|Withdrawn note" (mho-site-test--all-html))))))

(ert-deftest mho-site-empty-library-builds-empty-archives ()
  "An empty public collection still produces usable archive entry points."
  (mho-site-test--workspace
    (mho-site-test--note "PRIV" "Private title" '("private") "PRIVATEONLYSENTINEL")
    (mho-vulpea-site-build)
    (dolist (page '("index.html" "blog.html" "weeks.html" "pages.html"))
      (should (file-exists-p (expand-file-name page mho-vulpea-site-build-directory))))
    (should-not (string-match-p "PRIVATEONLYSENTINEL\\|Private title" (mho-site-test--all-html)))))

(ert-deftest mho-site-rejects-source-files-outside-real-library ()
  "A public database record cannot authorize reading outside the library."
  (mho-site-test--workspace
    (let* ((outside (mho-site-test--write
                     (expand-file-name "outside.org" fixture)
                     ":PROPERTIES:\n:ID: OUT1\n:END:\n#+TITLE: Outside note\n#+FILETAGS: :public:\nOUTSIDENOTESENTINEL\n"))
           (symlink (expand-file-name "linked.org" mho-vulpea-site-directory)))
      (make-symbolic-link outside symlink)
      (push (make-vulpea-note :id "OUT1" :title "Outside note" :path symlink
                             :level 0 :tags '("public"))
            mho-site-test--notes)
      (mho-vulpea-site-build)
      (should-not (file-exists-p (expand-file-name "notes/OUT1.html" mho-vulpea-site-build-directory)))
      (should-not (string-match-p "OUTSIDENOTESENTINEL" (mho-site-test--all-html))))))

(ert-deftest mho-site-does-not-delete-an-unowned-output-directory ()
  "Only directories marked as this builder's output may be replaced."
  (mho-site-test--workspace
    (let ((existing (mho-site-test--write
                     (expand-file-name "keep.txt" mho-vulpea-site-build-directory)
                     "EXISTINGFILESENTINEL")))
      (should-error (mho-vulpea-site-build))
      (should (equal "EXISTINGFILESENTINEL" (mho-site-test--read existing))))))

(ert-deftest mho-site-preserves-literal-directives-in-source-and-example-blocks ()
  "Org snippets remain readable without executing export hooks or macros."
  (mho-site-test--workspace
    (mho-site-test--note
     "PUB1" "Org syntax examples" '("public")
     "#+BEGIN_SRC org\n#+INCLUDE: source-example.txt\n#+BIND: example-value t\n#+MACRO: example literal macro\n#+END_SRC\n\n#+BEGIN_EXAMPLE\n#+SETUPFILE: example-settings.org\n#+OPTIONS: example-option\n#+END_EXAMPLE")
    (let ((org-export-before-processing-functions
           (list (lambda (_) (setq mho-site-test--evaluated t))))
          (org-export-before-parsing-functions
           (list (lambda (_) (setq mho-site-test--evaluated t)))))
      (mho-vulpea-site-build))
    (should-not mho-site-test--evaluated)
    (let ((html (mho-site-test--html "PUB1")))
      (dolist (literal '("#+INCLUDE: source-example.txt" "#+BIND: example-value t"
                         "#+MACRO: example literal macro" "#+SETUPFILE: example-settings.org"
                         "#+OPTIONS: example-option"))
        (should (string-match-p (regexp-quote literal) html))))))

(ert-deftest mho-site-literal-public-tags-do-not-opt-a-note-in ()
  "A FILETAGS line inside a code example cannot authorize publication."
  (mho-site-test--workspace
    (let ((source (mho-site-test--note "NONE" "Unmarked code sample" nil "" '("public"))))
      (mho-site-test--write
       source
       ":PROPERTIES:\n:ID: NONE\n:END:\n#+TITLE: Unmarked code sample\n#+BEGIN_SRC org\n#+FILETAGS: :public:\n#+END_SRC\nUNMARKEDCODESENTINEL\n")
      (mho-vulpea-site-build)
      (should-not (file-exists-p (expand-file-name "notes/NONE.html" mho-vulpea-site-build-directory)))
      (should-not (string-match-p "UNMARKEDCODESENTINEL" (mho-site-test--all-html))))))

(ert-deftest mho-site-private-tag-on-later-filetags-line-wins ()
  "All file-level FILETAGS lines participate in the public/private decision."
  (mho-site-test--workspace
    (mho-site-test--note "PRIV" "Multiple tag lines" '("public")
                         "#+FILETAGS: :private:\nMULTIPLETAGSSENTINEL" '("public"))
    (mho-vulpea-site-build)
    (should-not (file-exists-p (expand-file-name "notes/PRIV.html" mho-vulpea-site-build-directory)))
    (should-not (string-match-p "MULTIPLETAGSSENTINEL" (mho-site-test--all-html)))))

(ert-deftest mho-site-remote-notes-and-links-never-reach-file-operations ()
  "Reject remote inputs before a file handler could connect to a server."
  (mho-site-test--workspace
    (let* ((remote-note "/mho-remote:/server/note.org")
           (remote-image "/mho-remote:/server/image.png")
           (remote-p (lambda (path)
                       (and (stringp path) (string-prefix-p "/mho-remote:" path))))
           (guard (lambda (original)
                    (lambda (path &rest args)
                      (when (funcall remote-p path)
                        (ert-fail (format "Remote input reached a file operation: %s" path)))
                      (apply original path args))))
           (regular (funcall guard (symbol-function 'file-regular-p)))
           (truename (funcall guard (symbol-function 'file-truename)))
           (read-file (funcall guard (symbol-function 'insert-file-contents)))
           (read-literal (funcall guard (symbol-function 'insert-file-contents-literally))))
      (mho-site-test--note
       "PUB1" "Remote links" '("public")
       (format "[[file:%s][Remote document]]\n[[file:%s]]" remote-note remote-image))
      (push (make-vulpea-note :id "REMOTE" :title "Remote private title"
                             :path remote-note :level 0 :tags '("public"))
            mho-site-test--notes)
      (cl-letf (((symbol-function 'file-remote-p)
                 (lambda (path &rest _) (when (funcall remote-p path) "test-remote")))
                ((symbol-function 'file-regular-p) regular)
                ((symbol-function 'file-truename) truename)
                ((symbol-function 'insert-file-contents) read-file)
                ((symbol-function 'insert-file-contents-literally) read-literal))
        (should-not (mho-vulpea-site--media remote-image))
        (mho-vulpea-site-build))
      (let ((html (mho-site-test--html "PUB1")))
        (should (string-match-p "Remote document" html))
        (should (string-match-p "Unpublished file" html))
        (should-not (string-match-p "mho-remote:\\|Remote private title" html))))))

(ert-deftest mho-site-renders-inline-and-display-math-as-native-mathml ()
  "Produce MathML for inline and display formulas without remote scripts."
  (skip-unless (executable-find "pandoc"))
  (mho-site-test--workspace
    (mho-site-test--note
     "MATH" "Math examples" '("public")
     "Inline \\(x^2 + 1\\) in a sentence.\n\n\\[\n\\frac{1}{2}\n\\]\n")
    (mho-vulpea-site-build)
    (let ((html (mho-site-test--html "MATH")))
      (should (string-match-p "<math[^>]+display=\"inline\"" html))
      (should (string-match-p "<math[^>]+display=\"block\"" html))
      (should (string-match-p "<msup>" html))
      (should (string-match-p "<mfrac>" html))
      (should-not (string-match-p "MathJax\\|<script" html)))))

(ert-deftest mho-site-pandoc-sandbox-cannot-read-a-latex-include ()
  "A LaTeX input directive cannot include the contents of a private file."
  (skip-unless (executable-find "pandoc"))
  (mho-site-test--workspace
    (let* ((secret (mho-site-test--write
                    (expand-file-name "private.tex" fixture)
                    "PRIVATELATEXSENTINEL"))
           (element (org-element-create
                     'latex-environment
                     (list :value (format "\\input{%s}" secret))))
           (html (mho-vulpea-site--latex element nil nil)))
      (should-not (string-match-p "PRIVATELATEXSENTINEL" html)))))

(ert-deftest mho-site-identical-source-produces-identical-html ()
  "Unchanged notes should not create random-anchor diffs in the site checkout."
  (mho-site-test--workspace
    (mho-site-test--note "STABLE" "Stable output" '("public")
                         "* A heading without an ID\nA paragraph with a footnote.[fn:1]\n\n* Another heading\n\n[fn:1] Footnote text.")
    (mho-vulpea-site-build)
    (let ((before (mho-site-test--all-html)))
      (mho-vulpea-site-build)
      (should (equal before (mho-site-test--all-html))))))

(defun mho-site-test--heading (level title tags id body &optional created)
  "Compose a synthetic heading with an own ID and optional CREATED date."
  (concat (make-string level ?*) " " title
          (when tags (concat " :" (string-join tags ":") ":")) "\n"
          (when (or id created)
            (concat ":PROPERTIES:\n" (when id (concat ":ID: " id "\n"))
                    (when created (concat ":CREATED: " created "\n")) ":END:\n"))
          body "\n"))

(ert-deftest mho-site-journal-publishes-only-selected-entries ()
  "Public entry pages cannot expose their journal or unselected siblings."
  (mho-site-test--workspace
    (mho-site-test--write (expand-file-name "visible.png" mho-vulpea-site-directory) "VISIBLEIMAGE")
    (mho-site-test--write (expand-file-name "hidden.png" mho-vulpea-site-directory) "HIDDENIMAGE")
    (let* ((path
            (mho-site-test--note
             "MONTH" "2026-10" '("journal" "public")
             (concat
              "#+description: ROOTDESCRIPTIONSENTINEL\nROOTPROSESENTINEL\n"
              (mho-site-test--heading 1 "week 43" '("public") "WEEK" "WEEKPROSESENTINEL")
              (mho-site-test--heading 2 "DAYCONTEXTSENTINEL" '("public") "DAY" "DAYPROSESENTINEL" "[2026-10-25 Sun]")
              (mho-site-test--heading 3 "First selected moment" '("public") "ENTRYONE"
                                      "FIRSTPUBLICBODY\n[[file:visible.png]]\n[[id:ENTRYTWO]]\n[[id:PRIVATE][A chosen label]]"
                                      "[2026-10-25 Sun 09:30]")
              (mho-site-test--heading 4 "Visible child" '("public") "CHILD" "PUBLICCHILDBODY")
              (mho-site-test--heading 4 "PRIVATECHILDTITLE" '("private" "public") "PRIVATECHILD"
                                      "PRIVATECHILDBODY\n[[file:hidden.png]]")
              (mho-site-test--heading 3 "UNMARKEDSIBLINGTITLE" nil "UNMARKED" "UNMARKEDSIBLINGBODY")
              (mho-site-test--heading 3 "PRIVATESIBLINGTITLE" '("private") "PRIVATE" "PRIVATESIBLINGBODY")
              (mho-site-test--heading 3 "Second selected moment" '("public" "weeknote") "ENTRYTWO"
                                      "SECONDPUBLICBODY" "[2026-10-25 Sun 11:00]")
              (mho-site-test--heading 3 "Tasks" '("public") "TASKS" "TASKSCONTEXTSENTINEL")
              (mho-site-test--heading 4 "LIVE TASKTITLE" '("public") "TASK" "TASKBODYSENTINEL")
              (mho-site-test--heading 5 "TASKCHILDTITLE" '("public") "TASKCHILD" "TASKCHILDBODY"))))
           (before (mho-site-test--read path)))
      (mho-site-test--note "REF" "Public reference" '("public")
                           "[[id:ENTRYONE]]\n[[id:CHILD]]\n[[file:MONTH.org][Journal file]]\n[[id:DAY][Calendar day]]")
      (mho-vulpea-site-build)
      (let ((one (mho-site-test--html "ENTRYONE"))
            (two (mho-site-test--html "ENTRYTWO"))
            (reference (mho-site-test--html "REF"))
            (all (mho-site-test--all-html)))
        (should (string-match-p "FIRSTPUBLICBODY" one))
        (should (string-match-p "PUBLICCHILDBODY" one))
        (should (string-match-p "id=\"id-CHILD\"" one))
        (should (string-match-p "SECONDPUBLICBODY" two))
        (should (string-match-p "href=\"ENTRYONE.html\"" reference))
        (should (string-match-p "href=\"ENTRYONE.html#id-CHILD\"" reference))
        (should-not (string-match-p "href=\"[^\"]*MONTH\\|href=\"[^\"]*DAY" reference))
        (should-not (string-match-p "href=\"ENTRYTWO.html\"[^>]*>Journal file" reference))
        (dolist (sentinel '("ROOTDESCRIPTIONSENTINEL" "ROOTPROSESENTINEL" "WEEKPROSESENTINEL"
                            "DAYCONTEXTSENTINEL" "DAYPROSESENTINEL" "PRIVATECHILDTITLE"
                            "PRIVATECHILDBODY" "UNMARKEDSIBLINGTITLE" "UNMARKEDSIBLINGBODY"
                            "PRIVATESIBLINGTITLE" "PRIVATESIBLINGBODY" "TASKSCONTEXTSENTINEL"
                            "TASKTITLE" "TASKBODYSENTINEL" "TASKCHILDTITLE" "TASKCHILDBODY"))
          (should-not (string-match-p sentinel all)))
        (dolist (id '("MONTH" "WEEK" "DAY" "UNMARKED" "PRIVATE" "CHILD" "TASKS" "TASK" "TASKCHILD"))
          (should-not (file-exists-p (expand-file-name (concat "notes/" id ".html") mho-vulpea-site-build-directory))))
        (should (= 1 (length (directory-files (expand-file-name "media" mho-vulpea-site-build-directory) nil "\\.png\\'"))))
        (should (equal before (mho-site-test--read path)))))))

(ert-deftest mho-site-journal-private-and-comment-ancestors-veto-public-children ()
  "No public child can override explicit privacy on its file or ancestors."
  (mho-site-test--workspace
    (dolist (tag '("private" "noexport"))
      (mho-site-test--note
       (concat "FILE-" tag) "2026-10" (list "journal" "public" tag)
       (concat (mho-site-test--heading 1 "25 Sunday" nil "DAY" "" "[2026-10-25]")
               (mho-site-test--heading 2 "Should stay hidden" '("public") "HIDDEN" "FILEVETOSENTINEL")))
      (mho-site-test--note
       (concat "PARENT-" tag) "2026-10" '("journal")
       (concat (mho-site-test--heading 1 "25 Sunday" (list tag) "DAY" "" "[2026-10-25]")
               (mho-site-test--heading 2 "Should stay hidden" '("public") "HIDDEN" "PARENTVETOSENTINEL"))))
    (mho-site-test--note
     "COMMENT" "2026-10" '("journal")
     (concat (mho-site-test--heading 1 "COMMENT 25 Sunday" nil "DAY" "" "[2026-10-25]")
             (mho-site-test--heading 2 "Should stay hidden" '("public") "HIDDEN" "COMMENTVETOSENTINEL")))
    (mho-vulpea-site-build)
    (should-not (directory-files (expand-file-name "notes" mho-vulpea-site-build-directory) nil "\\.html\\'"))
    (should-not (string-match-p "VETOSENTINEL" (mho-site-test--all-html)))))

(ert-deftest mho-site-journal-daily-groups-and-stale-tags ()
  "A daily journal exposes only public roots or direct group entries."
  (mho-site-test--workspace
    (mho-site-test--note
     "DAILY" "2026-10-25 Sunday" '("journal")
     (concat (mho-site-test--heading 1 "Work" '("public") "WORK" "WORKPROSESENTINEL")
             (mho-site-test--heading 2 "Selected entry" '("public") "SELECTED" "DAILYPUBLICBODY" "[2026-10-25]")
             (mho-site-test--heading 2 "Now private" '("private") "WITHDRAWN" "WITHDRAWNSENTINEL")
             (mho-site-test--heading 1 "Personal" nil "PERSONAL" "PERSONALPROSESENTINEL")
             (mho-site-test--heading 2 "Unmarked entry" nil "UNMARKED" "DAILYUNMARKEDSENTINEL")
             (mho-site-test--heading 1 "A root entry" '("public") "ROOTENTRY" "ROOTENTRYBODY" "[2026-10-25]")
             (mho-site-test--heading 1 "Tasks" '("public") "TASKS" "TASKSPROSESENTINEL")
             (mho-site-test--heading 2 "Task child note" '("public") "TASKNOTE" "TASKNOTESENTINEL"))
     '("public"))
    (mho-vulpea-site-build)
    (should (string-match-p "DAILYPUBLICBODY" (mho-site-test--html "SELECTED")))
    (should (string-match-p "ROOTENTRYBODY" (mho-site-test--html "ROOTENTRY")))
    (should-not (string-match-p "PROSESENTINEL\\|WITHDRAWNSENTINEL\\|DAILYUNMARKEDSENTINEL\\|TASKNOTESENTINEL"
                               (mho-site-test--all-html)))))

(ert-deftest mho-site-journal-literal-tags-and-private-withdrawal ()
  "Literal headlines never opt in, and revocation removes pages and media."
  (mho-site-test--workspace
    (let* ((body (concat
                  (mho-site-test--heading 1 "25 Sunday" nil "DAY" "" "[2026-10-25]")
                  "#+BEGIN_SRC org\n** Literal :public:\n:PROPERTIES:\n:ID: LITERAL\n:END:\nLITERALBODY\n#+END_SRC\n"
                  (mho-site-test--heading 2 "Kept once" '("public") "ONCE" "SELECTEDONCEBODY\n[[file:once.png]]" "[2026-10-25]")))
           (path (mho-site-test--note "MONTH" "2026-10" '("journal") body)))
      (mho-site-test--write (expand-file-name "once.png" mho-vulpea-site-directory) "IMAGE")
      (mho-vulpea-site-build)
      (should (string-match-p "SELECTEDONCEBODY" (mho-site-test--html "ONCE")))
      (should-not (file-exists-p (expand-file-name "notes/LITERAL.html" mho-vulpea-site-build-directory)))
      (mho-site-test--write path (replace-regexp-in-string "Kept once :public:" "Kept once :private:" (mho-site-test--read path) t t))
      (mho-vulpea-site-build)
      (should-not (file-exists-p (expand-file-name "notes/ONCE.html" mho-vulpea-site-build-directory)))
      (should-not (directory-files (expand-file-name "media" mho-vulpea-site-build-directory) nil "\\.png\\'"))
      (should-not (string-match-p "SELECTEDONCEBODY\\|LITERALBODY" (mho-site-test--all-html))))))

(ert-deftest mho-site-journal-public-entry-requires-own-safe-id ()
  "A public entry cannot borrow its parent's identity or use a route escape."
  (dolist (id '(nil "../unsafe"))
    (mho-site-test--workspace
      (mho-site-test--note "DAILY" "2026-10-25" '("journal")
                           (mho-site-test--heading 1 "Selected" '("public") id "BODY"))
      (should-error (mho-vulpea-site-build) :type 'user-error))))

(ert-deftest mho-site-journal-rejects-ambiguous-source ()
  "Malformed metadata, IDs, or outline shapes cannot become public pages."
  (dolist (body (list
                "* Selected :public:\n:PROPERTIES:\n:ID: ENTRY\n:ID: OTHER\n:END:\nBODY"
                "* Selected :public:\n:PROPERTIES:\n:ID: ENTRY\n:END:\n#+BEGIN_SRC org\nUNFINISHED"
                "* Selected :public:\n:PROPERTIES:\n:ID: ENTRY\n:END:\n:LOGBOOK:\nUNFINISHED"
                "* Selected :public:\n:PROPERTIES:\n:ID: ENTRY\n:END:\nBODY\n* Private :private:\n:PROPERTIES:\n:ID: entry\n:END:\nPRIVATE"
                "#+TITLE: Another title\n* Selected :public:\n:PROPERTIES:\n:ID: ENTRY\n:END:\nBODY"))
    (mho-site-test--workspace
      (mho-site-test--note "DAILY" "2026-10-25" '("journal") body)
      (should-error (mho-vulpea-site-build) :type 'user-error)))
  (dolist (body (list
                (concat (mho-site-test--heading 1 "week 1" nil "WEEK" "")
                        (mho-site-test--heading 1 "25 Sunday" nil "DAY" "")
                        (mho-site-test--heading 2 "Selected" '("public") "ENTRY" "BODY"))
                (concat (mho-site-test--heading 1 "week 43" nil "WEEK" "")
                        (mho-site-test--heading 1 "25 Sunday" nil "DAY" "")
                        (mho-site-test--heading 2 "Selected" '("public") "ENTRY" "BODY"))
                (concat (mho-site-test--heading 1 "25 Sunday" nil "DAY" "")
                        (mho-site-test--heading 2 "Selected" '("public") "ENTRY" "BODY")
                        (mho-site-test--heading 1 "25 Sunday" '("private") "OTHERDAY" ""))))
    (mho-site-test--workspace
      (mho-site-test--note "MONTH" "2026-10" '("journal") body)
      (should-error (mho-vulpea-site-build) :type 'user-error))))

(ert-deftest mho-site-journal-filename-and-path-safety ()
  "Canonical filenames identify renamed journals; journal paths never opt in."
  (mho-site-test--workspace
    (mho-site-test--note
     "2026-10" "A renamed month" '("journal")
     (concat (mho-site-test--heading 1 "25 Sunday" nil "DAY" "")
             (mho-site-test--heading 2 "Selected" '("public") "ENTRY" "MONTHBODY")))
    (mho-site-test--note "2026-10-24" "A renamed day" '("journal")
                         (mho-site-test--heading 1 "Selected day" '("public") "DAILYENTRY" "DAYBODY"))
    (mho-site-test--note "CUSTOM" "Unknown journal structure" '("journal" "public")
                         (mho-site-test--heading 1 "Unknown" '("public") "UNKNOWN" "UNKNOWNBODYSENTINEL"))
    (let* ((path (mho-site-test--note "UNTAGGED" "Untagged journal" '("public") "UNTAGGEDJOURNALSENTINEL"))
           (target (expand-file-name "journal/UNTAGGED.org" mho-vulpea-site-directory)))
      (make-directory (file-name-directory target) t)
      (rename-file path target)
      (setf (vulpea-note-path (car mho-site-test--notes)) target))
    (mho-vulpea-site-build)
    (should (string-match-p "MONTHBODY" (mho-site-test--html "ENTRY")))
    (should (string-match-p "DAYBODY" (mho-site-test--html "DAILYENTRY")))
    (should-not (string-match-p "UNKNOWNBODYSENTINEL\\|UNTAGGEDJOURNALSENTINEL" (mho-site-test--all-html)))))

(ert-deftest mho-site-journal-archived-entries-are-not-eligible ()
  "Archived entries and ancestors stay unavailable even with own public tags."
  (mho-site-test--workspace
    (mho-site-test--note
     "DAILY" "2026-10-25" '("journal")
     (concat (mho-site-test--heading 1 "Old entry" '("public" "ARCHIVE") "OLD" "ARCHIVEDBODY")
             "* Work\n:PROPERTIES:\n:ID: WORK\n:ARCHIVE_TIME: [2026-10-25]\n:END:\n"
             (mho-site-test--heading 2 "Old grouped entry" '("public") "OLDGROUPED" "ARCHIVEDGROUPBODY")
             (mho-site-test--heading 1 "Selected" '("public") "ENTRY" "VISIBLEBODY")))
    (mho-vulpea-site-build)
    (should (string-match-p "VISIBLEBODY" (mho-site-test--html "ENTRY")))
    (should-not (string-match-p "ARCHIVEDBODY\\|ARCHIVEDGROUPBODY" (mho-site-test--all-html)))))

(ert-deftest mho-site-ordinary-public-source-must-pass-validity-checks ()
  "Private app status for ambiguous ordinary notes must also stop publication."
  (dolist (body '("#+TITLE: Duplicate title\nBODY"
                  "#+FILETAGS: :public:\nBODY"
                  "* Heading\n:PROPERTIES:\n:ID: HEAD\n:ID: OTHER\n:END:\nBODY"
                  "* Heading\n:PROPERTIES:\n:ID: FILE\n:END:\nBODY"
                  "* Heading\n:PROPERTIES:\n:ID: HEAD\n:END:\nBODY\n* Private :private:\n:PROPERTIES:\n:ID: head\n:END:\nPRIVATE"
                  "#+BEGIN_SRC org\nUNFINISHED"
                  ":LOGBOOK:\nUNFINISHED"))
    (mho-site-test--workspace
      (mho-site-test--note "FILE" "Public note" '("public") body)
      (should-error (mho-vulpea-site-build) :type 'user-error))))

(ert-deftest mho-site-invalid-file-aliases-stop-notes-and-journal-entries ()
  "Both public projections reject the same malformed aliases as the app."
  (dolist (journal '(nil t))
    (dolist (key '("ALIASES" "ROAM_ALIASES"))
      (dolist (aliases '("\"unfinished" "mid\"quote" "dangling\\" "\"closed\"joined" "\"escaped\\\""))
        (mho-site-test--workspace
          (let* ((path (mho-site-test--note
                        "FILE" (if journal "2026-10-25" "Public note")
                        (if journal '("journal") '("public"))
                        (if journal (mho-site-test--heading 1 "Selected" '("public") "ENTRY" "BODY") "BODY")))
                 (before (mho-site-test--read path)))
            (mho-site-test--write path (replace-regexp-in-string
                                        ":ID: FILE\n" (concat ":ID: FILE\n:" key ": " aliases "\n")
                                        before t t))
            (should-error (mho-vulpea-site-build) :type 'user-error)))))))

(ert-deftest mho-site-valid-file-aliases-preserve-publication ()
  "Quoted names, escaped characters, and opaque escapes remain valid."
  (dolist (journal '(nil t))
    (dolist (key '("ALIASES" "ROAM_ALIASES"))
      (mho-site-test--workspace
        (let ((path (mho-site-test--note
                     "FILE" (if journal "2026-10-25" "Public note")
                     (if journal '("journal") '("public"))
                     (if journal (mho-site-test--heading 1 "Selected" '("public") "ENTRY" "BODY") "BODY"))))
          (mho-site-test--write path (replace-regexp-in-string
                                      ":ID: FILE\n"
                                      (concat ":ID: FILE\n:" key ": Plain \"Two words\" \"A \\\"quote\\\"\" escaped\\ word \\\\path \\q\n")
                                      (mho-site-test--read path) t t))
          (mho-vulpea-site-build)
          (should (string-match-p "BODY" (mho-site-test--html (if journal "ENTRY" "FILE")))))))))

(ert-deftest mho-site-publicatorg-failure-keeps-last-complete-build ()
  "A failed Publicatorg compiler cannot replace the last complete preview."
  (mho-site-test--workspace
    (mho-site-test--note "PUB1" "Existing article" '("public" "blog") "Original body.")
    (mho-vulpea-site-build)
    (let ((before (mho-site-test--html "PUB1")))
      (cl-letf (((symbol-function 'porg-run)
                 (lambda (_name) (error "Synthetic compiler failure"))))
        (should-error (mho-vulpea-site-build)))
      (should (equal before (mho-site-test--html "PUB1"))))))

(ert-deftest mho-site-feed-follows-public-selection-and-withdrawal ()
  "RSS contains only public writing and withdraws entries with their source."
  (mho-site-test--workspace
    (mho-site-test--note "ARTICLE" "Writing & ideas" '("public" "blog") "ARTICLEBODY")
    (mho-site-test--note "WEEK" "A public week" '("public" "weeknote") "WEEKBODY")
    (mho-site-test--note "PAGE" "Permanent page" '("public" "page") "PAGEBODY")
    (let ((source (mho-site-test--note "PRIVATE" "PRIVATEFEEDSENTINEL" '("private" "blog") "SECRET")))
      (mho-vulpea-site-build)
      (let* ((file (expand-file-name "feed.xml" mho-vulpea-site-build-directory))
             (feed (mho-site-test--read file)))
        (should (string-match-p "Writing &amp; ideas" feed))
        (should (string-match-p "notes/ARTICLE.html" feed))
        (should (string-match-p "notes/WEEK.html" feed))
        (should-not (string-match-p "PRIVATEFEEDSENTINEL\\|Permanent page\\|ARTICLEBODY\\|SECRET" feed))
        (with-temp-buffer
          (insert feed)
          (should (eq 'rss (caar (xml-parse-region (point-min) (point-max)))))))
      ;; A stale public index must still obey the saved private source.
      (mho-site-test--write source ":PROPERTIES:\n:ID: PRIVATE\n:END:\n#+TITLE: PRIVATEFEEDSENTINEL\n#+FILETAGS: :private:blog:\nSECRET\n"))
    (mho-site-test--write
     (expand-file-name "ARTICLE.org" mho-vulpea-site-directory)
     ":PROPERTIES:\n:ID: ARTICLE\n:END:\n#+TITLE: Withdrawn article\n#+FILETAGS: :private:blog:\nWITHDRAWNFEEDSENTINEL\n")
    (mho-vulpea-site-build)
    (let ((feed (mho-site-test--read (expand-file-name "feed.xml" mho-vulpea-site-build-directory))))
      (should-not (string-match-p "ARTICLE.html\\|Withdrawn article\\|WITHDRAWNFEEDSENTINEL" feed)))))

(provide 'mho-vulpea-site-tests)
;;; mho-vulpea-site-tests.el ends here

(ert-deftest mho-site-stable-product-routes-links-and-media ()
  "Root product routes preserve cross-links, anchors, media and backlinks."
  (mho-site-test--workspace
    (let ((mho-vulpea-site-page-routes '(("PRODUCT" . "mho-0002.html") ("GUIDE" . "stillvaro-guide.html"))))
      (mho-site-test--note "PRODUCT" "Stillvaro" '("public" "page" "product")
                           "[[id:GUIDE][Guide]]\n[[id:ORDINARY][Article]]\n\n#+attr_html: :alt The practice dial :class screenshot :loading lazy :width 640 :height 480\n[[file:screen.svg]]\n* Help\n:PROPERTIES:\n:CUSTOM_ID: support\n:END:\nHelp text.")
      (mho-site-test--note "GUIDE" "Guide" '("public" "page" "documentation") "[[id:PRODUCT][Product]]")
      (mho-site-test--note "ORDINARY" "Ordinary" '("public" "blog") "[[id:PRODUCT][Product]]")
      (mho-site-test--write (expand-file-name "screen.svg" mho-vulpea-site-directory)
                            "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
      (mho-vulpea-site-build)
      (let ((product (mho-site-test--read (expand-file-name "mho-0002.html" mho-vulpea-site-build-directory)))
            (guide (mho-site-test--read (expand-file-name "stillvaro-guide.html" mho-vulpea-site-build-directory))))
        (should (string-match-p "href=\"stillvaro-guide.html\"" product))
        (should (string-match-p "href=\"notes/ORDINARY.html\"" product))
        (should (string-match-p "src=\"media/[a-f0-9]+.svg\"" product))
        (should (string-match-p "alt=\"The practice dial\"" product))
        (should (string-match-p "loading=\"lazy\"" product))
        (should (string-match-p "class=\"screenshot\"" product))
        (should (string-match-p "id=\"support\"" product))
        (should (string-match-p "class=\"stillvaro\"" product))
        (should (string-match-p "href=\"mho-0002.html\"" guide))
        (should (string-match-p "href=\"../mho-0002.html\"" (mho-site-test--html "ORDINARY")))))))

(ert-deftest mho-site-private-mapped-page-never-restores-old-checkout ()
  "Withdrawing a mapped page must not reveal its old retained website copy."
  (mho-site-test--workspace
    (let ((mho-vulpea-site-page-routes '(("PRODUCT" . "mho-0002.html")))
          (mho-vulpea-site-existing-pages '(("Stillvaro" "mho-0002.html" "Old"))))
      (mho-site-test--write (expand-file-name "mho-0002.html" mho-vulpea-site-repository) "OLDPUBLICSENTINEL")
      (let ((path (mho-site-test--note "PRODUCT" "Stillvaro" '("public" "page") "NEWPUBLICSENTINEL")))
        (mho-vulpea-site-build)
        (should (file-exists-p (expand-file-name "mho-0002.html" mho-vulpea-site-build-directory)))
        (mho-site-test--write path (replace-regexp-in-string ":public:" ":private:" (mho-site-test--read path)))
        (mho-vulpea-site-build)
        (should-not (file-exists-p (expand-file-name "mho-0002.html" mho-vulpea-site-build-directory)))
        (should-not (string-match-p "Stillvaro" (mho-site-test--read (expand-file-name "pages.html" mho-vulpea-site-build-directory))))))))

(ert-deftest mho-site-invalid-mapped-routes-rejected ()
  (mho-site-test--workspace
    (mho-site-test--note "A" "A" '("public" "page") "Public content")
    (dolist (routes '((("A" . "../outside.html")) (("A" . "index.html"))
                      (("A" . "product.html") ("B" . "product.html"))
                      (("A" . "product.html") ("A" . "other.html"))))
      (let ((mho-vulpea-site-page-routes routes))
        (should-error (mho-vulpea-site-build) :type 'user-error)))))

(ert-deftest mho-site-embeds-duo-masks-for-file-preview ()
  "A file preview must not depend on external mask images blocked by CORS."
  (mho-site-test--workspace
    (mho-vulpea-site-build)
    (let ((css (mho-site-test--read
                (expand-file-name "assets/vulpea-site.css" mho-vulpea-site-build-directory))))
      (dolist (asset '(("stillvaro-duo-outer-screen-mask.png" . "image/png")
                       ("stillvaro-duo-outer-screen-mask-landscape.svg" . "image/svg+xml")))
        (should-not (string-search (format "url(\"%s\")" (car asset)) css))
        (should (string-match
                 (concat (regexp-quote (format "url(\"data:%s;base64," (cdr asset)))
                         "\\([A-Za-z0-9+/=]+\\)\")") css))
        (let ((decoded (base64-decode-string (match-string 1 css)))
              (original (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally
                           (expand-file-name (car asset) mho-vulpea-site--assets))
                          (buffer-string))))
          (should (equal decoded original))))
      ;; Ordinary device artwork still resolves beside the generated CSS.
      (should (string-search "url(\"stillvaro-duo-outer-enclosure.png\")" css))
      (should (file-exists-p
               (expand-file-name "assets/stillvaro-duo-outer-enclosure.png"
                                 mho-vulpea-site-build-directory))))))

(ert-deftest mho-site-exports-built-theme-and-device-assets ()
  "Export a real build, including every device asset used by its stylesheet."
  (mho-site-test--workspace
    (mho-site-test--note "PUBLIC" "Public page" '("public") "Website content.")
    (mho-site-test--write
     (expand-file-name "assets/existing.png" mho-vulpea-site-repository) "UNMANAGED")
    (mho-vulpea-site-export)
    (let ((built (mho-vulpea-site-export--read-manifest mho-vulpea-site-build-directory))
          (exported (mho-vulpea-site-export--read-manifest mho-vulpea-site-repository)))
      (should (equal built exported))
      (dolist (route built)
        (should (equal
                 (mho-site-test--read
                  (expand-file-name route mho-vulpea-site-build-directory))
                 (mho-site-test--read
                  (expand-file-name route mho-vulpea-site-repository))))))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "assets/vulpea-site.css" mho-vulpea-site-repository))
      (while (re-search-forward "url(\"\\([^\"]+\\)\")" nil t)
        (let ((asset (match-string 1)))
          (unless (string-prefix-p "data:" asset)
            (should (file-regular-p
                     (expand-file-name (concat "assets/" asset)
                                       mho-vulpea-site-repository)))))))
    (should (equal "UNMANAGED"
                   (mho-site-test--read
                    (expand-file-name "assets/existing.png" mho-vulpea-site-repository))))))

(ert-deftest mho-site-org-layout-blocks-retain-semantics-and-link-privacy ()
  "Render the product title, actions, navigation and answers from Org alone."
  (mho-site-test--workspace
    (mho-site-test--note "GUIDE" "The guide" '("public" "page") "Guide text.")
    (mho-site-test--note "SECRET" "Private title" '("private") "PRIVATEBODY")
    (let* ((source
            (mho-site-test--note
             "PRODUCT" "Product" '("public" "page" "product")
             (concat
              "#+begin_sv-title\nThe art of\\\\\nchunking & learning.\n#+end_sv-title\n"
              "#+attr_html: :class sv-tagline\nFour digits at a time.\n\n"
              "#+begin_sv-actions\n[[https://example.com/app][Get the app]]\n"
              "[[#questions][Read the answers]]\n#+end_sv-actions\n"
              "#+begin_sv-nav\n[[#questions][Questions & answers]]\n#+end_sv-nav\n"
              "* Questions\n:PROPERTIES:\n:CUSTOM_ID: questions\n:END:\n"
              "#+caption: Can *I* use [[id:SECRET][private help]] & [[id:GUIDE][the guide]]?\n"
              "#+begin_sv-question\nYes. Read [[id:GUIDE][the guide]] and *practise*.\n\n"
              "- One step.\n- Another step.\n#+end_sv-question\n"
              "#+begin_sv-copy\nAn ordinary paragraph.\n#+end_sv-copy\n"
              "[[#hidden][Hidden anchor]] [[#SECRET][External ID as anchor]]\n"
              "* Hidden :private:\n:PROPERTIES:\n:CUSTOM_ID: hidden\n:END:\nHIDDENBODY\n")))
           (before (mho-site-test--read source)))
      (mho-vulpea-site-build)
      (let ((html (mho-site-test--html "PRODUCT")))
        (should (string-match-p
                 "<h1 id=\"page-title\">The art of<br */?>\nchunking &amp; learning.</h1>" html))
        (should (string-match-p "<p class=\"sv-tagline\">\nFour digits at a time." html))
        (should (string-match-p
                 "<div class=\"sv-actions\"[^>]*>\n<a href=\"https://example.com/app\">Get the app</a>" html))
        (should (string-match-p
                 "<nav class=\"sv-nav\" aria-label=\"Stillvaro page\">\n<a href=\"#questions\">Questions &amp; answers</a>" html))
        (should (string-search "<details><summary>Can <b>I</b> use private help &amp; <a href=\"GUIDE.html\">the guide</a>?</summary>" html))
        (should (string-match-p "<p>\nYes. Read <a href=\"GUIDE.html\">the guide</a> and <b>practise</b>." html))
        (should (string-match-p "<li>One step.</li>" html))
        (should (string-match-p "<div class=\"sv-copy\"[^>]*>\n<p>\nAn ordinary paragraph." html))
        (should-not (string-match-p "href=\"[^\"]*SECRET\\|PRIVATEBODY\\|Private title\\|HIDDENBODY\\|href=\"#hidden\"" html)))
      (should (equal before (mho-site-test--read source))))))

(ert-deftest mho-site-org-layout-reports-missing-title-or-question ()
  "Reject incomplete semantic blocks with a useful authoring error."
  (dolist (body '("#+begin_sv-title\nFirst paragraph.\n\nSecond paragraph.\n#+end_sv-title"
                  "#+begin_sv-question\nAnswer without its question.\n#+end_sv-question"))
    (mho-site-test--workspace
      (mho-site-test--note "PRODUCT" "Product" '("public" "page" "product") body)
      (should-error (mho-vulpea-site-build) :type 'user-error))))

(ert-deftest mho-site-single-file-keeps-separate-pages-links-and-media ()
  "An Org source can own a product and its documentation without duplication."
  (mho-site-test--workspace
    (let* ((mho-vulpea-site-page-routes
            '(("PRODUCT" . "mho-0002.html") ("GUIDE" . "stillvaro-guide.html")))
           (source (mho-site-test--note
                    "PRODUCT" "Stillvaro" '("public" "page" "product")
                    (concat
                     "PRODUCTBODYSENTINEL [[id:GUIDE][Guide]]\n"
                     "* Support\n:PROPERTIES:\n:CUSTOM_ID: support\n:END:\nSupport body.\n"
                     "* Stillvaro guide :documentation:\n:PROPERTIES:\n:ID: GUIDE\n"
                     ":SITE_PAGE: documentation\n:PUBLISH_DATE: 2026-11-01\n"
                     ":DESCRIPTION: A short guide.\n:END:\nGUIDEBODYSENTINEL\n"
                     "[[id:PRODUCT][Product]] [[file:screen.svg]]\n"
                     "** First steps\n:PROPERTIES:\n:CUSTOM_ID: first-steps\n:END:\nStep one.\n"
                     "** Hidden :private:\nHIDDENGUIDESENTINEL\n")))
           (before (mho-site-test--read source)))
      (mho-site-test--note "ARTICLE" "Related article" '("public" "blog")
                         "[[file:PRODUCT.org][Product file]] [[id:GUIDE][Guide]]")
      (mho-site-test--write (expand-file-name "screen.svg" mho-vulpea-site-directory)
                           "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
      (mho-vulpea-site-build)
      (let ((product (mho-site-test--read (expand-file-name "mho-0002.html" mho-vulpea-site-build-directory)))
            (guide (mho-site-test--read (expand-file-name "stillvaro-guide.html" mho-vulpea-site-build-directory))))
        (should (string-match-p "PRODUCTBODYSENTINEL" product))
        (should-not (string-match-p "GUIDEBODYSENTINEL" product))
        (should (string-match-p "GUIDEBODYSENTINEL" guide))
        (should-not (string-match-p "PRODUCTBODYSENTINEL\\|HIDDENGUIDESENTINEL" guide))
        (should (string-match-p "href=\"stillvaro-guide.html\"" product))
        (should (string-match-p "href=\"mho-0002.html\"" guide))
        (should (string-match-p "href=\"../mho-0002.html\">Product file" (mho-site-test--html "ARTICLE")))
        (should (string-match-p "href=\"../stillvaro-guide.html\"" (mho-site-test--html "ARTICLE")))
        (should (string-match-p "<h2 id=\"first-steps\"" guide))
        (should (string-match-p "id=\"support\"" product))
        (should (string-match-p "src=\"media/[a-f0-9]+.svg\"" guide))
        (should (string-match-p "A short guide" guide))
        (should-not (string-match-p "Stillvaro guide" (mho-site-test--read (expand-file-name "index.html" mho-vulpea-site-build-directory)))))
      (should (equal before (mho-site-test--read source)))
      ;; Withdrawing the shared source removes both routes, even with a stale DB.
      (mho-site-test--write source (replace-regexp-in-string ":public:" ":private:" before))
      (mho-vulpea-site-build)
      (dolist (route '("mho-0002.html" "stillvaro-guide.html"))
        (should-not (file-exists-p (expand-file-name route mho-vulpea-site-build-directory)))))))

(ert-deftest mho-site-subpages-respect-file-and-subtree-privacy ()
  "Explicit page markers cannot override a file or subtree privacy veto."
  (mho-site-test--workspace
    (mho-site-test--note
     "PRIVATE" "Private product" '("private" "public")
     "* Secret :public:\n:PROPERTIES:\n:ID: SECRET\n:SITE_PAGE: documentation\n:END:\nFILESECRETSENTINEL")
    (mho-site-test--note
     "PUBLIC" "Public product" '("public")
     (concat
      "Visible.\n* Hidden :private:\n:PROPERTIES:\n:ID: HIDDEN\n:SITE_PAGE: documentation\n:END:\nPRIVATESUBPAGESENTINEL\n"
      "* Excluded :noexport:\n:PROPERTIES:\n:ID: EXCLUDED\n:SITE_PAGE: documentation\n:END:\nNOEXPORTSUBPAGESENTINEL\n"
      "* COMMENT Internal\n:PROPERTIES:\n:ID: INTERNAL\n:SITE_PAGE: documentation\n:END:\nCOMMENTSUBPAGESENTINEL\n"))
    (mho-vulpea-site-build)
    (dolist (id '("PRIVATE" "SECRET" "HIDDEN" "EXCLUDED" "INTERNAL"))
      (should-not (file-exists-p (expand-file-name (concat "notes/" id ".html") mho-vulpea-site-build-directory))))
    (should-not (string-match-p "SECRETSENTINEL\\|SUBPAGESENTINEL" (mho-site-test--all-html)))))

(ert-deftest mho-site-subpages-reject-ambiguous-identity-and-nesting ()
  "Reject unsafe IDs, missing IDs, unsupported page kinds and nested pages."
  (mho-site-test--workspace
    (dolist (body '("* Missing ID\n:PROPERTIES:\n:SITE_PAGE: documentation\n:END:\nBody."
                    "* Unsafe ID\n:PROPERTIES:\n:ID: ../escape\n:SITE_PAGE: documentation\n:END:\nBody."
                    "* Duplicate ID\n:PROPERTIES:\n:ID: PRODUCT\n:SITE_PAGE: documentation\n:END:\nBody."
                    "* Invalid layout\n:PROPERTIES:\n:ID: GUIDE\n:SITE_PAGE: unknown\n:END:\nBody."
                    "* Container\n** Nested page\n:PROPERTIES:\n:ID: GUIDE\n:SITE_PAGE: documentation\n:END:\nBody."))
      (setq mho-site-test--notes nil)
      (mho-site-test--note "PRODUCT" "Product" '("public") body)
      (should-error (mho-vulpea-site-build) :type 'user-error))))
