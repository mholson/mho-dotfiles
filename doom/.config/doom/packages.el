;; -*- no-byte-compile: t; -*-
;;; packages.el

;; Run `doom sync` after changing package declarations.

(package! org-transclusion)
(package! org-super-agenda)
(package! aas)
(package! laas)
;; Preserve the installed revisions verified by the cross-editor workflow suite.
;; Newer catch-up support is tested separately; no package upgrade is implicit.
(package! vulpea :pin "f3af60a6dcfdababa74232b3b58fd44c511cfc4a")
(package! vulpea-ui :pin "c21204116b3cf3e921fa8f7849c932c8b0ad3181")
(package! vui :pin "d8e76e7ccc784ab0441caab04fcf36aba73f5bdb")
(package! vulpea-journal
  :recipe (:host github :repo "d12frosted/vulpea-journal")
  :pin "f21acb42c73395defcedae281ceb1fbf505f20fb")
(package! vulpea-para
  :recipe (:host github :repo "d12frosted/vulpea-para")
  :pin "c47ca23dd5d998236895571626b045f046d99659")
(package! outline-indent)
(package! org-ml
  :recipe (:host github :repo "ndwarshuis/org-ml")
  :pin "e348f446746bd1699eae05a82dccd4276c6cc9a8")
(package! publicatorg
  :recipe (:host github :repo "d12frosted/publicatorg")
  :pin "8c552714a471f343edd0d473dfd53b485b09d386")
(package! ob-mermaid)
(package! ob-swift)
(package! anki-editor :recipe (:host github
                             :repo "anki-editor/anki-editor"))
(package! typst-ts-mode :recipe (:host codeberg
                                 :repo "meow_king/typst-ts-mode"
                                 :files (:defaults "*.el")))
(package! ox-typst :recipe (:host github
                                 :repo "jmpunkt/ox-typst"))
