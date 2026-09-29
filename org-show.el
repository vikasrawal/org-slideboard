;; -*- lexical-binding: t; -*-
;;; org-show-beamer.el --- org-show with side-by-side beamer columns
;; Copyright(C) 2014 John Kitchin

;; Author: John Kitchin <jkitchin@andrew.cmu.edu>
;; Contributions from Sacha Chua.
;; Beamer column support added 2026.
;; This file is not currently part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program ; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;; A simple mode for presenting org-files as slide-shows. A slide is a headline
;; with a :slide: tag. See file:org-show.org for usage.
;;
;; This is a drop-in replacement for org-show.el that also understands
;; beamer columns.  When a slide has children with a BEAMER_col property
;; (or a :BMCOL: tag), the slide is shown as:
;;
;;   +------------------------------------------+
;;   | slide heading (and any text before cols) |
;;   +----------------------+-------------------+
;;   | column 1             | column 2          |
;;   +----------------------+-------------------+
;;
;; Each column is an indirect buffer narrowed to the column body, in its
;; own window, with widths proportional to BEAMER_col.  Images are scaled
;; to the column width.  Since the column buffers are indirect, the text
;; is still live org and can be edited during the show.
;;
;; Beamer/babel clutter (property drawers, #+NAME/#+RESULTS/#+ATTR_ lines,
;; src blocks with :exports results or none, and standalone raw LaTeX
;; lines such as \vspace{...}) is hidden during the show.
;;
;; LaTeX equations are sized to the text of the slide, so they shrink
;; and grow with it.
;;
;; Load this file instead of org-show.el; it provides the same feature.

;;; Code:
(require 'animate)
(require 'easymenu)
(require 'cl-lib)
(require 'org)
(require 'ob-core)
(require 'org-element)
(require 'org-macro)
(require 'face-remap)

;;* Variables

(defvar org-show-presentation-file nil
  "File containing the presentation.")

(defvar org-show-slide-tag "slide"
  "Tag that marks slides.")

(defvar org-show-slide-tag-regexp
  (concat ":" (regexp-quote org-show-slide-tag) ":")
  "Regex to identify slide tags.")

(defvar org-show-latex-scale 4.0
  "Scale at which LaTeX previews are rendered during the show.
This sets the resolution only: the equations are then displayed at
the size of the text, see `org-show-latex-size'.  A high value keeps
them sharp when the text is large.")

(defvar org-show-latex-size 0.8
  "Size of LaTeX equations relative to the text on the slides.
At 1.0, the LaTeX font is as large as the text font.  Equations grow
and shrink with the text of the slide.")

(defvar org-show-latex-preview-drop-regexp
  "^[ \t]*\\\\\\(?:setbeamer\\|use[a-z]*theme\\|AtBegin\\(?:Section\\|Subsection\\|Part\\|Lecture\\)\\|beamertemplate\\|logo\\|titlegraphic\\|institute\\).*"
  "Lines of the LaTeX preamble left out when previewing equations.
Org previews equations with the article class, but it adds the
#+LATEX_HEADER lines of the file, which in a beamer presentation use
commands such as \\setbeamersize that article does not know.  LaTeX
then prints their arguments, e.g. \"description width=0.1cm\", in
every equation image.  Set to nil to keep all lines.")

(defvar org-show--latex-point-pixels nil
  "Pixels per LaTeX point in preview images, as (KEY . PIXELS).
KEY is (PROCESS SCALE PREAMBLE-HASH), see `org-show--latex-point'.")

(defvar-local org-show--latex-point nil
  "Pixels per LaTeX point in the preview images of this buffer.")

(defvar org-show-center-display-math nil
  "If non-nil, center display equations horizontally, as LaTeX does.
By default they are left aligned, like the text.
Display equations are \\=\\[...\\], $$...$$ and LaTeX environments
on lines of their own.  Inline math is not moved.")

(defvar org-show-text-scale 4
  "Largest text scale for slides without columns.
Text is shrunk below this when needed to fit the window, see
`org-show-fit-text'.  \\[org-show-increase-text-size] and
\\[org-show-decrease-text-size] change it for all later slides.")

(defvar org-show-title-text-scale 2
  "Text scale for the slide title strip on slides with columns.")

(defvar org-show-column-text-scale 2
  "Largest text scale inside beamer column windows.
Text is shrunk below this when needed to fit the columns, see
`org-show-fit-text'.  \\[org-show-increase-text-size] and
\\[org-show-decrease-text-size] change it for all later slides.")

(defvar org-show-min-text-scale -6
  "Smallest text scale used when shrinking text to fit.")

(defvar org-show-fit-text t
  "If non-nil, shrink text on each slide until it fits its window.
All columns of a slide get the same text scale.")

(defvar org-show-image-width-fraction 0.8
  "Images are scaled to at most this fraction of the window width.")

(defvar org-show-image-height-fraction 0.8
  "Images are scaled to at most this fraction of the window height.")

(defvar org-show-hide-clutter t
  "If non-nil, hide drawers, keyword lines, non-exported src blocks and
raw LaTeX lines during the show.")

(defvar org-show-beautify-modes '(org-modern-mode variable-pitch-mode)
  "Minor modes to turn on in the slide buffers during the show.
The default gives styled headings and bullets (org-modern) and
proportional text (`variable-pitch-mode').
They are turned off again when the show stops, unless they were
already on.  Modes that are not installed are skipped.  Set to nil
to show plain org.")

(defface org-show-bullet
  '((t :inherit org-level-1 :weight bold :height 1.3))
  "Face for list bullets during the show, see `org-show-list-bullets'.
Change :height to make the bullets bigger or smaller."
  :group 'org)

(defvar org-show-list-bullets '("●" "○" "■" "□")
  "Bullets for unordered list items during the show, by nesting depth.
The first is used for top-level items, the second for sub-items, and
so on, starting again from the first for deeper lists.  They are shown
in face `org-show-bullet'.  Numbered items keep their numbers.  Set to
nil to keep the bullets as they are (or as org-modern draws them).")

(defvar org-show-list-indent 4
  "Indentation per level of list nesting during the show.
In spaces of the text font, so it scales with the text.")

(defvar org-show-hanging-indent t
  "If non-nil, lay out lists during the show.
Sub-items are indented by `org-show-list-indent' per level, and
wrapped lines of an item are aligned under its text.")

(defvar org-show-disable-modes '(org-indent-mode display-line-numbers-mode)
  "Minor modes to turn off in the slide buffers during the show.
They are turned on again when the show stops.  `org-indent-mode'
adds heading-level indentation and its own wrap prefixes, which spoil
the list layout, and line numbers do not belong on slides.")

(defvar org-show-hide-emphasis-markers t
  "If non-nil, hide the *, /, = etc. emphasis markers during the show.")

(defvar org-show-hide-macro-markers t
  "If non-nil, hide the {{{ and }}} around macros during the show.
This turns on `org-hide-macro-markers' in the slide buffers.  It
matters for macros that are not expanded, see
`org-show-expand-macros'.")

(defvar org-show-align-tables t
  "If non-nil, align Org tables to what is displayed on the slides.
Org aligns a table by the characters in the file, but on a slide a
cell can show an expanded macro, an equation image or proportional
text, so the columns would not line up.  The padding is done with
overlays, so the file is not changed.")

(defvar-local org-show--table-overlays nil
  "Overlays made by `org-show--align-tables' in this buffer.")

(defvar org-show-expand-macros t
  "If non-nil, show Org macros on the slides as their expansion.
A macro is expanded with, in this order of preference:

- its #+ORG_SHOW_MACRO: definition in the file, written like a
  #+MACRO: definition, e.g. \"#+ORG_SHOW_MACRO: cc $2\";
- its definition in `org-show-macro-templates';
- Org's own expansion: #+MACRO: definitions and the built-in macros
  such as title, author, date and time.  Export snippets for other
  back-ends, such as @@latex:...@@, are left out of the result, and
  the contents of @@org-show:...@@ snippets are kept.

Macros that expand to nothing are left as they are.  The buffer text
is not changed.")

(defvar org-show-macro-templates nil
  "Definitions of Org macros for the show, as (NAME . TEMPLATE).
TEMPLATE is a string like the definition in a #+MACRO: line, with
$1, $2... for the arguments, or a function that is called with the
arguments as strings and returns the string to show, which may have
faces.  For example:

  (setq org-show-macro-templates
        \\='((\"cc\" . (lambda (color text)
                     (propertize text \\='face
                                 \\=`(:background ,color))))))

#+ORG_SHOW_MACRO: lines in the file take precedence.  See
`org-show-expand-macros'.")

(defvar org-modern-tag)
(defvar org-modern-list)

(defvar-local org-show--disabled nil
  "Modes turned off by `org-show--beautify' in this buffer.")

(defvar-local org-show--beautified nil
  "Modes turned on by `org-show--beautify' in this buffer.")

(defvar org-show-title-page t
  "If non-nil, start the show with a title page.
It is made from the #+TITLE, #+SUBTITLE, #+AUTHOR and #+DATE keywords.")

(defvar org-show-section-pages t
  "If non-nil, show a section page before the first slide of each section.
A section is a heading above the slides, e.g. each level-1 heading
when the slides are level-2 headings (#+OPTIONS: H:2).")

(defvar org-show-animate-pages t
  "If non-nil, animate the title and section pages.
Pressing a key skips the rest of the animation.")

(defvar org-show-page-text-scale 5
  "Text scale for the title and section pages.")

(defconst org-show--page-buffer "*org-show-page*"
  "Buffer for the title and section pages.")

(defface org-show-page-title
  '((t :inherit org-document-title :height 1.0 :weight bold))
  "Face for the title on the title page."
  :group 'org)

(defface org-show-page-subtitle
  '((t :inherit org-document-info :height 1.0))
  "Face for the subtitle on the title page."
  :group 'org)

(defface org-show-page-info
  '((t :inherit org-document-info :height 1.0 :slant italic))
  "Face for the author and date on the title page."
  :group 'org)

(defface org-show-page-section
  '((t :inherit org-level-1 :height 1.0 :weight bold))
  "Face for the heading on a section page."
  :group 'org)

(defvar org-show-current-slide-number 1
  "Holds current slide number.")

(defvar org-show-mogrify-p
  (executable-find "mogrify")
  "Determines if images are mogrified (changed size in presentation mode.")

(when org-show-mogrify-p
  (ignore-errors (require 'eimp)))

(defvar org-show-tags-column -60
  "Column position to move tags to in slide mode.")

(defvar org-show-original-tags-column org-tags-column
  "Save value so we can change back to it.")

(defvar *org-show-flyspell-mode* nil
  "Whether flyspell mode is enabled at beginning of show.
Used to reset the state after the show.")

(defvar *org-show-running* nil
  "Flag for if the show is running.")

(defvar org-show-slide-list '()
  "List of slide numbers and markers to each slide.")

(defvar org-show-slide-titles '()
  "List of titles and slide numbers for each slide.")

(defvar org-show--column-buffers '()
  "Indirect buffers created to display beamer columns.")

(defvar org-show--hide-overlays '()
  "Overlays created to hide clutter during the show.")

(defvar org-show--windows '()
  "Windows whose mode-line was hidden for a column layout.")

(defvar org-show-mode)
(declare-function flyspell-mode-on "flyspell")
(declare-function flyspell-mode-off "flyspell")

;;* Functions
(defvar org-show-temp-images '() "List of temporary images.")

(defun org-show--base-buffer ()
  "Return the base buffer of the current buffer."
  (or (buffer-base-buffer) (current-buffer)))

(defun org-show--show-buffer ()
  "Return the buffer of the presentation being shown.
This is where the settings are read, since they may be local to it."
  (or (and org-show-presentation-file
           (find-buffer-visiting org-show-presentation-file))
      (org-show--base-buffer)))

(defun org-show--file ()
  "Return the file of the presentation in the current buffer."
  (buffer-file-name (org-show--base-buffer)))

;;** Clutter hiding

(defun org-show--hide-region (beg end)
  "Make the region BEG END invisible during the show."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'invisible 'org-show)
    (overlay-put ov 'evaporate t)
    (push ov org-show--hide-overlays)))

(defun org-show--hide-clutter (beg end)
  "Hide beamer and babel clutter between BEG and END."
  (when org-show-hide-clutter
    (add-to-invisibility-spec 'org-show)
    (let ((case-fold-search t))
      (save-excursion
        ;; property drawers
        (goto-char beg)
        (while (re-search-forward
                "^[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
                end t)
          (org-show--hide-region (match-beginning 0) (match-end 0)))
        ;; keyword lines
        (goto-char beg)
        (while (re-search-forward
                "^[ \t]*#\\+\\(?:name\\|results\\|caption\\|attr_[a-z]+\\)\\(?:\\[.*\\]\\)?:.*\n?"
                end t)
          (org-show--hide-region (match-beginning 0) (match-end 0)))
        ;; standalone raw LaTeX lines, e.g. \vspace{-0.5cm}, but not
        ;; lines of an equation
        (goto-char beg)
        (while (re-search-forward "^[ \t]*\\(\\\\[a-zA-Z]+\\).*\n?" end t)
          (unless (save-excursion
                    (save-match-data
                      (org-show--math-p
                       (org-element-context
                        (progn (goto-char (match-beginning 1))
                               (org-element-at-point))))))
            (org-show--hide-region (match-beginning 0) (match-end 0))))
        ;; src blocks that are not exported as code
        (goto-char beg)
        (while (re-search-forward "^[ \t]*#\\+begin_src\\b" end t)
          (let* ((block-beg (line-beginning-position))
                 (info (save-excursion
                         (goto-char block-beg)
                         (ignore-errors (org-babel-get-src-block-info 'no-eval))))
                 (exports (cdr (assq :exports (nth 2 info))))
                 (block-end (save-excursion
                              (when (re-search-forward "^[ \t]*#\\+end_src.*\n?" end t)
                                (match-end 0)))))
            (when (and block-end
                       (or (member exports '("results" "none"))
                           (equal (car info) "emacs-lisp-slide")))
              (org-show--hide-region block-beg block-end))
            (when block-end (goto-char block-end))))
        ;; blank lines left at the top once the clutter is hidden
        (goto-char beg)
        (while (and (< (point) end)
                    (or (invisible-p (point))
                        (memq (char-after) '(?\s ?\t ?\n))))
          (forward-char 1))
        (when (> (line-beginning-position) beg)
          (org-show--hide-region beg (line-beginning-position)))))))

;;** Beamer columns

(defun org-show--slide-columns ()
  "Return the beamer columns of the slide at point.
Each element is (WIDTH HEAD-BEG BODY-BEG BODY-END).  Columns are
direct children with a BEAMER_col property or a BMCOL tag."
  (save-excursion
    (org-back-to-heading t)
    (let ((cols '()))
      (when (org-goto-first-child)
        (cl-loop
         do (let ((w (org-entry-get nil "BEAMER_col"))
                  (tags (org-get-tags nil t)))
              (when (or w (member "BMCOL" tags))
                (let* ((head (point))
                       (end (save-excursion (org-end-of-subtree t t) (point)))
                       (body (save-excursion
                               (org-end-of-meta-data t)
                               (skip-chars-forward " \t\n" end)
                               (line-beginning-position))))
                  (push (list (if w (string-to-number w) 0)
                              head (min body end) end)
                        cols))))
         while (org-get-next-sibling)))
      (setq cols (nreverse cols))
      ;; columns without a width share equally
      (let ((n (length cols)))
        (dolist (c cols)
          (when (<= (car c) 0) (setcar c (/ 1.0 n)))))
      cols)))

(defun org-show--show-images (&optional win)
  "Display image links in the accessible part of the current buffer.
Images are scaled down to fit in window WIN (default: the selected
window), using `org-show-image-width-fraction' and
`org-show-image-height-fraction'.  The images are drawn with our own
high-priority overlays, so they do not depend on (and override) the
Org or scimax inline image settings."
  (let* ((win (or win (selected-window)))
         (max-w (floor (* org-show-image-width-fraction (window-body-width win t))))
         (max-h (floor (* org-show-image-height-fraction (window-body-height win t)))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\(?:file:\\)?\\([^]\n]+\\)\\]\\]" nil t)
        (let ((file (expand-file-name (match-string-no-properties 1))))
          (when (and (string-match-p (image-file-name-regexp) file)
                     (file-exists-p file))
            (let ((ov (make-overlay (match-beginning 0) (match-end 0) nil t nil)))
              (overlay-put ov 'display (create-image file nil nil
                                                     :max-width max-w
                                                     :max-height max-h))
              (overlay-put ov 'priority 1000)
              ;; Org hides the link brackets with an `invisible' text
              ;; property, and a display spec on invisible text is not
              ;; shown.  A non-nil overlay value that is not in the
              ;; invisibility spec takes precedence and keeps it visible.
              (overlay-put ov 'invisible 'org-show-image)
              (push ov org-show--hide-overlays))))))))

(defun org-show--reflow ()
  "Display hard-wrapped paragraphs in the accessible region as one line.
Line breaks inside a paragraph are shown as spaces, so that
`visual-line-mode' can wrap the text to the window, as LaTeX would.
Display equations (\\=\\[...\\] and $$...$$) keep their own lines."
  (org-element-map (org-element-parse-buffer) 'paragraph
    (lambda (par)
      (let ((beg (org-element-property :contents-begin par))
            (end (org-element-property :contents-end par))
            (math (org-element-map par 'latex-fragment
                    (lambda (f)
                      (when (string-match-p "\\`\\(?:\\$\\$\\|\\\\\\[\\)"
                                            (org-element-property :value f))
                        (cons (org-element-property :begin f)
                              (- (org-element-property :end f)
                                 (org-element-property :post-blank f))))))))
        (when (and beg end)
          (save-excursion
            (goto-char beg)
            (while (re-search-forward "[ \t]*\n[ \t]*" end t)
              (when (and (< (match-end 0) end)
                         (not (cl-some (lambda (m)
                                         (and (<= (match-beginning 0) (cdr m))
                                              (>= (match-end 0) (car m))))
                                       math)))
                (let ((ov (make-overlay (match-beginning 0) (match-end 0) nil t nil)))
                  (overlay-put ov 'display " ")
                  (push ov org-show--hide-overlays))))))))))

(defun org-show--list-depth (item)
  "Return the nesting depth of list ITEM, 0 for a top-level item."
  (let ((depth -1)
        (p (org-element-property :parent item)))
    (while p
      (when (eq (org-element-type p) 'plain-list)
        (setq depth (1+ depth)))
      (setq p (org-element-property :parent p)))
    (max depth 0)))

(defun org-show--style-lists ()
  "Lay out the plain lists in the accessible region for the show.
Unordered bullets are replaced by `org-show-list-bullets' according
to their depth, and with `org-show-hanging-indent', items are
indented by `org-show-list-indent' spaces per level and their
wrapped lines are aligned under the item text.  Everything is done
with overlays, so the buffer text is not changed."
  (when (or org-show-list-bullets org-show-hanging-indent)
    (let ((bg (face-background 'default nil t)))
      (org-element-map (org-element-parse-buffer) 'item
        (lambda (item)
          (save-excursion
            (let* ((depth (org-show--list-depth item))
                   (begin (org-element-property :begin item))
                   (end (org-element-property :end item))
                   (ordered (eq (org-element-property
                                 :type (org-element-property :parent item))
                                'ordered))
                   (bullet-beg (progn (goto-char begin)
                                      (skip-chars-forward " \t")
                                      (point)))
                   (bullet-end (+ bullet-beg
                                  (length (string-trim-right
                                           (org-element-property :bullet item)))))
                   (text-beg (progn (goto-char bullet-end)
                                    (skip-chars-forward " \t")
                                    (point)))
                   (bullets org-show-list-bullets)
                   (new-bullet
                    (when (and bullets (not ordered))
                      (let ((b (nth (mod depth (length bullets)) bullets)))
                        ;; also accept the old (CHAR . STRING) format
                        (when (consp b) (setq b (cdr b)))
                        (if (get-text-property 0 'face b)
                            b
                          (propertize b 'face 'org-show-bullet)))))
                   (bullet (or new-bullet
                               (buffer-substring bullet-beg bullet-end)))
                   (indent (if org-show-hanging-indent
                               (make-string (* depth org-show-list-indent) ?\s)
                             (buffer-substring-no-properties begin bullet-beg)))
                   ov)
              ;; indentation (a zero-width overlay when there is none)
              (setq ov (make-overlay begin bullet-beg nil t nil))
              (overlay-put ov (if (= begin bullet-beg) 'before-string 'display)
                           indent)
              (push ov org-show--hide-overlays)
              ;; bullet
              (when new-bullet
                (setq ov (make-overlay bullet-beg bullet-end nil t nil))
                (overlay-put ov 'display new-bullet)
                (push ov org-show--hide-overlays))
              ;; wrapped lines start under the item text: the prefix is the
              ;; indentation, an invisible copy of the bullet (same width)
              ;; and the space after it
              (when org-show-hanging-indent
                (let ((ghost (if (and bg (not (string-prefix-p "unspecified" bg)))
                                 (propertize (substring-no-properties bullet)
                                             'face (list (list :foreground bg)
                                                         (or (get-text-property 0 'face bullet)
                                                             (get-char-property bullet-beg 'face))))
                               (make-string (string-width bullet) ?\s))))
                  (setq ov (make-overlay text-beg end nil t nil))
                  (overlay-put ov 'wrap-prefix
                               (concat indent ghost
                                       (buffer-substring-no-properties bullet-end text-beg)))
                  ;; nested items lie inside their parent's overlay
                  (overlay-put ov 'priority (+ 10 depth))
                  (push ov org-show--hide-overlays))))))))))

(defun org-show--org-images ()
  "Redisplay Org inline images in the current buffer the normal way."
  (if (fboundp 'org-link-preview-region)
      (org-link-preview-region nil t (point-min) (point-max))
    (with-no-warnings
      (org-display-inline-images nil t (point-min) (point-max)))))

(defun org-show--fits-p (win)
  "Return non-nil if the text of WIN fits in it without scrolling."
  (with-current-buffer (window-buffer win)
    (<= (cdr (window-text-pixel-size win (point-min) (point-max)))
        (window-body-height win t))))

(defun org-show--fit-text (wins scale)
  "Give the buffers of WINS the largest text scale <= SCALE at which they fit.
All windows get the same scale.  Return the scale used."
  (setq scale (or scale 0))
  (cl-loop
   do (dolist (w wins)
        (with-current-buffer (window-buffer w)
          (text-scale-set scale)
          (org-show--scale-latex w)
          (org-show--align-tables w)))
   until (or (not org-show-fit-text)
             (<= scale org-show-min-text-scale)
             (cl-every #'org-show--fits-p wins))
   do (setq scale (1- scale)))
  scale)

(defun org-show--math-p (el)
  "Return non-nil if Org element EL is an equation.
That is a LaTeX environment or a math fragment ($...$, \\(...\\),
\\=\\[...\\] or $$...$$), not a LaTeX command such as \\vspace{...}."
  (pcase (org-element-type el)
    ('latex-environment t)
    ('latex-fragment
     (string-match-p "\\`\\(?:\\$\\|\\\\[[(]\\)"
                     (org-element-property :value el)))))

(defun org-show--latex-overlays ()
  "Return the LaTeX preview overlays in the accessible part of the buffer."
  (cl-remove-if-not
   (lambda (o) (eq (overlay-get o 'org-overlay-type) 'org-latex-overlay))
   (overlays-in (point-min) (point-max))))

(defun org-show--latex-preview-header ()
  "Return the preamble for previewing equations in the current buffer.
It is the preamble Org would use, without the lines matching
`org-show-latex-preview-drop-regexp'.  Return nil when nothing needs
to be left out, or when the process in
`org-preview-latex-default-process' has its own preamble."
  (when (and org-show-latex-preview-drop-regexp
             (not (plist-get (cdr (assq org-preview-latex-default-process
                                        org-preview-latex-process-alist))
                             :latex-header))
             (require 'ox-latex nil t))
    (let* ((full (ignore-errors
                   (org-latex-make-preamble
                    (org-export-get-environment (org-export-get-backend 'latex))
                    org-format-latex-header
                    'snippet)))
           (header (and full
                        (replace-regexp-in-string
                         (concat org-show-latex-preview-drop-regexp "\n?")
                         "" full))))
      (unless (equal header full) header))))

(defun org-show--preview-latex ()
  "Preview LaTeX math in the accessible part of the current buffer.
The images are rendered at `org-show-latex-scale', centered if they
are display equations, and sized to the text by
`org-show--scale-latex'."
  (when (save-excursion
          (goto-char (point-min))
          (re-search-forward "\\$\\|\\\\(\\|\\\\\\[\\|\\\\begin{" nil t))
    (let* ((header (org-show--latex-preview-header))
           (proc org-preview-latex-default-process)
           (org-preview-latex-process-alist
            (if header
                (cons (cons proc (plist-put (copy-sequence
                                             (cdr (assq proc org-preview-latex-process-alist)))
                                            :latex-header header))
                      org-preview-latex-process-alist)
              org-preview-latex-process-alist))
           (org-format-latex-options
            (plist-put (plist-put (copy-sequence org-format-latex-options)
                                  :scale org-show-latex-scale)
                       ;; Org's image cache ignores the #+LATEX_HEADER
                       ;; lines, so make images with another preamble
                       ;; get other file names
                       :org-show-header (and header (sha1 header)))))
      (ignore-errors
        (if (fboundp 'org-latex-preview)
            (org-latex-preview '(16))
          (with-no-warnings (org-preview-latex-fragment '(4)))))
      (setq org-show--latex-point
            (org-show--measure-latex-point
             (list proc org-show-latex-scale (and header (sha1 header))))))
    ;; an environment's overlay starts at its #+NAME: etc. lines, which
    ;; may be hidden as clutter, and a hidden start hides the image
    (dolist (ov (org-show--latex-overlays))
      (save-excursion
        (goto-char (overlay-start ov))
        (while (looking-at "[ \t]*#\\+.*\n") (goto-char (match-end 0)))
        (when (< (overlay-start ov) (point) (overlay-end ov))
          (move-overlay ov (point) (overlay-end ov)))))
    (org-show--center-latex)
    (org-show--scale-latex)))

(defun org-show--measure-latex-point (key)
  "Return the pixels per LaTeX point in preview images made now.
It is measured once for each KEY by previewing a 10pt square with the
current preview settings, and cached in `org-show--latex-point-pixels'."
  (or (cdr (assoc key org-show--latex-point-pixels))
      (let* ((proc org-preview-latex-default-process)
             (type (or (plist-get (cdr (assq proc org-preview-latex-process-alist))
                                  :image-output-type)
                       "png"))
             (file (make-temp-file "org-show-ltx" nil (concat "." type)))
             (height (ignore-errors
                       (org-create-formula-image "$\\rule{10pt}{10pt}$" file
                                                 org-format-latex-options
                                                 (current-buffer) proc)
                       (cdr (image-size (create-image file nil nil :scale 1) t)))))
        (ignore-errors (delete-file file))
        (when (and (numberp height) (> height 0))
          (push (cons key (/ height 10.0)) org-show--latex-point-pixels)
          (/ height 10.0)))))

(defun org-show--latex-display-scale ()
  "Return the image scale that sizes LaTeX previews to the current text.
The 10pt LaTeX font is matched to the text font: 12pt, the LaTeX line
spacing, is shown as high as a line of text.  This follows the text
scale and `variable-pitch-mode'.  `org-show-latex-size' scales the
result.  If the preview size could not be measured, fall back to
`org-format-latex-options' :scale at text scale 0."
  (* org-show-latex-size
     (if org-show--latex-point
         (/ (default-font-height) 12.0 org-show--latex-point)
       (* (/ (float (or (plist-get org-format-latex-options :scale) 1.0))
             org-show-latex-scale)
          (expt text-scale-mode-step text-scale-mode-amount)))))

(defun org-show--center-string (image)
  "Return a string that moves IMAGE to the center of the window."
  (propertize " " 'display `(space :align-to (- center (0.5 . ,image)))))

(defun org-show--scale-latex (&optional win)
  "Size the LaTeX previews in the accessible region to the current text.
See `org-show--latex-display-scale'.  Images are also kept within the
width of window WIN (default: the selected window), since LaTeX
environments with equation numbers are as wide as a LaTeX page."
  (let ((scale (org-show--latex-display-scale))
        (max-w (window-body-width (or win (selected-window)) t)))
    (dolist (ov (org-show--latex-overlays))
      (let ((spec (overlay-get ov 'display))
            (center (overlay-get ov 'org-show-center)))
        (when (eq (car-safe spec) 'image)
          (let ((props (copy-sequence (cdr spec))))
            (setq props (plist-put props :scale scale))
            (setq spec (cons 'image (plist-put props :max-width max-w))))
          (overlay-put ov 'display spec)
          (when (and center (overlay-buffer center))
            (overlay-put center 'before-string (org-show--center-string spec))))))))

(defun org-show--display-math-p (ov)
  "Return non-nil if LaTeX preview overlay OV is a display equation.
That is a LaTeX environment, or \\=\\[...\\] or $$...$$ on lines of its
own."
  (save-excursion
    (goto-char (overlay-start ov))
    (skip-chars-forward " \t")
    (or (looking-at-p "\\\\begin{")
        (and (looking-at-p "\\\\\\[\\|\\$\\$")
             (save-excursion (skip-chars-backward " \t") (bolp))
             (progn (goto-char (overlay-end ov))
                    (skip-chars-forward " \t")
                    (eolp))))))

(defun org-show--center-latex ()
  "Center the display equations in the accessible region.
Each gets an overlay whose `before-string' aligns the image to the
center of the window; `org-show--scale-latex' keeps it up to date
when the image is resized."
  (when org-show-center-display-math
    (dolist (ov (org-show--latex-overlays))
      (when (and (eq (car-safe (overlay-get ov 'display)) 'image)
                 (org-show--display-math-p ov))
        (let ((center (make-overlay (overlay-start ov) (overlay-end ov) nil t nil)))
          (overlay-put center 'before-string
                       (org-show--center-string (overlay-get ov 'display)))
          (overlay-put ov 'org-show-center center)
          (push center org-show--hide-overlays))))))

(defun org-show--hide-drawers ()
  "Fold drawers in the accessible part of the current buffer."
  (if (fboundp 'org-fold-hide-drawer-all)
      (org-fold-hide-drawer-all)
    (org-cycle-hide-drawers 'all)))

(defun org-show--hide-mode-line (win)
  "Hide the mode line of WIN for the column layout."
  (set-window-parameter win 'mode-line-format 'none)
  (push win org-show--windows))

(defun org-show--setup-column-window (win base col i)
  "Show column COL of buffer BASE in window WIN.
I is the column index, used to name the indirect buffer."
  (let ((buf (make-indirect-buffer
              base (generate-new-buffer-name (format "*org-show-col-%d*" i)) t)))
    (push buf org-show--column-buffers)
    (set-window-buffer win buf)
    (org-show--hide-mode-line win)
    (with-selected-window win
      ;; the clone shares the base buffer's face remapping list, so text
      ;; scaling here would undo the title's text scale
      (setq-local face-remapping-alist nil)
      (setq-local text-scale-mode-remapping nil)
      (setq-local text-scale-mode-amount 0)
      (widen)
      (if (fboundp 'org-fold-show-all) (org-fold-show-all) (outline-show-all))
      (narrow-to-region (nth 2 col) (nth 3 col))
      ;; the clone copied the base buffer's mode variables, but the face
      ;; remapping was reset above, so apply the beautify modes afresh
      (setq org-show--beautified nil
            org-show--disabled nil
            org-show--table-overlays nil)
      (kill-local-variable 'buffer-face-mode)
      (org-show--beautify)
      (goto-char (point-min))
      (visual-line-mode 1)
      (org-show--hide-clutter (point-min) (point-max))
      (org-show--hide-drawers)
      (org-show--reflow)
      (org-show--expand-macros)
      (org-show--style-lists)
      (org-show--preview-latex)
      (org-show--show-images win)
      (set-window-start win (point-min)))))

(defun org-show--display-columns (cols)
  "Lay out the current slide with beamer columns COLS side by side.
The current buffer must be the base buffer, narrowed to the slide."
  (let* ((base (current-buffer))
         (title-win (selected-window))
         (total (apply #'+ (mapcar #'car cols)))
         (title-end (save-excursion
                      (goto-char (nth 1 (car cols)))
                      (skip-chars-backward " \t\n")
                      (max (line-end-position) (point-min)))))
    ;; the title strip: heading plus anything before the first column
    (narrow-to-region (point-min) title-end)
    ;; `or': an older `defvar' of this variable may have left it nil
    (text-scale-set (or org-show-title-text-scale 2))
    (org-show--hide-clutter (point-min) (point-max))
    (org-show--hide-drawers)
    (org-show--reflow)
    (org-show--expand-macros)
    (org-show--style-lists)
    (org-show--preview-latex)
    (org-show--align-tables title-win)
    (org-show--hide-mode-line title-win)
    (goto-char (point-min))
    ;; size the title strip first, so the column heights are final
    ;; before images are scaled and text is fitted
    (let* ((win (split-window title-win nil 'below))
           (col-wins '())
           (i 1))
      (fit-window-to-buffer title-win (floor (window-total-height (frame-root-window)) 3) 1)
      (with-selected-window title-win (org-show--show-images))
      ;; the columns
      (let ((width (window-total-width win)))
        (while cols
          (let ((col (car cols)))
            (when (cdr cols)
              (split-window win (max window-min-width
                                     (round (* width (/ (car col) total))))
                            'right))
            (let ((next (and (cdr cols) (window-right win))))
              (org-show--setup-column-window win base col i)
              (push win col-wins)
              (setq win next
                    cols (cdr cols)
                    i (1+ i))))))
      (org-show--fit-text col-wins org-show-column-text-scale))
    (select-window title-win)))

(defun org-show--teardown-columns ()
  "Remove column windows, indirect buffers and clutter overlays."
  (mapc #'delete-overlay org-show--hide-overlays)
  (setq org-show--hide-overlays '())
  (dolist (win org-show--windows)
    (when (window-live-p win)
      (set-window-parameter win 'mode-line-format nil)))
  (setq org-show--windows '())
  (dolist (buf org-show--column-buffers)
    (when (buffer-live-p buf) (kill-buffer buf)))
  (setq org-show--column-buffers '()))

;;** Per-file settings

;; File-local variables: the simple settings are safe, so Emacs does not
;; ask about them.  The mode lists are not marked safe, since a file
;; could use them to turn on any mode.
(dolist (var '(org-show-fit-text org-show-hide-clutter org-show-title-page
               org-show-section-pages org-show-animate-pages
               org-show-hanging-indent org-show-hide-emphasis-markers
               org-show-hide-macro-markers org-show-expand-macros
               org-show-align-tables
               org-show-center-display-math))
  (put var 'safe-local-variable #'booleanp))
(dolist (var '(org-show-text-scale org-show-column-text-scale
               org-show-title-text-scale org-show-min-text-scale
               org-show-page-text-scale org-show-image-width-fraction
               org-show-image-height-fraction org-show-list-indent
               org-show-latex-size org-show-latex-scale))
  (put var 'safe-local-variable #'numberp))
(put 'org-show-list-bullets 'safe-local-variable #'org-show--string-list-p)
(put 'org-show-slide-tag 'safe-local-variable #'stringp)

(defun org-show--string-list-p (value)
  "Return non-nil if VALUE is a list of strings."
  (and (listp value) (seq-every-p #'stringp value)))

(defun org-show--mode-list-p (value)
  "Return non-nil if VALUE is a list of mode symbols (names ending in -mode)."
  (and (listp value)
       (seq-every-p (lambda (m)
                      (and (symbolp m) (string-suffix-p "-mode" (symbol-name m))))
                    value)))

(defconst org-show--keyword-settings
  '(("modern" :mode org-modern-mode booleanp)
    ("variable-pitch" :mode variable-pitch-mode booleanp)
    ("modes" org-show-beautify-modes org-show--mode-list-p)
    ("disable" org-show-disable-modes org-show--mode-list-p)
    ("emphasis" org-show-hide-emphasis-markers booleanp)
    ("macro-markers" org-show-hide-macro-markers booleanp)
    ("macros" org-show-expand-macros booleanp)
    ("align-tables" org-show-align-tables booleanp)
    ("bullets" org-show-list-bullets org-show--string-list-p)
    ("list-indent" org-show-list-indent natnump)
    ("hanging" org-show-hanging-indent booleanp)
    ("title-page" org-show-title-page booleanp)
    ("section-pages" org-show-section-pages booleanp)
    ("animate" org-show-animate-pages booleanp)
    ("page-scale" org-show-page-text-scale numberp)
    ("text-scale" org-show-text-scale numberp)
    ("column-scale" org-show-column-text-scale numberp)
    ("title-scale" org-show-title-text-scale numberp)
    ("min-scale" org-show-min-text-scale numberp)
    ("fit" org-show-fit-text booleanp)
    ("image-width" org-show-image-width-fraction numberp)
    ("image-height" org-show-image-height-fraction numberp)
    ("clutter" org-show-hide-clutter booleanp)
    ("latex-size" org-show-latex-size numberp)
    ("latex-scale" org-show-latex-scale numberp)
    ("center-math" org-show-center-display-math booleanp))
  "Keys of the #+ORG_SHOW: keyword.
Each entry is (KEY VARIABLE PREDICATE), or (KEY :mode MODE PREDICATE)
for a key that adds MODE to or removes it from
`org-show-beautify-modes'.")

(defvar-local org-show--saved-settings nil
  "Settings changed by #+ORG_SHOW:, as (VARIABLE LOCALP . OLD-VALUE).")

(defun org-show--parse-keyword (string)
  "Parse STRING, the value of #+ORG_SHOW: lines, into (KEY . VALUE) pairs.
Values are read as Lisp, like the values of #+OPTIONS.  Pairs that
cannot be read are skipped with a message."
  (let ((pos 0)
        (pairs '()))
    (while (string-match "\\([a-z][a-z-]*\\):" string pos)
      (let ((key (match-string 1 string)))
        (setq pos (match-end 0))
        (condition-case nil
            (let ((read (read-from-string string pos)))
              (push (cons key (car read)) pairs)
              (setq pos (cdr read)))
          (error
           (message "org-show: cannot read the value of %s: in #+ORG_SHOW:" key)
           (setq pos (length string))))))
    (nreverse pairs)))

(defun org-show--set-setting (var value)
  "Set VAR to VALUE in this buffer, recording its old state for restoring."
  (unless (assq var org-show--saved-settings)
    (push (cons var (cons (local-variable-p var) (symbol-value var)))
          org-show--saved-settings))
  (set (make-local-variable var) value))

(defun org-show--apply-keyword-settings ()
  "Apply the #+ORG_SHOW: settings of the current buffer, locally.
See `org-show--keyword-settings' for the keys.  Unknown keys and
invalid values are skipped with a message."
  (org-show--restore-keyword-settings)
  (let ((value (mapconcat #'identity
                          (cdr (assoc "ORG_SHOW" (org-collect-keywords '("ORG_SHOW"))))
                          " ")))
    (dolist (pair (org-show--parse-keyword value))
      (let* ((key (car pair))
             (val (cdr pair))
             (entry (assoc key org-show--keyword-settings)))
        (cond
         ((null entry)
          (message "org-show: unknown #+ORG_SHOW: key %s" key))
         ((eq (nth 1 entry) :mode)
          (if (not (funcall (nth 3 entry) val))
              (message "org-show: ignoring %s:%S" key val)
            (let ((mode (nth 2 entry)))
              (org-show--set-setting
               'org-show-beautify-modes
               (if val
                   (append (remq mode org-show-beautify-modes) (list mode))
                 (remq mode org-show-beautify-modes))))))
         ((not (funcall (nth 2 entry) val))
          (message "org-show: ignoring %s:%S" key val))
         (t
          (org-show--set-setting (nth 1 entry) val)))))))

(defun org-show--restore-keyword-settings ()
  "Undo `org-show--apply-keyword-settings' in the current buffer."
  (dolist (saved org-show--saved-settings)
    (let ((var (car saved)))
      (if (cadr saved)
          (set (make-local-variable var) (cddr saved))
        (kill-local-variable var))))
  (setq org-show--saved-settings nil))

;;** Beautify modes

(defun org-show--mode-on-p (mode)
  "Return non-nil if minor MODE is on in the current buffer."
  (if (eq mode 'variable-pitch-mode)
      ;; not a real minor mode; it works through `buffer-face-mode'
      (bound-and-true-p buffer-face-mode)
    (and (boundp mode) (symbol-value mode))))

(defun org-show--beautify ()
  "Turn on `org-show-beautify-modes' and marker hiding in this buffer.
Only modes that are installed and not already on are turned on, and
they are recorded so `org-show--unbeautify' can turn them off.
Also turn off the modes in `org-show-disable-modes'."
  (org-show--disable-modes)
  (dolist (mode org-show-beautify-modes)
    (ignore-errors
      (unless (fboundp mode)
        (require (intern (string-remove-suffix "-mode" (symbol-name mode))) nil t))
      (when (and (fboundp mode) (not (org-show--mode-on-p mode)))
        (when (eq mode 'org-modern-mode)
          ;; org-modern draws tags as labels, which shows part of the
          ;; hidden :slide: tag; tags are not wanted on slides anyway
          (setq-local org-modern-tag nil)
          ;; org-show draws its own bullets, see `org-show--style-lists'
          (when org-show-list-bullets
            (setq-local org-modern-list nil)))
        (funcall mode 1)
        (push mode org-show--beautified))))
  (when (and org-show-hide-emphasis-markers
             (not org-hide-emphasis-markers))
    (setq-local org-hide-emphasis-markers t)
    (push 'org-hide-emphasis-markers org-show--beautified))
  (when (and org-show-hide-macro-markers
             (not org-hide-macro-markers))
    (setq-local org-hide-macro-markers t)
    (push 'org-hide-macro-markers org-show--beautified))
  (when org-show--beautified
    (font-lock-flush)))

(defun org-show--disable-modes ()
  "Turn off the modes in `org-show-disable-modes' in this buffer.
They are recorded so `org-show--unbeautify' can turn them on again."
  (dolist (mode org-show-disable-modes)
    (ignore-errors
      (when (and (fboundp mode) (org-show--mode-on-p mode))
        (funcall mode -1)
        (push mode org-show--disabled)))))

(defun org-show--unbeautify ()
  "Undo `org-show--beautify' in this buffer."
  (dolist (mode org-show--disabled)
    (ignore-errors (funcall mode 1)))
  (setq org-show--disabled nil)
  (when org-show--beautified
    (dolist (mode org-show--beautified)
      (ignore-errors
        (if (memq mode '(org-hide-emphasis-markers org-hide-macro-markers))
            (kill-local-variable mode)
          (funcall mode -1)
          (when (eq mode 'org-modern-mode)
            (kill-local-variable 'org-modern-tag)
            (kill-local-variable 'org-modern-list)))))
    (setq org-show--beautified nil)
    (font-lock-flush)))

;;** Macros

(defun org-show--macro-templates ()
  "Return the macro templates for the show in the current buffer.
See `org-show-expand-macros'.  Org's templates come from
`org-macro-initialize-templates', without #+MACRO: definitions that
evaluate Lisp: showing a presentation should not run code in it."
  (org-with-wide-buffer
   (let* ((kw (org-collect-keywords '("ORG_SHOW_MACRO" "MACRO")))
          (defs (lambda (key)
                  (delq nil
                        (mapcar (lambda (v)
                                  (when (string-match "\\`\\(\\S-+\\)[ \t]*" v)
                                    (cons (match-string 1 v) (substring v (match-end 0)))))
                                (cdr (assoc key kw))))))
          (show (cl-remove-if (lambda (d) (string-match-p "\\`(eval\\>" (cdr d)))
                              (funcall defs "ORG_SHOW_MACRO")))
          (eval-names (mapcar #'car
                              (cl-remove-if-not
                               (lambda (d) (string-match-p "\\`(eval\\>" (cdr d)))
                               (funcall defs "MACRO"))))
          (org (let ((org-macro-templates nil))
                 (ignore-errors (org-macro-initialize-templates))
                 (cl-remove-if (lambda (d) (member-ignore-case (car d) eval-names))
                               org-macro-templates))))
     ;; `org-macro-expand' uses the first match
     (append (reverse show) org-show-macro-templates org))))

(defun org-show--strip-snippets (text)
  "Return TEXT without export snippets for back-ends other than org-show.
The contents of @@org-show:...@@ snippets are kept."
  (replace-regexp-in-string
   "@@\\([-A-Za-z0-9]+\\):\\(\\(?:.\\|\n\\)*?\\)@@"
   (lambda (m)
     (if (string= (downcase (match-string 1 m)) "org-show")
         (match-string 2 m)
       ""))
   text t t))

(defun org-show--macro-string (text templates)
  "Return the expansion TEXT of a macro, as it should look on a slide.
Export snippets for other back-ends are removed, the contents of
@@org-show:...@@ snippets are kept, macros in TEXT are expanded with
TEMPLATES, and the rest is fontified as Org text, keeping any faces
TEXT already has."
  (setq text (org-show--expand-macros-in-string
              (org-show--strip-snippets text) templates 1))
  (if (or (string-empty-p (string-trim text))
          (text-property-not-all 0 (length text) 'face nil text))
      text
    (let ((hide-emphasis org-hide-emphasis-markers))
      (with-temp-buffer
        (delay-mode-hooks (org-mode))
        (setq-local org-hide-emphasis-markers hide-emphasis)
        (insert text)
        (font-lock-ensure)
        ;; leave out what Org makes invisible, e.g. emphasis markers
        (let ((pos (point-min)) (parts '()))
          (while (< pos (point-max))
            (let ((next (next-single-char-property-change pos 'invisible)))
              (unless (invisible-p pos)
                (push (buffer-substring pos next) parts))
              (setq pos next)))
          (apply #'concat (nreverse parts)))))))

(defun org-show--expand-macros ()
  "Show the macros in the accessible region as their expansion.
See `org-show-expand-macros'.  This is done with overlays, so the
buffer text is not changed."
  (when org-show-expand-macros
    (let ((templates nil) (initialized nil))
      (org-element-map (org-element-parse-buffer) 'macro
        (lambda (macro)
          (unless initialized
            (setq templates (org-show--macro-templates)
                  initialized t))
          (let* ((value (ignore-errors (org-macro-expand macro templates)))
                 (string (and value (org-show--macro-string value templates))))
            (when (and string (not (string-empty-p (string-trim string))))
              (let ((ov (make-overlay (org-element-property :begin macro)
                                      (- (org-element-property :end macro)
                                         (org-element-property :post-blank macro))
                                      nil t nil)))
                (overlay-put ov 'display string)
                (overlay-put ov 'priority 1000)
                ;; `org-hide-macro-markers' makes the braces invisible,
                ;; and a display spec on invisible text is not shown; an
                ;; overlay value not in the invisibility spec wins
                (overlay-put ov 'invisible 'org-show-macro)
                (push ov org-show--hide-overlays)))))))))

;;** Tables

(defun org-show--table-line-cells ()
  "Return the cells of the table line at point, as (BEG . END) pairs.
BEG and END are just inside the separators around the cell: the |
characters, and in a horizontal rule also the + characters."
  (save-excursion
    (let* ((eol (line-end-position))
           (seps (progn (skip-chars-forward " \t")
                        (if (looking-at-p "|-") "|+" "|")))
           (pos '()))
      (while (< (point) eol)
        (when (memq (char-after) (append seps nil))
          (push (point) pos))
        (forward-char))
      (setq pos (nreverse pos))
      (cl-loop for (a b) on pos while b collect (cons (1+ a) b)))))

(defun org-show--table-pad (beg end pixels &optional face)
  "Display the region BEG END as blank space PIXELS wide, in FACE."
  (when (< beg end)
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'display `(space :width (,(max 0 pixels))))
      (overlay-put ov 'priority 1001)
      (when face (overlay-put ov 'face face))
      (push ov org-show--table-overlays)
      (push ov org-show--hide-overlays))))

(defun org-show--align-tables (&optional win)
  "Align the Org tables in the accessible region to their display in WIN.
WIN defaults to the selected window.  The width of each cell is
measured as displayed, with expanded macros, equation images and the
font in use, and the blanks around it are shown as space of the width
that lines up the columns.  Cells that Org right-aligned (numbers) stay
right-aligned.  Horizontal rules are drawn to the column widths.  See
`org-show-align-tables'."
  (setq win (or win (selected-window)))
  (mapc #'delete-overlay org-show--table-overlays)
  (setq org-show--table-overlays nil)
  (when org-show-align-tables
    (org-element-map (org-element-parse-buffer) 'table
      (lambda (table)
        (when (eq (org-element-property :type table) 'org)
          (save-excursion
            (let ((end (org-element-property :contents-end table))
                  (rows '())
                  (widths (make-hash-table))
                  (spc nil))
              (goto-char (org-element-property :post-affiliated table))
              ;; measure
              (while (and (< (point) (or end (point-max)))
                          (looking-at-p "[ \t]*|"))
                (let* ((hline (looking-at-p "[ \t]*|-"))
                       (cells
                        (cl-loop
                         for (b . e) in (org-show--table-line-cells)
                         for i from 0
                         collect
                         (let* ((cb (save-excursion (goto-char b)
                                                    (skip-chars-forward " \t" e)
                                                    (point)))
                                (ce (save-excursion (goto-char e)
                                                    (skip-chars-backward " \t" cb)
                                                    (point)))
                                (w (if (or hline (>= cb ce)) 0
                                     (car (window-text-pixel-size win cb ce)))))
                           (when (and (not spc) (not hline) (< b cb))
                             (setq spc (car (window-text-pixel-size win b (1+ b)))))
                           (puthash i (max w (gethash i widths 0)) widths)
                           (list b e cb ce w)))))
                  (push (cons hline cells) rows))
                (forward-line 1))
              (setq spc (or spc (frame-char-width (window-frame win))))
              ;; pad
              (dolist (row rows)
                (cl-loop
                 for (b e cb ce w) in (cdr row)
                 for i from 0
                 do (let ((col (gethash i widths 0)))
                      (cond
                       ((car row)
                        (org-show--table-pad b e (+ col (* 2 spc))
                                             '(:inherit org-table :strike-through t)))
                       ((>= cb ce)
                        (org-show--table-pad b e (+ col (* 2 spc))))
                       ;; Org pads numbers on the left
                       ((> (- cb b) 1)
                        (org-show--table-pad b cb (+ (- col w) spc))
                        (org-show--table-pad ce e spc))
                       (t
                        (org-show--table-pad b cb spc)
                        (org-show--table-pad ce e (+ (- col w) spc))))))))))))))

;;** Title and section pages

(defun org-show--expand-macros-in-string (string &optional templates depth)
  "Return STRING with its Org macros expanded, see `org-show-expand-macros'.
Macros in the expansions are expanded too, up to a few levels deep.
Macros that cannot be expanded are removed.  TEMPLATES defaults to
`org-show--macro-templates'; DEPTH is used for the recursion."
  (let ((depth (or depth 0)))
    (if (or (not org-show-expand-macros) (> depth 5)
            (not (string-match-p "{{{" string)))
        (replace-regexp-in-string "{{{\\(?:.\\|\n\\)*?}}}" "" string t t)
      (let ((templates (or templates (org-show--macro-templates))))
        (replace-regexp-in-string
         "{{{\\([^}(]+\\)\\(?:(\\(\\(?:.\\|\n\\)*?\\))\\)?}}}"
         (lambda (m)
           (let* ((key (downcase (string-trim (match-string 1 m))))
                  (args (and (match-string 2 m)
                             (org-macro-extract-arguments (match-string 2 m))))
                  (value (ignore-errors
                           (org-macro-expand (list 'macro (list :key key :args args))
                                             templates))))
             (if value
                 (org-show--expand-macros-in-string
                  (org-show--strip-snippets value) templates (1+ depth))
               "")))
         string t t)))))

(defun org-show--keyword-lines (value)
  "Split keyword VALUE into lines of plain text.
LaTeX line breaks (\\\\) start new lines, \\today becomes today's
date, \\and becomes a comma, Org macros are expanded (see
`org-show-expand-macros') or dropped, and other LaTeX commands are
dropped, keeping their arguments."
  (let ((value (substring-no-properties
                (org-show--expand-macros-in-string (or value "")))))
    (delq nil
          (mapcar
           (lambda (s)
             (setq s (replace-regexp-in-string
                      "\\\\today\\b" (string-trim (format-time-string "%e %B %Y")) s t t))
             (setq s (replace-regexp-in-string "[ \t]*\\\\and\\b[ \t]*" ", " s t t))
             (setq s (replace-regexp-in-string
                      "\\\\[a-zA-Z]+\\*?\\(?:\\[[^]]*\\]\\)?{\\([^}]*\\)}" "\\1" s))
             (setq s (replace-regexp-in-string "\\\\[a-zA-Z]+\\*?\\|[{}~]" "" s t t))
             (setq s (string-trim s))
             (unless (string= s "") s))
           (split-string value "\\\\\\\\")))))

(defun org-show--heading-title ()
  "Return the plain text of the heading at point."
  (org-link-display-format (org-get-heading t t t t)))

(defun org-show--title-lines ()
  "Return the title page of the current buffer as a list of (TEXT . FACE)."
  (let* ((kw (org-collect-keywords '("TITLE" "SUBTITLE" "AUTHOR" "DATE")))
         (get (lambda (k)
                (org-show--keyword-lines (mapconcat #'identity (cdr (assoc k kw)) " "))))
         (face (lambda (f) (lambda (s) (cons s f))))
         (title (or (funcall get "TITLE")
                    (list (file-name-base (or (buffer-file-name (org-show--base-buffer))
                                              (buffer-name))))))
         (info (append (funcall get "AUTHOR") (funcall get "DATE"))))
    (append (mapcar (funcall face 'org-show-page-title) title)
            (mapcar (funcall face 'org-show-page-subtitle) (funcall get "SUBTITLE"))
            (when info
              (cons (cons "" nil)
                    (mapcar (funcall face 'org-show-page-info) info))))))

(defun org-show--section-lines (marker)
  "Return the section page for the heading at MARKER as a list of (TEXT . FACE)."
  (org-with-point-at marker
    (list (cons (org-show--heading-title) 'org-show-page-section))))

(defun org-show--section-ancestors ()
  "Return the positions of the section headings above the slide at point.
These are the ancestors without the slide tag, outermost first."
  (save-excursion
    (let ((res '()))
      (while (org-up-heading-safe)
        (unless (member org-show-slide-tag (org-get-tags nil t))
          (push (point) res)))
      res)))

(defun org-show--place-string (text vpos hpos)
  "Insert TEXT at line VPOS, column HPOS, padding with newlines and spaces."
  (goto-char (point-min))
  (dotimes (_ vpos)
    (end-of-line)
    (when (= (forward-line 1) 1) (insert "\n")))
  (move-to-column hpos t)
  (insert text))

(defun org-show--show-page (lines scale animate)
  "Show LINES, a list of (TEXT . FACE), centred on a page of their own.
SCALE is the text scale.  With ANIMATE, the lines are animated in; a
key press skips the rest of the animation."
  (org-show--teardown-columns)
  (delete-other-windows)
  (switch-to-buffer (get-buffer-create org-show--page-buffer))
  (let ((inhibit-read-only t)) (erase-buffer))
  (setq buffer-undo-list t)
  (setq-local cursor-type nil)
  (setq-local show-trailing-whitespace nil)
  (org-show--disable-modes)
  (setq-local indent-tabs-mode nil)
  (org-show--hide-mode-line (selected-window))
  (text-scale-set (or scale 5))
  (let* ((cols (window-max-chars-per-line))
         (rows (/ (window-body-height nil t) (window-font-height nil 'default)))
         (vpos (max 0 (/ (- rows (length lines)) 2))))
    (dolist (line lines)
      (let* ((text (car line))
             (hpos (max 0 (/ (- cols (string-width text)) 2))))
        (unless (string= text "")
          (if (and animate (not (input-pending-p)))
              (animate-string text vpos hpos)
            (org-show--place-string text vpos hpos))
          (when (cdr line)
            (save-excursion
              (goto-char (point-min))
              (forward-line vpos)
              (move-to-column hpos)
              (put-text-property (point) (min (line-end-position) (+ (point) (length text)))
                                 'face (cdr line)))))
        (setq vpos (1+ vpos)))))
  (goto-char (point-min))
  (set-window-start nil (point-min)))

(defun org-show--show-special (entry n)
  "Show the title or section page ENTRY, which is slide N."
  (let (lines scale animate)
    ;; read everything in the presentation buffer, where the settings
    ;; may be buffer-local (file-local variables, #+ORG_SHOW:)
    (with-current-buffer (org-show--show-buffer)
      (save-restriction
        (widen)
        (setq lines (pcase (car entry)
                      (:title (org-show--title-lines))
                      (:section (org-show--section-lines (cadr entry))))
              scale org-show-page-text-scale
              animate org-show-animate-pages)))
    (set-frame-name (format "%-180s%15s%s" (car (car lines)) "slide " n))
    (org-show--show-page lines scale animate)
    (message "")))

(defun org-show--entry-title (entry)
  "Return a title for the slide list ENTRY, for the table of contents."
  (if (markerp entry)
      (org-with-point-at entry (nth 4 (org-heading-components)))
    (with-current-buffer (find-file-noselect org-show-presentation-file)
      (save-restriction
        (widen)
        (pcase (car entry)
          (:title (concat "Title page: " (car (car (org-show--title-lines)))))
          (:section (concat "Section: " (car (car (org-show--section-lines (cadr entry)))))))))))

;;** Slides

(defun org-show--goto-slide-heading ()
  "Move point to the slide heading containing point."
  (org-back-to-heading t)
  (while (and (not (member org-show-slide-tag (org-get-tags nil t)))
              (org-up-heading-safe))))

(defun org-show-execute-slide ()
  "Process slide at point.
If it contains an Emacs Lisp source block, evaluate it.
  If it has beamer columns, show them side by side.
  Else, focus on that buffer.
  Hide all drawers.
On a title or section page, show that page again."
  (interactive)
  (if (equal (buffer-name) org-show--page-buffer)
      (org-show-goto-slide org-show-current-slide-number)
    (org-show--execute-slide)))

(defun org-show--execute-slide ()
  "Show the slide at point.  See `org-show-execute-slide'."
  ;; if point is in a column buffer, move to the same place in the base buffer
  (let ((pos (point))
        (base (org-show--base-buffer)))
    (org-show--teardown-columns)
    (switch-to-buffer base)
    (goto-char pos))
  (setq org-show-presentation-file (org-show--file))
  (delete-other-windows)

  ;; make sure nothing is folded. This seems to be necessary to
  ;; prevent an error on narrowing then trying to make latex fragments
  ;; I think.
  (widen)
  (org-cycle '(64))

  (org-narrow-to-subtree)
  (visual-line-mode 1)
  (let ((heading-text (nth 4 (org-heading-components)))
        (cols (org-show--slide-columns)))

    (set-frame-name (format "%-180s%15s%s"
                            heading-text
                            "slide "
                            (cdr (assoc heading-text org-show-slide-titles))))

    ;; setup the text
    (switch-to-buffer (current-buffer))
    (with-no-warnings
      (if (fboundp 'org-fold-show-subtree) (org-fold-show-subtree) (org-show-subtree))
      (if (fboundp 'org-fold-hide-block-all) (org-fold-hide-block-all) (org-hide-block-all)))
    (if cols
        (org-show--display-columns cols)
      (delete-other-windows)
      (org-show--hide-clutter (point-min) (point-max))
      (org-show--hide-drawers)
      (org-show--reflow)
      (org-show--expand-macros)
      (org-show--style-lists)
      ;; preview equations in the current subtree
      (org-show--preview-latex)
      (org-show--show-images)
      (org-show--fit-text (list (selected-window)) org-show-text-scale))

    ;; evaluate special code blocks last as they may change the arrangement
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-babel-src-block-regexp nil t)
        (save-excursion
          (goto-char (match-beginning 0))
          (let* ((info (save-excursion
                         (org-babel-get-src-block-info))))
            (when (string= "emacs-lisp-slide" (car info))
              ;; fold code
              (org-cycle)
              (eval (read (concat "(progn " (nth 1 info) ")"))))))))
    ;; clear the minibuffer
    (message "")))

(defun org-show-next-slide ()
  "Goto next slide in presentation."
  (interactive)
  (find-file org-show-presentation-file)
  (widen)
  (if (<= (+ org-show-current-slide-number 1) (length org-show-slide-list))
      (progn
        (setq org-show-current-slide-number (+ org-show-current-slide-number 1))
        (org-show-goto-slide org-show-current-slide-number))
    (org-show-goto-slide org-show-current-slide-number)
    (message "This is the end. My only friend the end.  Jim Morrison.")))


(defun org-show-previous-slide ()
  "Goto previous slide in the list."
  (interactive)
  (find-file org-show-presentation-file)
  (widen)
  (if (> (- org-show-current-slide-number 1) 0)
      (progn
        (setq org-show-current-slide-number (- org-show-current-slide-number 1))
        (org-show-goto-slide org-show-current-slide-number))
    (org-show-goto-slide org-show-current-slide-number)
    (message "Once upon a time...")))


(defun org-show-open-slide ()
  "Start show at this slide."
  (interactive)
  (let ((pos (point)))
    (switch-to-buffer (org-show--base-buffer))
    (goto-char pos))
  (setq org-show-presentation-file (org-show--file))
  (widen)
  (org-show--apply-keyword-settings)
  (org-show-initialize)
  (org-show--goto-slide-heading)
  (let ((n (cdr (assoc (nth 4 (org-heading-components)) org-show-slide-titles))))
    (unless n (user-error "Not in a slide"))
    (setq *org-show-running* t)
    (org-show--beautify)
    (unless org-show-mode (org-show-mode 1))
    (setq org-show-current-slide-number n)
    (org-show-goto-slide n)))


(defun org-show-initialize ()
  "Initialize the org-show.
Make slide lists for future navigation. Rerun this if you change
slide order.  The list starts with a title page if
`org-show-title-page' is non-nil, and has a section page before the
first slide of each section if `org-show-section-pages' is non-nil."
  (setq  org-show-slide-titles '()
         org-show-temp-images '()
         org-show-slide-list '())

  (let ((n 0)
        (seen '()))
    (when org-show-title-page
      (push (cons (cl-incf n) (list :title)) org-show-slide-list))
    (org-map-entries
     (lambda ()
       ;; COMMENTed slides are skipped, as they are in export
       (when (and (member org-show-slide-tag (org-get-tags nil t))
                  (not (org-in-commented-heading-p)))
         (when org-show-section-pages
           (dolist (pos (org-show--section-ancestors))
             (unless (member pos seen)
               (push pos seen)
               (cl-incf n)
               (push (cons (save-excursion
                             (goto-char pos)
                             (nth 4 (org-heading-components)))
                           n)
                     org-show-slide-titles)
               (push (cons n (list :section (set-marker (make-marker) pos)))
                     org-show-slide-list))))
         (cl-incf n)
         (push (cons (nth 4 (org-heading-components)) n) org-show-slide-titles)
         (push (cons n (set-marker (make-marker) (point))) org-show-slide-list))))
    (setq org-show-slide-titles (nreverse org-show-slide-titles)
          org-show-slide-list (nreverse org-show-slide-list))))


(defun org-show-start-slideshow ()
  "Start the slide show, at the beginning."
  (interactive)
  (switch-to-buffer (org-show--base-buffer))
  (setq *org-show-running* t)
  (setq org-show-presentation-file (org-show--file))
  (widen)
  (goto-char (point-min))
  (setq org-tags-column org-show-tags-column)
  (org-set-tags-command '(4))

  (org-show--apply-keyword-settings)
  (org-show-initialize)
  ;; hide slide tags
  (save-excursion
    (while (re-search-forward org-show-slide-tag-regexp nil t)
      (overlay-put
       (make-overlay (match-beginning 0) (match-end 0))
       'invisible 'slide)))
  ;; hide emacs-lisp-slide blocks
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward org-babel-src-block-regexp nil t)
      (save-excursion
        (goto-char (match-beginning 0))
        (let* ((src (org-element-context))
               (start (org-element-property :begin src))
               (end (org-element-property :end src))
               (info (save-excursion
                       (org-babel-get-src-block-info))))
          (when (string= "emacs-lisp-slide" (car info))
            (overlay-put
             (make-overlay start end)
             'invisible 'slide))))))
  (add-to-invisibility-spec 'slide)
  (goto-char (point-min))
  (delete-other-windows)
  (org-show--beautify)
  (unless org-show-mode (org-show-mode 1))
  (setq org-show-current-slide-number 1)
  (org-show-goto-slide 1))


(defun org-show-stop-slideshow ()
  "Stop the org-show.
Try to reset the state of your Emacs. It isn't perfect ;)"
  (interactive)
  (org-show--teardown-columns)
  (when org-show-presentation-file (find-file org-show-presentation-file))
  ;; make slide tag visible again
  (remove-from-invisibility-spec 'slide)
  (remove-from-invisibility-spec 'org-show)

  ;; Redisplay inline images
  (widen)
  (org-show--org-images)

  ;; clean up temp images
  (mapc (lambda (x)
          (let ((bname (file-name-nondirectory x)))
            (when (get-buffer bname)
              (set-buffer bname)
              (save-buffer)
              (kill-buffer bname)))

          (when (file-exists-p x)
            (delete-file x)))
        org-show-temp-images)
  (setq org-show-temp-images '())

  ;; ;; clean up miscellaneous buffers
  (when (get-buffer "*Animation*") (kill-buffer "*Animation*"))
  (when (get-buffer org-show--page-buffer) (kill-buffer org-show--page-buffer))

  (when org-show-presentation-file (find-file org-show-presentation-file))
  (widen)
  ;; the equation images were made for the slides
  (org-clear-latex-preview)
  (text-scale-set 0)
  (delete-other-windows)
  (setq org-show-presentation-file nil)
  (setq org-show-current-slide-number 1)
  (set-frame-name (if (buffer-file-name)
                      (abbreviate-file-name (buffer-file-name))))
  (org-show--unbeautify)
  (org-show--restore-keyword-settings)
  (setq org-tags-column org-show-original-tags-column)
  (org-set-tags-command '(4))
  (setq *org-show-running* nil)
  (org-show-mode -1))


(defun org-show-goto-slide (n)
  "Goto slide N."
  (interactive "nSlide number: ")
  (message "Going to slide %s" n)
  (find-file org-show-presentation-file)
  (setq org-show-current-slide-number n)
  (widen)
  (let ((entry (cdr (assoc n org-show-slide-list))))
    (if (markerp entry)
        (progn
          (goto-char entry)
          (org-show--execute-slide))
      (org-show--show-special entry n))))


(defun org-show-toc ()
  "Show a table of contents for the slideshow."
  (interactive)
  (let ((links
         (mapcar (lambda (x)
                   (format " [[elisp:(org-show-goto-slide %s)][%2s %s]]\n\n"
                           (car x) (car x) (org-show--entry-title (cdr x))))
                 org-show-slide-list)))
    (org-show--teardown-columns)
    (delete-other-windows)
    (switch-to-buffer "*List of Slides*")
    (org-mode)
    (erase-buffer)

    (insert (mapconcat 'identity links ""))
    (goto-char (point-min))

    (use-local-map (copy-keymap org-mode-map))
    (local-set-key "q" #'(lambda () (interactive) (kill-buffer)))))


(defun org-show-animate (strings)
  "Animate STRINGS in an *Animation* buffer."
  (switch-to-buffer (get-buffer-create
                     (or animation-buffer-name
                         "*Animation*")))
  (erase-buffer)
  (text-scale-set 6)
  (let* ((vpos (/ (- 20
                     1 ;; For the mode-line
                     (1- (length strings))
                     (length strings))
                  2))
         (width 43)
         hpos)
    (while strings
      (setq hpos (/ (- width (length (car strings))) 2))
      (when (> 0 hpos) (setq hpos 0))
      (when (> 0 vpos) (setq vpos 0))
      (animate-string (car strings) vpos hpos)
      (setq vpos (1+ vpos))
      (setq strings (cdr strings)))))


(defun org-show--change-text-scale (delta)
  "Change the slide text scale by DELTA steps for this and later slides.
On a title or section page this changes `org-show-page-text-scale', on a
slide with columns `org-show-column-text-scale',
otherwise `org-show-text-scale'.  The change starts from the scale
currently shown, which may be smaller than the maximum when text was
shrunk to fit."
  (let* ((col (cl-find-if #'buffer-live-p org-show--column-buffers))
         (page (equal (buffer-name) org-show--page-buffer))
         (var (cond (page 'org-show-page-text-scale)
                    (col 'org-show-column-text-scale)
                    (t 'org-show-text-scale)))
         (shown (with-current-buffer (if page (current-buffer)
                                       (or col (org-show--base-buffer)))
                  (bound-and-true-p text-scale-mode-amount)))
         (new (+ (or shown (buffer-local-value var (org-show--show-buffer))) delta)))
    ;; in the presentation buffer, so a value local to it (file-local
    ;; variable or #+ORG_SHOW:) is changed there, and a global one globally
    (with-current-buffer (org-show--show-buffer)
      (set var new))
    (if *org-show-running*
        (org-show-goto-slide org-show-current-slide-number)
      (text-scale-set new))
    (message "%s = %s" var new)))


(defun org-show-increase-text-size ()
  "Increase the text size of this and later slides.
Bound to \\[org-show-increase-text-size].  With `org-show-fit-text'
non-nil, text never grows beyond what fits in the window."
  (interactive)
  (org-show--change-text-scale 1))


(defun org-show-decrease-text-size ()
  "Decrease the text size of this and later slides.
Bound to \\[org-show-decrease-text-size]."
  (interactive)
  (org-show--change-text-scale -1))

;;* Menu and org-show-mode

(defvar org-show-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [next] 'org-show-next-slide)
    (define-key map [prior] 'org-show-previous-slide)

    (define-key map [f5] 'org-show-start-slideshow)
    (define-key map [f6] 'org-show-execute-slide)
    (define-key map (kbd "C--") 'org-show-decrease-text-size)
    (define-key map (kbd "C-=") 'org-show-increase-text-size)
    (define-key map (kbd "\e\eg") 'org-show-goto-slide)
    (define-key map (kbd "\e\et") 'org-show-toc)
    (define-key map (kbd "\e\eq") 'org-show-stop-slideshow)
    map)
  "Keymap for function ‘org-show-mode’.")


(easy-menu-define org-show-menu org-show-mode-map "Menu for org-show."
  '("org-show"
    ["Start slide show" org-show-start-slideshow t]
    ["Next slide" org-show-next-slide t]
    ["Previous slide" org-show-previous-slide t]
    ["Open this slide" org-show-open-slide t]
    ["Goto slide" org-show-goto-slide t]
    ["Table of contents" org-show-toc t]
    ["Stop slide show"  org-show-stop-slideshow t]))


(define-minor-mode org-show-mode
  "Minor mode for org-show

\\{org-show-mode-map}"
  :init-value nil
  :lighter " org-show"
  :global t
  :group 'org
  :keymap org-show-mode-map
  ;; https://www.gnu.org/software/emacs/manual/html_node/elisp/Minor-Mode-Conventions.html
  (if org-show-mode
      (when (bound-and-true-p flyspell-mode)
        (setq *org-show-flyspell-mode* t)
        (flyspell-mode-off))
    ;; restore flyspell
    (when *org-show-flyspell-mode*
      (flyspell-mode-on)
      (setq *org-show-flyspell-mode* nil))

    ;; close the show.
    (when *org-show-running*
      (org-show-stop-slideshow))))

;;* Make emacs-lisp-slide blocks executable

;; this is tricker than I thought. It seems babel usually runs in some
;; sub-process and I need the code to be executed in the current buffer.
(defun org-babel-execute:emacs-lisp-slide (body _params)
  (message "%S" body)
  (let ((src (org-element-context)))
    (save-excursion
      (goto-char (org-element-property :begin src))
      (re-search-forward (org-element-property :value src))
      (eval-region (match-beginning 0) (match-end 0)))))

;; * help
(defun org-show-help ()
  "Open the help file."
  (interactive)
  (find-file (expand-file-name "org-show.org"
                               (file-name-directory
                                (locate-library "org-show")))))



;;* The end

(provide 'org-show)

;;; org-show-beamer.el ends here
