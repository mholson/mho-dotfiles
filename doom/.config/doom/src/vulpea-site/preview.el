;;; preview.el --- Build a persistent sample website -*- lexical-binding: t; -*-

;;; Commentary:
;; Run from the Doom config:
;;   emacs --batch -Q -l src/vulpea-site/preview.el
;; MHO_EMACS_PACKAGE_DIR can select another straight package build directory.
;; By default, keep a new fixture under Emacs' temporary-file-directory.
;; Rebuild the same preview by setting MHO_SITE_PREVIEW_ROOT to its printed path.
;; Reuse requires this script's ownership marker and a root in a temporary
;; directory.  No real notes or website checkout files are modified.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(let* ((packages (or (getenv "MHO_EMACS_PACKAGE_DIR")
                     (expand-file-name
                      (format "~/.config/emacs/.local/straight/build-%d.%d/"
                              emacs-major-version emacs-minor-version))))
       (src (expand-file-name "../" (file-name-directory load-file-name))))
  (unless (file-directory-p packages)
    (error "Set MHO_EMACS_PACKAGE_DIR to Doom's straight package build directory"))
  (dolist (path (directory-files packages t "^[^.].*"))
    (when (file-directory-p path) (add-to-list 'load-path path)))
  (add-to-list 'load-path src))

(dolist (path (split-string (or (getenv "MHO_SITE_EXTRA_LOAD_PATH") "") path-separator t))
  (add-to-list 'load-path path))
(require 'mho-vulpea-site)
(defvar mho-vulpea-site-theme-preview-p nil)

(defconst mho-site-preview--marker ".mho-vulpea-site-preview")
(defconst mho-site-preview--signature "mho-vulpea-site-preview-v1\n")

(defun mho-site-preview--root ()
  "Create or validate an owned temporary preview root."
  (let* ((requested (let ((value (getenv "MHO_SITE_PREVIEW_ROOT")))
                      (and value (not (string-empty-p value)) value)))
         (root (if requested
                   (file-name-as-directory (expand-file-name requested))
                 (file-name-as-directory (make-temp-file "mho-site-preview-" t))))
         (marker (expand-file-name mho-site-preview--marker root))
         (temporary-roots (delete-dups
                           (mapcar (lambda (path) (file-name-as-directory (file-truename path)))
                                   (list temporary-file-directory "/tmp/")))))
    (when (or (file-remote-p root)
              (file-symlink-p (directory-file-name root))
              (not (cl-some (lambda (parent) (file-in-directory-p (file-truename root) parent))
                            temporary-roots)))
      (user-error "Preview root must be a local directory inside a temporary directory"))
    (when requested
      (unless (and (file-directory-p root)
                   (file-regular-p marker)
                   (not (file-symlink-p marker))
                   (equal (with-temp-buffer
                            (insert-file-contents marker)
                            (buffer-string))
                          mho-site-preview--signature))
        (user-error "Refusing to reuse an unowned preview directory: %s" root)))
    (unless requested
      (with-temp-file marker (insert mho-site-preview--signature)))
    (dolist (directory '("notes" "data" "build"))
      (let ((path (expand-file-name directory root)))
        (when (or (file-symlink-p path)
                  (and (file-exists-p path) (not (file-directory-p path))))
          (user-error "Preview subdirectory must be an ordinary directory: %s" path))))
    root))

(defconst mho-site-preview--notes
  '((:id "d0af2f8c-2f4c-48e4-9ad0-000000000001"
     :title "A note should still make sense next month"
     :kind "blog" :date "2026-10-12"
     :description "A sample essay about context, useful links, and leaving a clear path back into an idea."
     :body "This sample essay explores a practical question: what needs to remain when the original conversation is gone? A useful note keeps enough context to be read on its own, and enough links to be read alongside other things.

* Start with the question
A title gives a note a place to begin. The opening paragraph explains why the question matters. The rest should help a future reader recover the reasoning without reconstructing the whole day.

#+BEGIN_QUOTE
Leave a small amount of context where it will save a large amount of searching.
#+END_QUOTE

The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000015][before-sharing checklist]] is one way to turn that idea into a repeatable habit. Links are useful when their destination answers a question raised by the current paragraph.

* Give the idea some structure
An outline is a way to separate claims, evidence, and the next useful question. It can be light: two or three headings are often enough.

| Part | What it preserves | A useful check |
|------+-------------------+----------------|
| Question | The original uncertainty | Is it specific? |
| Example | A concrete observation | Can it be repeated? |
| Link | Related context | Does the label explain it? |
| Next step | Something still unresolved | Is it small enough? |

* A small model of review
Suppose a note has \\(n\\) useful connections. A simple toy score is \\(r = n/(n+1)\\): the first few links add more than the tenth. This is an illustration, not a measure of the quality of a real collection.

\\[
R_N = \\sum_{n=1}^{N} \\frac{1}{n(n+1)} = 1 - \\frac{1}{N+1}
\\]

The point of the model is to ask which connection helps most. A long list of references can be less useful than one carefully described link.

* Keep the source simple
An ordinary Org file keeps text, structure, and identity together. The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000002][small-tools example]] takes the same approach to commands.

#+BEGIN_SRC emacs-lisp :eval never :exports code
(defun sample-note-summary (title links)
  (format \"%s — %d useful connections\" title (length links)))
#+END_SRC

The next revision does not need to make the note complete. It only needs to make the next reading easier.

* Unpublished working material :private:
MHOPREVIEWPRIVATESENTINEL
This hidden fixture proves that private source material stays out of the sample website.
** Also hidden
Nested working text remains private.")
    (:id "d0af2f8c-2f4c-48e4-9ad0-000000000002"
     :title "Small tools, clear interfaces"
     :kind "blog" :date "2026-04-08"
     :description "A sample note on giving a command one understandable job."
     :body "This sample starts with a small tool: a command that takes a title, creates a note, and opens it. Its usefulness comes from a clear result and a short path to that result.

* Make the input visible
:PROPERTIES:
:ID: d0af2f8c-2f4c-48e4-9ad0-000000000012
:END:
Ask for the information needed now. Keep defaults visible and make empty input easy to correct. A prompt is part of the interface, just as much as a button or a page title.

#+BEGIN_SRC emacs-lisp :eval never :exports code
(defun sample-clean-title (title)
  (let ((clean (string-trim title)))
    (if (string-empty-p clean)
        (user-error \"Give the note a title\")
      clean)))
#+END_SRC

* Finish in a useful place
After a command succeeds, the result should be ready for the next action. For a note, that usually means opening the file at its beginning.

The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000006][sample Emacs workbench]] collects a few related operations. The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000001][essay on readable notes]] describes the same principle for written material.")
    (:id "d0af2f8c-2f4c-48e4-9ad0-000000000003"
     :title "Weeknote 42: Make one path easier"
     :kind "weeknote" :date "2026-10-12"
     :description "An illustrative weekly entry: one improvement, one observation, and one next step."
     :body "This is a sample weeknote for the preview, not a record of a real week.

* One improvement
A repeated operation became a single command with a clear result. The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000012][input-design example]] shows the kind of small change being considered.

* One observation
The last step matters. An operation that creates a file but leaves the reader searching for it still feels unfinished.

* One next step
- [X] Write down the current path.
- [X] Remove one unnecessary decision.
- [ ] Try the [[id:d0af2f8c-2f4c-48e4-9ad0-000000000005][publishing checklist]] on another sample note.")
    (:id "d0af2f8c-2f4c-48e4-9ad0-000000000004"
     :title "Weeknote 01: Keep the useful pieces"
     :kind "weeknote" :date "2025-12-29"
     :description "A sample year-boundary entry about carrying useful notes forward."
     :body "This sample entry belongs to ISO week 01 of 2026, even though its calendar date is in December 2025. It gives the archive a useful year-boundary example.

* Keep
Keep the explanations that stand on their own. Keep the examples that still run. Keep the questions that are still worth asking.

* Revisit
Some notes need a better title. Others need one sentence of context or a link to the idea that motivated them.

* Leave room
A collection does not need a final structure before it can be useful. The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000006][workbench sample]] is deliberately small enough to change.")
    (:id "d0af2f8c-2f4c-48e4-9ad0-000000000005"
     :title "A small publishing checklist"
     :kind "page" :date "2025-08-19"
     :description "An example reference page for checking a note before sharing it."
     :body "This reference page is sample content. It shows how an evergreen page can sit beside dated writing and weeknotes.

* Before sharing
:PROPERTIES:
:ID: d0af2f8c-2f4c-48e4-9ad0-000000000015
:END:
- [ ] The title explains the subject.
- [ ] The opening gives enough context.
- [ ] Links lead to material that is also public.
- [ ] Examples are clearly distinguished from personal records.
- [ ] Private working material stays in a private subtree.

* Read it as a visitor
Follow the links once. Look at the headings without reading the paragraphs. Check the page on a narrow screen.

The [[id:d0af2f8c-2f4c-48e4-9ad0-000000000001][sample essay]] contains a table, code, formulas, and a link back to this heading. Those details help exercise a real reading layout.")
    (:id "d0af2f8c-2f4c-48e4-9ad0-000000000006"
     :title "An Emacs workbench"
     :kind "page" :date "2026-02-14"
     :description "A sample reference page for a few everyday note-taking operations."
     :body "A workbench is easier to use when related actions sit together. This illustrative page names a few operations without claiming a particular personal workflow.

| Operation | Result |
|-----------+--------|
| Find a note | Open an existing idea |
| Create a note | Give a new idea an identity |
| Insert a link | Connect two pieces of context |
| Read backlinks | See where the idea is used |
| Open a journal | Return to a dated entry |

* Keep the commands readable
A command name should explain the action. A short key binding is useful after the operation is familiar.

See [[id:d0af2f8c-2f4c-48e4-9ad0-000000000002][small tools, clear interfaces]] for a compact example and the [[id:d0af2f8c-2f4c-48e4-9ad0-000000000003][sample weeknote]] for a possible next step."))
  "Six illustrative public notes with stable UUIDs and source filenames.")

(let* ((root (mho-site-preview--root))
       (notes (expand-file-name "notes/" root))
       (data (expand-file-name "data/" root))
       (user-emacs-directory data)
       (org-directory notes)
       (org-agenda-files nil)
       (org-id-locations-file (expand-file-name "org-id-locations" data))
       (org-id-locations (make-hash-table :test #'equal))
       (org-id-files nil)
       (org-id-extra-files nil)
       (vulpea-default-notes-directory notes)
       (vulpea-db-sync-directories (list notes))
       (vulpea-db-location (expand-file-name "vulpea.db" data))
       (vulpea-db--connection nil)
       (mho-vulpea-site-directory notes)
       (mho-vulpea-site-build-directory (expand-file-name "build/" root))
       (mho-vulpea-site-theme-preview-p t))
  (make-directory notes t)
  (make-directory data t)
  (when (file-symlink-p vulpea-db-location)
    (user-error "Preview database must not be a symlink: %s" vulpea-db-location))
  (unwind-protect
      (progn
        (dolist (note mho-site-preview--notes)
          (let* ((id (plist-get note :id))
                 (path (expand-file-name (concat id ".org") notes)))
            (when (file-symlink-p path)
              (user-error "Refusing to overwrite a symlink in the preview: %s" path))
            (with-temp-file path
              (insert
               (format ":PROPERTIES:\n:ID: %s\n:CREATED: [%s]\n:END:\n#+title: %s\n#+date: %s\n#+description: %s\n#+filetags: :public:%s:\n\n%s\n"
                       id (plist-get note :date) (plist-get note :title)
                       (plist-get note :date) (plist-get note :description)
                       (plist-get note :kind) (plist-get note :body))))
            (vulpea-db-update-file path)))
        (let ((build (mho-vulpea-site-build)))
          (princ (format "MHO_SITE_PREVIEW_ROOT=%s\nBuild directory: %s\nHome: %s\nSample article: %s\n"
                         root build (expand-file-name "index.html" build)
                         (expand-file-name
                          "notes/d0af2f8c-2f4c-48e4-9ad0-000000000001.html" build)))))
    (when vulpea-db--connection (vulpea-db-close))))

;;; preview.el ends here
