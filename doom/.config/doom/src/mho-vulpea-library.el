;;; mho-vulpea-library.el --- Opt-in empty library bootstrap -*- lexical-binding: t; -*-

(require 'mho-vulpea-workflow)
(require 'subr-x)

(defun mho-vulpea-library--heading (title &optional tags)
  (format "* %s%s\n:PROPERTIES:\n:ID: %s\n:END:\n\n" title (or tags "") (org-id-new)))

(defun mho-vulpea-library-files ()
  "Generate one new profile-v1 library snapshot as relative path/content pairs.
The returned IDs belong to this snapshot and are written once, never refreshed
by a retry into an existing library.  This function does not access any notes."
  (let* ((resource-id (org-id-new))
         (resource-file (concat resource-id "--review-checklist.org")))
    (append
     (cl-loop for (file title) in '(("work.org" "Work") ("home.org" "Home"))
              collect
              (cons file
                    (concat (format ":PROPERTIES:\n:ID: %s\n:END:\n#+title: %s\n#+filetags: :area:private:agenda:\n\n" (org-id-new) title)
                            (mho-vulpea-library--heading "Notes")
                            "Responsibility:\n\nStandard:\n\n"
                            (format "Review guide: [[id:%s][Review checklist]]\n\n" resource-id)
                            (mho-vulpea-library--heading "Inbox" " :inbox:")
                            (mho-vulpea-library--heading "Tasks")
                            (mho-vulpea-library--heading "Actions")
                            (mho-vulpea-library--heading "Meetings")
                            (mho-vulpea-library--heading "Archive" " :ARCHIVE:"))))
     (list
      (cons resource-file
            (format ":PROPERTIES:\n:ID: %s\n:CREATED: %s\n:END:\n#+title: Review checklist\n#+filetags: :private:workflow:\n\n* Review\n- Empty capture inboxes.\n- Check each active project for one next action.\n- Review waiting work and area standards.\n- Extract useful journal insights into resources.\n- Archive finished projects after checking descendants and clocks.\n"
                    resource-id (format-time-string "[%Y-%m-%d %a]")))
      (cons ".vulpios/template-profile.json"
            (concat (json-encode (mho-vulpea-workflow-profile)) "\n"))))))

(defun mho-vulpea-library-preview ()
  "Preview a new library without creating a folder or changing configuration."
  (interactive)
  (let ((files (mho-vulpea-library-files)))
    (with-current-buffer (get-buffer-create "*Vulpios new library preview*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "New empty library — profile v1\n\nWork and Home are private areas. Journal dates are created on demand.\nNo existing folder is changed; initialization does not switch your library.\n\n")
        (dolist (file files) (insert (car file) "\n" (make-string 60 ?-) "\n" (cdr file) "\n"))
        (goto-char (point-min)) (special-mode))
      (pop-to-buffer (current-buffer)))))

(defun mho-vulpea-library-initialize (directory)
  "Initialize only an absent or empty DIRECTORY, without switching libraries.
All files are assembled beside the target, then the complete directory is
renamed into place.  A nonempty target is refused, including hidden files.
This command is opt-in and is never run by module setup or indexing."
  (interactive (list (read-directory-name "New empty Vulpios library: " nil nil nil)))
  (let* ((target (directory-file-name (expand-file-name directory)))
         (parent (file-name-directory target))
         staging)
    (when (or (file-remote-p target) (file-symlink-p target)
              (not (file-directory-p parent))
              (and (file-exists-p target) (not (file-directory-p target))))
      (user-error "Choose an ordinary local empty folder with an existing parent"))
    (when (and (file-directory-p target)
               (directory-files target nil directory-files-no-dot-files-regexp))
      (user-error "Refusing to initialize a nonempty folder: %s" target))
    (unwind-protect
        (progn
          (setq staging (make-temp-file (expand-file-name ".vulpios-new-" parent) t))
          (dolist (directory '("journal" "assets" ".vulpios"))
            (make-directory (expand-file-name directory staging)))
          (dolist (file (mho-vulpea-library-files))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (cdr file) nil (expand-file-name (car file) staging) nil 'silent)))
          ;; Nonrecursive removal refuses a folder populated since the check.
          (when (file-directory-p target) (delete-directory target))
          (rename-file staging target nil)
          (setq staging nil)
          (message "Created %s. Choose it in Vulpios and configure org-directory when ready; current libraries are unchanged" target)
          target)
      (when (and staging (file-directory-p staging)) (delete-directory staging t)))))

(provide 'mho-vulpea-library)
;;; mho-vulpea-library.el ends here
