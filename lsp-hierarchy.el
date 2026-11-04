;;; lsp-hierarchy.el --- LSP hierarchy views -*- lexical-binding: t; -*-

;; Copyright (C) 2026-2026 Zhiwei Chen

;; Author: Zhiwei Chen <condy0919@gmail.com>
;; Keywords: languages, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lsp-mode "9.0"))
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

;; Asynchronous call and type hierarchy views backed by explicit node data.

;;; Code:

(require 'lsp-mode)
(require 'cl-lib)
(require 'outline)
(require 'seq)
(require 'xref)

;;; Customization

(defgroup lsp-hierarchy nil
  "LSP hierarchy views."
  :group 'lsp-mode
  :link '(url-link "https://github.com/condy0919/lsp-hierarchy"))

(defcustom lsp-hierarchy-expand-depth 1
  "Initial expansion depth.
Zero leaves roots closed; one loads their immediate children."
  :type 'natnum
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

;;; Core: View and Node State

(cl-defstruct (lsp-hierarchy--node (:constructor lsp-hierarchy--make-node))
  "One occurrence of an LSP item in a hierarchy view.
Each occurrence has independent expansion and request state, even when
several paths lead to the same protocol item."
  (id (make-symbol "lsp-hierarchy-node"))
  workspace lsp-item type name kind detail annotation uri range parent children call-sites
  ;; Expansion is a user choice; loading can finish while a node is folded.
  expanded (load-state 'unloaded) request error)

(cl-defstruct (lsp-hierarchy--view (:constructor lsp-hierarchy--make-view))
  "Resources and query context owned by one hierarchy buffer."
  source kind direction roots
  (generation (make-symbol "lsp-hierarchy-view"))
  (requests (make-hash-table :test 'eq))
  (file-cache (make-hash-table :test 'equal))
  (nodes (make-hash-table :test 'eq)))

(defvar-local lsp-hierarchy--view nil
  "The model and resources owned by this buffer.")

(defun lsp-hierarchy--cancel-request (token)
  "Cancel TOKEN and release handlers even when sending cancellation fails."
  (let ((lsp--cur-workspace nil)
        (request (gethash token lsp--cancelable-requests)))
    (unwind-protect
        (ignore-errors (lsp-cancel-request-by-token token))
      ;; A disconnected server must not leave callbacks and source-buffer
      ;; hooks retaining a view which has already been replaced.
      (when request
        (dolist (workspace (cdr request))
          (remhash (car request)
                   (lsp--client-response-handlers (lsp--workspace-client workspace))))
        (lsp--request-cleanup-hooks (car request))
        (remhash token lsp--cancelable-requests)))))

(defun lsp-hierarchy--dispose ()
  "Invalidate the view and cancel all of its pending requests."
  ;; Local kill hooks can survive a major-mode change after view locals are gone.
  (when (lsp-hierarchy--view-p lsp-hierarchy--view)
    (setf (lsp-hierarchy--view-generation lsp-hierarchy--view) nil)
    (when (lsp-hierarchy--view-requests lsp-hierarchy--view)
      (maphash (lambda (token _) (lsp-hierarchy--cancel-request token)) (lsp-hierarchy--view-requests lsp-hierarchy--view))
      (clrhash (lsp-hierarchy--view-requests lsp-hierarchy--view)))
    (when (lsp-hierarchy--view-file-cache lsp-hierarchy--view)
      (maphash (lambda (_ entry)
                 (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
               (lsp-hierarchy--view-file-cache lsp-hierarchy--view))
      (clrhash (lsp-hierarchy--view-file-cache lsp-hierarchy--view)))))

(defun lsp-hierarchy--error-message (err)
  "Format a protocol error, Lisp condition or string ERR."
  (cond
   ((stringp err) err)
   ((and (consp err) (symbolp (car err)) (get (car err) 'error-conditions))
    (error-message-string err))
   (t (or (ignore-errors (lsp--error-string err)) (format "%s" err)))))

(defconst lsp-hierarchy--method-requirements
  '(("textDocument/prepareCallHierarchy" :capability :callHierarchyProvider)
    ("textDocument/prepareTypeHierarchy" :capability :typeHierarchyProvider)
    ("callHierarchy/incomingCalls"
     :check-command lsp-hierarchy--call-supported-p)
    ("callHierarchy/outgoingCalls"
     :check-command lsp-hierarchy--call-supported-p)
    ("typeHierarchy/supertypes"
     :check-command lsp-hierarchy--type-supported-p)
    ("typeHierarchy/subtypes"
     :check-command lsp-hierarchy--type-supported-p))
  "Standard hierarchy methods missing from some lsp-mode versions.
Bind these locally around hierarchy requests; do not alter other clients
of lsp-mode or replace requirements already supplied by the user.")

(defun lsp-hierarchy--call-supported-p (workspace)
  "Return non-nil if WORKSPACE supports preparing a call hierarchy."
  (with-lsp-workspace workspace
    (lsp-feature? "textDocument/prepareCallHierarchy")))

(defun lsp-hierarchy--type-supported-p (workspace)
  "Return non-nil if WORKSPACE supports preparing a type hierarchy."
  (with-lsp-workspace workspace
    (lsp-feature? "textDocument/prepareTypeHierarchy")))

(defun lsp-hierarchy--request (source method params success &optional failure token workspaces no-merge)
  "Send METHOD and PARAMS from SOURCE for the current hierarchy view.
Call SUCCESS or FAILURE at most once in the current view generation.
TOKEN permits cancellation.  WORKSPACES restricts routing when supplied;
NO-MERGE preserves workspace ownership of responses."
  (let ((view (current-buffer))
        (model lsp-hierarchy--view)
        (generation (lsp-hierarchy--view-generation lsp-hierarchy--view))
        (token (or token (make-symbol "lsp-hierarchy-request"))))
    (puthash token t (lsp-hierarchy--view-requests lsp-hierarchy--view))
    (cl-labels ((finish (fn result)
                 (when (buffer-live-p view)
                   (with-current-buffer view
                     (when (and (eq model lsp-hierarchy--view)
                                (eq generation (lsp-hierarchy--view-generation model))
                                (gethash token (lsp-hierarchy--view-requests lsp-hierarchy--view)))
                       (remhash token (lsp-hierarchy--view-requests lsp-hierarchy--view))
                       (when fn (funcall fn result)))))))
      (condition-case err
          (progn
            (unless (buffer-live-p source)
              (user-error "The hierarchy source buffer has been killed"))
            (with-current-buffer source
              (let ((lsp--cur-workspace nil))
                (when (and workspaces
                           (not (cl-every (lambda (workspace) (memq workspace (lsp-workspaces))) workspaces)))
                  (user-error "The hierarchy language server is no longer attached"))
                (let ((lsp--buffer-workspaces (or workspaces (lsp-workspaces)))
                      (lsp-method-requirements
                       (append lsp-method-requirements lsp-hierarchy--method-requirements)))
                  (lsp-request-async
                 method params (lambda (result) (finish success result))
                 :error-handler (lambda (error) (finish failure error))
                 :cancel-handler (lambda () (finish failure "Request cancelled"))
                 :cancel-token token :mode 'alive :no-merge no-merge)))))
        (error
         (lsp-hierarchy--cancel-request token)
         (finish failure err))))))

;;; Core: Rendering Engine

(defun lsp-hierarchy--insert-node (item indent)
  "Insert ITEM at INDENT using its structured name and location."
  (let ((beg (point)))
    (insert (make-string (* indent 2) ?\s))
    (pcase (lsp-hierarchy--node-type item)
      ('code
       ;; Source reads stay lazy: unopened siblings contain only locations.
       (insert "    " (lsp-hierarchy--extract-line
                        (lsp-hierarchy--node-uri item)
                        (lsp-hierarchy--node-range item)
                        (lsp-hierarchy--node-workspace item))))
      ('symbol
       (insert (apply #'propertize "@" 'lsp-hierarchy-icon-marker t
                      (lsp-hierarchy--icon-properties item)) " ")
       (let ((abbrev (lsp-hierarchy--kind-abbrev (lsp-hierarchy--node-kind item))))
         (unless (string-empty-p abbrev)
           (insert (propertize (concat "[" abbrev "] ")
                               'face 'lsp-hierarchy-detail-face))))
       ;; Names may contain spaces.  Style protocol fields directly instead
       ;; of parsing a formatted label back into name and signature.
       (insert (propertize (lsp-hierarchy--node-name item) 'face 'lsp-hierarchy-node-face))
       (when-let* ((detail (and lsp-hierarchy-detailed-outline
                               (lsp-hierarchy--node-detail item)))
                   ((not (string-empty-p detail))))
         (insert (propertize (concat " " (string-trim-left detail))
                             'face 'lsp-hierarchy-detail-face)))
       (when-let* ((annotation (lsp-hierarchy--node-annotation item)))
         (insert (propertize annotation 'face 'lsp-hierarchy-detail-face)))))
    (add-text-properties beg (point)
                         (list 'lsp-hierarchy-item item
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
  "Apply FLAG (hide or show) while preserving descendant expansion states."
  (let ((inhibit-read-only t)
        (indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent)))
    (when indent
      (save-excursion
        ;; A response may arrive after an ancestor was folded.  New rows
        ;; inherit that hidden state even if this node is still expanded.
        (let ((hidden-depth (when (or (eq flag 'hide) (invisible-p (point))) indent)))
          (forward-line 1)
          (while (and (not (eobp))
                      (> (or (lsp-hierarchy--get-prop 'lsp-hierarchy-indent) -1) indent))
            (let ((depth (lsp-hierarchy--get-prop 'lsp-hierarchy-indent))
                  (child (lsp-hierarchy--get-prop 'lsp-hierarchy-item)))
              (when (and hidden-depth (<= depth hidden-depth)) (setq hidden-depth nil))
              (outline-flag-region (line-beginning-position) (line-beginning-position 2)
                                   (and hidden-depth t))
              (when (and (not hidden-depth) child
                         (not (lsp-hierarchy--node-expanded child)))
                (setq hidden-depth depth)))
            (forward-line 1)))))))

(defun lsp-hierarchy--expandable-p (node)
  "Return non-nil if NODE has children or has not yet resolved them.
An empty successful response is a leaf; an error remains retryable."
  (and node
       (eq (lsp-hierarchy--node-type node) 'symbol)
       (or (not (eq (lsp-hierarchy--node-load-state node) 'loaded))
           (lsp-hierarchy--node-children node))))

(defun lsp-hierarchy-toggle ()
  "Toggle node at point, loading children if necessary."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent)))
    (unless item
      (user-error "No node here"))
    (if (not (lsp-hierarchy--expandable-p item))
        (forward-line 1)
      (cond
       ((or (eq (lsp-hierarchy--node-load-state item) 'loaded)
            (eq (lsp-hierarchy--node-load-state item) 'loading))
        (let ((current-state (lsp-hierarchy--node-expanded item)))
          (if current-state
              (progn
                (lsp-hierarchy--set-subtree-visibility 'hide)
                (setf (lsp-hierarchy--node-expanded item) nil))
            (progn
              (lsp-hierarchy--set-subtree-visibility 'show)
              (setf (lsp-hierarchy--node-expanded item) t)))
          (lsp-hierarchy--update-icon)))

       ((eq (lsp-hierarchy--node-type item) 'symbol)
        (lsp-hierarchy--load-async item indent))))))

(defun lsp-hierarchy--load-async (item indent &optional depth)
  "Load ITEM at INDENT, expanding up to DEPTH levels."
  (let* ((depth (or depth 1))
         (precomputed (lsp-hierarchy--node-call-sites item))
         (source (lsp-hierarchy--view-source lsp-hierarchy--view))
         (origin (copy-marker (line-beginning-position) t))
         (marker (copy-marker (line-beginning-position 2)))
         (token (make-symbol "lsp-hierarchy-node-request"))
         placeholder)
    (setf (lsp-hierarchy--node-request item) token
          (lsp-hierarchy--node-load-state item) 'loading
          (lsp-hierarchy--node-error item) nil)
    (setf (lsp-hierarchy--node-expanded item) t)
    (lsp-hierarchy--update-icon)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char marker)
        (let ((beg (point)))
          (insert (make-string (* (1+ indent) 2) ?\s) "  Loading...\n")
          ;; Status rows take part in folding but are not symbol nodes.
          (add-text-properties beg (point)
                               (list 'lsp-hierarchy-loading t
                                     'lsp-hierarchy-indent (1+ indent)
                                     'lsp-hierarchy-item nil))
          ;; Responses can finish out of order.  Each request owns its row;
          ;; searching the buffer for the first loading marker is ambiguous.
          (setq placeholder (make-overlay beg (point)))
          (overlay-put placeholder 'evaporate t))))
    (cl-labels
        ((remove-loading ()
           (when-let* ((pos (overlay-start placeholder)))
             (goto-char pos)
             (delete-region pos (overlay-end placeholder))
             (delete-overlay placeholder)))
         (finish ()
           (setf (lsp-hierarchy--node-request item) nil)
           (set-marker marker nil)
           (set-marker origin nil))
         (fail (err)
           (let ((inhibit-read-only t))
             (save-excursion
               (remove-loading)
               (setf (lsp-hierarchy--node-expanded item) nil)
               (setf (lsp-hierarchy--node-load-state item) 'error
                     (lsp-hierarchy--node-error item) err)
               (goto-char origin)
               (lsp-hierarchy--update-icon)))
           (finish)
           (message "LSP hierarchy: %s (TAB to retry)" (lsp-hierarchy--error-message err)))
         (succeed (children)
           (condition-case err
               (let* ((inhibit-read-only t)
                      (nodes (append precomputed children))
                      (view lsp-hierarchy--view)
                      ;; Finish rendering before publishing any child.  An
                      ;; invalid row must not leave half a response to retry.
                      (text (with-temp-buffer
                              (setq-local lsp-hierarchy--view view)
                              (dolist (child nodes)
                                (lsp-hierarchy--insert-node child (1+ indent)))
                              (buffer-string))))
                 (save-excursion
                   (remove-loading)
                   (goto-char marker)
                   (atomic-change-group (insert text))
                   (dolist (child nodes)
                     (setf (lsp-hierarchy--node-parent child) item)
                     (puthash (lsp-hierarchy--node-id child) child
                              (lsp-hierarchy--view-nodes view)))
                   (setf (lsp-hierarchy--node-load-state item) 'loaded
                         (lsp-hierarchy--node-children item) nodes)
                   (goto-char origin)
                   (lsp-hierarchy--set-subtree-visibility
                    (if (lsp-hierarchy--node-expanded item) 'show 'hide))
                   (lsp-hierarchy--update-icon))
                 ;; Expansion uses node identity after insertion, not markers
                 ;; allocated while an incomplete response is being rendered.
                 (when (and (> depth 1) (lsp-hierarchy--node-expanded item)
                            (not (invisible-p origin)))
                   (dolist (child nodes)
                     (when (eq (lsp-hierarchy--node-type child) 'symbol)
                       (save-excursion
                         (goto-char (text-property-any (point-min) (point-max)
                                                       'lsp-hierarchy-item child))
                         (lsp-hierarchy--load-async child (1+ indent) (1- depth))))))
                 (finish))
             (error (fail err)))))
      ;; Send-time exceptions and asynchronous failures take the same path;
      ;; neither is a successful empty result and both must allow retrying.
      (condition-case err
          (lsp-hierarchy--fetch-children item source #'succeed #'fail token)
        (error (fail err))))))

(defun lsp-hierarchy-goto ()
  "Jump to the source location of the node at point."
  (interactive)
  (let ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item)))
    (unless (and node (lsp-hierarchy--node-uri node) (lsp-hierarchy--node-range node))
      (user-error "No location for this node"))
    (lsp-hierarchy--open-file (lsp-hierarchy--node-uri node)
                              (lsp-hierarchy--node-range node)
                              (lsp-hierarchy--node-workspace node))))

(defun lsp-hierarchy-smart-tab ()
  "Toggle the node at point, or move to the next symbol."
  (interactive)
  (if (lsp-hierarchy--expandable-p (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
      (lsp-hierarchy-toggle)
    (outline-next-heading)))

;;; Expansion Indicators

(defvar lsp-hierarchy--outline-regexp
  (rx line-start (* space) "@")
  "Regular expression to match the start of a hierarchy node line.")

(defun lsp-hierarchy--icon-properties (item)
  "Return display properties for ITEM's expander."
  (list 'face 'lsp-hierarchy-icon-face
        'display (if (lsp-hierarchy--expandable-p item)
                     (if (lsp-hierarchy--node-expanded item)
                         lsp-hierarchy-icon-open
                       lsp-hierarchy-icon-close)
                   " ")
        'mouse-face 'highlight))

(defun lsp-hierarchy--update-icon ()
  "Update the expander on the current row after a state transition."
  (let ((inhibit-read-only t)
        (pos (text-property-any (line-beginning-position) (line-end-position)
                                'lsp-hierarchy-icon-marker t)))
    (when pos
      (add-text-properties pos (1+ pos)
                           (lsp-hierarchy--icon-properties
                            (get-text-property pos 'lsp-hierarchy-item))))))

;;; Major Mode Definition

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
  (outline-minor-mode 1)
  ;; Nodes already show their fold state with an arrow.  We hide whole lines,
  ;; so outline's ellipsis would appear before the next visible node.
  (remove-from-invisibility-spec '(outline . t))
  (add-to-invisibility-spec 'outline)

  (setq-local buffer-undo-list t)
  (setq-local buffer-read-only t)
  (setq-local indent-tabs-mode nil)
  (setq-local truncate-lines t)

  (setq-local lsp-hierarchy--view (lsp-hierarchy--make-view))
  (add-hook 'kill-buffer-hook #'lsp-hierarchy--dispose nil t)
  (add-hook 'change-major-mode-hook #'lsp-hierarchy--dispose nil t))

(defun lsp-hierarchy--display (lsp-roots source-buffer buffer-name title view-type outgoing-or-direction)
  "Display LSP-ROOTS, a list of (WORKSPACE . ITEM), in BUFFER-NAME.
SOURCE-BUFFER is the original buffer where the request was made.
TITLE is used as the mode name.
VIEW-TYPE is either \='call or \='type.
OUTGOING-OR-DIRECTION specifies the direction of the hierarchy."
  (let ((buf (get-buffer-create buffer-name))
        initial-nodes)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lsp-hierarchy-mode)
        (setf (lsp-hierarchy--view-source lsp-hierarchy--view) source-buffer
              (lsp-hierarchy--view-kind lsp-hierarchy--view) view-type
              (lsp-hierarchy--view-direction lsp-hierarchy--view) outgoing-or-direction)
        (setq mode-name title)
        ;; Root entries retain the workspace that produced each protocol item.
        ;; Opaque item data must never be resolved by a different server.
        (dolist (entry lsp-roots)
          (let ((item (lsp-hierarchy--symbol-node (cdr entry) (car entry))))
            (push item (lsp-hierarchy--view-roots lsp-hierarchy--view))
            (setf (lsp-hierarchy--node-expanded item) nil)
            (puthash (lsp-hierarchy--node-id item) item (lsp-hierarchy--view-nodes lsp-hierarchy--view))
            (let ((start (point)))
              (lsp-hierarchy--insert-node item 0)
              (push (cons item (copy-marker start t)) initial-nodes)))))
      (setf (lsp-hierarchy--view-roots lsp-hierarchy--view)
            (nreverse (lsp-hierarchy--view-roots lsp-hierarchy--view)))
      (goto-char (point-min))
      (unwind-protect
          (when (> lsp-hierarchy-expand-depth 0)
            (dolist (entry (reverse initial-nodes))
              (save-excursion
                (goto-char (cdr entry))
                (lsp-hierarchy--load-async (car entry) 0 lsp-hierarchy-expand-depth))))
        (dolist (entry initial-nodes) (set-marker (cdr entry) nil))))
    (pop-to-buffer buf)))

;;; --- LSP Backends & Views Implementation ---

(defun lsp-hierarchy--position-encoding (workspace)
  "Return WORKSPACE's negotiated position encoding, defaulting to UTF-16."
  (or (and workspace
           (lsp-get (lsp--workspace-server-capabilities workspace) :positionEncoding))
      "utf-16"))

(defun lsp-hierarchy--position-to-point (position encoding)
  "Convert POSITION to a buffer point using ENCODING.
The caller must widen the buffer.  This explicit conversion also works
with lsp-mode 9 and source snapshots which have no buffer-local LSP state."
  (goto-char (point-min))
  (forward-line (lsp-get position :line))
  (let ((remaining (lsp-get position :character))
        (end (line-end-position)))
    (while (and (> remaining 0) (< (point) end))
      (let* ((char (char-after))
             (units (pcase encoding
                      ("utf-8" (string-bytes (encode-coding-string (char-to-string char) 'utf-8)))
                      ("utf-32" 1)
                      (_ (if (> char #xffff) 2 1)))))
        (setq remaining (- remaining units))
        (forward-char 1)))
    (point)))

(defun lsp-hierarchy--source-snapshot (filename)
  "Return a current buffer for FILENAME, reusing owned snapshots."
  (or (find-buffer-visiting filename)
      (let* ((attrs (file-attributes filename))
             (signature (list (file-attribute-modification-time attrs)
                              (file-attribute-size attrs)))
             (entry (gethash filename (lsp-hierarchy--view-file-cache lsp-hierarchy--view))))
        (unless (and entry (buffer-live-p (cdr entry)))
          (setq entry (cons nil (generate-new-buffer " *lsp-hierarchy-source*")))
          (puthash filename entry (lsp-hierarchy--view-file-cache lsp-hierarchy--view)))
        (unless (equal (car entry) signature)
          (with-current-buffer (cdr entry)
            (erase-buffer)
            (insert-file-contents filename))
          (setcar entry signature))
        (cdr entry))))

(defun lsp-hierarchy--extract-line (uri range &optional workspace)
  "Extract the first line of RANGE at URI using WORKSPACE's position encoding."
  (let* ((line (lsp-get (lsp-get range :start) :line))
         (encoding (lsp-hierarchy--position-encoding workspace))
         (read-line
          (lambda ()
            (save-restriction
              (widen)
              (save-excursion
                (let* ((start (lsp-hierarchy--position-to-point (lsp-get range :start) encoding))
                       (beg (line-beginning-position))
                       (eol (line-end-position))
                       (end (min eol (lsp-hierarchy--position-to-point (lsp-get range :end) encoding))))
                  ;; LSP columns count encoding units, not Emacs characters.
                  ;; Multi-line ranges only highlight their first displayed line.
                  (concat
                   (string-trim-left (buffer-substring-no-properties beg start))
                   (propertize (buffer-substring-no-properties start (max start end))
                               'face 'lsp-hierarchy-call-site-face)
                   (buffer-substring-no-properties (max start end) eol)
                   (propertize (format " (line %d)" (1+ line)) 'face 'lsp-hierarchy-detail-face))))))))
    (condition-case nil
        (let ((filename (with-lsp-workspace workspace (lsp--uri-to-path uri))))
          (with-current-buffer (lsp-hierarchy--source-snapshot filename)
            (funcall read-line)))
      (error (format "call at line %d" (1+ line))))))

(defun lsp-hierarchy--open-file (uri range &optional workspace)
  "Open URI at RANGE using WORKSPACE's URI handling and xref history."
  (let ((filename (with-lsp-workspace workspace (lsp--uri-to-path uri))))
    (xref-push-marker-stack)
    (pop-to-buffer (find-file-noselect filename)
                   '((display-buffer-reuse-window display-buffer-pop-up-window)
                     (inhibit-same-window . t)))
    (let ((target (save-restriction
                    (widen)
                    (lsp-hierarchy--position-to-point
                     (lsp-get range :start) (lsp-hierarchy--position-encoding workspace)))))
      (unless (<= (point-min) target (point-max)) (widen))
      (goto-char target))
    (run-hooks 'xref-after-jump-hook)))

(defun lsp-hierarchy--symbol-node (item workspace &optional annotation)
  "Describe one occurrence of protocol ITEM owned by WORKSPACE.
ANNOTATION is optional view text.  Keep ITEM intact, including opaque data;
selectionRange identifies the name rather than its whole declaration."
  (lsp-hierarchy--make-node
   :workspace workspace :lsp-item item :type 'symbol
   :name (lsp-get item :name) :kind (lsp-get item :kind)
   :detail (lsp-get item :detail) :annotation annotation
   :uri (lsp-get item :uri) :range (lsp-get item :selectionRange)))

(defun lsp-hierarchy--call-nodes (calls parent outgoing)
  "Convert CALLS under PARENT to nodes in the OUTGOING direction.
This conversion only describes data; it never reads files or changes a view."
  (let ((workspace (lsp-hierarchy--node-workspace parent)))
    (mapcar
     (lambda (call)
       (let* ((item (if outgoing (lsp:call-hierarchy-outgoing-call-to call)
                      (lsp:call-hierarchy-incoming-call-from call)))
              (node (lsp-hierarchy--symbol-node item workspace))
              ;; fromRanges belong to the caller, i.e. the parent for
              ;; outgoing calls and the returned item for incoming calls.
              (uri (if outgoing (lsp-hierarchy--node-uri parent) (lsp-get item :uri))))
         (setf (lsp-hierarchy--node-call-sites node)
               (mapcar (lambda (range)
                         (lsp-hierarchy--make-node
                          :workspace workspace :type 'code :uri uri :range range))
                       (append (lsp-get call :fromRanges) nil)))
         node))
     calls)))

(defun lsp-hierarchy--type-nodes (items workspace direction)
  "Convert protocol ITEMS from WORKSPACE in DIRECTION to nodes."
  (mapcar (lambda (item)
            (lsp-hierarchy--symbol-node item workspace
                                        (if (eq direction 'supertypes) " ↑" " ↓")))
          items))

(defun lsp-hierarchy--fetch-children (node source callback error-handler token)
  "Request NODE's children from SOURCE using the current view's query.
Pass normalized nodes to CALLBACK, errors to ERROR-HANDLER; TOKEN owns the
request.  Only this adapter knows which hierarchy protocol methods to use."
  (let* ((kind (lsp-hierarchy--view-kind lsp-hierarchy--view))
         (direction (lsp-hierarchy--view-direction lsp-hierarchy--view))
         (workspace (lsp-hierarchy--node-workspace node))
         (method (if (eq kind 'call)
                     (if direction "callHierarchy/outgoingCalls" "callHierarchy/incomingCalls")
                   (if (eq direction 'supertypes) "typeHierarchy/supertypes" "typeHierarchy/subtypes"))))
    (lsp-hierarchy--request
     source method (list :item (lsp-hierarchy--node-lsp-item node))
     (lambda (result)
       (condition-case err
           (funcall callback
                    (if (eq kind 'call)
                        (lsp-hierarchy--call-nodes result node direction)
                      (lsp-hierarchy--type-nodes result workspace direction)))
         (error (funcall error-handler err))))
     error-handler token (list workspace))))

(defun lsp-hierarchy--prepare (view-type direction)
  "Prepare VIEW-TYPE in DIRECTION, keeping only the latest requested view."
  (let* ((source (current-buffer))
         (method (if (eq view-type 'call)
                     "textDocument/prepareCallHierarchy" "textDocument/prepareTypeHierarchy"))
         (lsp-method-requirements
          (append lsp-method-requirements lsp-hierarchy--method-requirements))
         (workspaces (or (lsp--find-workspaces-for method)
                         (user-error "%s hierarchy is not supported by the current servers"
                                     (capitalize (symbol-name view-type)))))
         (params (lsp--text-document-position-params))
         (name (if (eq view-type 'call) "*LSP Call Hierarchy*" "*LSP Type Hierarchy*"))
         (view (get-buffer-create name)))
    (with-current-buffer view
      ;; Resetting the mode cancels the previous generation before replacing
      ;; its text.  New requests belong to this view until completion or exit.
      (lsp-hierarchy-mode)
      (let ((inhibit-read-only t)) (erase-buffer) (insert "Loading hierarchy...\n"))
      (lsp-hierarchy--request
       source
       method params
       (lambda (responses)
         (let (roots)
           (dolist (response responses)
             (seq-doseq (root (cdr response))
               (push (cons (car response) root) roots)))
           (lsp-hierarchy--display
          (nreverse roots) source name
          (if (eq view-type 'call)
              (if direction "Outgoing Calls" "Incoming Calls")
            (if (eq direction 'supertypes) "Supertypes" "Subtypes"))
          view-type direction)))
       (lambda (err)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert "Unable to load hierarchy: " (lsp-hierarchy--error-message err) "\n")))
       nil workspaces t))
    (pop-to-buffer view)))

;;;###autoload
(defun lsp-hierarchy-show-call (&optional outgoing)
  "Show the call hierarchy asynchronously.
If OUTGOING is non-nil (or when called with a prefix argument),
show outgoing calls.  Otherwise, show incoming calls."
  (interactive "P")
  (lsp-hierarchy--prepare 'call outgoing))

;;;###autoload
(defun lsp-hierarchy-show-type (&optional super)
  "Show the type hierarchy asynchronously.
If SUPER is non-nil (or when called with a prefix argument),
show supertypes.  Otherwise, show subtypes."
  (interactive "P")
  (lsp-hierarchy--prepare 'type (if super 'supertypes 'subtypes)))



(provide 'lsp-hierarchy)
;;; lsp-hierarchy.el ends here
