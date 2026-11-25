;;; mho-vulpea-site-theme.el --- mholson presentation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mark Olson
;; SPDX-License-Identifier: MIT

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar mho-vulpea-site-theme-preview-p nil
  "Non-nil labels an isolated design preview.")
(defvar mho-vulpea-site-theme-preview-message
  "Illustrative notes · Stillvaro is an existing project"
  "Explanation shown only in isolated design previews.")

(defun mho-vulpea-site-theme--escape (text)
  "Escape TEXT as HTML text or a quoted attribute."
  (let ((result (or text "")))
    (dolist (replacement '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;")
                           ("\"" . "&quot;") ("'" . "&#39;")))
      (setq result (replace-regexp-in-string
                    (car replacement) (cdr replacement) result t t)))
    result))

(defun mho-vulpea-site-theme--kind (page)
  "Return PAGE's reader-facing category."
  (pcase (plist-get page :kind) ('blog "Writing") ('week "Weeknote") (_ "Page")))

(defun mho-vulpea-site-theme--route (page)
  "Return PAGE's route relative to the site root."
  (or (plist-get page :url) (format "notes/%s.html" (plist-get page :id))))

(defun mho-vulpea-site-theme--date (date &optional full)
  "Format DATE for an archive row or a FULL article date."
  (if (or (null date) (string-empty-p date)) "Undated"
    (condition-case nil
        (format-time-string (if full "%e %B %Y" "%d %b")
                            (date-to-time (concat date " 12:00:00")))
      (error date))))

(defun mho-vulpea-site-theme--document (title body description root current &optional stylesheet)
  "Wrap TITLE and BODY with DESCRIPTION, ROOT links and CURRENT navigation.
Load the page-specific STYLESHEET when supplied."
  (let* ((root (or root ""))
         (escape #'mho-vulpea-site-theme--escape)
         (url (lambda (path) (funcall escape (concat root path)))))
    (concat
     "<!doctype html>\n<html lang=\"en\">\n<head>\n"
     "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     "<meta name=\"color-scheme\" content=\"light dark\">\n"
     "<meta name=\"description\" content=\"" (funcall escape (or description "Notes, writing, and things I make. By Mark Olson.")) "\">\n"
     "<title>" (funcall escape title) " · mholson</title>\n"
     "<link rel=\"icon\" href=\"" (funcall url "assets/vulpea-site-mark.svg") "\" type=\"image/svg+xml\">\n"
     "<link rel=\"stylesheet\" href=\"" (funcall url "assets/vulpea-site.css") "\">\n"
     (when stylesheet
       (concat "<link rel=\"stylesheet\" href=\"" (funcall url stylesheet) "\">\n"))
     "<link rel=\"alternate\" type=\"application/rss+xml\" title=\"mholson\" href=\""
     (funcall url "feed.xml") "\">\n</head>\n"
     "<body id=\"top\"><a class=\"skip\" href=\"#content\">Skip to content</a>\n"
     (when mho-vulpea-site-theme-preview-p
       (concat "<div class=\"preview\"><strong>Design preview</strong><span>"
               (funcall escape mho-vulpea-site-theme-preview-message) "</span></div>\n"))
     "<header class=\"site-header\"><div class=\"shell masthead\">"
     "<a class=\"brand\" href=\"" (funcall url "index.html") "\" aria-label=\"mholson — Home\">"
     "<img class=\"brand-mark\" src=\"" (funcall url "assets/vulpea-site-mark.svg")
     "\" width=\"40\" height=\"40\" alt=\"\"><span class=\"brand-name\">mholson</span></a>"
     "<nav class=\"nav\" aria-label=\"Main navigation\">"
     (mapconcat
      (lambda (item)
        (concat "<a href=\"" (funcall url (cdr item)) "\""
                (when (equal current (cdr item)) " aria-current=\"page\"")
                ">" (car item) "</a>"))
      '(("Home" . "index.html") ("Writing" . "blog.html")
        ("Weeknotes" . "weeks.html") ("Pages" . "pages.html")) "")
     "</nav></div></header><main id=\"content\" tabindex=\"-1\"><div class=\"shell\">" body "</div></main>"
     "<footer class=\"site-footer\"><div class=\"shell footer\"><p>Mark Olson<span> · mholson</span></p>"
     "<div class=\"footer-links\"><a href=\"" (funcall url "feed.xml") "\">RSS feed</a>"
     "<a href=\"#top\">Back to top <span aria-hidden=\"true\">↑</span></a></div>"
     "</div></footer></body></html>\n")))

(defun mho-vulpea-site-theme--explore-link (title description route icon)
  "Render a homepage entry point with TITLE, DESCRIPTION, ROUTE and ICON."
  (concat
   "<a class=\"explore-link\" href=\"" (mho-vulpea-site-theme--escape route) "\">"
   "<svg class=\"explore-icon\" viewBox=\"0 0 32 32\" fill=\"none\" stroke=\"currentColor\""
   " stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">"
   (pcase icon
     ('writing "<path d=\"M4 6.5h8a5 5 0 0 1 4 2 5 5 0 0 1 4-2h8v20h-8a5 5 0 0 0-4 2 5 5 0 0 0-4-2H4Z\"/><path d=\"M16 8.5v20M8 12h4m-4 5h4m8-5h4m-4 5h4\"/>")
     ('weeks "<rect x=\"4\" y=\"6\" width=\"24\" height=\"22\" rx=\"3\"/><path d=\"M10 3v6m12-6v6M4 13h24m-18 5h3m6 0h3m-12 5h3m6 0h3\"/>")
     ('projects "<path d=\"m10 7-7 9 7 9m12-18 7 9-7 9M19 4l-6 24\"/>")
     (_ "<rect x=\"8\" y=\"8\" width=\"20\" height=\"20\" rx=\"3\"/><path d=\"M23 4H7a3 3 0 0 0-3 3v16m9-9h10m-10 5h10m-10 5h6\"/>"))
   "</svg><span class=\"explore-title\">" (mho-vulpea-site-theme--escape title)
   "</span><span class=\"explore-description\">" (mho-vulpea-site-theme--escape description)
   "</span></a>"))

(defun mho-vulpea-site-theme--entries (pages)
  "Render PAGES as a simple dated list."
  (concat
   "<ul class=\"entry-list\">"
   (mapconcat
    (lambda (page)
      (let ((date (plist-get page :date)) (summary (plist-get page :description)))
        (concat "<li class=\"entry\">"
                (if (and date (not (string-empty-p date)))
                    (format "<time datetime=\"%s\">%s</time>"
                            (mho-vulpea-site-theme--escape date)
                            (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--date date)))
                  "<span class=\"entry-date\">Undated</span>")
                "<div class=\"entry-copy\"><h3><a href=\""
                (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--route page)) "\">"
                (mho-vulpea-site-theme--escape (plist-get page :title)) "</a></h3>"
                (when (and summary (not (string-empty-p summary)))
                  (concat "<p>" (mho-vulpea-site-theme--escape summary) "</p>"))
                (when (eq (plist-get page :kind) 'week)
                  "<span class=\"entry-kind\">Weeknote</span>")
                "</div><span class=\"entry-arrow\" aria-hidden=\"true\">↗</span></li>")))
    pages "") "</ul>"))

(defun mho-vulpea-site-theme--project (page)
  "Render a compact row for a project or permanent PAGE."
  (concat
   "<article class=\"project-row\">"
   (when-let* ((image (plist-get page :image)))
     (concat "<img class=\"project-icon\" src=\"" (mho-vulpea-site-theme--escape image)
             "\" alt=\"\" width=\"64\" height=\"64\" loading=\"lazy\">"))
   "<div><h3><a href=\"" (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--route page)) "\">"
   (mho-vulpea-site-theme--escape (plist-get page :title))
   " <span aria-hidden=\"true\">↗</span></a></h3>"
   (when-let* ((description (plist-get page :description)))
     (concat "<p>" (mho-vulpea-site-theme--escape description) "</p>"))
   "</div></article>"))

(defun mho-vulpea-site-theme-home (pages projects)
  "Render an inviting homepage from public PAGES and retained PROJECTS."
  (let* ((writing (seq-filter (lambda (page) (memq (plist-get page :kind) '(blog week))) pages))
         (projects (append (seq-filter (lambda (page) (eq (plist-get page :layout) 'product)) pages)
                           projects))
         (permanent (seq-filter (lambda (page) (and (eq (plist-get page :kind) 'page)
                                                   (not (plist-get page :layout)))) pages))
         (about (seq-find (lambda (page)
                            (string-prefix-p "about" (downcase (plist-get page :title)))) permanent))
         (featured (car writing))
         (recent (seq-take (cdr writing) 4)))
    (mho-vulpea-site-theme--document
     "Mark Olson"
     (concat
      "<section class=\"home-intro\" aria-labelledby=\"page-title\">"
      "<img class=\"home-intro-mark\" src=\"assets/vulpea-site-mark.svg\" width=\"96\" height=\"96\" alt=\"\">"
      "<h1 id=\"page-title\">Notes, writing,<br>and things I make<span class=\"hero-stop\">.</span></h1>"
      "<p class=\"intro-copy\">I'm Mark Olson. I write about what I'm working on and share the things I build.</p>"
      (when about
        (concat "<a class=\"text-link\" href=\""
                (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--route about))
                "\">About this archive <span aria-hidden=\"true\">↗</span></a>"))
      "</section>"
      "<nav class=\"home-explore\" aria-label=\"Explore the archive\">"
      (mho-vulpea-site-theme--explore-link "Writing" "Ideas and explanations" "blog.html" 'writing)
      (mho-vulpea-site-theme--explore-link "Weeknotes" "One week at a time" "weeks.html" 'weeks)
      (when projects
        (mho-vulpea-site-theme--explore-link "Projects" "Things I'm making" "#projects" 'projects))
      (mho-vulpea-site-theme--explore-link "Pages" "Notes to return to" "pages.html" 'pages)
      "</nav>"
      "<section class=\"home-writing\" aria-label=\"Latest writing\">"
      "<div class=\"section-head\"><h2>Latest writing</h2><a href=\"blog.html\">All writing <span aria-hidden=\"true\">↗</span></a></div>"
      (if featured
          (concat "<article class=\"featured\"><div class=\"article-date\">"
                  (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--date (plist-get featured :date) t))
                  (when (eq (plist-get featured :kind) 'week) " <span>· Weeknote</span>")
                  "</div><h2><a href=\""
                  (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--route featured)) "\">"
                  (mho-vulpea-site-theme--escape (plist-get featured :title)) "</a></h2>"
                  (when-let* ((description (plist-get featured :description)))
                    (concat "<p>" (mho-vulpea-site-theme--escape description) "</p>"))
                  "<a class=\"text-link\" href=\""
                  (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--route featured))
                  "\">Read the " (if (eq (plist-get featured :kind) 'week) "weeknote" "article")
                  " <span aria-hidden=\"true\">→</span></a></article>")
        "<p class=\"empty-state\">New writing will appear here.</p>")
      (when recent (mho-vulpea-site-theme--entries recent))
      "</section>"
      (when (or projects permanent)
        (concat
         "<div class=\"home-collections\">"
         (when projects
           (concat "<section id=\"projects\" aria-label=\"Projects\"><div class=\"section-head\"><h2>Things I make</h2></div>"
                   (mapconcat #'mho-vulpea-site-theme--project projects "") "</section>"))
         (when permanent
           (concat "<section aria-label=\"Permanent pages\"><div class=\"section-head\"><h2>From the archive</h2>"
                   "<a href=\"pages.html\">All pages <span aria-hidden=\"true\">↗</span></a></div>"
                   (mapconcat #'mho-vulpea-site-theme--project (seq-take permanent 3) "") "</section>"))
         "</div>")))
     "Notes, writing, and things I make. By Mark Olson." "" "index.html")))

(defun mho-vulpea-site-theme-archive (title pages &optional projects)
  "Render an archive with TITLE, public PAGES and retained PROJECTS."
  (let* ((is-pages (equal title "Pages"))
         (route (cond (is-pages "pages.html") ((equal title "Writing") "blog.html") (t "weeks.html")))
         (description (cond (is-pages "Projects and notes to return to.")
                            ((equal title "Writing") "Ideas, explanations, and work in progress.")
                            (t "A few observations from one week to the next.")))
         (count (+ (length pages) (length projects))))
    (mho-vulpea-site-theme--document
     title
     (concat
      "<header class=\"archive-header\"><p class=\"eyebrow\">mholson</p>"
      "<h1 id=\"page-title\">" (mho-vulpea-site-theme--escape title) "</h1>"
      "<p class=\"lede\">" description "</p></header>"
      (if (= count 0)
          "<div class=\"archive empty-state\"><p>No published notes yet.</p><a class=\"text-link\" href=\"index.html\">Back to the archive <span aria-hidden=\"true\">→</span></a></div>"
        (if is-pages
            (concat "<section class=\"page-list\" aria-label=\"Pages and projects\">"
                    (mapconcat #'mho-vulpea-site-theme--project (append pages projects) "") "</section>")
          (concat "<div class=\"archive\">"
                  (mapconcat
                   (lambda (group)
                     (concat "<section class=\"archive-year\" aria-labelledby=\"year-"
                             (mho-vulpea-site-theme--escape (car group)) "\">"
                             "<h2 class=\"year\" id=\"year-" (mho-vulpea-site-theme--escape (car group)) "\">"
                             (mho-vulpea-site-theme--escape (car group)) "</h2>"
                             (mho-vulpea-site-theme--entries (cdr group)) "</section>"))
                   (seq-group-by (lambda (page)
                                   (let ((date (plist-get page :date)))
                                     (if (and date (>= (length date) 4)) (substring date 0 4) "Undated"))) pages)
                   "") "</div>")))
      "<p class=\"archive-follow\">Follow new writing and weeknotes with the <a href=\"feed.xml\">RSS feed</a>.</p>")
     description "" route)))

(defun mho-vulpea-site-theme--outline (body)
  "Return section navigation for BODY, using its exported anchors."
  (let ((position 0) entries)
    (while (string-match "<h2[^>]* id=\"\\([^\"]+\\)\"[^>]*>\\(.*?\\)</h2>" body position)
      (let ((anchor (match-string 1 body)) (heading (match-string 2 body)))
        (setq position (match-end 0))
        (push (concat "<li><a href=\"#" (mho-vulpea-site-theme--escape anchor) "\">"
                      (replace-regexp-in-string "<[^>]*>" "" heading) "</a></li>") entries)))
    (when (>= (length entries) 3)
      (concat "<nav class=\"reading-toc\" aria-label=\"On this page\"><p>On this page</p><ol>"
              (string-join (nreverse entries) "") "</ol></nav>"))))

(defun mho-vulpea-site-theme-page (title body &optional description root metadata)
  "Render a reading page from TITLE, BODY and METADATA, with section navigation."
  (let* ((root (or root "")) (kind (plist-get metadata :kind))
         (route (pcase kind ('blog "blog.html") ('week "weeks.html") (_ "pages.html")))
         (label (pcase kind ('blog "Writing") ('week "Weeknotes") (_ "Pages")))
         (date (plist-get metadata :date))
         (outline (mho-vulpea-site-theme--outline body)))
    (if (eq (plist-get metadata :layout) 'product)
        (let ((vulpios-p (equal (plist-get metadata :url) "vulpios.html")))
          (mho-vulpea-site-theme--document
           title (concat "<article class=\"" (if vulpios-p "vulpios" "stillvaro")
                         "\" aria-labelledby=\"page-title\">" body "</article>")
           description root "pages.html" (when vulpios-p "assets/vulpios.css")))
      (mho-vulpea-site-theme--document
     title
     (concat
      "<div class=\"reading-layout\"><a class=\"back-link\" href=\""
      (mho-vulpea-site-theme--escape (concat root route)) "\"><span aria-hidden=\"true\">←</span> " label "</a>"
      "<article class=\"note\" aria-labelledby=\"page-title\"><header class=\"note-header\">"
      "<p class=\"article-date\">" (mho-vulpea-site-theme--kind metadata)
      (when (and date (not (string-empty-p date)))
        (concat " <span aria-hidden=\"true\">·</span> <time datetime=\""
                (mho-vulpea-site-theme--escape date) "\">"
                (mho-vulpea-site-theme--escape (mho-vulpea-site-theme--date date t)) "</time>"))
      "</p><h1 id=\"page-title\">" (mho-vulpea-site-theme--escape title) "</h1>"
      (when (and description (not (string-empty-p description)))
        (concat "<p class=\"lede\">" (mho-vulpea-site-theme--escape description) "</p>"))
      "</header><div class=\"reading-body" (when outline " has-outline") "\">" outline
      "<div class=\"prose\">" body "</div></div></article>"
      "<a class=\"text-link reading-end\" href=\"" (mho-vulpea-site-theme--escape (concat root route))
      "\"><span aria-hidden=\"true\">←</span> More " (downcase label) "</a></div>")
     description root route))))

(provide 'mho-vulpea-site-theme)
;;; mho-vulpea-site-theme.el ends here
