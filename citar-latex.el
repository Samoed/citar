;;; citar-latex.el --- Latex adapter for citar -*- lexical-binding: t; -*-

;; Copyright (C) 2021 Bruce D'Arcus

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
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A small package that provides the functions required to use citar
;; with latex.

;; Simply loading this file will enable manipulating the citations with
;; commands provided by citar.

;;; Code:

(require 'citar)
(require 'tex nil t)
(require 'reftex-parse)
(require 'reftex-cite)

(defvar citar-major-mode-functions)

(defcustom citar-latex-cite-commands
  '((("cite" "Cite" "citet" "Citet" "citep" "Citep" "parencite"
      "Parencite" "footcite" "footcitetext" "textcite" "Textcite"
      "smartcite" "Smartcite" "cite*" "parencite*" "autocite"
      "Autocite" "autocite*" "Autocite*" "citeauthor" "Citeauthor"
      "citeauthor*" "Citeauthor*" "citetitle" "citetitle*" "citeyear"
      "citeyear*" "citedate" "citedate*" "citeurl" "fullcite"
      "footfullcite" "notecite" "Notecite" "pnotecite" "Pnotecite"
      "fnotecite") . (["Prenote"] ["Postnote"] t))
    (("nocite" "supercite") . nil))
  "Citation commands and their argument specs.

The argument spec is the same as the args argument of
`TeX-parse-macro'. When calling `citar-insert-citation' the keys
will be inserted at the position where `TeX-parse-macro' leaves
the point."
  :group 'citar-latex
  :type '(alist :key-type (repeat string)
                :value-type sexp))

(defcustom citar-latex-prompt-for-cite-style t
  "Whether to prompt for a citation command when inserting."
  :group 'citar
  :type '(radio (const :tag "Prompt for a command" t)
                (const :tag "Do not prompt for a command" nil))
  :safe 'always)

(defcustom citar-latex-default-cite-command "cite"
  "Default command for citations.

Must be in `citar-latex-cite-commands'. Used when as a cite
command when prompting for one is disabled, and as the default
entry when it is enabled."
  :group 'citar
  :type 'string
  :safe 'always)

(defcustom citar-latex-prompt-for-extra-arguments t
  "Whether to prompt for additional arguments when inserting a citation."
  :group 'citar-latex
  :type 'boolean)

;;;###autoload
(defun citar-latex-local-bib-files ()
  "Local bibliographic for latex retrieved using reftex."
  (reftex-access-scan-info t)
  (ignore-errors (reftex-get-bibfile-list)))

;;;###autoload
(defun citar-latex-key-at-point ()
  "Return citation key at point with its bounds.
  
The return value is (KEY . BOUNDS), where KEY is the citation key
at point and BOUNDS is a pair of buffer positions.  

Return nil if there is no key at point."
  (save-excursion
    (when-let* ((bounds (citar-latex--macro-bounds))
                (keych "^,{}")
                (beg (progn (skip-chars-backward keych (car bounds)) (point)))
                (end (progn (skip-chars-forward keych (cdr bounds)) (point)))
                (pre (buffer-substring-no-properties (car bounds) beg))
                (post (buffer-substring-no-properties end (cdr bounds))))
      (and (string-match-p "{\\([^{}]*,\\)?\\'" pre)  ; preceded by { ... ,
           (string-match-p "\\`\\(,[^{}]*\\)?}" post) ; followed by , ... }
           (goto-char beg)
           (looking-at (concat "[[:space:]]*\\([" keych "]+?\\)[[:space:]]*[,}]"))
           (cons (match-string-no-properties 1)
                 (cons (match-beginning 1) (match-end 1)))))))

;;;###autoload
(defun citar-latex-citation-at-point ()
  "Find citation macro at point and extract keys.
  
Find brace-delimited strings inside the bounds of the macro,
splits them at comma characters, and trims whitespace.

Return (KEYS . BOUNDS), where KEYS is a list of the found
citation keys and BOUNDS is a pair of buffer positions indicating
the start and end of the citation macro."
  (save-excursion
    (when-let ((bounds (citar-latex--macro-bounds)))
      (let ((keylists nil))
        (goto-char (car bounds))
        (while (re-search-forward "{\\([^{}]*\\)}" (cdr bounds) 'noerror)
          (push (split-string (match-string-no-properties 1) "," t "[[:space:]]*")
                keylists))
        (cons (apply #'append (nreverse keylists))
              bounds)))))

(defun citar-latex--macro-bounds ()
  "Return the bounds of the citation macro at point.
  
Return a pair of buffer positions indicating the beginning and
end of the enclosing citation macro, or nil if point is not
inside a citation macro."
  (unless (fboundp 'TeX-find-macro-boundaries)
    (error "Please install AUCTeX"))
  (save-excursion
    (when-let* ((bounds (TeX-find-macro-boundaries))
                (macro (progn (goto-char (car bounds))
                              (looking-at (concat (regexp-quote TeX-esc)
                                                  "\\([@A-Za-z]+\\)"))
                              (match-string-no-properties 1))))
      (when (citar-latex-is-a-cite-command macro)
        bounds))))

(defvar citar-latex-cite-command-history nil
  "Variable for history of cite commands.")

;;;###autoload
(defun citar-latex-insert-citation (keys &optional invert-prompt command)
  "Insert a citation consisting of KEYS.

If the command is inside a citation command keys are added to it. Otherwise
a new command is started.

If the optional COMMAND is provided use it (ignoring INVERT-PROMPT).
Otherwise prompt for a citation command, depending on the value of
`citar-latex-prompt-for-cite-style'. If INVERT-PROMPT is non-nil, invert
whether or not to prompt.

The availiable commands and how to provide them arguments are configured
by `citar-latex-cite-commands'.

If `citar-latex-prompt-for-extra-arguments' is `nil`, every
command is assumed to have a single argument into which keys are
inserted."
  (unless (fboundp 'TeX-current-macro)
    (error "Please install AUCTeX"))
  (when keys
    (if (citar-latex-is-a-cite-command (TeX-current-macro))
        (progn (skip-chars-forward "^,}")
               (unless (equal ?} (preceding-char)) (insert ", ")))
      (let ((macro
	     (or command
		 (if (xor invert-prompt citar-latex-prompt-for-cite-style)
                     (completing-read "Cite command: "
                                      (seq-mapcat #'car citar-latex-cite-commands)
                                      nil nil nil
                                      'citar-latex-cite-command-history
				      citar-latex-default-cite-command nil))
	       citar-latex-default-cite-command)))
        (TeX-parse-macro macro
                         (when citar-latex-prompt-for-extra-arguments
                           (cdr (citar-latex-is-a-cite-command macro))))))
    (citar--insert-keys-comma-separated keys)
    (skip-chars-forward "^}") (forward-char 1)))

;;;###autoload
(defun citar-latex-insert-edit (&optional arg)
  "Prompt for keys and call `citar-latex-insert-citation.
With ARG non-nil, rebuild the cache before offering candidates."
  (citar-latex-insert-citation
   (citar--extract-keys (citar-select-refs :rebuild-cache arg))))

(defun citar-latex-is-a-cite-command (command)
  "Return element of `citar-latex-cite-commands` containing COMMAND."
  (seq-find (lambda (x) (member command (car x)))
            citar-latex-cite-commands))

(provide 'citar-latex)
;;; citar-latex.el ends here
