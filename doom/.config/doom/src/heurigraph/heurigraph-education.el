;;; heurigraph-education.el --- Education extension for Heurigraph -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 4.3.1
;; Package-Requires: ((emacs "30.2") (heurigraph "4.3.1"))
;; Keywords: tools, languages, typst, education
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; Education-only activation and key bindings layered over the generic forest
;; and ontology support in heurigraph.el and heurigraph-mode.el.  Activation is
;; driven by the resolved project bundle identity, not a directory name.

;;; Code:

(require 'heurigraph)
(require 'heurigraph-mode)

(defgroup heurigraph-education nil
  "Education authoring extensions for Heurigraph."
  :group 'heurigraph
  :prefix "heurigraph-education-")

(defcustom heurigraph-education-default-subject "math:mathematics"
  "Fallback subject for education nodes when the resolved registry is unavailable."
  :type '(choice (const :tag "None" nil) string)
  :group 'heurigraph-education)

(defcustom heurigraph-education-taxons
  '("math:concept" "math:definition" "math:result" "math:procedure"
    "math:example" "edu:learning-objective" "edu:learning-component"
    "edu:exercise" "edu:problem" "edu:assessment-item"
    "edu:worked-example" "edu:solution" "edu:explanation"
    "edu:assessment" "edu:assessment-section" "edu:question-part"
    "curriculum:framework" "curriculum:course" "curriculum:objective"
    "curriculum:competency" "ibdp:topic" "ibdp:subtopic"
    "ibdp:learning-statement" "ibdp:command-term")
  "Compact fallback taxon ids for education projects.
The resolved project ontology remains authoritative."
  :type '(repeat string)
  :group 'heurigraph-education)

(defcustom heurigraph-education-subjects
  '("math:mathematics" "math:algebra" "math:number"
    "math:statistics-probability")
  "Compact fallback subject ids for education projects."
  :type '(repeat string)
  :group 'heurigraph-education)

(defcustom heurigraph-education-predicates
  '("math:depends_on" "math:uses" "math:defines" "math:proves"
    "edu:has_learning_prerequisite" "edu:teaches" "edu:illustrates"
    "edu:assesses" "edu:has_part" "edu:has_stimulus" "edu:solution_to"
    "curriculum:aligns_to" "curriculum:supports" "curriculum:part_of"
    "curriculum:precedes" "ibdp:clarifies" "ibdp:uses_command_term")
  "Compact fallback predicate ids for education projects."
  :type '(repeat string)
  :group 'heurigraph-education)

(defcustom heurigraph-education-response-formats
  '("short-response" "extended-response" "multiple-choice" "numeric"
    "symbolic" "graphical" "proof" "mixed")
  "Controlled response formats offered by education assessment commands."
  :type '(repeat string)
  :group 'heurigraph-education)

(defcustom heurigraph-manuscript-default-profile "draft"
  "Default publication profile used by semantic manuscript commands."
  :type '(choice (const "draft") (const "release"))
  :group 'heurigraph-education)

(defun heurigraph-education-lsp-project-file-p (file mode root)
  "Recognize education-owned FILE in MODE below project ROOT."
  (when (memq mode '(toml-mode toml-ts-mode conf-toml-mode))
    (let ((collections (file-name-as-directory
                        (expand-file-name "collections" root)))
          (manuscripts (file-name-as-directory
                        (expand-file-name "manuscripts" root))))
      (or (file-in-directory-p file collections)
          (and (file-in-directory-p file manuscripts)
               (string= (file-name-nondirectory file) "manuscript.toml"))))))

(with-eval-after-load 'heurigraph-lsp
  (add-hook 'heurigraph-lsp-extra-project-file-functions
            #'heurigraph-education-lsp-project-file-p))

(defun heurigraph-education-filter-context-candidates (field candidates)
  "Restrict context CANDIDATES for education context FIELD."
  (let ((taxons
         (pcase field
           ("framework" '("curriculum:framework"))
           ("stage" '("curriculum:course" "curriculum:stage"))
           (_ nil))))
    (if (null taxons)
        candidates
      (seq-filter
       (lambda (candidate)
         (member (alist-get 'taxon (cdr candidate)) taxons))
       candidates))))

(add-hook 'heurigraph-assertion-context-candidate-filter-functions
          #'heurigraph-education-filter-context-candidates)

(defun heurigraph-education-project-p ()
  "Return non-nil when the current forest resolves `heurigraph:education'."
  (condition-case nil
      (pcase-let ((`(,code . ,output)
                   (heurigraph--call-output
                    '("bundle" "show" "heurigraph:education" "--json"))))
        (and (zerop code)
             (equal (alist-get 'id
                               (heurigraph--parse-json-output
                                output "education module"))
                    "heurigraph:education")))
    (error nil)))

(defun heurigraph-education--apply-fallbacks ()
  "Install education fallbacks buffer-locally.
Resolved ontology JSON replaces these values during normal completion."
  (setq-local heurigraph-default-subject heurigraph-education-default-subject)
  (setq-local heurigraph-subjectless-taxon-prefixes '("curriculum:"))
  (setq-local heurigraph-taxons heurigraph-education-taxons)
  (setq-local heurigraph-subjects heurigraph-education-subjects)
  (setq-local heurigraph-predicate-types heurigraph-education-predicates))

;;; Semantic manuscripts ----------------------------------------------------

(defun heurigraph--manuscript-rows ()
  "Return manuscript rows from `heurigraph manuscript list --json'."
  (pcase-let ((`(,code . ,output)
               (heurigraph--call-output '("manuscript" "list" "--json"))))
    (unless (zerop code)
      (user-error "Heurigraph manuscript list failed: %s"
                  (string-trim output)))
    (append (heurigraph--parse-json-output output "manuscript list") nil)))

(defun heurigraph--manuscript-id-at-file ()
  "Return the current manuscript id when visiting its manifest."
  (when buffer-file-name
    (let* ((root (file-truename (heurigraph--root)))
           (manuscripts (file-name-as-directory
                         (expand-file-name "manuscripts" root)))
           (file (file-truename buffer-file-name)))
      (when (and (file-in-directory-p file manuscripts)
                 (string= (file-name-nondirectory file) "manuscript.toml"))
        (file-name-nondirectory
         (directory-file-name (file-name-directory file)))))))

(defun heurigraph--read-manuscript-id ()
  "Read a semantic manuscript id, defaulting to the current manifest."
  (let* ((rows (heurigraph--manuscript-rows))
         (_ (unless rows (user-error "No manuscript manifests found")))
         (choices
          (mapcar (lambda (row)
                    (cons (format "%s — %s"
                                  (alist-get 'id row)
                                  (alist-get 'title row))
                          (alist-get 'id row)))
                  rows))
         (default (heurigraph--manuscript-id-at-file))
         (default-label
          (car (seq-find (lambda (candidate)
                           (equal (cdr candidate) default))
                         choices)))
         (choice (completing-read "Manuscript: " choices nil t
                                  nil nil default-label)))
    (or (cdr (assoc choice choices))
        (and (not (string-empty-p choice)) choice)
        (user-error "No manuscript selected"))))

(defun heurigraph--manuscript-build-args ()
  "Return interactive manuscript and profile arguments."
  (list
   (heurigraph--read-manuscript-id)
   (completing-read "Profile: " '("draft" "release") nil t nil nil
                    heurigraph-manuscript-default-profile)
   current-prefix-arg))

;;;###autoload
(defun heurigraph-manuscript-build (manuscript profile &optional force)
  "Build MANUSCRIPT for PROFILE as reference Typst/PDF output.
With a prefix argument FORCE, replace an existing output even when its bytes
have changed."
  (interactive (heurigraph--manuscript-build-args))
  (heurigraph--compile
   (append (list "manuscript" "build" manuscript "--profile" profile)
           (when force (list "--force")))
   "*heurigraph-manuscript-build*"))

;;; Education metadata ------------------------------------------------------

(defun heurigraph-education--insert-metadata-call (name fields)
  "Insert a Typst metadata call named NAME containing ordered FIELDS."
  (unless (bolp) (insert "\n"))
  (insert (format "#%s(\n" name)
          (mapconcat #'identity fields "\n")
          "\n)"))

;;;###autoload
(defun heurigraph-insert-assessment-data
    (order label marks calculator response-format cognitive-demand inquiry-stages)
  "Insert structured education assessment item metadata at point.
ORDER, LABEL, MARKS, CALCULATOR, RESPONSE-FORMAT, COGNITIVE-DEMAND, and
INQUIRY-STAGES become optional fields in the inserted call."
  (interactive
   (list
    (heurigraph--read-optional-positive-integer "Order (blank for none): ")
    (string-trim (read-string "Part label (blank for none): "))
    (heurigraph--read-optional-positive-integer "Marks (blank to derive): ")
    (completing-read "Calculator permitted (true/false, blank for none): "
                     '("" "true" "false") nil t)
    (completing-read "Response format (blank for none): "
                     heurigraph-education-response-formats nil t)
    (string-trim (read-string "Cognitive demand (blank for none): "))
    (split-string
     (read-string "Inquiry stages (comma-separated, blank for none): ")
     "[[:space:]]*,[[:space:]]*" t)))
  (unless (member calculator '("" "true" "false"))
    (user-error "Calculator must be true, false, or blank"))
  (let (fields)
    (when order (push (format "  order: %d," order) fields))
    (unless (string-empty-p label)
      (push (format "  label: \"%s\"," (heurigraph--typst-string label)) fields))
    (when marks (push (format "  marks: %d," marks) fields))
    (unless (string-empty-p calculator)
      (push (format "  calculator: %s," calculator) fields))
    (unless (string-empty-p response-format)
      (push (format "  response-format: \"%s\","
                    (heurigraph--typst-string response-format)) fields))
    (unless (string-empty-p cognitive-demand)
      (push (format "  cognitive-demand: \"%s\","
                    (heurigraph--typst-string cognitive-demand)) fields))
    (when inquiry-stages
      (push (format "  inquiry-stages: (%s),"
                    (mapconcat
                     (lambda (stage)
                       (format "\"%s\"" (heurigraph--typst-string stage)))
                     inquiry-stages ", "))
            fields))
    (heurigraph-education--insert-metadata-call
     "assessment-data" (nreverse fields))))

;;;###autoload
(defun heurigraph-insert-assessment-scheme-data
    (completeness total-weighting-percent declared-external-duration-minutes)
  "Insert bounded education assessment scheme metadata at point.
COMPLETENESS is required; TOTAL-WEIGHTING-PERCENT and
DECLARED-EXTERNAL-DURATION-MINUTES are optional positive integers."
  (interactive
   (list
    (completing-read "Scheme completeness: " '("complete" "partial") nil t nil nil
                     "complete")
    (heurigraph--read-optional-positive-integer
     "Total weighting percent (blank means 100): ")
    (heurigraph--read-optional-positive-integer
     "Declared external duration in minutes (blank for none): ")))
  (unless (member completeness '("complete" "partial"))
    (user-error "Completeness must be complete or partial"))
  (when (and total-weighting-percent (> total-weighting-percent 100))
    (user-error "Total weighting percent must not exceed 100"))
  (let ((fields (list (format "  completeness: \"%s\"," completeness))))
    (when total-weighting-percent
      (setq fields
            (append fields
                    (list (format "  total-weighting-percent: %d,"
                                  total-weighting-percent)))))
    (when declared-external-duration-minutes
      (setq fields
            (append fields
                    (list (format "  declared-external-duration-minutes: %d,"
                                  declared-external-duration-minutes)))))
    (heurigraph-education--insert-metadata-call "assessment-scheme-data" fields)))

;;;###autoload
(defun heurigraph-insert-assessment-component-data
    (mode weighting-percent duration-minutes notional-hours)
  "Insert weighted education assessment component metadata at point.
MODE and WEIGHTING-PERCENT are required; DURATION-MINUTES and NOTIONAL-HOURS
are optional positive integers."
  (interactive
   (list
    (completing-read "Component mode: " '("external" "internal") nil t)
    (read-number "Weighting percent: ")
    (heurigraph--read-optional-positive-integer
     "Timed duration in minutes (blank for none): ")
    (heurigraph--read-optional-positive-integer
     "Notional work time in hours (blank for none): ")))
  (unless (member mode '("external" "internal"))
    (user-error "Mode must be external or internal"))
  (unless (and (integerp weighting-percent) (<= 1 weighting-percent 100))
    (user-error "Weighting percent must be between 1 and 100"))
  (let ((fields (list (format "  mode: \"%s\"," mode)
                      (format "  weighting-percent: %d," weighting-percent))))
    (when duration-minutes
      (setq fields
            (append fields (list (format "  duration-minutes: %d," duration-minutes)))))
    (when notional-hours
      (setq fields
            (append fields (list (format "  notional-hours: %d," notional-hours)))))
    (heurigraph-education--insert-metadata-call "assessment-component-data" fields)))

;;;###autoload
(defun heurigraph-insert-mark-scheme-point (order code marks description)
  "Insert one ordered education mark-scheme point at point.
ORDER and MARKS are positive integers; CODE and DESCRIPTION are required."
  (interactive
   (list (read-number "Point order: " 1)
         (read-string "Mark code (for example M1 or A1): ")
         (read-number "Marks: " 1)
         (read-string "Description: ")))
  (unless (and (integerp order) (> order 0) (integerp marks) (> marks 0))
    (user-error "Order and marks must be positive integers"))
  (when (or (string-empty-p (string-trim code))
            (string-empty-p (string-trim description)))
    (user-error "Code and description must not be blank"))
  (heurigraph-education--insert-metadata-call
   "mark-scheme-point"
   (list (format "  order: %d," order)
         (format "  code: \"%s\"," (heurigraph--typst-string code))
         (format "  marks: %d," marks)
         (format "  description: \"%s\"," (heurigraph--typst-string description)))))

;;;###autoload
(defun heurigraph-insert-exam-administration
    (authority programme course year session time-zone paper component language version
               duration-minutes declared-total-marks coverage status permitted-materials)
  "Insert formal education exam administration metadata at point.
AUTHORITY, COURSE, and YEAR are required.  PROGRAMME, SESSION, TIME-ZONE,
PAPER, COMPONENT, LANGUAGE, VERSION, DURATION-MINUTES, DECLARED-TOTAL-MARKS,
COVERAGE, STATUS, and PERMITTED-MATERIALS are optional."
  (interactive
   (list
    (string-trim (read-string "Awarding authority: "))
    (string-trim (read-string "Programme (blank for none): "))
    (string-trim (read-string "Course: "))
    (read-number "Exam year: " (string-to-number (format-time-string "%Y")))
    (string-trim (read-string "Session (blank for none): "))
    (string-trim (read-string "Time zone (blank for none): "))
    (string-trim (read-string "Paper (blank for none): "))
    (string-trim (read-string "Component (blank for none): "))
    (string-trim (read-string "Language tag (blank for none): "))
    (string-trim (read-string "Version (blank for none): "))
    (heurigraph--read-optional-positive-integer
     "Official duration in minutes (blank for none): ")
    (heurigraph--read-optional-positive-integer
     "Official declared total marks (blank for none): ")
    (completing-read "Coverage (complete/partial, blank for none): "
                     '("" "complete" "partial") nil t)
    (completing-read "Paper status (official/specimen/mock, blank for none): "
                     '("" "official" "specimen" "mock") nil t)
    (split-string
     (read-string "Permitted materials (comma-separated, blank for none): ")
     "[[:space:]]*,[[:space:]]*" t)))
  (when (or (string-empty-p authority) (string-empty-p course))
    (user-error "Awarding authority and course must not be blank"))
  (unless (and (integerp year) (<= 1000 year 9999))
    (user-error "Exam year must be a four-digit integer"))
  (unless (member coverage '("" "complete" "partial"))
    (user-error "Coverage must be complete, partial, or blank"))
  (unless (member status '("" "official" "specimen" "mock"))
    (user-error "Paper status must be official, specimen, mock, or blank"))
  (let ((fields (list
                 (format "  authority: \"%s\"," (heurigraph--typst-string authority))
                 (format "  course: \"%s\"," (heurigraph--typst-string course))
                 (format "  year: %d," year))))
    (dolist (field `(("programme" . ,programme) ("session" . ,session)
                     ("time-zone" . ,time-zone) ("paper" . ,paper)
                     ("component" . ,component) ("language" . ,language)
                     ("version" . ,version)))
      (unless (string-empty-p (cdr field))
        (setq fields
              (append fields
                      (list (format "  %s: \"%s\"," (car field)
                                    (heurigraph--typst-string (cdr field))))))))
    (when duration-minutes
      (setq fields (append fields (list (format "  duration-minutes: %d,"
                                                duration-minutes)))))
    (when declared-total-marks
      (setq fields (append fields (list (format "  declared-total-marks: %d,"
                                                declared-total-marks)))))
    (unless (string-empty-p coverage)
      (setq fields (append fields (list (format "  coverage: \"%s\"," coverage)))))
    (unless (string-empty-p status)
      (setq fields (append fields (list (format "  status: \"%s\"," status)))))
    (setq permitted-materials
          (heurigraph--normalize-string-list permitted-materials))
    (when permitted-materials
      (setq fields
            (append fields
                    (list
                     (format "  permitted-materials: (%s),"
                             (mapconcat
                              (lambda (material)
                                (format "\"%s\""
                                        (heurigraph--typst-string material)))
                              permitted-materials ", "))))))
    (heurigraph-education--insert-metadata-call "exam-administration" fields)))

;;; Education assertion conveniences ---------------------------------------

;;;###autoload
(defun heurigraph-insert-depends-on ()
  "Insert a mathematics dependency assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "math:depends_on"))

;;;###autoload
(defun heurigraph-insert-uses ()
  "Insert the mathematics resource-use assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "math:uses"))

;;;###autoload
(defun heurigraph-insert-enables-method ()
  "Insert the mathematics method-enablement assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "math:enables_method"))

;;;###autoload
(defun heurigraph-insert-solution-to ()
  "Insert an education solution assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "edu:solution_to"))

;;;###autoload
(defun heurigraph-insert-strategy-for ()
  "Insert an education strategy assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "edu:strategy_for"))

;;;###autoload
(defun heurigraph-insert-addresses ()
  "Insert an education-addresses assertion."
  (interactive)
  (heurigraph--insert-fixed-assertion "edu:addresses"))

;;;###autoload
(defun heurigraph-education-module-preview ()
  "Preview the exact education-module migration without writing the forest."
  (interactive)
  (heurigraph--run '("module" "preview") "*heurigraph-module-migration*"))

;;;###autoload
(defun heurigraph-education-module-migrate (plan-digest)
  "Apply education module PLAN-DIGEST after explicit confirmation.
PLAN-DIGEST must come from `heurigraph-education-module-preview'.  The CLI
recomputes the plan under its project lock and refuses stale input."
  (interactive
   (list (string-trim
          (read-string "Plan digest from module preview: "))))
  (unless (string-match-p "\\`sha256:[[:xdigit:]]\\{64\\}\\'" plan-digest)
    (user-error "Plan digest must be sha256 followed by 64 hexadecimal digits"))
  (when (yes-or-no-p
         (format "Apply education-module plan %s? " plan-digest))
    (when (zerop
           (heurigraph--run
            (list "module" "migrate" "--plan" plan-digest)
            "*heurigraph-module-migration*"))
      (heurigraph--refresh-active-lsp)
      (message "Heurigraph Education: module migration complete"))))

(defvar-keymap heurigraph-education-note-mode-map
  :doc "Education commands layered over `heurigraph-note-mode'."
  "C-c h E" #'heurigraph-insert-assessment-data
  "C-c h G" #'heurigraph-insert-assessment-scheme-data
  "C-c h H" #'heurigraph-insert-assessment-component-data
  "C-c h K" #'heurigraph-insert-mark-scheme-point
  "C-c h z" #'heurigraph-insert-exam-administration
  "C-c h R" #'heurigraph-insert-depends-on
  "C-c h u" #'heurigraph-insert-uses
  "C-c h e" #'heurigraph-insert-enables-method
  "C-c h x" #'heurigraph-insert-solution-to
  "C-c h s" #'heurigraph-insert-strategy-for
  "C-c h m" #'heurigraph-insert-addresses
  "C-c h U" #'heurigraph-manuscript-build)

;;;###autoload
(define-minor-mode heurigraph-education-note-mode
  "Education authoring commands for a Heurigraph note buffer."
  :lighter " HeuriEdu"
  :keymap heurigraph-education-note-mode-map
  (when heurigraph-education-note-mode
    (unless (heurigraph-education-project-p)
      (setq heurigraph-education-note-mode nil)
      (user-error "This project does not resolve heurigraph:education"))
    (heurigraph-education--apply-fallbacks)))

;;;###autoload
(defun heurigraph-education-enable-for-typst ()
  "Enable generic and education authoring for an education forest."
  (when (and (locate-dominating-file default-directory "heurigraph.toml")
             (heurigraph-education-project-p))
    (heurigraph-enable-for-typst)
    (heurigraph-education-note-mode 1)))

;;;###autoload
(defun heurigraph-education-doom-setup-keybindings ()
  "Install generic and education commands below Doom's `SPC e' prefix."
  (interactive)
  (heurigraph-doom-setup-keybindings)
  (dolist (binding
           '(("E" . heurigraph-insert-assessment-data)
             ("G" . heurigraph-insert-assessment-scheme-data)
             ("C" . heurigraph-insert-assessment-component-data)
             ("K" . heurigraph-insert-mark-scheme-point)
             ("z" . heurigraph-insert-exam-administration)
             ("U" . heurigraph-manuscript-build)))
    (define-key heurigraph-doom-leader-map
                (kbd (car binding)) (cdr binding)))
  (message "Heurigraph Education commands installed under SPC e"))

(provide 'heurigraph-education)

;;; heurigraph-education.el ends here
