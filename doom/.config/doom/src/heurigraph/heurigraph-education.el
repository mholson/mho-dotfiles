;;; heurigraph-education.el --- Education extension for Heurigraph -*- lexical-binding: t; -*-

;; Author: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Maintainer: Mark Olson <41911657+mholson@users.noreply.github.com>
;; Version: 6.4.24
;; Package-Requires: ((emacs "30.2") (heurigraph "6.4.24"))
;; Keywords: tools, languages, typst, education
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:

;; Education-only activation and key bindings layered over the generic source
;; and ontology support in heurigraph.el and heurigraph-mode.el.  This package
;; targets the compiled education CLI and activates in a Heurigraph workspace.

;;; Code:

(require 'heurigraph)
(require 'heurigraph-mode)

(defgroup heurigraph-education nil
  "Education authoring extensions for Heurigraph."
  :group 'heurigraph
  :prefix "heurigraph-education-")

(defcustom heurigraph-education-response-formats
  '("short-response" "extended-response" "multiple-choice" "numeric"
    "symbolic" "graphical" "proof" "mixed")
  "Controlled response formats offered by education assessment commands."
  :type '(repeat string)
  :group 'heurigraph-education)

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
      (push (format "  total-weighting-percent: %d," total-weighting-percent) fields))
    (when declared-external-duration-minutes
      (push (format "  declared-external-duration-minutes: %d,"
                    declared-external-duration-minutes) fields))
    (heurigraph-education--insert-metadata-call "assessment-scheme-data" (nreverse fields))))

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
(defun heurigraph-insert-mark-scheme-point (id order type value annotation description)
  "Insert one ordered education mark-scheme point at point.
ID, TYPE, ANNOTATION, and DESCRIPTION are required.
ORDER and VALUE must be positive integers."
  (interactive
   (let* ((id (read-string "Stable criterion ID: ")) (order (read-number "Point order: " 1))
          (type (read-string "Provider mark type (for example M or A): "))
          (value (read-number "Award value: " 1)))
     (list id order type value (read-string "Source annotation: " (format "%s%d" type value))
           (read-string "Description (Typst markup): "))))
  (unless (and (integerp order) (> order 0) (integerp value) (> value 0))
    (user-error "Order and value must be positive integers"))
  (unless (and (<= (length id) 250) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" id))
    (user-error "ID must use letters, digits, dot, underscore or hyphen and leave room for .award"))
  (when (seq-some (lambda (text) (string-empty-p (string-trim text)))
                 (list id type annotation description))
    (user-error "ID, type, annotation, and description must not be blank"))
  (heurigraph-education--insert-metadata-call
   "mark-scheme-point"
   (mapcar (lambda (field)
             (format "  %s: %s," (car field)
                     (if (numberp (cdr field)) (number-to-string (cdr field))
                       (format "\"%s\"" (heurigraph--typst-string (cdr field))))))
           `((id . ,id) (order . ,order) (type . ,type) (value . ,value)
             (source-annotation . ,annotation) (description . ,description)))))

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

;;; Education projections --------------------------------------------------

(defun heurigraph-education-generate-manuscript (id)
  "Generate the accepted manuscript identified by ID."
  (interactive (list (heurigraph--required-id "Manuscript")))
  (heurigraph--run (list "generate" "manuscript" id)))

(defun heurigraph-education-generate-assessment (id)
  "Generate the accepted assessment identified by ID."
  (interactive (list (heurigraph--required-id "Assessment")))
  (heurigraph--run (list "generate" "assessment" id)))

(defun heurigraph-education-generate-solution-design (id)
  "Generate both Solution Design table formats for manuscript ID."
  (interactive (list (heurigraph--required-id "Manuscript")))
  (heurigraph--run (list "generate" "solution-design" id "--format" "both")))

(dolist (action '(("Assessment item metadata" . heurigraph-insert-assessment-data)
                  ("Assessment scheme metadata" . heurigraph-insert-assessment-scheme-data)
                  ("Assessment component metadata" . heurigraph-insert-assessment-component-data)
                  ("Mark-scheme point" . heurigraph-insert-mark-scheme-point)
                  ("Exam administration" . heurigraph-insert-exam-administration)))
  (add-to-list 'heurigraph-extra-edit-actions action t))

(dolist (action '(("Manuscript" . heurigraph-education-generate-manuscript)
                  ("Assessment" . heurigraph-education-generate-assessment)
                  ("Solution Design" . heurigraph-education-generate-solution-design)))
  (add-to-list 'heurigraph-extra-generate-actions action t))

;;;###autoload
(defun heurigraph-education-enable-for-typst ()
  "Enable Heurigraph editing with Education actions in a Typst workspace."
  (heurigraph-enable-for-typst))

(provide 'heurigraph-education)

;;; heurigraph-education.el ends here
