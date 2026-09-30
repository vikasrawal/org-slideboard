;;; org-slideboard.el --- Present Org files as slides with columns and code -*- lexical-binding: t; -*-

;; Copyright (C) 2014 John Kitchin
;; Copyright (C) 2026 Vikas Rawal

;; Author: Vikas Rawal <vikasrawal@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5-5
;; Maintainer: Vikas Rawal <vikasrawal@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org "9.6"))
;; Keywords: outlines, tex, multimedia, convenience
;; URL: https://github.com/vikasrawal/org-slideboard

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-slideboard presents an Org file as slides, inside Emacs.  A slide
;; is a heading with the :slide: tag.  The text stays live Org, so it
;; can be edited, and code run, during the show.
;;
;; It is meant for files written for beamer export, and shows them much
;; as beamer would:
;;
;; - beamer columns (BEAMER_col or the BMCOL tag) side by side, each in
;;   its own window, with images scaled to the column;
;; - a title page and section pages from #+TITLE, #+AUTHOR and the
;;   headings above the slides;
;; - text fitted to the window, paragraphs reflowed, and lists, tables
;;   and LaTeX equations laid out for the slide;
;; - Org macros expanded, with optional definitions for the show;
;; - source blocks shown as code, results, or both, one above the other
;;   or side by side, with C-c C-c updating the results and the block's
;;   editor shown next to a running R or Python REPL;
;; - beamer and babel clutter hidden.
;;
;; Start a presentation with M-x org-slideboard-start-slideshow in an
;; Org buffer.  PgDn and PgUp move between slides; M-ESC q stops.
;; Settings can be given per file with #+SLIDEBOARD: lines.  See the
;; README for the full documentation.
;;
;; org-slideboard is based on org-show by John Kitchin, from scimax,
;; which itself built on Sacha Chua's presentation code.

;;; Code:
(require 'animate)
(require 'easymenu)
(require 'cl-lib)
(require 'org)
(require 'ob-core)
(require 'org-element)
(require 'org-macro)
(require 'face-remap)
(require 'subr-x)
(require 'seq)

;;* Variables

(defgroup org-slideboard nil
  "Present Org files as slides."
  :group 'org
  :prefix "org-slideboard-"
  :link '(url-link "https://github.com/vikasrawal/org-slideboard"))

(defvar org-slideboard-presentation-file nil
  "File containing the presentation.")

(defcustom org-slideboard-slide-tag "slide"
  "Tag that marks slides."
  :type 'string
  :group 'org-slideboard)

(defcustom org-slideboard-latex-scale 4.0
  "Scale at which LaTeX previews are rendered during the show.
This sets the resolution only: the equations are then displayed at
the size of the text, see `org-slideboard-latex-size'.  A high value keeps
them sharp when the text is large."
  :type 'number
  :group 'org-slideboard)

(defcustom org-slideboard-latex-size 0.8
  "Size of LaTeX equations relative to the text on the slides.
At 1.0, the LaTeX font is as large as the text font.  Equations grow
and shrink with the text of the slide."
  :type 'number
  :group 'org-slideboard)

(defcustom org-slideboard-latex-preview-drop-regexp
  "^[ \t]*\\\\\\(?:setbeamer\\|use[a-z]*theme\\|AtBegin\\(?:Section\\|Subsection\\|Part\\|Lecture\\)\\|beamertemplate\\|logo\\|titlegraphic\\|institute\\).*"
  "Lines of the LaTeX preamble left out when previewing equations.
Org previews equations with the article class, but it adds the
#+LATEX_HEADER lines of the file, which in a beamer presentation use
commands such as \\setbeamersize that article does not know.  LaTeX
then prints their arguments, e.g. \"description width=0.1cm\", in
every equation image.  Set to nil to keep all lines."
  :type '(choice (const :tag "Keep all lines" nil) regexp)
  :group 'org-slideboard)

(defvar org-slideboard--latex-point-pixels nil
  "Pixels per LaTeX point in preview images, as (KEY . PIXELS).
KEY is (PROCESS SCALE PREAMBLE-HASH), see `org-slideboard--latex-point'.")

(defvar-local org-slideboard--latex-point nil
  "Pixels per LaTeX point in the preview images of this buffer.")

(defcustom org-slideboard-center-display-math nil
  "If non-nil, center display equations horizontally, as LaTeX does.
By default they are left aligned, like the text.
Display equations are \\=\\[...\\], $$...$$ and LaTeX environments
on lines of their own.  Inline math is not moved."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-text-scale 2
  "Text scale of the frames of all slides, in steps of `text-scale-mode'.
The frames are the windows of a slide below its title: its body, the
text before its beamer columns, the columns, and code and results.
Nothing is shrunk to fit.  \\[org-slideboard-increase-text-size] and
\\[org-slideboard-decrease-text-size] change the size of all frames of
all slides; \\[org-slideboard-increase-frame-text-size] and
\\[org-slideboard-decrease-frame-text-size] (or Emacs's own zoom keys)
change the selected frame only.  Slide titles have their own size,
`org-slideboard-title-text-scale', and title and section pages
`org-slideboard-page-text-scale'."
  :type 'integer
  :group 'org-slideboard)

(defcustom org-slideboard-title-text-scale 2
  "Text scale of the slide titles, the heading strip at the top of a slide.
The size keys do not change it."
  :type 'integer
  :group 'org-slideboard)

(defcustom org-slideboard-zoom-resizes-frame t
  "If non-nil, Emacs's zoom keys resize a frame of a slide for the show.
Then \\[text-scale-adjust] and the other zoom keys in a frame work like
\\[org-slideboard-increase-frame-text-size]: the frame keeps its size
when its slide is shown again.  If nil, they are plain Emacs zoom, and
the size is lost when the slide is shown again."
  :type 'boolean
  :group 'org-slideboard)

(defvar org-slideboard--frame-offsets '()
  "Size changes of single frames during the show, as (MARKER . STEPS).
MARKER is at the start of the frame's text in the presentation buffer,
so a frame keeps its size when its slide is shown again.")

(defvar-local org-slideboard--frame-key nil
  "Start of this frame's text in the presentation buffer, or nil.
Set in the indirect buffers that show the frames of a slide.")

(defvar org-slideboard--start-text-scale nil
  "The value of `org-slideboard-text-scale' when the show started.")

(defvar org-slideboard--frame-shares '()
  "Frame sizes changed by dragging during the show, as ((TYPE . MARKER) . SHARE).
TYPE is col for a beamer column (or the code or results of a slide),
or src for the code or results inside a column.  MARKER is at the
start of the frame's text in the presentation buffer, and SHARE its
part of the width or height it shares with its neighbours.")

(defvar org-slideboard--saved-divider-width nil
  "The frame's `right-divider-width' before the show.")

(defvar org-slideboard--resize-timer nil
  "Timer that shows the slide again after its frames were resized.")

(defvar org-slideboard--scaling nil
  "Non-nil while org-slideboard itself changes a text scale.")

(defcustom org-slideboard-image-width-fraction 0.8
  "Images are scaled to at most this fraction of the window width."
  :type 'number
  :group 'org-slideboard)

(defcustom org-slideboard-image-height-fraction 0.8
  "Images are scaled to at most this fraction of the window height."
  :type 'number
  :group 'org-slideboard)

(defcustom org-slideboard-hide-clutter t
  "If non-nil, hide beamer and babel clutter during the show.
That is drawers, keyword lines, source blocks shown only as results
and stray LaTeX lines."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-beautify-modes '(org-modern-mode variable-pitch-mode)
  "Minor modes to turn on in the slide buffers during the show.
The default gives styled headings and bullets (org-modern) and
proportional text (`variable-pitch-mode').
They are turned off again when the show stops, unless they were
already on.  Modes that are not installed are skipped.  Set to nil
to show plain org."
  :type '(repeat symbol)
  :group 'org-slideboard)

(defface org-slideboard-bullet
  '((t :inherit org-level-1 :weight bold :height 1.3))
  "Face for list bullets during the show, see `org-slideboard-list-bullets'.
Change :height to make the bullets bigger or smaller."
  :group 'org-slideboard)

(defface org-slideboard-divider
  '((((background dark)) :background "gray35" :height 0.4 :box nil)
    (t :background "gray75" :height 0.4 :box nil))
  "Face of the line between code and results shown one above the other.
The line is the mode line of the upper window in this face; its
:height sets the thickness and its :background the colour."
  :group 'org-slideboard)

(defcustom org-slideboard-divider-width 6
  "Width in pixels of the line between frames side by side during the show.
It is Emacs's window divider, which can be dragged with the mouse to
change the widths of the frames; see `org-slideboard--frame-shares'."
  :type 'natnum
  :group 'org-slideboard)

(defcustom org-slideboard-list-bullets '("●" "○" "■" "□")
  "Bullets for unordered list items during the show, by nesting depth.
The first is used for top-level items, the second for sub-items, and
so on, starting again from the first for deeper lists.  They are shown
in face `org-slideboard-bullet'.  Numbered items keep their numbers.  Set to
nil to keep the bullets as they are (or as org-modern draws them)."
  :type '(choice (const :tag "Keep the bullets" nil) (repeat string))
  :group 'org-slideboard)

(defcustom org-slideboard-list-indent 4
  "Indentation per level of list nesting during the show.
In spaces of the text font, so it scales with the text."
  :type 'natnum
  :group 'org-slideboard)

(defcustom org-slideboard-hanging-indent t
  "If non-nil, lay out lists during the show.
Sub-items are indented by `org-slideboard-list-indent' per level, and
wrapped lines of an item are aligned under its text."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-disable-modes '(org-indent-mode display-line-numbers-mode)
  "Minor modes to turn off in the slide buffers during the show.
They are turned on again when the show stops.  `org-indent-mode'
adds heading-level indentation and its own wrap prefixes, which spoil
the list layout, and line numbers do not belong on slides."
  :type '(repeat symbol)
  :group 'org-slideboard)

(defcustom org-slideboard-hide-emphasis-markers t
  "If non-nil, hide the *, /, = etc. emphasis markers during the show."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-hide-macro-markers t
  "If non-nil, hide the {{{ and }}} around macros during the show.
This turns on `org-hide-macro-markers' in the slide buffers.  It
matters for macros that are not expanded, see
`org-slideboard-expand-macros'."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-align-tables t
  "If non-nil, align Org tables to what is displayed on the slides.
Org aligns a table by the characters in the file, but on a slide a
cell can show an expanded macro, an equation image or proportional
text, so the columns would not line up.  The padding is done with
overlays, so the file is not changed."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-src-display 'exports
  "How source blocks with results are shown on the slides.
- `exports': follow each block's :exports header: code shows the
  code, results the results, both the code and the results
  together, and none nothing.
- `results': show only the results of every block.
- `both': show the code and the results of every block together.

It can be set for one file with #+SLIDEBOARD: src:both, and for one
slide (or a section of slides) with the property SLIDEBOARD_SRC.  With
both, the first such block of a slide is shown in two windows, by
default the results above the code, see `org-slideboard-src-split',
`org-slideboard-execute-src-block' and
`org-slideboard-src-repl-functions'."
  :type '(choice (const :tag "Follow :exports" exports)
                 (const :tag "Results only" results)
                 (const :tag "Code and results" both))
  :group 'org-slideboard)

(defcustom org-slideboard-src-code-width 0.5
  "Share of the space used for the code when code and results are shown.
It is a fraction of the width when they are side by side, and of the
height when the code is above the results, see `org-slideboard-src-split'."
  :type 'number
  :group 'org-slideboard)

(defcustom org-slideboard-src-split 'bt
  "Where the code and the results go when both are shown.
The value names where the code goes, then the results:

  lr  code on the left, results on the right
  rl  code on the right, results on the left
  tb  code at the top, results at the bottom
  bt  code at the bottom, results at the top (the default)

as with rankdir in Graphviz.  It can be set for one file with
#+SLIDEBOARD: src-split:tb, and for one slide or beamer column (or a
section) with the property SLIDEBOARD_SRC_SPLIT.  See
`org-slideboard-src-display'."
  :type '(choice (const :tag "Code left, results right" lr)
                 (const :tag "Code right, results left" rl)
                 (const :tag "Code at the top, results at the bottom" tb)
                 (const :tag "Code at the bottom, results at the top" bt))
  :group 'org-slideboard)

(defcustom org-slideboard-src-repl-functions
  '(("R" . org-slideboard--start-R)
    ("python" . org-slideboard--start-python))
  "Functions that start a REPL for editing a block during the show.
Each element is (LANGUAGE . FUNCTION).  FUNCTION is called with no
arguments and returns the REPL buffer.  When a source block is opened
for editing (\\[org-edit-special]) during the show, the editing buffer
is shown next to the REPL, where its code can be evaluated.  Blocks
with a :session header use that session instead, in any language."
  :type '(alist :key-type string :value-type function)
  :group 'org-slideboard)

(defvar org-slideboard--split-direction nil
  "Direction of the code and results split of the slide being shown.")

(defvar org-slideboard--slide-src nil
  "The SLIDEBOARD_SRC setting of the slide being shown, a symbol or nil.")

(defvar-local org-slideboard--table-overlays nil
  "Overlays made by `org-slideboard--align-tables' in this buffer.")

(defcustom org-slideboard-expand-macros t
  "If non-nil, show Org macros on the slides as their expansion.
A macro is expanded with, in this order of preference:

- its #+SLIDEBOARD_MACRO: definition in the file, written like a
  #+MACRO: definition, e.g. \"#+SLIDEBOARD_MACRO: cc $2\";
- its definition in `org-slideboard-macro-templates';
- Org's own expansion: #+MACRO: definitions and the built-in macros
  such as title, author, date and time.  Export snippets for other
  back-ends, such as @@latex:...@@, are left out of the result, and
  the contents of @@slideboard:...@@ snippets are kept.

Macros that expand to nothing are left as they are.  The buffer text
is not changed."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-macro-templates nil
  "Definitions of Org macros for the show, as (NAME . TEMPLATE).
TEMPLATE is a string like the definition in a #+MACRO: line, with
$1, $2... for the arguments, or a function that is called with the
arguments as strings and returns the string to show, which may have
faces.  For example:

  (setq org-slideboard-macro-templates
        \\='((\"cc\" . (lambda (color text)
                     (propertize text \\='face
                                 \\=`(:background ,color))))))

#+SLIDEBOARD_MACRO: lines in the file take precedence.  See
`org-slideboard-expand-macros'."
  :type '(alist :key-type string :value-type (choice string function))
  :group 'org-slideboard)

(defvar org-modern-tag)
(defvar org-modern-list)

(defvar-local org-slideboard--disabled nil
  "Modes turned off by `org-slideboard--beautify' in this buffer.")

(defvar-local org-slideboard--beautified nil
  "Modes turned on by `org-slideboard--beautify' in this buffer.")

(defcustom org-slideboard-title-page t
  "If non-nil, start the show with a title page.
It is made from the #+TITLE, #+SUBTITLE, #+AUTHOR and #+DATE keywords."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-section-pages t
  "If non-nil, show a section page before the first slide of each section.
A section is a heading above the slides, e.g. each level-1 heading
when the slides are level-2 headings (#+OPTIONS: H:2)."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-animate-pages t
  "If non-nil, animate the title and section pages.
Pressing a key skips the rest of the animation."
  :type 'boolean
  :group 'org-slideboard)

(defcustom org-slideboard-page-text-scale 5
  "Text scale for the title and section pages."
  :type 'integer
  :group 'org-slideboard)

(defconst org-slideboard--page-buffer "*org-slideboard-page*"
  "Buffer for the title and section pages.")

(defface org-slideboard-page-title
  '((t :inherit org-document-title :height 1.0 :weight bold))
  "Face for the title on the title page."
  :group 'org-slideboard)

(defface org-slideboard-page-subtitle
  '((t :inherit org-document-info :height 1.0))
  "Face for the subtitle on the title page."
  :group 'org-slideboard)

(defface org-slideboard-page-info
  '((t :inherit org-document-info :height 1.0 :slant italic))
  "Face for the author and date on the title page."
  :group 'org-slideboard)

(defface org-slideboard-page-section
  '((t :inherit org-level-1 :height 1.0 :weight bold))
  "Face for the heading on a section page."
  :group 'org-slideboard)

(defcustom org-slideboard-footline '("%a" "%t" "%n / %N")
  "What the information strip shows on every slide, or nil for no strip.
A list of up to three parts, shown at the left, in the centre and at
the right of the strip.  Each part is a string, in which these are
replaced:

  %t  title (#+TITLE)            %s  subtitle (#+SUBTITLE)
  %a  author (#+AUTHOR)          %d  date (#+DATE)
  %S  section heading above the slide
  %h  heading of the slide
  %n  number of the slide        %N  number of slides
  %%  a %

and other text is shown as it is, or a function of no arguments that
returns the text; it is called in the presentation buffer, at the
heading of the slide.  For example, (\"%a\" \"%S\" \"%n / %N\") or
\=(\"Workshop, Rome\" \"\" \"%d\").  The strip is at the bottom of the
slide or at the top, see `org-slideboard-footline-position', and uses
the face `org-slideboard-footline'.  Title and section pages have no
strip."
  :type '(choice (const :tag "No strip" nil)
                 (list (choice :tag "Left" string function)
                       (choice :tag "Centre" string function)
                       (choice :tag "Right" string function)))
  :group 'org-slideboard)

(defcustom org-slideboard-footline-position 'bottom
  "Where the information strip goes: bottom or top of the slide.
See `org-slideboard-footline'."
  :type '(choice (const :tag "At the bottom" bottom)
                 (const :tag "At the top" top))
  :group 'org-slideboard)

(defface org-slideboard-footline
  '((t :inherit shadow :height 0.9))
  "Face of the information strip, see `org-slideboard-footline'."
  :group 'org-slideboard)

(defconst org-slideboard--footline-buffer "*org-slideboard-footline*"
  "Buffer for the information strip.")

(defvar org-slideboard-current-slide-number 1
  "Holds current slide number.")

(defvar org-slideboard--flyspell nil
  "Whether flyspell mode is enabled at beginning of show.
Used to reset the state after the show.")

(defvar org-slideboard--running nil
  "Flag for if the show is running.")

(defvar org-slideboard-slide-list '()
  "List of slide numbers and markers to each slide.")

(defvar org-slideboard-slide-titles '()
  "List of titles and slide numbers for each slide.")

(defvar org-slideboard--column-buffers '()
  "Indirect buffers created to display beamer columns.")

(defvar org-slideboard--hide-overlays '()
  "Overlays created to hide clutter during the show.")

(defvar org-slideboard--windows '()
  "Windows whose mode-line was hidden for a column layout.")

(defvar org-slideboard-mode)
(declare-function flyspell-mode-on "flyspell")
(declare-function flyspell-mode-off "flyspell")

;;* Functions
(defun org-slideboard--base-buffer ()
  "Return the base buffer of the current buffer."
  (or (buffer-base-buffer) (current-buffer)))

(defun org-slideboard--show-buffer ()
  "Return the buffer of the presentation being shown.
This is where the settings are read, since they may be local to it."
  (or (and org-slideboard-presentation-file
           (find-buffer-visiting org-slideboard-presentation-file))
      (org-slideboard--base-buffer)))

(defun org-slideboard--file ()
  "Return the file of the presentation in the current buffer."
  (buffer-file-name (org-slideboard--base-buffer)))

;;** Clutter hiding

(defun org-slideboard--hide-region (beg end)
  "Make the region BEG END invisible during the show."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'invisible 'org-slideboard)
    (overlay-put ov 'evaporate t)
    (push ov org-slideboard--hide-overlays)))

(defun org-slideboard--hide-clutter (beg end)
  "Hide beamer and babel clutter between BEG and END."
  (when org-slideboard-hide-clutter
    (add-to-invisibility-spec 'org-slideboard)
    (let ((case-fold-search t))
      (save-excursion
        ;; drawers: properties, logbook and any others
        (goto-char beg)
        (while (re-search-forward
                "^[ \t]*:\\([[:alnum:]_-]+\\):[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
                end t)
          (if (string= (upcase (match-string 1)) "END")
              ;; a stray :END: line, not the start of a drawer
              (goto-char (1+ (match-beginning 0)))
            (org-slideboard--hide-region (match-beginning 0) (match-end 0))))
        ;; keyword lines
        (goto-char beg)
        (while (re-search-forward
                "^[ \t]*#\\+\\(?:name\\|results\\|caption\\|attr_[a-z]+\\)\\(?:\\[.*\\]\\)?:.*\n?"
                end t)
          (org-slideboard--hide-region (match-beginning 0) (match-end 0)))
        ;; standalone raw LaTeX lines, e.g. \vspace{-0.5cm}, but not
        ;; lines of an equation
        (goto-char beg)
        (while (re-search-forward "^[ \t]*\\(\\\\[a-zA-Z]+\\).*\n?" end t)
          (unless (save-excursion
                    (save-match-data
                      (org-slideboard--math-p
                       (org-element-context
                        (progn (goto-char (match-beginning 1))
                               (org-element-at-point))))))
            (org-slideboard--hide-region (match-beginning 0) (match-end 0))))
        ;; src blocks that are not exported as code
        (goto-char beg)
        (while (re-search-forward "^[ \t]*#\\+begin_src\\b" end t)
          (let* ((block-beg (line-beginning-position))
                 (info (save-excursion
                         (goto-char block-beg)
                         (ignore-errors (org-babel-get-src-block-info 'no-eval))))
                 (block-end (save-excursion
                              (when (re-search-forward "^[ \t]*#\\+end_src.*\n?" end t)
                                (match-end 0)))))
            (when (and block-end
                       (or (memq (org-slideboard--src-mode info) '(results none))
                           (equal (car info) "slideboard-elisp")))
              (org-slideboard--hide-region block-beg block-end))
            (when block-end (goto-char block-end))))
        ;; blank lines left at the top once the clutter is hidden
        (goto-char beg)
        (while (and (< (point) end)
                    (or (invisible-p (point))
                        (memq (char-after) '(?\s ?\t ?\n))))
          (forward-char 1))
        (when (> (line-beginning-position) beg)
          (org-slideboard--hide-region beg (line-beginning-position)))))))

;;** Beamer columns

(defun org-slideboard--slide-columns ()
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

(defvar org-slideboard--image-times (make-hash-table :test #'equal)
  "Modification times of the image files shown, by file name.")

(defun org-slideboard--fresh-image-file (file)
  "Make sure FILE is shown as it is now, not as Emacs cached it.
Emacs caches images by file name, so a plot rewritten by a code
block would still show the old picture.  When FILE changed since it
was last shown, it is removed from the image cache."
  (let ((time (file-attribute-modification-time (file-attributes file)))
        (old (gethash file org-slideboard--image-times)))
    (when (and old (not (equal old time)))
      (clear-image-cache file))
    (puthash file time org-slideboard--image-times)))

(defun org-slideboard--show-images (&optional win)
  "Display image links in the accessible part of the current buffer.
Images are scaled down to fit in window WIN (default: the selected
window), using `org-slideboard-image-width-fraction' and
`org-slideboard-image-height-fraction'.  The images are drawn with our own
high-priority overlays, so they do not depend on (and override) the
Org inline image settings.  Image files that changed since
they were last shown are read again."
  (let* ((win (or win (selected-window)))
         (max-w (floor (* org-slideboard-image-width-fraction (window-body-width win t))))
         (max-h (floor (* org-slideboard-image-height-fraction (window-body-height win t)))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\(?:file:\\)?\\([^]\n]+\\)\\]\\]" nil t)
        (let ((file (expand-file-name (match-string-no-properties 1))))
          (when (and (string-match-p (image-file-name-regexp) file)
                     (file-exists-p file))
            (org-slideboard--fresh-image-file file)
            (let ((ov (make-overlay (match-beginning 0) (match-end 0) nil t nil)))
              (overlay-put ov 'display (create-image file nil nil
                                                     :max-width max-w
                                                     :max-height max-h))
              (overlay-put ov 'priority 1000)
              ;; the link's underline would be drawn across the image
              (overlay-put ov 'face '(:underline nil :inherit default))
              ;; Org hides the link brackets with an `invisible' text
              ;; property, and a display spec on invisible text is not
              ;; shown.  A non-nil overlay value that is not in the
              ;; invisibility spec takes precedence and keeps it visible.
              (overlay-put ov 'invisible 'org-slideboard-image)
              (push ov org-slideboard--hide-overlays))))))))

(defun org-slideboard--reflow ()
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
                  (push ov org-slideboard--hide-overlays))))))))))

(defun org-slideboard--list-depth (item)
  "Return the nesting depth of list ITEM, 0 for a top-level item."
  (let ((depth -1)
        (p (org-element-property :parent item)))
    (while p
      (when (eq (org-element-type p) 'plain-list)
        (setq depth (1+ depth)))
      (setq p (org-element-property :parent p)))
    (max depth 0)))

(defun org-slideboard--style-lists ()
  "Lay out the plain lists in the accessible region for the show.
Unordered bullets are replaced by `org-slideboard-list-bullets' according
to their depth, and with `org-slideboard-hanging-indent', items are
indented by `org-slideboard-list-indent' spaces per level and their
wrapped lines are aligned under the item text.  Everything is done
with overlays, so the buffer text is not changed."
  (when (or org-slideboard-list-bullets org-slideboard-hanging-indent)
    (let ((bg (face-background 'default nil t)))
      (org-element-map (org-element-parse-buffer) 'item
        (lambda (item)
          (save-excursion
            (let* ((depth (org-slideboard--list-depth item))
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
                   (bullets org-slideboard-list-bullets)
                   (new-bullet
                    (when (and bullets (not ordered))
                      (let ((b (nth (mod depth (length bullets)) bullets)))
                        ;; also accept the old (CHAR . STRING) format
                        (when (consp b) (setq b (cdr b)))
                        (if (get-text-property 0 'face b)
                            b
                          (propertize b 'face 'org-slideboard-bullet)))))
                   (bullet (or new-bullet
                               (buffer-substring bullet-beg bullet-end)))
                   (indent (if org-slideboard-hanging-indent
                               (make-string (* depth org-slideboard-list-indent) ?\s)
                             (buffer-substring-no-properties begin bullet-beg)))
                   ov)
              ;; indentation (a zero-width overlay when there is none)
              (setq ov (make-overlay begin bullet-beg nil t nil))
              (overlay-put ov (if (= begin bullet-beg) 'before-string 'display)
                           indent)
              (push ov org-slideboard--hide-overlays)
              ;; bullet
              (when new-bullet
                (setq ov (make-overlay bullet-beg bullet-end nil t nil))
                (overlay-put ov 'display new-bullet)
                (push ov org-slideboard--hide-overlays))
              ;; wrapped lines start under the item text: the prefix is the
              ;; indentation, an invisible copy of the bullet (same width)
              ;; and the space after it
              (when org-slideboard-hanging-indent
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
                  (push ov org-slideboard--hide-overlays))))))))))

(defun org-slideboard--org-images ()
  "Redisplay Org inline images in the current buffer the normal way."
  (if (fboundp 'org-link-preview-region)
      (org-link-preview-region nil t (point-min) (point-max))
    (with-no-warnings
      (org-display-inline-images nil t (point-min) (point-max)))))

(defun org-slideboard--frame-offset (pos)
  "Return the size change, in steps, of the frame whose text starts at POS."
  (or (cdr (cl-find-if (lambda (e) (eql (marker-position (car e)) pos))
                       org-slideboard--frame-offsets))
      0))

(defun org-slideboard--set-frame-offset (pos steps)
  "Remember that the frame whose text starts at POS is STEPS larger."
  (let ((entry (cl-find-if (lambda (e) (eql (marker-position (car e)) pos))
                           org-slideboard--frame-offsets)))
    (if entry
        (setcdr entry steps)
      ;; in the presentation buffer: the frame's own buffer goes away
      ;; with the slide
      (push (cons (set-marker (make-marker) pos
                              (or (buffer-base-buffer) (current-buffer)))
                  steps)
            org-slideboard--frame-offsets))))

(defun org-slideboard--set-text-scale (wins)
  "Give the frames in WINS their text size.
That is `org-slideboard-text-scale' plus the frame's own change, see
`org-slideboard-increase-frame-text-size'.  Equations and tables are
laid out again for that size."
  (let ((org-slideboard--scaling t))
    (dolist (w wins)
      (with-current-buffer (window-buffer w)
        (text-scale-set (+ (or org-slideboard-text-scale 0)
                           (if org-slideboard--frame-key
                               (org-slideboard--frame-offset org-slideboard--frame-key)
                             0)))
        (org-slideboard--scale-latex w)
        (org-slideboard--align-tables w)))))

(defun org-slideboard--math-p (el)
  "Return non-nil if Org element EL is an equation.
That is a LaTeX environment or a math fragment ($...$, \\(...\\),
\\=\\[...\\] or $$...$$), not a LaTeX command such as \\vspace{...}."
  (pcase (org-element-type el)
    ('latex-environment t)
    ('latex-fragment
     (string-match-p "\\`\\(?:\\$\\|\\\\[[(]\\)"
                     (org-element-property :value el)))))

(defun org-slideboard--latex-overlays ()
  "Return the LaTeX preview overlays in the accessible part of the buffer."
  (cl-remove-if-not
   (lambda (o) (eq (overlay-get o 'org-overlay-type) 'org-latex-overlay))
   (overlays-in (point-min) (point-max))))

(defun org-slideboard--latex-preview-header ()
  "Return the preamble for previewing equations in the current buffer.
It is the preamble Org would use, without the lines matching
`org-slideboard-latex-preview-drop-regexp'.  Return nil when nothing needs
to be left out, or when the process in
`org-preview-latex-default-process' has its own preamble."
  (when (and org-slideboard-latex-preview-drop-regexp
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
                         (concat org-slideboard-latex-preview-drop-regexp "\n?")
                         "" full))))
      (unless (equal header full) header))))

(defun org-slideboard--preview-latex ()
  "Preview LaTeX math in the accessible part of the current buffer.
The images are rendered at `org-slideboard-latex-scale', centered if they
are display equations, and sized to the text by
`org-slideboard--scale-latex'."
  (when (save-excursion
          (goto-char (point-min))
          (re-search-forward "\\$\\|\\\\(\\|\\\\\\[\\|\\\\begin{" nil t))
    (let* ((header (org-slideboard--latex-preview-header))
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
                                  :scale org-slideboard-latex-scale)
                       ;; Org's image cache ignores the #+LATEX_HEADER
                       ;; lines, so make images with another preamble
                       ;; get other file names
                       :org-slideboard-header (and header (sha1 header)))))
      (ignore-errors
        (if (fboundp 'org-latex-preview)
            (org-latex-preview '(16))
          (with-no-warnings (org-preview-latex-fragment '(4)))))
      (setq org-slideboard--latex-point
            (org-slideboard--measure-latex-point
             (list proc org-slideboard-latex-scale (and header (sha1 header))))))
    ;; an environment's overlay starts at its #+NAME: etc. lines, which
    ;; may be hidden as clutter, and a hidden start hides the image
    (dolist (ov (org-slideboard--latex-overlays))
      (save-excursion
        (goto-char (overlay-start ov))
        (while (looking-at "[ \t]*#\\+.*\n") (goto-char (match-end 0)))
        (when (< (overlay-start ov) (point) (overlay-end ov))
          (move-overlay ov (point) (overlay-end ov)))))
    (org-slideboard--center-latex)
    (org-slideboard--scale-latex)))

(defun org-slideboard--measure-latex-point (key)
  "Return the pixels per LaTeX point in preview images made now.
It is measured once for each KEY by previewing a 10pt square with the
current preview settings, and cached in `org-slideboard--latex-point-pixels'."
  (or (cdr (assoc key org-slideboard--latex-point-pixels))
      (let* ((proc org-preview-latex-default-process)
             (type (or (plist-get (cdr (assq proc org-preview-latex-process-alist))
                                  :image-output-type)
                       "png"))
             (file (make-temp-file "org-slideboard-ltx" nil (concat "." type)))
             (height (ignore-errors
                       (org-create-formula-image "$\\rule{10pt}{10pt}$" file
                                                 org-format-latex-options
                                                 (current-buffer) proc)
                       (cdr (image-size (create-image file nil nil :scale 1) t)))))
        (ignore-errors (delete-file file))
        (when (and (numberp height) (> height 0))
          (push (cons key (/ height 10.0)) org-slideboard--latex-point-pixels)
          (/ height 10.0)))))

(defun org-slideboard--latex-display-scale ()
  "Return the image scale that sizes LaTeX previews to the current text.
The 10pt LaTeX font is matched to the text font: 12pt, the LaTeX line
spacing, is shown as high as a line of text.  This follows the text
scale and `variable-pitch-mode'.  `org-slideboard-latex-size' scales the
result.  If the preview size could not be measured, fall back to
`org-format-latex-options' :scale at text scale 0."
  (* org-slideboard-latex-size
     (if org-slideboard--latex-point
         (/ (default-font-height) 12.0 org-slideboard--latex-point)
       (* (/ (float (or (plist-get org-format-latex-options :scale) 1.0))
             org-slideboard-latex-scale)
          (expt text-scale-mode-step text-scale-mode-amount)))))

(defun org-slideboard--center-string (image)
  "Return a string that moves IMAGE to the center of the window."
  (propertize " " 'display `(space :align-to (- center (0.5 . ,image)))))

(defun org-slideboard--scale-latex (&optional win)
  "Size the LaTeX previews in the accessible region to the current text.
See `org-slideboard--latex-display-scale'.  Images are also kept within the
width of window WIN (default: the selected window), since LaTeX
environments with equation numbers are as wide as a LaTeX page."
  (let ((scale (org-slideboard--latex-display-scale))
        (max-w (window-body-width (or win (selected-window)) t)))
    (dolist (ov (org-slideboard--latex-overlays))
      (let ((spec (overlay-get ov 'display))
            (center (overlay-get ov 'org-slideboard-center)))
        (when (eq (car-safe spec) 'image)
          (let ((props (copy-sequence (cdr spec))))
            (setq props (plist-put props :scale scale))
            (setq spec (cons 'image (plist-put props :max-width max-w))))
          (overlay-put ov 'display spec)
          (when (and center (overlay-buffer center))
            (overlay-put center 'before-string (org-slideboard--center-string spec))))))))

(defun org-slideboard--display-math-p (ov)
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

(defun org-slideboard--center-latex ()
  "Center the display equations in the accessible region.
Each gets an overlay whose `before-string' aligns the image to the
center of the window; `org-slideboard--scale-latex' keeps it up to date
when the image is resized."
  (when org-slideboard-center-display-math
    (dolist (ov (org-slideboard--latex-overlays))
      (when (and (eq (car-safe (overlay-get ov 'display)) 'image)
                 (org-slideboard--display-math-p ov))
        (let ((center (make-overlay (overlay-start ov) (overlay-end ov) nil t nil)))
          (overlay-put center 'before-string
                       (org-slideboard--center-string (overlay-get ov 'display)))
          (overlay-put ov 'org-slideboard-center center)
          (push center org-slideboard--hide-overlays))))))

(defun org-slideboard--hide-drawers ()
  "Fold drawers in the accessible part of the current buffer.
With `org-slideboard-hide-clutter', the drawers are already hidden, and
folding them too would show Org's ellipsis in their place."
  (unless org-slideboard-hide-clutter
    (if (fboundp 'org-fold-hide-drawer-all)
        (org-fold-hide-drawer-all)
      (org-cycle-hide-drawers 'all))))

(defun org-slideboard--hide-mode-line (win)
  "Hide the mode line of WIN for the column layout."
  (set-window-parameter win 'mode-line-format 'none)
  (push win org-slideboard--windows))

(defun org-slideboard--divider (win)
  "Draw a thin line along the bottom of WIN, in `org-slideboard-divider'.
WIN's hidden mode line is shown again, as an empty line in that face."
  (set-window-parameter win 'mode-line-format " ")
  (with-current-buffer (window-buffer win)
    (dolist (face '(mode-line mode-line-active mode-line-inactive))
      (push (list face 'org-slideboard-divider) face-remapping-alist))
    (force-mode-line-update)))

(defun org-slideboard--setup-column-window (win base col i)
  "Show column COL of buffer BASE in window WIN.
I is the column index, used to name the indirect buffer."
  (let ((buf (make-indirect-buffer
              base (generate-new-buffer-name (format "*org-slideboard-col-%d*" i)) t)))
    (push buf org-slideboard--column-buffers)
    (set-window-buffer win buf)
    (org-slideboard--hide-mode-line win)
    (with-selected-window win
      ;; the clone shares the base buffer's face remapping list, so text
      ;; scaling here would undo the title's text scale
      (setq-local face-remapping-alist nil)
      (setq-local text-scale-mode-remapping nil)
      (setq-local text-scale-mode-amount 0)
      (widen)
      (if (fboundp 'org-fold-show-all) (org-fold-show-all) (outline-show-all))
      (narrow-to-region (nth 2 col) (nth 3 col))
      (setq org-slideboard--frame-key (nth 2 col))
      ;; the clone copied the base buffer's mode variables, but the face
      ;; remapping was reset above, so apply the beautify modes afresh
      (setq org-slideboard--beautified nil
            org-slideboard--disabled nil
            org-slideboard--table-overlays nil)
      (kill-local-variable 'buffer-face-mode)
      (org-slideboard--beautify)
      (goto-char (point-min))
      (visual-line-mode 1)
      (org-slideboard--hide-clutter (point-min) (point-max))
      (org-slideboard--hide-drawers)
      (org-slideboard--reflow)
      (org-slideboard--expand-macros)
      (org-slideboard--style-lists)
      (org-slideboard--preview-latex)
      (org-slideboard--show-images win)
      (org-slideboard-keys-mode 1)
      (when (eq (nth 4 col) 'code)
        (org-slideboard-code-mode 1))
      (set-window-start win (point-min)))))

(defun org-slideboard--visible-text-p (beg end)
  "Return non-nil if BEG to END has text that is shown on a slide.
Blank lines, keyword lines and stray LaTeX commands, which are hidden
as clutter, do not count."
  (save-excursion
    (goto-char beg)
    (let ((found nil))
      (while (and (not found) (< (point) end))
        (unless (looking-at-p "[ \t]*\\(?:$\\|#\\+\\|\\\\[a-zA-Z]+\\)")
          (setq found t))
        (forward-line 1))
      found)))

(defun org-slideboard--footline-fields ()
  "Return the values for `org-slideboard-footline', as (CHAR . STRING).
The current buffer is the presentation buffer, at the slide heading."
  (let* ((kw (org-with-wide-buffer
              (org-collect-keywords '("TITLE" "SUBTITLE" "AUTHOR" "DATE"))))
         (get (lambda (key sep)
                (mapconcat #'identity
                           (org-slideboard--keyword-lines
                            (mapconcat #'identity (cdr (assoc key kw)) " "))
                           sep)))
         (section (org-with-wide-buffer
                   (let ((up (car (last (org-slideboard--section-ancestors)))))
                     (if up
                         (save-excursion (goto-char up) (org-slideboard--heading-title))
                       "")))))
    (list (cons ?t (funcall get "TITLE" " "))
          (cons ?s (funcall get "SUBTITLE" " "))
          (cons ?a (funcall get "AUTHOR" ", "))
          (cons ?d (funcall get "DATE" " "))
          (cons ?S section)
          (cons ?h (save-excursion (goto-char (point-min))
                                   (org-slideboard--heading-title)))
          (cons ?n (number-to-string org-slideboard-current-slide-number))
          (cons ?N (number-to-string (length org-slideboard-slide-list))))))

(defun org-slideboard--format-footline (part fields)
  "Return the text of PART of the information strip, using FIELDS.
PART is a string with %-escapes or a function, see
`org-slideboard-footline'; FIELDS is from
`org-slideboard--footline-fields'."
  (cond
   ((functionp part) (format "%s" (or (ignore-errors (funcall part)) "")))
   ((stringp part)
    (replace-regexp-in-string
     "%\\(.\\)"
     (lambda (m)
       (let ((c (aref (match-string 1 m) 0)))
         (cond ((eq c ?%) "%")
               ((assq c fields) (cdr (assq c fields)))
               (t m))))
     part t t))
   (t "")))

(defun org-slideboard--show-footline (win)
  "Split an information strip off window WIN, if there is one to show.
Its place and content are set by `org-slideboard-footline-position'
and `org-slideboard-footline'.  WIN keeps the rest of its space."
  (when org-slideboard-footline
    (let* ((fields (org-slideboard--footline-fields))
           (parts (mapcar (lambda (p) (org-slideboard--format-footline p fields))
                          org-slideboard-footline))
           (top (eq org-slideboard-footline-position 'top))
           ;; one line: Emacs would otherwise keep windows 4 lines high
           (window-min-height 1)
           (strip (split-window win (if top 2 -2) (if top 'above 'below)))
           (buf (get-buffer-create org-slideboard--footline-buffer)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq-local cursor-type nil
                      truncate-lines t
                      buffer-read-only t)
          (org-slideboard-keys-mode 1)
          (let ((left (propertize (or (nth 0 parts) "") 'face 'org-slideboard-footline))
                (centre (propertize (or (nth 1 parts) "") 'face 'org-slideboard-footline))
                (right (propertize (or (nth 2 parts) "") 'face 'org-slideboard-footline)))
            (insert " " left)
            (insert (propertize " " 'org-slideboard-spacer 'centre))
            (insert centre)
            (insert (propertize " " 'org-slideboard-spacer 'right))
            (insert right " "))))
      (set-window-buffer strip buf)
      (set-window-dedicated-p strip t)
      (set-window-parameter strip 'no-other-window t)
      (org-slideboard--hide-mode-line strip)
      (let ((window-min-height 1)
            (window-resize-pixelwise t))
        (fit-window-to-buffer strip nil 1))
      (org-slideboard--align-footline strip)
      strip)))

(defun org-slideboard--align-footline (win)
  "Centre the middle part of the information strip in WIN, right-align the last.
The widths are measured as displayed, so this works with any font."
  (with-current-buffer (window-buffer win)
    (let* ((inhibit-read-only t)
           (width (window-body-width win t))
           (spacers '()))
      (save-excursion
        (goto-char (point-min))
        (let (m)
          (while (setq m (text-property-search-forward 'org-slideboard-spacer nil nil))
            (push (cons (prop-match-value m) (prop-match-beginning m)) spacers))))
      (let* ((c (cdr (assq 'centre spacers)))
             (r (cdr (assq 'right spacers)))
             (px (lambda (from to) (car (window-text-pixel-size win from to))))
             (left-w (funcall px (point-min) c))
             (centre-w (funcall px (1+ c) r))
             (right-w (funcall px (1+ r) (point-max)))
             (centre-x (max (+ left-w 8) (/ (- width centre-w) 2)))
             (right-x (max (+ centre-x centre-w 8) (- width right-w))))
        (put-text-property c (1+ c) 'display `(space :align-to (,centre-x)))
        (put-text-property r (1+ r) 'display `(space :align-to (,right-x)))))))

(defun org-slideboard--display-columns (cols &optional direction)
  "Lay out the current slide: its title, then its frames.
The title strip at the top shows the heading only, at
`org-slideboard-title-text-scale'.  Below it, text before the first of
COLS gets a full-width frame, and then each of COLS a frame, side by
side, or with DIRECTION below one above the other (for code above its
results).  COLS are beamer columns, code and results, or the body of
the slide; see `org-slideboard--slide-columns'.  The current buffer
must be the base buffer, narrowed to the slide."
  (let* ((base (current-buffer))
         (title-win (selected-window))
         (total (apply #'+ (mapcar #'car cols)))
         ;; the heading with its drawers and planning lines
         (meta-end (save-excursion
                     (goto-char (point-min))
                     (org-end-of-meta-data t)
                     (min (point) (point-max))))
         (title-end (save-excursion
                      (goto-char meta-end)
                      (skip-chars-backward " \t\n")
                      (max (line-end-position) (point-min))))
         ;; the columns may not be in buffer order, e.g. results left
         ;; of the code
         (first-col (apply #'min (mapcar #'cadr cols)))
         (intro (and (< meta-end first-col)
                     (org-slideboard--visible-text-p meta-end first-col)
                     (list 1.0 meta-end meta-end first-col)))
         ;; strips of one or two lines: Emacs would keep windows 4 high
         (window-min-height 1)
         (strip nil))
    ;; a window kept from the previous slide keeps its parameters
    (dolist (w (window-list))
      (set-window-parameter w 'org-slideboard-share nil))
    ;; the information strip first, so the slide gets the rest
    (setq strip (org-slideboard--show-footline title-win))
    ;; the title strip
    (narrow-to-region (point-min) title-end)
    (let ((org-slideboard--scaling t))
      (text-scale-set (or org-slideboard-title-text-scale 0)))
    (org-slideboard--hide-clutter (point-min) (point-max))
    (org-slideboard--hide-drawers)
    (org-slideboard--expand-macros)
    (org-slideboard--preview-latex)
    (org-slideboard--hide-mode-line title-win)
    (goto-char (point-min))
    ;; size the title strip and the text before the columns first, so
    ;; the column heights are final before images are scaled
    (let* ((win (split-window title-win nil 'below))
           (col-wins '())
           (i 1))
      (fit-window-to-buffer title-win (floor (window-total-height (frame-root-window)) 3) 1)
      (when intro
        (let ((rest (split-window win nil 'below)))
          (org-slideboard--setup-column-window win base intro 0)
          (org-slideboard--set-text-scale (list win))
          (fit-window-to-buffer win (floor (window-total-height (frame-root-window)) 3) 1)
          (push win col-wins)
          (setq win rest)))
      ;; the frames
      (let* ((below (eq direction 'below))
             (space (if below (window-total-height win) (window-total-width win)))
             (shares (org-slideboard--shares 'col (mapcar #'caddr cols)
                                             (mapcar (lambda (c) (/ (car c) total)) cols)))
             (several (cdr cols)))
        (while cols
          (let* ((col (car cols))
                 (share (pop shares))
                 (next (and (cdr cols)
                            (split-window
                             win
                             (max (if below window-min-height window-min-width)
                                  (round (* space share)))
                             (if below 'below 'right))))
                 (wins (org-slideboard--setup-column win base col i)))
            (setq col-wins (append wins col-wins))
            ;; the column's window, or the pair of code and results it
            ;; was divided into
            (when several
              (org-slideboard--mark-share (if (cdr wins) (window-parent win) win)
                                          'col (nth 2 col) share))
            ;; code and results one above the other
            (when (and below next)
              (org-slideboard--divider win))
            (setq win next
                  cols (cdr cols)
                  i (1+ i)))))
      (org-slideboard--set-text-scale col-wins))
    ;; the other windows took space from the strip; give it back
    (when (window-live-p strip)
      (fit-window-to-buffer strip nil 1)
      (org-slideboard--align-footline strip))
    (select-window title-win)
    ;; keep point on the heading: at the end of a hidden drawer below it,
    ;; the strip would scroll to show point and the heading would be lost
    (goto-char (point-min))
    (set-window-start title-win (point-min))))

(defun org-slideboard--teardown-columns ()
  "Remove column windows, indirect buffers and clutter overlays."
  (mapc #'delete-overlay org-slideboard--hide-overlays)
  (setq org-slideboard--hide-overlays '())
  (dolist (win org-slideboard--windows)
    (when (window-live-p win)
      (set-window-parameter win 'mode-line-format nil)))
  (setq org-slideboard--windows '())
  (dolist (buf org-slideboard--column-buffers)
    (when (buffer-live-p buf) (kill-buffer buf)))
  (setq org-slideboard--column-buffers '()))

;;** Per-file settings

;; File-local variables: the simple settings are safe, so Emacs does not
;; ask about them.  The mode lists are not marked safe, since a file
;; could use them to turn on any mode.
(dolist (var '(org-slideboard-hide-clutter org-slideboard-title-page
               org-slideboard-section-pages org-slideboard-animate-pages
               org-slideboard-hanging-indent org-slideboard-hide-emphasis-markers
               org-slideboard-hide-macro-markers org-slideboard-expand-macros
               org-slideboard-align-tables org-slideboard-zoom-resizes-frame
               org-slideboard-center-display-math))
  (put var 'safe-local-variable #'booleanp))
(dolist (var '(org-slideboard-text-scale org-slideboard-title-text-scale
               org-slideboard-page-text-scale org-slideboard-image-width-fraction
               org-slideboard-image-height-fraction org-slideboard-list-indent
               org-slideboard-latex-size org-slideboard-latex-scale
               org-slideboard-src-code-width))
  (put var 'safe-local-variable #'numberp))
(put 'org-slideboard-src-display 'safe-local-variable #'org-slideboard--src-display-p)
(put 'org-slideboard-src-split 'safe-local-variable #'org-slideboard--src-split-p)
(put 'org-slideboard-footline 'safe-local-variable #'org-slideboard--footline-p)
(put 'org-slideboard-footline-position 'safe-local-variable
     #'org-slideboard--footline-position-p)

(defun org-slideboard--footline-p (value)
  "Return non-nil if VALUE is a strip made of strings only.
Parts that are functions can only be set in the configuration."
  (or (null value)
      (and (listp value) (<= (length value) 3) (seq-every-p #'stringp value))))

(defun org-slideboard--footline-position-p (value)
  "Return non-nil if VALUE is a valid `org-slideboard-footline-position'."
  (memq value '(bottom top)))

(defun org-slideboard--src-split-p (value)
  "Return non-nil if VALUE is a valid `org-slideboard-src-split'."
  (memq value '(lr rl tb bt)))

(defun org-slideboard--src-display-p (value)
  "Return non-nil if VALUE is a valid `org-slideboard-src-display'."
  (memq value '(exports results both)))
(put 'org-slideboard-list-bullets 'safe-local-variable #'org-slideboard--string-list-p)
(put 'org-slideboard-slide-tag 'safe-local-variable #'stringp)

(defun org-slideboard--string-list-p (value)
  "Return non-nil if VALUE is a list of strings."
  (and (listp value) (seq-every-p #'stringp value)))

(defun org-slideboard--mode-list-p (value)
  "Return non-nil if VALUE is a list of mode symbols (names ending in -mode)."
  (and (listp value)
       (seq-every-p (lambda (m)
                      (and (symbolp m) (string-suffix-p "-mode" (symbol-name m))))
                    value)))

(defconst org-slideboard--keyword-settings
  '(("modern" :mode org-modern-mode booleanp)
    ("variable-pitch" :mode variable-pitch-mode booleanp)
    ("modes" org-slideboard-beautify-modes org-slideboard--mode-list-p)
    ("disable" org-slideboard-disable-modes org-slideboard--mode-list-p)
    ("emphasis" org-slideboard-hide-emphasis-markers booleanp)
    ("macro-markers" org-slideboard-hide-macro-markers booleanp)
    ("macros" org-slideboard-expand-macros booleanp)
    ("align-tables" org-slideboard-align-tables booleanp)
    ("src" org-slideboard-src-display org-slideboard--src-display-p)
    ("code-width" org-slideboard-src-code-width numberp)
    ("src-split" org-slideboard-src-split org-slideboard--src-split-p)
    ("bullets" org-slideboard-list-bullets org-slideboard--string-list-p)
    ("list-indent" org-slideboard-list-indent natnump)
    ("hanging" org-slideboard-hanging-indent booleanp)
    ("title-page" org-slideboard-title-page booleanp)
    ("section-pages" org-slideboard-section-pages booleanp)
    ("animate" org-slideboard-animate-pages booleanp)
    ("page-scale" org-slideboard-page-text-scale numberp)
    ("text-scale" org-slideboard-text-scale numberp)
    ("title-scale" org-slideboard-title-text-scale numberp)
    ("image-width" org-slideboard-image-width-fraction numberp)
    ("image-height" org-slideboard-image-height-fraction numberp)
    ("clutter" org-slideboard-hide-clutter booleanp)
    ("latex-size" org-slideboard-latex-size numberp)
    ("latex-scale" org-slideboard-latex-scale numberp)
    ("center-math" org-slideboard-center-display-math booleanp)
    ("footline" org-slideboard-footline org-slideboard--footline-p)
    ("footline-position" org-slideboard-footline-position
     org-slideboard--footline-position-p))
  "Keys of the #+SLIDEBOARD: keyword.
Each entry is (KEY VARIABLE PREDICATE), or (KEY :mode MODE PREDICATE)
for a key that adds MODE to or removes it from
`org-slideboard-beautify-modes'.")

(defvar-local org-slideboard--saved-settings nil
  "Settings changed by #+SLIDEBOARD:, as (VARIABLE LOCALP . OLD-VALUE).")

(defun org-slideboard--parse-keyword (string)
  "Parse STRING, the value of #+SLIDEBOARD: lines, into (KEY . VALUE) pairs.
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
           (message "org-slideboard: cannot read the value of %s: in #+SLIDEBOARD:" key)
           (setq pos (length string))))))
    (nreverse pairs)))

(defun org-slideboard--set-setting (var value)
  "Set VAR to VALUE in this buffer, recording its old state for restoring."
  (unless (assq var org-slideboard--saved-settings)
    (push (cons var (cons (local-variable-p var) (symbol-value var)))
          org-slideboard--saved-settings))
  (set (make-local-variable var) value))

(defun org-slideboard--apply-keyword-settings ()
  "Apply the #+SLIDEBOARD: settings of the current buffer, locally.
See `org-slideboard--keyword-settings' for the keys.  Unknown keys and
invalid values are skipped with a message."
  (org-slideboard--restore-keyword-settings)
  (let ((value (mapconcat #'identity
                          (cdr (assoc "SLIDEBOARD" (org-collect-keywords '("SLIDEBOARD"))))
                          " ")))
    (dolist (pair (org-slideboard--parse-keyword value))
      (let* ((key (car pair))
             (val (cdr pair))
             (entry (assoc key org-slideboard--keyword-settings)))
        (cond
         ((null entry)
          (message "org-slideboard: unknown #+SLIDEBOARD: key %s" key))
         ((eq (nth 1 entry) :mode)
          (if (not (funcall (nth 3 entry) val))
              (message "org-slideboard: ignoring %s:%S" key val)
            (let ((mode (nth 2 entry)))
              (org-slideboard--set-setting
               'org-slideboard-beautify-modes
               (if val
                   (append (remq mode org-slideboard-beautify-modes) (list mode))
                 (remq mode org-slideboard-beautify-modes))))))
         ((not (funcall (nth 2 entry) val))
          (message "org-slideboard: ignoring %s:%S" key val))
         (t
          (org-slideboard--set-setting (nth 1 entry) val)))))))

(defun org-slideboard--restore-keyword-settings ()
  "Undo `org-slideboard--apply-keyword-settings' in the current buffer."
  (dolist (saved org-slideboard--saved-settings)
    (let ((var (car saved)))
      (if (cadr saved)
          (set (make-local-variable var) (cddr saved))
        (kill-local-variable var))))
  (setq org-slideboard--saved-settings nil))

;;** Beautify modes

(defun org-slideboard--mode-on-p (mode)
  "Return non-nil if minor MODE is on in the current buffer."
  (if (eq mode 'variable-pitch-mode)
      ;; not a real minor mode; it works through `buffer-face-mode'
      (bound-and-true-p buffer-face-mode)
    (and (boundp mode) (symbol-value mode))))

(defun org-slideboard--beautify ()
  "Turn on `org-slideboard-beautify-modes' and marker hiding in this buffer.
Only modes that are installed and not already on are turned on, and
they are recorded so `org-slideboard--unbeautify' can turn them off.
Also turn off the modes in `org-slideboard-disable-modes'."
  (org-slideboard--disable-modes)
  (dolist (mode org-slideboard-beautify-modes)
    (ignore-errors
      (unless (fboundp mode)
        (require (intern (string-remove-suffix "-mode" (symbol-name mode))) nil t))
      (when (and (fboundp mode) (not (org-slideboard--mode-on-p mode)))
        (when (eq mode 'org-modern-mode)
          ;; org-modern draws tags as labels, which shows part of the
          ;; hidden :slide: tag; tags are not wanted on slides anyway
          (setq-local org-modern-tag nil)
          ;; org-slideboard draws its own bullets, see `org-slideboard--style-lists'
          (when org-slideboard-list-bullets
            (setq-local org-modern-list nil)))
        (funcall mode 1)
        (push mode org-slideboard--beautified))))
  (when (and org-slideboard-hide-emphasis-markers
             (not org-hide-emphasis-markers))
    (setq-local org-hide-emphasis-markers t)
    (push 'org-hide-emphasis-markers org-slideboard--beautified))
  (when (and org-slideboard-hide-macro-markers
             (not org-hide-macro-markers))
    (setq-local org-hide-macro-markers t)
    (push 'org-hide-macro-markers org-slideboard--beautified))
  (when org-slideboard--beautified
    (font-lock-flush)))

(defun org-slideboard--disable-modes ()
  "Turn off the modes in `org-slideboard-disable-modes' in this buffer.
They are recorded so `org-slideboard--unbeautify' can turn them on again."
  (dolist (mode org-slideboard-disable-modes)
    (ignore-errors
      (when (and (fboundp mode) (org-slideboard--mode-on-p mode))
        (funcall mode -1)
        (push mode org-slideboard--disabled)))))

(defun org-slideboard--unbeautify ()
  "Undo `org-slideboard--beautify' in this buffer."
  (dolist (mode org-slideboard--disabled)
    (ignore-errors (funcall mode 1)))
  (setq org-slideboard--disabled nil)
  (when org-slideboard--beautified
    (dolist (mode org-slideboard--beautified)
      (ignore-errors
        (if (memq mode '(org-hide-emphasis-markers org-hide-macro-markers))
            (kill-local-variable mode)
          (funcall mode -1)
          (when (eq mode 'org-modern-mode)
            (kill-local-variable 'org-modern-tag)
            (kill-local-variable 'org-modern-list)))))
    (setq org-slideboard--beautified nil)
    (font-lock-flush)))

;;** Macros

(defun org-slideboard--macro-templates ()
  "Return the macro templates for the show in the current buffer.
See `org-slideboard-expand-macros'.  Org's templates come from
`org-macro-initialize-templates', without #+MACRO: definitions that
evaluate Lisp: showing a presentation should not run code in it."
  (org-with-wide-buffer
   (let* ((kw (org-collect-keywords '("SLIDEBOARD_MACRO" "MACRO")))
          (defs (lambda (key)
                  (delq nil
                        (mapcar (lambda (v)
                                  (when (string-match "\\`\\(\\S-+\\)[ \t]*" v)
                                    (cons (match-string 1 v) (substring v (match-end 0)))))
                                (cdr (assoc key kw))))))
          (show (cl-remove-if (lambda (d) (string-match-p "\\`(eval\\>" (cdr d)))
                              (funcall defs "SLIDEBOARD_MACRO")))
          (eval-names (mapcar #'car
                              (cl-remove-if-not
                               (lambda (d) (string-match-p "\\`(eval\\>" (cdr d)))
                               (funcall defs "MACRO"))))
          (org (let ((org-macro-templates nil))
                 (ignore-errors (org-macro-initialize-templates))
                 (cl-remove-if (lambda (d) (member-ignore-case (car d) eval-names))
                               org-macro-templates))))
     ;; `org-macro-expand' uses the first match
     (append (reverse show) org-slideboard-macro-templates org))))

(defun org-slideboard--strip-snippets (text)
  "Return TEXT without export snippets for back-ends other than org-slideboard.
The contents of @@slideboard:...@@ snippets are kept."
  (replace-regexp-in-string
   "@@\\([-A-Za-z0-9]+\\):\\(\\(?:.\\|\n\\)*?\\)@@"
   (lambda (m)
     (if (string= (downcase (match-string 1 m)) "slideboard")
         (match-string 2 m)
       ""))
   text t t))

(defun org-slideboard--macro-string (text templates)
  "Return the expansion TEXT of a macro, as it should look on a slide.
Export snippets for other back-ends are removed, the contents of
@@slideboard:...@@ snippets are kept, macros in TEXT are expanded with
TEMPLATES, and the rest is fontified as Org text, keeping any faces
TEXT already has."
  (setq text (org-slideboard--expand-macros-in-string
              (org-slideboard--strip-snippets text) templates 1))
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

(defun org-slideboard--expand-macros ()
  "Show the macros in the accessible region as their expansion.
See `org-slideboard-expand-macros'.  This is done with overlays, so the
buffer text is not changed."
  (when org-slideboard-expand-macros
    (let ((templates nil) (initialized nil))
      (org-element-map (org-element-parse-buffer) 'macro
        (lambda (macro)
          (unless initialized
            (setq templates (org-slideboard--macro-templates)
                  initialized t))
          (let* ((value (ignore-errors (org-macro-expand macro templates)))
                 (string (and value (org-slideboard--macro-string value templates))))
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
                (overlay-put ov 'invisible 'org-slideboard-macro)
                (push ov org-slideboard--hide-overlays)))))))))

;;** Code and results

(defun org-slideboard--src-mode (info)
  "Return how the source block with INFO is shown: code, results, both or none.
INFO is from `org-babel-get-src-block-info'.  See `org-slideboard-src-display'."
  (let ((exports (or (cdr (assq :exports (nth 2 info))) "code"))
        (setting (or org-slideboard--slide-src org-slideboard-src-display)))
    (cond ((equal exports "none") 'none)
          ((eq setting 'results) 'results)
          ((eq setting 'both) 'both)
          ((equal exports "results") 'results)
          ((equal exports "both") 'both)
          (t 'code))))

(defun org-slideboard--slide-src-split (&optional with-text)
  "Return the code and results in the accessible region as two columns.
The format is that of `org-slideboard--slide-columns', with a fifth element,
code, marking the code column.  Return nil unless the region has a
source block to be shown with its results, see `org-slideboard-src-display'.
The first such block is split: the code, and its results with the
rest of the region.  Text before the block is left out (it goes in
the title strip), or with WITH-TEXT, shown above the code."
  (catch 'found
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (block)
        (let* ((beg (org-element-property :begin block))
               (info (save-excursion
                       (goto-char (org-element-property :post-affiliated block))
                       (ignore-errors (org-babel-get-src-block-info 'no-eval)))))
          (when (and info
                     (not (equal (car info) "slideboard-elisp"))
                     (eq (org-slideboard--src-mode info) 'both))
            (let* ((end (save-excursion
                          (goto-char (org-element-property :end block))
                          (skip-chars-backward " \t\n" beg)
                          (min (point-max) (1+ (point)))))
                   (res (save-excursion
                          (goto-char (org-element-property :post-affiliated block))
                          (ignore-errors (org-babel-where-is-src-block-result))))
                   (right (if (and res (<= end res (point-max)))
                              (save-excursion (goto-char res) (line-beginning-position))
                            end)))
              (throw 'found
                     (list (list org-slideboard-src-code-width
                                 beg (if with-text (point-min) beg) end 'code)
                           (list (- 1.0 org-slideboard-src-code-width)
                                 right right (point-max)))))))))
    nil))

(defun org-slideboard--src-split-direction (pos)
  "Return how to split code and results at POS, as (DIRECTION . CODE-FIRST).
DIRECTION is right or below, and CODE-FIRST is non-nil when the code
goes on the left or at the top.  POS is a heading, of a slide or a
beamer column; its SLIDEBOARD_SRC_SPLIT property, or that of a heading
above it, overrides `org-slideboard-src-split'."
  (let* ((prop (org-entry-get pos "SLIDEBOARD_SRC_SPLIT" t))
         (value (if prop (intern (downcase (string-trim prop))) org-slideboard-src-split))
         (value (if (org-slideboard--src-split-p value) value org-slideboard-src-split)))
    (pcase value
      ('rl '(right))
      ('tb '(below . t))
      ('bt '(below))
      (_ '(right . t)))))

(defun org-slideboard--src-setting (pos)
  "Return the SLIDEBOARD_SRC property at heading POS, or above it.
The value is returned as a symbol, or nil if there is none or it is
not valid, see `org-slideboard-src-display'."
  (let* ((v (org-with-wide-buffer (org-entry-get pos "SLIDEBOARD_SRC" t)))
         (sym (and v (intern (downcase (string-trim v))))))
    (and (org-slideboard--src-display-p sym) sym)))

(defun org-slideboard--frame-share (type pos)
  "Return the remembered share of the frame of TYPE whose text starts at POS."
  (cdr (cl-find-if (lambda (e) (and (eq (caar e) type)
                                    (eql (marker-position (cdar e)) pos)))
                   org-slideboard--frame-shares)))

(defun org-slideboard--set-frame-share (type pos share)
  "Remember SHARE for the frame of TYPE whose text starts at POS."
  (let ((entry (cl-find-if (lambda (e) (and (eq (caar e) type)
                                            (eql (marker-position (cdar e)) pos)))
                           org-slideboard--frame-shares)))
    (if entry
        (setcdr entry share)
      (push (cons (cons type (set-marker (make-marker) pos
                                         (or (buffer-base-buffer) (current-buffer))))
                  share)
            org-slideboard--frame-shares))))

(defun org-slideboard--clear-frame-shares ()
  "Forget the frame sizes changed by dragging."
  (dolist (entry org-slideboard--frame-shares)
    (set-marker (cdar entry) nil))
  (setq org-slideboard--frame-shares '()))

(defun org-slideboard--shares (type positions defaults)
  "Return the shares of frames of TYPE at POSITIONS, with DEFAULTS.
A frame whose size was changed by dragging gets its remembered share;
the others share the rest in proportion to DEFAULTS.  The result sums
to 1."
  (let* ((known (mapcar (lambda (p) (org-slideboard--frame-share type p)) positions))
         (known-sum (apply #'+ (delq nil (copy-sequence known))))
         (unknown-sum (apply #'+ (cl-loop for k in known for d in defaults
                                          unless k collect d)))
         (rest (max 0.0 (- 1.0 known-sum)))
         (shares (cl-loop for k in known for d in defaults
                          collect (or k (if (> unknown-sum 0)
                                            (* rest (/ d unknown-sum))
                                          0.0))))
         (sum (apply #'+ shares)))
    (if (> sum 0)
        (mapcar (lambda (x) (/ x sum)) shares)
      defaults)))

(defun org-slideboard--mark-share (win type pos share)
  "Mark window WIN as the frame of TYPE at POS, laid out with SHARE.
When its size is changed later, by dragging, the new share is kept;
see `org-slideboard--size-changed'."
  (set-window-parameter win 'org-slideboard-share (list type pos share)))

(defun org-slideboard--size-changed (frame)
  "Keep the sizes of frames changed by dragging, and show the slide again.
For `window-size-change-functions' during the show; FRAME is the Emacs
frame whose windows changed.  A frame's share is its part of the width
or height of the frames it was laid out with, see
`org-slideboard--mark-share'."
  (when (and org-slideboard--running (eq frame (selected-frame)))
    (let ((groups '())
          (changed nil))
      ;; the frames laid out together share a parent window
      (walk-window-tree
       (lambda (w)
         (when (window-parameter w 'org-slideboard-share)
           (let ((entry (assq (window-parent w) groups)))
             (if entry
                 (push w (cdr entry))
               (push (list (window-parent w) w) groups)))))
       frame t)
      (dolist (group groups)
        (let* ((wins (cdr group))
               (horizontal (window-combined-p (car wins) t))
               (size (lambda (w) (if horizontal (window-total-width w)
                                   (window-total-height w))))
               (total (float (apply #'+ (mapcar size wins)))))
          (when (and (cdr wins) (> total 0))
            (dolist (w wins)
              (let ((mark (window-parameter w 'org-slideboard-share))
                    (share (/ (funcall size w) total)))
                (when (> (abs (- share (nth 2 mark))) 0.02)
                  (with-current-buffer (org-slideboard--show-buffer)
                    (org-slideboard--set-frame-share (nth 0 mark) (nth 1 mark) share))
                  (set-window-parameter w 'org-slideboard-share
                                        (list (nth 0 mark) (nth 1 mark) share))
                  (setq changed t)))))))
      (when changed
        ;; images are scaled to their window: show the slide again when
        ;; the dragging is over
        (when (timerp org-slideboard--resize-timer)
          (cancel-timer org-slideboard--resize-timer))
        (setq org-slideboard--resize-timer
              (run-with-idle-timer 0.3 nil #'org-slideboard--redraw-keeping-frame))))))

(defun org-slideboard--redraw-keeping-frame ()
  "Show the current slide again, with the same frame selected."
  (setq org-slideboard--resize-timer nil)
  (when org-slideboard--running
    (let ((key (buffer-local-value 'org-slideboard--frame-key
                                   (window-buffer (selected-window))))
          (pos (window-point (selected-window))))
      (org-slideboard-goto-slide org-slideboard-current-slide-number)
      (org-slideboard--select-frame key pos))))

(defun org-slideboard--setup-column (win base col i)
  "Show column COL of buffer BASE in window WIN; return the windows used.
If the column has code to be shown with its results, WIN is divided
into a window for the code (with the column text before it) and one
for the results, see `org-slideboard-src-split'.  I is the column index.
The column heading's SLIDEBOARD_SRC property, if any, applies to it."
  (let* ((org-slideboard--slide-src (or (and (not (nth 4 col))
                                       (with-current-buffer base
                                         (org-slideboard--src-setting (nth 1 col))))
                                  org-slideboard--slide-src))
         (inner (and (not (nth 4 col))
                    (with-current-buffer base
                      (save-restriction
                        (narrow-to-region (nth 2 col) (nth 3 col))
                        (org-slideboard--slide-src-split t))))))
    (if (not inner)
        (progn (org-slideboard--setup-column-window win base col i)
               (list win))
      (let* ((split (with-current-buffer base
                      (save-restriction
                        (widen)
                        (org-slideboard--src-split-direction (nth 1 col)))))
             (dir (car split))
             (inner (if (cdr split) inner (reverse inner)))
             (shares (with-current-buffer base
                       (org-slideboard--shares 'src (mapcar #'caddr inner)
                                               (mapcar #'car inner))))
             (size (if (eq dir 'below)
                       (max window-min-height
                            (round (* (window-total-height win) (car shares))))
                     (max window-min-width
                          (round (* (window-total-width win) (car shares))))))
             ;; a combination of its own, so the column keeps its size
             (other (let ((window-combination-limit t))
                      (split-window win size dir))))
        (org-slideboard--setup-column-window win base (nth 0 inner) i)
        (org-slideboard--setup-column-window other base (nth 1 inner) i)
        (org-slideboard--mark-share win 'src (nth 2 (nth 0 inner)) (nth 0 shares))
        (org-slideboard--mark-share other 'src (nth 2 (nth 1 inner)) (nth 1 shares))
        (when (eq dir 'below)
          (org-slideboard--divider win))
        (list win other)))))

(defvar org-slideboard-code-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'org-slideboard-execute-src-block)
    map)
  "Keymap for `org-slideboard-code-mode'.")

(define-minor-mode org-slideboard-code-mode
  "Minor mode for the code side of a slide with code and results.
\\{org-slideboard-code-mode-map}"
  :lighter nil
  :keymap org-slideboard-code-mode-map)

(defvar org-slideboard--executing nil
  "Non-nil while `org-slideboard-execute-src-block' runs a block.")

(defun org-slideboard-execute-src-block ()
  "Run the source block at point and show the slide with its new results.
The block is run in the presentation buffer, as \\[org-ctrl-c-ctrl-c]
would, so the results are written to the file as usual."
  (interactive)
  ;; the code window may also hold text before the block
  (unless (org-element-lineage (org-element-at-point) '(src-block) t)
    (let ((case-fold-search t))
      (goto-char (point-min))
      (re-search-forward "^[ \t]*#\\+begin_src\\b" nil t)
      (forward-line 1)))
  (let ((pos (point))
        (base (org-slideboard--base-buffer)))
    (with-current-buffer base
      (save-restriction
        (widen)
        (save-excursion
          (goto-char pos)
          (let ((org-slideboard--executing t))
            (org-babel-execute-src-block)))))
    (org-slideboard--refresh-slide pos)))

(defun org-slideboard--refresh-slide (&optional code-pos)
  "Show the current slide again, e.g. with new results.
With CODE-POS, select the code window and put point there."
  (when (and org-slideboard--running org-slideboard-presentation-file)
    (org-slideboard-goto-slide org-slideboard-current-slide-number)
    (when code-pos
      (let ((win (cl-find-if (lambda (w)
                               (buffer-local-value 'org-slideboard-code-mode (window-buffer w)))
                             (window-list))))
        (when win
          (select-window win)
          (goto-char (max (point-min) (min code-pos (point-max)))))))))

(defun org-slideboard--after-execute ()
  "Show the slide again after a block of the presentation was run.
For `org-babel-after-execute-hook' during the show."
  (when (and org-slideboard--running (not org-slideboard--executing)
             org-slideboard-presentation-file
             (equal (buffer-file-name (org-slideboard--base-buffer))
                    (expand-file-name org-slideboard-presentation-file)))
    (let ((pos (and org-slideboard-code-mode (point))))
      (run-at-time 0 nil #'org-slideboard--refresh-slide pos))))

(defun org-slideboard--start-R ()
  "Return the buffer of a running R process, started with ESS if needed."
  (or (cl-find-if (lambda (b)
                    (and (eq (buffer-local-value 'major-mode b) 'inferior-ess-r-mode)
                         (get-buffer-process b)))
                  (buffer-list))
      (when (or (fboundp 'R) (require 'ess-r-mode nil t))
        (with-no-warnings
          (let ((ess-ask-for-ess-directory nil))
            (let ((buf (R)))
              (if (bufferp buf) buf (current-buffer))))))))

(defun org-slideboard--start-python ()
  "Return the buffer of a running Python shell, started if needed."
  (require 'python)
  (with-no-warnings
    (let ((proc (or (python-shell-get-process)
                    (run-python nil nil nil))))
      (cond ((processp proc) (process-buffer proc))
            ((bufferp proc) proc)
            (t (get-buffer "*Python*"))))))

(defun org-slideboard--src-repl (info)
  "Return a REPL buffer for the source block with INFO, starting one if needed.
See `org-slideboard-src-repl-functions'."
  (let ((session (cdr (assq :session (nth 2 info))))
        (fn (cdr (assoc-string (car info) org-slideboard-src-repl-functions t))))
    (ignore-errors
      (save-window-excursion
        (let ((buf (if (and session (not (equal session "none")))
                       (org-babel-initiate-session nil info)
                     (and fn (funcall fn)))))
          (and buf (get-buffer buf)))))))

(defvar org-slideboard--scaled-buffers '()
  "Buffers whose text scale was changed for editing during the show.")

(defvar org-src--beg-marker)

(defun org-slideboard--src-edit-setup ()
  "Show a block opened for editing during the show next to its REPL.
For `org-src-mode-hook'."
  (when (and org-src-mode org-slideboard--running
             (boundp 'org-src--beg-marker)
             (markerp org-src--beg-marker)
             (buffer-live-p (marker-buffer org-src--beg-marker))
             org-slideboard-presentation-file
             (with-current-buffer (marker-buffer org-src--beg-marker)
               (equal (buffer-file-name (org-slideboard--base-buffer))
                      (expand-file-name org-slideboard-presentation-file))))
    (let* ((edit (current-buffer))
           ;; local to the editing buffer, so read it here
           (marker org-src--beg-marker)
           (info (with-current-buffer (marker-buffer marker)
                   (save-excursion
                     (goto-char marker)
                     (ignore-errors (org-babel-get-src-block-info 'no-eval))))))
      (add-hook 'kill-buffer-hook #'org-slideboard--src-edit-done nil t)
      ;; lay out after Org has shown the editing buffer
      (run-at-time 0 nil #'org-slideboard--src-edit-layout edit info))))

(defun org-slideboard--src-edit-layout (edit info)
  "Show the editing buffer EDIT on the left and the REPL for INFO on the right."
  (when (buffer-live-p edit)
    (let ((repl (and info (org-slideboard--src-repl info)))
          (scale (or org-slideboard-text-scale 0)))
      (with-current-buffer edit
        (text-scale-set scale)
        ;; ESS evaluates in `ess-local-process-name'
        (when (and repl (boundp 'ess-local-process-name))
          (let ((name (buffer-local-value 'ess-local-process-name repl)))
            (when name (setq-local ess-local-process-name name)))))
      (delete-other-windows)
      (set-window-parameter (selected-window) 'mode-line-format nil)
      (switch-to-buffer edit)
      (when repl
        (let ((win (split-window nil (max window-min-width
                                          (round (* (window-total-width)
                                                    org-slideboard-src-code-width)))
                                 'right)))
          (set-window-buffer win repl)
          (with-current-buffer repl
            (unless (memq repl org-slideboard--scaled-buffers)
              (push repl org-slideboard--scaled-buffers))
            (text-scale-set scale))
          (with-selected-window win (goto-char (point-max))))))))

(defun org-slideboard--src-edit-done ()
  "Show the slide again when the editing buffer is closed.
For the buffer-local `kill-buffer-hook' of the editing buffer."
  (let ((pos (and (boundp 'org-src--beg-marker)
                  (markerp org-src--beg-marker)
                  (marker-position org-src--beg-marker))))
    (run-at-time 0 nil #'org-slideboard--refresh-slide pos)))

;;** Tables

(defun org-slideboard--table-line-cells ()
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

(defun org-slideboard--table-pad (beg end pixels &optional face)
  "Display the region BEG END as blank space PIXELS wide, in FACE."
  (when (< beg end)
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'display `(space :width (,(max 0 pixels))))
      (overlay-put ov 'priority 1001)
      (when face (overlay-put ov 'face face))
      (push ov org-slideboard--table-overlays)
      (push ov org-slideboard--hide-overlays))))

(defun org-slideboard--align-tables (&optional win)
  "Align the Org tables in the accessible region to their display in WIN.
WIN defaults to the selected window.  The width of each cell is
measured as displayed, with expanded macros, equation images and the
font in use, and the blanks around it are shown as space of the width
that lines up the columns.  Cells that Org right-aligned (numbers) stay
right-aligned.  Horizontal rules are drawn to the column widths.  See
`org-slideboard-align-tables'."
  (setq win (or win (selected-window)))
  (mapc #'delete-overlay org-slideboard--table-overlays)
  (setq org-slideboard--table-overlays nil)
  (when org-slideboard-align-tables
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
                         for (b . e) in (org-slideboard--table-line-cells)
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
                        (org-slideboard--table-pad b e (+ col (* 2 spc))
                                             '(:inherit org-table :strike-through t)))
                       ((>= cb ce)
                        (org-slideboard--table-pad b e (+ col (* 2 spc))))
                       ;; Org pads numbers on the left
                       ((> (- cb b) 1)
                        (org-slideboard--table-pad b cb (+ (- col w) spc))
                        (org-slideboard--table-pad ce e spc))
                       (t
                        (org-slideboard--table-pad b cb spc)
                        (org-slideboard--table-pad ce e (+ (- col w) spc))))))))))))))

;;** Title and section pages

(defun org-slideboard--expand-macros-in-string (string &optional templates depth)
  "Return STRING with its Org macros expanded, see `org-slideboard-expand-macros'.
Macros in the expansions are expanded too, up to a few levels deep.
Macros that cannot be expanded are removed.  TEMPLATES defaults to
`org-slideboard--macro-templates'; DEPTH is used for the recursion."
  (let ((depth (or depth 0)))
    (if (or (not org-slideboard-expand-macros) (> depth 5)
            (not (string-match-p "{{{" string)))
        (replace-regexp-in-string "{{{\\(?:.\\|\n\\)*?}}}" "" string t t)
      (let ((templates (or templates (org-slideboard--macro-templates))))
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
                 (org-slideboard--expand-macros-in-string
                  (org-slideboard--strip-snippets value) templates (1+ depth))
               "")))
         string t t)))))

(defun org-slideboard--keyword-lines (value)
  "Split keyword VALUE into lines of plain text.
LaTeX line breaks (\\\\) start new lines, \\today becomes today's
date, \\and becomes a comma, Org macros are expanded (see
`org-slideboard-expand-macros') or dropped, and other LaTeX commands are
dropped, keeping their arguments."
  (let ((value (substring-no-properties
                (org-slideboard--expand-macros-in-string (or value "")))))
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

(defun org-slideboard--heading-title ()
  "Return the plain text of the heading at point."
  (org-link-display-format (org-get-heading t t t t)))

(defun org-slideboard--title-lines ()
  "Return the title page of the current buffer as a list of (TEXT . FACE)."
  (let* ((kw (org-collect-keywords '("TITLE" "SUBTITLE" "AUTHOR" "DATE")))
         (get (lambda (k)
                (org-slideboard--keyword-lines (mapconcat #'identity (cdr (assoc k kw)) " "))))
         (face (lambda (f) (lambda (s) (cons s f))))
         (title (or (funcall get "TITLE")
                    (list (file-name-base (or (buffer-file-name (org-slideboard--base-buffer))
                                              (buffer-name))))))
         (info (append (funcall get "AUTHOR") (funcall get "DATE"))))
    (append (mapcar (funcall face 'org-slideboard-page-title) title)
            (mapcar (funcall face 'org-slideboard-page-subtitle) (funcall get "SUBTITLE"))
            (when info
              (cons (cons "" nil)
                    (mapcar (funcall face 'org-slideboard-page-info) info))))))

(defun org-slideboard--section-lines (marker)
  "Return the section page for the heading at MARKER as a list of (TEXT . FACE)."
  (org-with-point-at marker
    (list (cons (org-slideboard--heading-title) 'org-slideboard-page-section))))

(defun org-slideboard--section-ancestors ()
  "Return the positions of the section headings above the slide at point.
These are the ancestors without the slide tag, outermost first."
  (save-excursion
    (let ((res '()))
      (while (org-up-heading-safe)
        (unless (member org-slideboard-slide-tag (org-get-tags nil t))
          (push (point) res)))
      res)))

(defun org-slideboard--place-string (text vpos hpos)
  "Insert TEXT at line VPOS, column HPOS, padding with newlines and spaces."
  (goto-char (point-min))
  (dotimes (_ vpos)
    (end-of-line)
    (when (= (forward-line 1) 1) (insert "\n")))
  (move-to-column hpos t)
  (insert text))

(defun org-slideboard--show-page (lines scale animate)
  "Show LINES, a list of (TEXT . FACE), centred on a page of their own.
SCALE is the text scale.  With ANIMATE, the lines are animated in; a
key press skips the rest of the animation."
  (org-slideboard--teardown-columns)
  (delete-other-windows)
  (switch-to-buffer (get-buffer-create org-slideboard--page-buffer))
  (let ((inhibit-read-only t)) (erase-buffer))
  (org-slideboard-keys-mode 1)
  (setq buffer-undo-list t)
  (setq-local cursor-type nil)
  (setq-local show-trailing-whitespace nil)
  (org-slideboard--disable-modes)
  (setq-local indent-tabs-mode nil)
  (org-slideboard--hide-mode-line (selected-window))
  (let ((org-slideboard--scaling t))
    (text-scale-set (or scale 5)))
  (let* ((cols (window-max-chars-per-line))
         (rows (/ (window-body-height nil t) (window-font-height nil 'default)))
         (vpos (max 0 (/ (- rows (length lines)) 2))))
    (dolist (line lines)
      (let* ((text (car line))
             (hpos (max 0 (/ (- cols (string-width text)) 2))))
        (unless (string= text "")
          (if (and animate (not (input-pending-p)))
              (animate-string text vpos hpos)
            (org-slideboard--place-string text vpos hpos))
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

(defun org-slideboard--show-special (entry n)
  "Show the title or section page ENTRY, which is slide N."
  (let (lines scale animate)
    ;; read everything in the presentation buffer, where the settings
    ;; may be buffer-local (file-local variables, #+SLIDEBOARD:)
    (with-current-buffer (org-slideboard--show-buffer)
      (save-restriction
        (widen)
        (setq lines (pcase (car entry)
                      (:title (org-slideboard--title-lines))
                      (:section (org-slideboard--section-lines (cadr entry))))
              scale org-slideboard-page-text-scale
              animate org-slideboard-animate-pages)))
    (set-frame-name (format "%-180s%15s%s" (car (car lines)) "slide " n))
    (org-slideboard--show-page lines scale animate)
    (message "")))

(defun org-slideboard--entry-title (entry)
  "Return a title for the slide list ENTRY, for the table of contents."
  (if (markerp entry)
      (org-with-point-at entry (nth 4 (org-heading-components)))
    (with-current-buffer (find-file-noselect org-slideboard-presentation-file)
      (save-restriction
        (widen)
        (pcase (car entry)
          (:title (concat "Title page: " (car (car (org-slideboard--title-lines)))))
          (:section (concat "Section: " (car (car (org-slideboard--section-lines (cadr entry)))))))))))

;;** Slides

(defun org-slideboard--goto-slide-heading ()
  "Move point to the slide heading containing point."
  (org-back-to-heading t)
  (while (and (not (member org-slideboard-slide-tag (org-get-tags nil t)))
              (org-up-heading-safe))))

(defun org-slideboard-execute-slide ()
  "Process slide at point.
If it contains an Emacs Lisp source block, evaluate it.
  If it has beamer columns, show them side by side.
  Else, focus on that buffer.
  Hide all drawers.
On a title or section page, show that page again."
  (interactive)
  (if (equal (buffer-name) org-slideboard--page-buffer)
      (org-slideboard-goto-slide org-slideboard-current-slide-number)
    (org-slideboard--execute-slide)))

(defun org-slideboard--execute-slide ()
  "Show the slide at point.  See `org-slideboard-execute-slide'."
  ;; if point is in a column buffer, move to the same place in the base buffer
  (let ((pos (point))
        (base (org-slideboard--base-buffer)))
    (org-slideboard--teardown-columns)
    (switch-to-buffer base)
    (org-slideboard-keys-mode 1)
    (goto-char pos))
  (setq org-slideboard-presentation-file (org-slideboard--file))
  (delete-other-windows)

  ;; make sure nothing is folded. This seems to be necessary to
  ;; prevent an error on narrowing then trying to make latex fragments
  ;; I think.
  (widen)
  (org-cycle '(64))

  (org-narrow-to-subtree)
  (visual-line-mode 1)
  (let ((heading-text (nth 4 (org-heading-components)))
        (cols (org-slideboard--slide-columns)))

    (set-frame-name (format "%-180s%15s%s"
                            heading-text
                            "slide "
                            (cdr (assoc heading-text org-slideboard-slide-titles))))

    ;; setup the text
    (switch-to-buffer (current-buffer))
    (with-no-warnings
      (if (fboundp 'org-fold-show-subtree) (org-fold-show-subtree) (org-slideboard-subtree)))
    ;; blocks are not folded: code that is not wanted is hidden instead,
    ;; see `org-slideboard-src-display'
    (setq org-slideboard--slide-src (org-slideboard--src-setting (point)))
    (let ((src (and (not cols) (org-slideboard--slide-src-split))))
      (when src
        (let ((split (org-slideboard--src-split-direction (point-min))))
          (setq cols (if (cdr split) src (reverse src))
                src (car split))))
      (setq org-slideboard--split-direction src))
    ;; a slide without columns is one frame: its body
    (unless cols
      (let ((body (save-excursion
                    (goto-char (point-min))
                    (org-end-of-meta-data t)
                    (min (point) (point-max)))))
        (setq cols (list (list 1.0 body body (point-max))))))
    (org-slideboard--display-columns cols org-slideboard--split-direction)

    ;; evaluate special code blocks last as they may change the arrangement
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-babel-src-block-regexp nil t)
        (save-excursion
          (goto-char (match-beginning 0))
          (let* ((info (save-excursion
                         (org-babel-get-src-block-info))))
            (when (string= "slideboard-elisp" (car info))
              ;; fold code
              (org-cycle)
              (eval (read (concat "(progn " (nth 1 info) ")"))))))))
    ;; clear the minibuffer
    (message "")))

(defun org-slideboard-next-slide ()
  "Goto next slide in presentation."
  (interactive)
  (find-file org-slideboard-presentation-file)
  (widen)
  (if (<= (+ org-slideboard-current-slide-number 1) (length org-slideboard-slide-list))
      (progn
        (setq org-slideboard-current-slide-number (+ org-slideboard-current-slide-number 1))
        (org-slideboard-goto-slide org-slideboard-current-slide-number))
    (org-slideboard-goto-slide org-slideboard-current-slide-number)
    (message "This is the end. My only friend the end.  Jim Morrison.")))


(defun org-slideboard-previous-slide ()
  "Goto previous slide in the list."
  (interactive)
  (find-file org-slideboard-presentation-file)
  (widen)
  (if (> (- org-slideboard-current-slide-number 1) 0)
      (progn
        (setq org-slideboard-current-slide-number (- org-slideboard-current-slide-number 1))
        (org-slideboard-goto-slide org-slideboard-current-slide-number))
    (org-slideboard-goto-slide org-slideboard-current-slide-number)
    (message "Once upon a time...")))


(defun org-slideboard--setup-show ()
  "Prepare the presentation buffer and Emacs for a show.
Hide the tags of the slides and the slideboard-elisp blocks, and add
the hooks and window dividers of the show.  The current buffer is the
presentation buffer, widened."
  (save-excursion
    (goto-char (point-min))
    ;; hide the tags of slide headings, with the blanks before them, so a
    ;; heading does not wrap at large text sizes
    (save-excursion
      (while (re-search-forward (org-slideboard--slide-tag-regexp) nil t)
        (when (org-at-heading-p)
          (let ((eol (line-end-position)))
            (beginning-of-line)
            (when (re-search-forward "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*$" eol t)
              (org-slideboard--start-overlay (match-beginning 0) (match-end 0)))
            (goto-char eol)))))
    ;; hide slideboard-elisp blocks
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
            (when (string= "slideboard-elisp" (car info))
              (org-slideboard--start-overlay start end))))))
    (add-to-invisibility-spec 'org-slideboard-slide))
  (add-hook 'org-babel-after-execute-hook #'org-slideboard--after-execute)
  (add-hook 'org-src-mode-hook #'org-slideboard--src-edit-setup)
  (add-hook 'text-scale-mode-hook #'org-slideboard--text-scale-changed)
  (add-hook 'window-size-change-functions #'org-slideboard--size-changed)
  ;; draggable lines between frames side by side
  (unless org-slideboard--saved-divider-width
    (setq org-slideboard--saved-divider-width
          (or (frame-parameter nil 'right-divider-width) 0)))
  (set-frame-parameter nil 'right-divider-width org-slideboard-divider-width))

(defun org-slideboard-open-slide ()
  "Start show at this slide."
  (interactive)
  (let ((pos (point)))
    (switch-to-buffer (org-slideboard--base-buffer))
    (goto-char pos))
  (setq org-slideboard-presentation-file (org-slideboard--file))
  (widen)
  (org-slideboard--apply-keyword-settings)
  (setq org-slideboard--start-text-scale org-slideboard-text-scale)
  (org-slideboard-initialize)
  (org-slideboard--goto-slide-heading)
  (let ((n (cdr (assoc (nth 4 (org-heading-components)) org-slideboard-slide-titles))))
    (unless n (user-error "Not in a slide"))
    (setq org-slideboard--running t)
    (org-slideboard--setup-show)
    (org-slideboard--beautify)
    (unless org-slideboard-mode (org-slideboard-mode 1))
    (setq org-slideboard-current-slide-number n)
    (org-slideboard-goto-slide n)))


(defvar org-slideboard--start-overlays '()
  "Overlays made when the show starts, removed when it stops.")

(defun org-slideboard--start-overlay (beg end)
  "Hide BEG to END for the whole show."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'invisible 'org-slideboard-slide)
    (push ov org-slideboard--start-overlays)))

(defun org-slideboard--slide-tag-regexp ()
  "Return a regexp matching the slide tag, see `org-slideboard-slide-tag'."
  (concat ":" (regexp-quote org-slideboard-slide-tag) ":"))

(defun org-slideboard-initialize ()
  "Initialize the org-slideboard.
Make slide lists for future navigation.  Rerun this if you change
slide order.  The list starts with a title page if
`org-slideboard-title-page' is non-nil, and has a section page before the
first slide of each section if `org-slideboard-section-pages' is non-nil."
  (setq  org-slideboard-slide-titles '()
         org-slideboard-slide-list '())

  (let ((n 0)
        (seen '()))
    (when org-slideboard-title-page
      (push (cons (cl-incf n) (list :title)) org-slideboard-slide-list))
    (org-map-entries
     (lambda ()
       ;; COMMENTed slides are skipped, as they are in export
       (when (and (member org-slideboard-slide-tag (org-get-tags nil t))
                  (not (org-in-commented-heading-p)))
         (when org-slideboard-section-pages
           (dolist (pos (org-slideboard--section-ancestors))
             (unless (member pos seen)
               (push pos seen)
               (cl-incf n)
               (push (cons (save-excursion
                             (goto-char pos)
                             (nth 4 (org-heading-components)))
                           n)
                     org-slideboard-slide-titles)
               (push (cons n (list :section (set-marker (make-marker) pos)))
                     org-slideboard-slide-list))))
         (cl-incf n)
         (push (cons (nth 4 (org-heading-components)) n) org-slideboard-slide-titles)
         (push (cons n (set-marker (make-marker) (point))) org-slideboard-slide-list))))
    (setq org-slideboard-slide-titles (nreverse org-slideboard-slide-titles)
          org-slideboard-slide-list (nreverse org-slideboard-slide-list))))


;;;###autoload
(defun org-slideboard-start-slideshow ()
  "Start the slide show, at the beginning."
  (interactive)
  (switch-to-buffer (org-slideboard--base-buffer))
  (setq org-slideboard--running t)
  (setq org-slideboard-presentation-file (org-slideboard--file))
  (widen)
  (goto-char (point-min))

  (org-slideboard--apply-keyword-settings)
  (setq org-slideboard--start-text-scale org-slideboard-text-scale)
  (org-slideboard-initialize)
  (org-slideboard--setup-show)
  (goto-char (point-min))
  (delete-other-windows)
  (org-slideboard--beautify)
  (unless org-slideboard-mode (org-slideboard-mode 1))
  (setq org-slideboard-current-slide-number 1)
  (org-slideboard-goto-slide 1))


(defun org-slideboard-stop-slideshow ()
  "Stop the slide show and restore the presentation buffer."
  (interactive)
  (remove-hook 'org-babel-after-execute-hook #'org-slideboard--after-execute)
  (remove-hook 'org-src-mode-hook #'org-slideboard--src-edit-setup)
  (remove-hook 'text-scale-mode-hook #'org-slideboard--text-scale-changed)
  (remove-hook 'window-size-change-functions #'org-slideboard--size-changed)
  (when (timerp org-slideboard--resize-timer)
    (cancel-timer org-slideboard--resize-timer))
  (org-slideboard--clear-frame-shares)
  (when org-slideboard--saved-divider-width
    (set-frame-parameter nil 'right-divider-width org-slideboard--saved-divider-width)
    (setq org-slideboard--saved-divider-width nil))
  ;; the text size goes back to what it was when the show started
  (org-slideboard--clear-frame-sizes)
  (when (and org-slideboard--start-text-scale org-slideboard-presentation-file)
    (with-current-buffer (org-slideboard--show-buffer)
      (setq org-slideboard-text-scale org-slideboard--start-text-scale)))
  (setq org-slideboard--start-text-scale nil)
  (dolist (buf org-slideboard--scaled-buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf (text-scale-set 0))))
  (setq org-slideboard--scaled-buffers '())
  (org-slideboard--teardown-columns)
  (when org-slideboard-presentation-file (find-file org-slideboard-presentation-file))
  ;; make slide tag visible again
  (remove-from-invisibility-spec 'org-slideboard-slide)
  (remove-from-invisibility-spec 'org-slideboard)
  (mapc #'delete-overlay org-slideboard--start-overlays)
  (setq org-slideboard--start-overlays '())

  ;; Redisplay inline images
  (widen)
  (org-slideboard--org-images)

  ;; ;; clean up miscellaneous buffers
  (when (get-buffer "*Animation*") (kill-buffer "*Animation*"))
  (when (get-buffer org-slideboard--page-buffer) (kill-buffer org-slideboard--page-buffer))
  (when (get-buffer org-slideboard--footline-buffer)
    (kill-buffer org-slideboard--footline-buffer))

  (when org-slideboard-presentation-file (find-file org-slideboard-presentation-file))
  (widen)
  (org-slideboard-keys-mode -1)
  ;; the equation images were made for the slides
  (org-clear-latex-preview)
  (text-scale-set 0)
  (delete-other-windows)
  (setq org-slideboard-presentation-file nil)
  (setq org-slideboard-current-slide-number 1)
  (set-frame-name (if (buffer-file-name)
                      (abbreviate-file-name (buffer-file-name))))
  (org-slideboard--unbeautify)
  (org-slideboard--restore-keyword-settings)
  (setq org-slideboard--running nil)
  (org-slideboard-mode -1))


(defun org-slideboard-goto-slide (n)
  "Goto slide N."
  (interactive "nSlide number: ")
  (message "Going to slide %s" n)
  (find-file org-slideboard-presentation-file)
  (setq org-slideboard-current-slide-number n)
  (widen)
  (let ((entry (cdr (assoc n org-slideboard-slide-list))))
    (if (markerp entry)
        (progn
          (goto-char entry)
          (org-slideboard--execute-slide))
      (org-slideboard--show-special entry n))))


(defun org-slideboard-toc ()
  "Show a table of contents for the slideshow."
  (interactive)
  (let ((links
         (mapcar (lambda (x)
                   (format " [[elisp:(org-slideboard-goto-slide %s)][%2s %s]]\n\n"
                           (car x) (car x) (org-slideboard--entry-title (cdr x))))
                 org-slideboard-slide-list)))
    (org-slideboard--teardown-columns)
    (delete-other-windows)
    (switch-to-buffer "*List of Slides*")
    (org-mode)
    (erase-buffer)

    (insert (mapconcat 'identity links ""))
    (goto-char (point-min))

    (use-local-map (copy-keymap org-mode-map))
    (local-set-key "q" #'(lambda () (interactive) (kill-buffer)))))


(defun org-slideboard-animate (strings)
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


(defun org-slideboard--change-text-scale (delta)
  "Change the text size of all frames of all slides by DELTA steps.
Slide titles and title and section pages keep their size."
  (if (equal (buffer-name) org-slideboard--page-buffer)
      (message "Title and section pages keep their size")
    (let ((new (+ (or (buffer-local-value 'org-slideboard-text-scale
                                          (org-slideboard--show-buffer))
                      0)
                  delta)))
      ;; in the presentation buffer, so a value local to it (file-local
      ;; variable or #+SLIDEBOARD:) is changed there, and a global one
      ;; globally
      (with-current-buffer (org-slideboard--show-buffer)
        (setq org-slideboard-text-scale new))
      (when org-slideboard--running
        (let ((key org-slideboard--frame-key)
              (pos (point)))
          (org-slideboard-goto-slide org-slideboard-current-slide-number)
          (org-slideboard--select-frame key pos)))
      (message "Text size of all slides: %s" new))))

(defun org-slideboard--select-frame (key pos)
  "Select the frame whose text starts at KEY, with point at POS.
Do nothing if KEY is nil or no window shows that frame."
  (let ((win (and key
                  (cl-find-if (lambda (w)
                                (eql (buffer-local-value 'org-slideboard--frame-key
                                                         (window-buffer w))
                                     key))
                              (window-list)))))
    (when win
      (select-window win)
      (goto-char (max (point-min) (min pos (point-max)))))))

(defun org-slideboard--change-frame-scale (delta)
  "Change the text size of the selected frame of this slide by DELTA steps."
  (if (not org-slideboard--frame-key)
      (message "Not in a frame of a slide; slide titles keep their size")
    (let ((steps (+ (org-slideboard--frame-offset org-slideboard--frame-key) delta)))
      (org-slideboard--set-frame-offset org-slideboard--frame-key steps)
      (org-slideboard--set-text-scale (get-buffer-window-list nil nil t))
      (message "Text size of this frame: %+d" steps))))

(defun org-slideboard--clear-frame-sizes ()
  "Forget the size changes of single frames."
  (dolist (entry org-slideboard--frame-offsets)
    (set-marker (car entry) nil))
  (setq org-slideboard--frame-offsets '()))

(defun org-slideboard-reset-text-size ()
  "Put the text and the frames of all slides back as the show started.
The text of all frames goes back to its starting size, including frames
changed on their own, and frames resized by dragging get their usual
size again.  Slide titles and pages keep their size."
  (interactive)
  (org-slideboard--clear-frame-sizes)
  (org-slideboard--clear-frame-shares)
  (when org-slideboard--start-text-scale
    (with-current-buffer (org-slideboard--show-buffer)
      (setq org-slideboard-text-scale org-slideboard--start-text-scale)))
  (when org-slideboard--running
    (let ((key org-slideboard--frame-key)
          (pos (point)))
      (org-slideboard-goto-slide org-slideboard-current-slide-number)
      (org-slideboard--select-frame key pos)))
  (message "Text size of all slides back to %s"
           (buffer-local-value 'org-slideboard-text-scale (org-slideboard--show-buffer))))

(defun org-slideboard-increase-frame-text-size ()
  "Increase the text size of the selected frame of this slide.
The frame keeps the size when the slide is shown again.  Emacs's own
zoom keys, such as \\[text-scale-adjust], do the same during the show."
  (interactive)
  (org-slideboard--change-frame-scale 1))

(defun org-slideboard-decrease-frame-text-size ()
  "Decrease the text size of the selected frame of this slide.
See `org-slideboard-increase-frame-text-size'."
  (interactive)
  (org-slideboard--change-frame-scale -1))

(defun org-slideboard--text-scale-changed ()
  "Keep a size change made with Emacs's zoom keys during the show.
In a frame of a slide, it becomes that frame's own size, see
`org-slideboard-increase-frame-text-size'; turning the zoom off (as
\\[text-scale-adjust] 0 does) goes back to the size of all frames.
Slide titles and pages are set back to their size.  For
`text-scale-mode-hook'."
  (when (and org-slideboard--running (not org-slideboard--scaling)
             org-slideboard-zoom-resizes-frame)
    (let ((buf (current-buffer)))
      (cond
       (org-slideboard--frame-key
        (org-slideboard--set-frame-offset
         org-slideboard--frame-key
         (if text-scale-mode
             (- text-scale-mode-amount (or org-slideboard-text-scale 0))
           0))
        ;; after the zoom command is done
        (run-at-time 0 nil (lambda ()
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (org-slideboard--set-text-scale
                                  (get-buffer-window-list buf nil t)))))))
       ((or (equal (buffer-name) org-slideboard--page-buffer)
            (and (not (buffer-base-buffer))
                 org-slideboard-presentation-file
                 (equal buffer-file-name
                        (expand-file-name org-slideboard-presentation-file))))
        (let ((scale (if (equal (buffer-name) org-slideboard--page-buffer)
                         org-slideboard-page-text-scale
                       org-slideboard-title-text-scale)))
          (run-at-time 0 nil (lambda ()
                               (when (buffer-live-p buf)
                                 (with-current-buffer buf
                                   (let ((org-slideboard--scaling t))
                                     (text-scale-set (or scale 0))))
                                 (message "Titles keep their size"))))))))))


(defun org-slideboard-increase-text-size ()
  "Increase the text size of all frames of all slides.
Slide titles keep their size.  To change one frame only, use
\\[org-slideboard-increase-frame-text-size]."
  (interactive)
  (org-slideboard--change-text-scale 1))


(defun org-slideboard-decrease-text-size ()
  "Decrease the text size of all frames of all slides.
See `org-slideboard-increase-text-size'."
  (interactive)
  (org-slideboard--change-text-scale -1))

;;* Menu and org-slideboard-mode

(defvar org-slideboard-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [next] 'org-slideboard-next-slide)
    (define-key map [prior] 'org-slideboard-previous-slide)

    ;; F5-F9 are reserved for users, and C-c C-<letter> for major modes;
    ;; C-c followed by { } < > : ; is for minor modes like this one
    (define-key map (kbd "C-c ;") 'org-slideboard-execute-slide)
    (define-key map (kbd "C--") 'org-slideboard-decrease-text-size)
    (define-key map (kbd "C-=") 'org-slideboard-increase-text-size)
    (define-key map (kbd "C-c }") 'org-slideboard-increase-frame-text-size)
    (define-key map (kbd "C-c {") 'org-slideboard-decrease-frame-text-size)
    (define-key map (kbd "\e\eg") 'org-slideboard-goto-slide)
    (define-key map (kbd "\e\et") 'org-slideboard-toc)
    (define-key map (kbd "\e\eq") 'org-slideboard-stop-slideshow)
    (define-key map (kbd "\e\e0") 'org-slideboard-reset-text-size)
    map)
  "Keys of the show, active only in slide windows.
They work in the title strip, the frames and the title and section
pages of a show, see `org-slideboard-keys-mode', so they do not
shadow your own keys in other buffers.  Change them with `define-key'
or `keymap-set' on this map.")


(easy-menu-define org-slideboard-menu org-slideboard-keys-mode-map "Menu for org-slideboard."
  '("org-slideboard"
    ["Start slide show" org-slideboard-start-slideshow t]
    ["Next slide" org-slideboard-next-slide t]
    ["Previous slide" org-slideboard-previous-slide t]
    ["Open this slide" org-slideboard-open-slide t]
    ["Goto slide" org-slideboard-goto-slide t]
    ["Table of contents" org-slideboard-toc t]
    ["Stop slide show"  org-slideboard-stop-slideshow t]))


(define-minor-mode org-slideboard-keys-mode
  "Minor mode for the keys of a show, in the buffers of its slides.
It is turned on in the title strip, the frames and the title and
section pages while `org-slideboard-mode' runs a show.  Other buffers,
such as a REPL or another file, keep your own keys.

\\{org-slideboard-keys-mode-map}"
  :lighter nil
  :keymap org-slideboard-keys-mode-map)

;;;###autoload
(define-minor-mode org-slideboard-mode
  "Minor mode for presenting Org files as slides.
It is on while a show runs: `org-slideboard-start-slideshow' turns it
on, and turning it off stops the show.  The keys of the show are in
`org-slideboard-keys-mode-map', active only in slide windows, see
`org-slideboard-keys-mode'."
  :init-value nil
  :lighter " org-slideboard"
  :global t
  :group 'org-slideboard
  ;; https://www.gnu.org/software/emacs/manual/html_node/elisp/Minor-Mode-Conventions.html
  (if org-slideboard-mode
      (when (bound-and-true-p flyspell-mode)
        (setq org-slideboard--flyspell t)
        (flyspell-mode-off))
    ;; restore flyspell
    (when org-slideboard--flyspell
      (flyspell-mode-on)
      (setq org-slideboard--flyspell nil))

    ;; close the show.
    (when org-slideboard--running
      (org-slideboard-stop-slideshow))))

;;* Make slideboard-elisp blocks executable

;; this is tricker than I thought. It seems babel usually runs in some
;; sub-process and I need the code to be executed in the current buffer.
(defun org-babel-execute:slideboard-elisp (_body _params)
  "Evaluate a slideboard-elisp block in the current buffer.
Such blocks are run when their slide is shown, and can change the
slide's arrangement."
  (let ((src (org-element-context)))
    (save-excursion
      (goto-char (org-element-property :begin src))
      (re-search-forward (org-element-property :value src))
      (eval-region (match-beginning 0) (match-end 0)))))

;; * help
(defun org-slideboard-help ()
  "Show the org-slideboard documentation.
Open README.org when it is next to the library, as in a git checkout,
and the README on the web otherwise."
  (interactive)
  (let ((readme (expand-file-name "README.org"
                                  (file-name-directory
                                   (locate-library "org-slideboard")))))
    (if (file-exists-p readme)
        (find-file readme)
      (browse-url "https://github.com/vikasrawal/org-slideboard#readme"))))



;;* The end

(provide 'org-slideboard)

;;; org-slideboard.el ends here
