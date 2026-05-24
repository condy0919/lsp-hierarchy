;;; lsp-hierarchy.el --- LSP hierarchy views -*- lexical-binding: t; -*-

;; Copyright (C) 2026-2026 Zhiwei Chen

;; Author: Zhiwei Chen <condy0919@gmail.com>
;; Keywords: languages, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lsp-mode "9.0") (hierarchy "1.0"))
;; Homepage: https://github.com/condy0919/lsp-hierarchy
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
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

;; LSP hierarchy views fully powered by Emacs' built-in `hierarchy.el' data engine.

;;; Code:

(require 'lsp-mode)
(require 'cl-lib)
(require 'outline)
(require 'hierarchy)

;;; Customization

(defgroup lsp-hierarchy nil
  "LSP hierarchy views."
  :group 'lsp-mode
  :link '(url-link "https://github.com/condy0919/lsp-hierarchy"))

(defcustom lsp-hierarchy-expand-depth 1
  "Initial expansion depth."
  :type 'integer
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-detailed-outline t
  "Include signatures in symbol labels."
  :type 'boolean
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-icon-close "▶"
  "Text icon used for closed sections."
  :type 'string
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-icon-open "▼"
  "Text icon used for opened sections."
  :type 'string
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-node-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for symbol/function nodes."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-detail-face
  '((t :inherit shadow))
  "Face for detail and line info."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-icon-face
  '((t :inherit shadow))
  "Face for the expansion icons."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-call-site-face
  '((t :inherit highlight))
  "Face for the target symbol in code lines."
  :group 'lsp-hierarchy)

(defun lsp-hierarchy--kind-abbrev (kind)
  "Return a short abbreviation for LSP symbol KIND."
  (cl-case kind
    (5 "c") (6 "m") (9 "M") (11 "I") (12 "f")
    (23 "s") (10 "e") (14 "C") (7 "p") (8 "v") (1 "F")
    (t "")))

;;; Core: Buffer State & Hash Storage

(defvar-local lsp-hierarchy--source-buffer nil
  "The buffer from which the hierarchy was requested.")
(defvar-local lsp-hierarchy--state-table nil "Hash table mapping item to its open/close state.")
(defvar-local lsp-hierarchy--loaded-table nil "Hash table mapping item to t if loaded.")
(defvar-local lsp-hierarchy--loading-table nil "Hash table mapping item to t if loading.")

;;; Core: Rendering Engine

(defun lsp-hierarchy--match-node-label (limit)
  "Match function for font-lock to identify symbol node labels up to LIMIT.
This identifies the symbol name and its signature/details by looking
for the `lsp-hierarchy-label-bound' property and parsing the text."
  (let ((found nil))
    (while (and (not found) (< (point) limit))
      (let ((bound (get-text-property (point) 'lsp-hierarchy-label-bound))
            (next-change (next-single-property-change (point) 'lsp-hierarchy-label-bound nil limit)))
        (if bound
            (let* ((beg (point))
                   (end (or next-change limit))
                   (label (buffer-substring-no-properties beg end)))
              (if (string-match "\\([^ ]+\\)\\( +\\(.+\\)\\)?" label)
                  (let* ((name-len (length (match-string 1 label)))
                         (sig-beg-idx (match-beginning 3))
                         (name-end beg)
                         (sig-beg end)
                         (sig-end end))
                    (setq name-end (+ beg name-len))
                    (when sig-beg-idx
                      (setq sig-beg (+ beg sig-beg-idx))
                      (setq sig-end end))
                    (set-match-data (list beg end
                                          beg name-end
                                          (+ beg (match-beginning 2)) end
                                          sig-beg sig-end)))
                (set-match-data (list beg end beg end)))
              (goto-char end)
              (setq found t))
          (goto-char (or next-change limit)))))
    found))

(defun lsp-hierarchy--insert-node (item indent hierarchy)
  "Render and insert hierarchy ITEM at INDENT level within HIERARCHY context.
The rendered line includes indentation, expansion icons (for symbols),
LSP kind abbreviations, the symbol label, and any extra details."
  (let* ((type (plist-get item :type))
         (label (plist-get item :label))
         (kind (plist-get item :kind))
         (detail (plist-get item :detail))
         (cfn (plist-get item :children-fn))
         (beg (point)))
    (insert (make-string (* indent 2) ?\s))

    (when (eq type 'code)
      (insert "    " label))

    (when (eq type 'symbol)
      (if (or cfn (hierarchy-children hierarchy item))
          (insert (propertize "@" 'lsp-hierarchy-icon-marker t) " ")
        (insert "  "))
      (when-let* ((abbrev (lsp-hierarchy--kind-abbrev kind)))
        (unless (string-empty-p abbrev)
          (insert "[" abbrev "] ")))

      (let ((l-beg (point)))
        (insert label)
        (add-text-properties l-beg (point) '(lsp-hierarchy-label-bound t))))

    (when detail
      (insert " " detail))

    (add-text-properties beg (point)
                         (list 'lsp-hierarchy-item item
                               'lsp-hierarchy-tree hierarchy
                               'lsp-hierarchy-indent indent))
    (insert "\n")))

(defun lsp-hierarchy--get-prop (prop)
  "Get text property PROP on the current line."
  (save-excursion
    (let* ((beg (line-beginning-position))
           (end (line-end-position))
           (pos beg)
           (val nil))
      (setq val (get-text-property pos prop))
      (while (and (not val)
                  (< pos end)
                  (setq pos (next-single-property-change pos prop nil end)))
        (setq val (get-text-property pos prop)))
      val)))

;;; Core: Interaction Logic

(defun lsp-hierarchy--set-subtree-visibility (flag)
  "Set visibility of the current node's subtree based on FLAG.
FLAG can be either \='hide or \='show."
  (let ((inhibit-read-only t)
        (current-indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent)))
    (when current-indent
      (save-excursion
        (forward-line 1)
        (let ((keep-going t))
          (while (and keep-going (not (eobp)))
            (let ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
                  (indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent)))
              (if (and indent (> indent current-indent))
                  (progn
                    (outline-flag-region (line-beginning-position)
                                         (1+ (line-end-position))
                                         (if (eq flag 'hide) t nil))
                    (when (and (eq flag 'show)
                               item
                               (eq (gethash item lsp-hierarchy--state-table) 'close))
                      (let ((sub-indent indent))
                        (forward-line 1)
                        (while (let ((next-indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent)))
                                 (and next-indent (> next-indent sub-indent) (not (eobp))))
                          (forward-line 1))
                        (forward-line -1)))
                    (forward-line 1))
                (setq keep-going nil)))))))))

(defun lsp-hierarchy-toggle ()
  "Toggle node at point, loading children if necessary."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (h (lsp-hierarchy--get-prop 'lsp-hierarchy-tree))
         (indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent))
         (type (plist-get item :type))
         (cfn (plist-get item :children-fn)))
    (unless item
      (user-error "No node here"))
    (if (eq type 'code)
        (forward-line 1)
      (cond
       ((gethash item lsp-hierarchy--loading-table)
        (message "LSP: Loading children, please wait..."))

       ((gethash item lsp-hierarchy--loaded-table)
        (let ((current-state (gethash item lsp-hierarchy--state-table)))
          (if (eq current-state 'open)
              (progn
                (lsp-hierarchy--set-subtree-visibility 'hide)
                (puthash item 'close lsp-hierarchy--state-table))
            (progn
              (lsp-hierarchy--set-subtree-visibility 'show)
              (puthash item 'open lsp-hierarchy--state-table)))
          (font-lock-flush (line-beginning-position) (line-end-position))))

       (cfn
        (lsp-hierarchy--load-async item indent h))))))

(defun lsp-hierarchy--load-async (item indent hierarchy)
  "Fetch and insert children of ITEM asynchronously.
INDENT is the current indentation level.
HIERARCHY is the hierarchy object used for state management."
  (let* ((cfn (plist-get item :children-fn))
         (precomputed (plist-get item :children))
         (tree-buf (current-buffer))
         (sb lsp-hierarchy--source-buffer)
         (marker (save-excursion
                   (beginning-of-line)
                   (copy-marker (line-beginning-position 2)))))

    (puthash item t lsp-hierarchy--loading-table)
    (puthash item 'open lsp-hierarchy--state-table)
    (font-lock-flush (line-beginning-position) (line-end-position))

    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char marker)
        (let ((beg (point)))
          (insert (make-string (* (1+ indent) 2) ?\s) "  Loading...\n")
          (add-text-properties beg (point) '(lsp-hierarchy-loading t)))))

    (if cfn
        (funcall cfn item sb
                 (lambda (async-children)
                   (when (buffer-live-p tree-buf)
                     (with-current-buffer tree-buf
                       (unwind-protect
                           (save-excursion
                             (let ((inhibit-read-only t))
                               (let ((lp (text-property-any (point-min) (point-max) 'lsp-hierarchy-loading t)))
                                 (when lp
                                   (goto-char lp)
                                   (delete-region (line-beginning-position) (progn (forward-line 1) (point)))))
                               (goto-char marker)
                               (dolist (c (append precomputed async-children))
                                 ;; Register the child node in the hierarchy engine.
                                 (hierarchy-add-tree hierarchy c (lambda (_) item))
                                 (puthash c 'close lsp-hierarchy--state-table)
                                 (lsp-hierarchy--insert-node c (1+ indent) hierarchy))
                               (lsp-hierarchy--set-subtree-visibility 'show)))
                         (set-marker marker nil)
                         (remhash item lsp-hierarchy--loading-table)
                         (puthash item t lsp-hierarchy--loaded-table))))))
      (set-marker marker nil)
      (remhash item lsp-hierarchy--loading-table)
      (puthash item t lsp-hierarchy--loaded-table))))

(defun lsp-hierarchy-goto ()
  "Jump to the source location of the item at point."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (goto-fn (plist-get item :goto-fn)))
    (if goto-fn
        (funcall goto-fn)
      (user-error "No location for this node"))))

(defun lsp-hierarchy-smart-tab ()
  "Smart TAB command for `lsp-hierarchy-mode'."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (h (lsp-hierarchy--get-prop 'lsp-hierarchy-tree))
         (cfn (plist-get item :children-fn)))
    (if (and item (or cfn (hierarchy-children h item)))
        (lsp-hierarchy-toggle)
      (outline-next-heading))))

;;; Regular Expression & Matchers

(defvar lsp-hierarchy--outline-regexp
  (rx line-start (* space) "@")
  "Regular expression to match the start of a hierarchy node line.")

(defvar lsp-hierarchy--detail-regexp
  (rx "[" (or "c" "m" "M" "I" "f" "s" "e" "C" "p" "v" "F") "]")
  "Regular expression to match the LSP symbol kind abbreviation.")

(defun lsp-hierarchy--match-icon-marker (limit)
  "Match function for font-lock to find icon markers up to LIMIT."
  (let ((found nil))
    (while (and (not found) (< (point) limit))
      (let ((marker (get-text-property (point) 'lsp-hierarchy-icon-marker))
            (next-change (next-single-property-change (point) 'lsp-hierarchy-icon-marker nil limit)))
        (if marker
            (progn
              (set-match-data (list (point) (1+ (point))))
              (forward-char 1)
              (setq found t))
          (goto-char (or next-change limit)))))
    found))

(defun lsp-hierarchy--get-icon-properties (start)
  "Return font-lock properties (face and display) for icon at START."
  (let* ((item (get-text-property start 'lsp-hierarchy-item))
         (h (get-text-property start 'lsp-hierarchy-tree))
         (cfn (plist-get item :children-fn)))
    (if (and item (or cfn (hierarchy-children h item)))
        (let ((icon (if (eq (gethash item lsp-hierarchy--state-table) 'open)
                        lsp-hierarchy-icon-open
                      lsp-hierarchy-icon-close)))
          (list 'face 'lsp-hierarchy-icon-face
                'display icon
                'mouse-face 'highlight))
      (list 'face 'default 'display " "))))

;;; Major Mode Definition

(defvar lsp-hierarchy-font-lock-keywords
  `((lsp-hierarchy--match-icon-marker 0 (lsp-hierarchy--get-icon-properties (match-beginning 0)))
    (,lsp-hierarchy--detail-regexp 0 'lsp-hierarchy-detail-face)
    ("(line [[:digit:]]*)" 0 'lsp-hierarchy-detail-face)
    (lsp-hierarchy--match-node-label
     (1 'lsp-hierarchy-node-face)
     (3 'lsp-hierarchy-detail-face t t)))
  "Default font-lock keywords for `lsp-hierarchy-mode'.")

(defvar lsp-hierarchy-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "TAB") #'lsp-hierarchy-smart-tab)
    (define-key map (kbd "<tab>") #'lsp-hierarchy-smart-tab)
    (define-key map (kbd "RET") #'lsp-hierarchy-goto)
    map)
  "Keymap for `lsp-hierarchy-mode'.")

(define-derived-mode lsp-hierarchy-mode special-mode "LSP-Hierarchy"
  "Major mode for viewing LSP hierarchy views.
\\{lsp-hierarchy-mode-map}"
  :interactive nil
  :group 'lsp-hierarchy

  (setq-local outline-minor-mode-cycle nil)
  (setq-local outline-minor-mode-highlight nil)
  (setq-local outline-minor-mode-use-buttons nil)
  (setq-local outline-regexp lsp-hierarchy--outline-regexp)
  (setq-local outline-level (lambda () (1+ (/ (current-indentation) 2))))
  (setq-local outline-minor-mode t)

  (setq-local buffer-undo-list t)
  (setq-local buffer-read-only t)
  (setq-local indent-tabs-mode nil)
  (setq-local truncate-lines t)

  (setq-local lsp-hierarchy--state-table (make-hash-table :test 'equal))
  (setq-local lsp-hierarchy--loaded-table (make-hash-table :test 'equal))
  (setq-local lsp-hierarchy--loading-table (make-hash-table :test 'equal))

  (setq font-lock-defaults '(lsp-hierarchy-font-lock-keywords)))

(defun lsp-hierarchy--display (lsp-roots source-buffer buffer-name title view-type outgoing-or-direction)
  "Display the hierarchy for LSP-ROOTS in BUFFER-NAME.
SOURCE-BUFFER is the original buffer where the request was made.
TITLE is used as the mode name.
VIEW-TYPE is either \='call or \='type.
OUTGOING-OR-DIRECTION specifies the direction of the hierarchy."
  (let ((buf (get-buffer-create buffer-name))
        (h (hierarchy-new)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lsp-hierarchy-mode)
        (setq-local lsp-hierarchy--source-buffer source-buffer)
        (setq mode-name title)
        (dolist (root lsp-roots)
          (let* ((label (if (eq view-type 'call)
                            (lsp-render-symbol root lsp-hierarchy-detailed-outline)
                          (lsp-get root :name)))
                 (item (list :label label
                             :kind (lsp-get root :kind)
                             :lsp-item root
                             :type 'symbol)))
            (setq item
                  (plist-put item :children-fn
                             (if (eq view-type 'call)
                                 (lambda (it s cb) (lsp-hierarchy--call-hierarchy-children it s cb outgoing-or-direction))
                               (lambda (it s cb) (lsp-hierarchy--type-hierarchy-children it s cb outgoing-or-direction)))))
            (when (eq view-type 'type)
              (setq item (plist-put item :goto-fn (lambda () (lsp-hierarchy--open-file (lsp-get root :uri) (lsp-get root :range))))))

            ;; Register the root node in the hierarchy engine.
            (hierarchy-add-tree h item nil)
            (puthash item 'close lsp-hierarchy--state-table)
            (puthash item nil lsp-hierarchy--loaded-table)
            (lsp-hierarchy--insert-node item 0 h))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;; --- LSP Backends & Views Implementation ---

(defun lsp-hierarchy--extract-line (uri range)
  "Extract and format the code line at URI and RANGE."
  (let* ((filename (lsp--uri-to-path uri))
         (start (lsp-get range :start))
         (line-n (lsp-get start :line))
         (c-start (lsp-get start :character))
         (end (lsp-get range :end))
         (c-end (lsp-get end :character))
         (get-fn (lambda ()
                   (save-excursion
                     (goto-char (point-min))
                     (forward-line line-n)
                     (let* ((beg (line-beginning-position))
                            (ep (line-end-position))
                            (txt (buffer-substring beg ep))
                            (len (length txt)))
                       (concat
                        (string-trim-left (substring txt 0 (min c-start len)))
                        (propertize (substring txt (min c-start len) (min c-end len))
                                    'face 'lsp-hierarchy-call-site-face)
                        (substring txt (min c-end len) len)
                        (propertize (format " (line %d)" (1+ line-n)) 'face 'lsp-hierarchy-detail-face)))))))
    (condition-case nil
        (if-let* ((b (find-buffer-visiting filename)))
            (with-current-buffer b (funcall get-fn))
          (with-temp-buffer (insert-file-contents filename) (funcall get-fn)))
      (error (format "call at line %d" (1+ line-n))))))

(defun lsp-hierarchy--open-file (uri range)
  "Open file at URI and jump to RANGE."
  (let ((win (get-mru-window (selected-frame) nil t)))
    (if win
        (select-window win)
      (split-window-right))
    (find-file (lsp--uri-to-path uri))
    (goto-char (lsp--position-to-point (lsp-get range :start)))
    (recenter)))

(defun lsp-hierarchy--call-hierarchy-children (item sb callback outgoing)
  "Fetch children for call hierarchy ITEM.
SB is the source buffer.  CALLBACK is called with the results.
OUTGOING is non-nil for outgoing calls."
  (let* ((method (if outgoing "callHierarchy/outgoingCalls" "callHierarchy/incomingCalls"))
         (lsp-p (plist-get item :lsp-item))
         (parent-uri (lsp-get lsp-p :uri)))
    (with-current-buffer sb
      (lsp-request-async
       method (list :item lsp-p)
       (lambda (res)
         (funcall callback
                  (mapcar
                   (lambda (call)
                     (let* ((tar (if outgoing (lsp:call-hierarchy-outgoing-call-to call) (lsp:call-hierarchy-incoming-call-from call)))
                            (uri (lsp-get tar :uri))
                            (call-uri (if outgoing parent-uri uri)))
                       (list :label (lsp-render-symbol tar lsp-hierarchy-detailed-outline)
                             :kind (lsp-get tar :kind)
                             :lsp-item tar
                             :type 'symbol
                             :goto-fn (lambda () (lsp-hierarchy--open-file uri (lsp-get tar :selectionRange)))
                             :children (mapcar (lambda (r)
                                                 (list :label (lsp-hierarchy--extract-line call-uri r)
                                                       :type 'code
                                                       :goto-fn (lambda () (lsp-hierarchy--open-file call-uri r))))
                                               (append (lsp-get call :fromRanges) nil))
                             :children-fn (lambda (it s cb) (lsp-hierarchy--call-hierarchy-children it s cb outgoing)))))
                   res)))
       :mode 'detached))))

;;;###autoload
(defun lsp-show-call-hierarchy (&optional outgoing)
  "Show the call hierarchy asynchronously.
If OUTGOING is non-nil (or when called with a prefix argument),
show outgoing calls.  Otherwise, show incoming calls."
  (interactive "P")
  (unless (lsp-feature? "textDocument/prepareCallHierarchy")
    (user-error "Call hierarchy not supported by the current servers: %s"
                (-map #'lsp--workspace-print (lsp-workspaces))))
  (let ((sb (current-buffer)))
    (lsp-request-async
     "textDocument/prepareCallHierarchy" (lsp--text-document-position-params)
     (lambda (roots)
       (lsp-hierarchy--display roots sb "*LSP Call Hierarchy*"
                               (if outgoing "Outgoing Calls" "Incoming Calls") 'call outgoing))
     :mode 'detached)))

;;;###autoload
(defun lsp-show-type-hierarchy (&optional super)
  "Show the type hierarchy asynchronously.
If SUPER is non-nil (or when called with a prefix argument),
show supertypes.  Otherwise, show subtypes."
  (interactive "P")
  (unless (lsp--find-workspaces-for "textDocument/typeHierarchy")
    (user-error "Type hierarchy not supported by the current servers: %s"
                (-map #'lsp--workspace-print (lsp-workspaces))))
  (let ((sb (current-buffer))
        (direction (if super 'supertypes 'subtypes)))
    (lsp-request-async
     "textDocument/prepareTypeHierarchy" (lsp--text-document-position-params)
     (lambda (roots)
       (lsp-hierarchy--display roots sb "*LSP Type Hierarchy*"
                               (if super "Supertypes" "Subtypes") 'type direction))
     :mode 'detached)))

(defun lsp-hierarchy--type-hierarchy-children (item sb callback direction)
  "Fetch children for type hierarchy ITEM.
SB is the source buffer.  CALLBACK is called with the results.
DIRECTION is \='supertypes or \='subtypes."
  (let ((method (if (eq direction 'supertypes) "typeHierarchy/supertypes" "typeHierarchy/subtypes"))
        (lsp-it (plist-get item :lsp-item)))
    (with-current-buffer sb
      (lsp-request-async
       method (list :item lsp-it)
       (lambda (res)
         (funcall callback
                  (mapcar (lambda (it)
                            (list :label (concat (lsp-get it :name) (if (eq direction 'supertypes) " ↑" " ↓"))
                                  :kind (lsp-get it :kind)
                                  :lsp-item it
                                  :type 'symbol
                                  :goto-fn (lambda () (lsp-hierarchy--open-file (lsp-get it :uri) (lsp-get it :range)))
                                  :children-fn (lambda (it sb cb) (lsp-hierarchy--type-hierarchy-children it sb cb direction))))
                          res)))
       :mode 'detached))))

(provide 'lsp-hierarchy)
;;; lsp-hierarchy.el ends here
