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

;; LSP hierarchy views fully powered by Emacs' built-in `hierarchy.el' data engine.

;;; Code:

(require 'lsp-mode)
(require 'cl-lib)
(require 'outline)
(require 'hierarchy)
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
  workspace lsp-item type name kind detail annotation uri range children children-fn goto-fn
  ;; Expansion is a user choice; loading can finish while a node is folded.
  expanded (load-state 'unloaded) request error)

(defvar-local lsp-hierarchy--source-buffer nil
  "The buffer from which the hierarchy was requested.")
(defvar-local lsp-hierarchy--nodes nil
  "Map stable occurrence IDs to nodes in this view.")

(defvar-local lsp-hierarchy--generation nil
  "Identity of the currently requested view, used to reject late responses.")

(defvar-local lsp-hierarchy--file-cache nil
  "Map filenames to (SIGNATURE . BUFFER) for snapshots owned by this view.")

(defvar-local lsp-hierarchy--requests nil
  "Cancellation tokens owned by the current view.")

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
  (setq lsp-hierarchy--generation nil)
  (when lsp-hierarchy--requests
    (maphash (lambda (token _) (lsp-hierarchy--cancel-request token)) lsp-hierarchy--requests)
    (clrhash lsp-hierarchy--requests))
  (when lsp-hierarchy--file-cache
    (maphash (lambda (_ entry)
               (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
             lsp-hierarchy--file-cache)
    (clrhash lsp-hierarchy--file-cache)))

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
        (generation lsp-hierarchy--generation)
        (token (or token (make-symbol "lsp-hierarchy-request"))))
    (puthash token t lsp-hierarchy--requests)
    (cl-labels ((finish (fn result)
                 (when (buffer-live-p view)
                   (with-current-buffer view
                     (when (and (eq generation lsp-hierarchy--generation)
                                (gethash token lsp-hierarchy--requests))
                       (remhash token lsp-hierarchy--requests)
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

(defun lsp-hierarchy--insert-node (item indent hierarchy)
  "Insert ITEM at INDENT using its structured name and location.
HIERARCHY contains loaded relationships used to choose the expander."
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
                      (lsp-hierarchy--icon-properties item hierarchy)) " ")
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

(defun lsp-hierarchy--expandable-p (node hierarchy)
  "Return non-nil if NODE has children or has not yet resolved them.
HIERARCHY contains the already loaded relationships.  An empty successful
response is a leaf, whereas an error remains retryable."
  (and node
       (eq (lsp-hierarchy--node-type node) 'symbol)
       (or (and (not (eq (lsp-hierarchy--node-load-state node) 'loaded))
                (lsp-hierarchy--node-children-fn node))
           (lsp-hierarchy--node-children node)
           (hierarchy-children hierarchy (lsp-hierarchy--node-id node)))))

(defun lsp-hierarchy-toggle ()
  "Toggle node at point, loading children if necessary."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (h (lsp-hierarchy--get-prop 'lsp-hierarchy-tree))
         (indent (lsp-hierarchy--get-prop 'lsp-hierarchy-indent))
         (cfn (and item (lsp-hierarchy--node-children-fn item))))
    (unless item
      (user-error "No node here"))
    (if (not (lsp-hierarchy--expandable-p item h))
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

       (cfn
        (lsp-hierarchy--load-async item indent h))))))

(defun lsp-hierarchy--load-async (item indent hierarchy &optional depth)
  "Load ITEM at INDENT in HIERARCHY, expanding up to DEPTH levels."
  (let* ((depth (or depth 1))
         (cfn (and item (lsp-hierarchy--node-children-fn item)))
         (precomputed (lsp-hierarchy--node-children item))
         (source lsp-hierarchy--source-buffer)
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
               (let ((inhibit-read-only t)
                     expand)
                 (save-excursion
                   (remove-loading)
                   (goto-char marker)
                   (dolist (child (append precomputed children))
                     (hierarchy-add-tree hierarchy (lsp-hierarchy--node-id child) (lambda (_) (lsp-hierarchy--node-id item)))
                     (puthash (lsp-hierarchy--node-id child) child lsp-hierarchy--nodes)
                     (let ((start (point)))
                       (lsp-hierarchy--insert-node child (1+ indent) hierarchy)
                       (when (and (> depth 1) (lsp-hierarchy--node-children-fn child))
                         (push (cons child (copy-marker start t)) expand))))
                   (setf (lsp-hierarchy--node-load-state item) 'loaded)
                   (goto-char origin)
                   (lsp-hierarchy--set-subtree-visibility
                    (if (lsp-hierarchy--node-expanded item) 'show 'hide))
                   (lsp-hierarchy--update-icon))
                 ;; Keep a finite depth budget with this request.  Point may
                 ;; have moved, and the user may have folded an ancestor.
                 (unwind-protect
                     (when (and (lsp-hierarchy--node-expanded item)
                                (not (invisible-p origin)))
                       (dolist (entry (reverse expand))
                         (save-excursion
                           (goto-char (cdr entry))
                           (lsp-hierarchy--load-async (car entry) (1+ indent) hierarchy (1- depth)))))
                   (dolist (entry expand) (set-marker (cdr entry) nil)))
                 (finish))
             (error (fail err)))))
      ;; Send-time exceptions and asynchronous failures take the same path;
      ;; neither is a successful empty result and both must allow retrying.
      (condition-case err
          (if cfn (funcall cfn item source #'succeed #'fail token) (succeed nil))
        (error (fail err))))))

(defun lsp-hierarchy-goto ()
  "Jump to the source location of the item at point."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (goto-fn (and item (lsp-hierarchy--node-goto-fn item))))
    (if goto-fn
        (funcall goto-fn)
      (user-error "No location for this node"))))

(defun lsp-hierarchy-smart-tab ()
  "Smart TAB command for `lsp-hierarchy-mode'."
  (interactive)
  (let* ((item (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
         (h (lsp-hierarchy--get-prop 'lsp-hierarchy-tree)))
    (if (lsp-hierarchy--expandable-p item h)
        (lsp-hierarchy-toggle)
      (outline-next-heading))))

;;; Expansion Indicators

(defvar lsp-hierarchy--outline-regexp
  (rx line-start (* space) "@")
  "Regular expression to match the start of a hierarchy node line.")

(defun lsp-hierarchy--icon-properties (item hierarchy)
  "Return display properties for ITEM's expander in HIERARCHY."
  (list 'face 'lsp-hierarchy-icon-face
        'display (if (lsp-hierarchy--expandable-p item hierarchy)
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
                            (get-text-property pos 'lsp-hierarchy-item)
                            (get-text-property pos 'lsp-hierarchy-tree))))))

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

  (setq-local lsp-hierarchy--generation (make-symbol "lsp-hierarchy-view"))
  (setq-local lsp-hierarchy--requests (make-hash-table :test 'eq))
  (setq-local lsp-hierarchy--file-cache (make-hash-table :test 'equal))
  (add-hook 'kill-buffer-hook #'lsp-hierarchy--dispose nil t)
  (add-hook 'change-major-mode-hook #'lsp-hierarchy--dispose nil t)
  (setq-local lsp-hierarchy--nodes (make-hash-table :test 'eq)))

(defun lsp-hierarchy--display (lsp-roots source-buffer buffer-name title view-type outgoing-or-direction)
  "Display LSP-ROOTS, a list of (WORKSPACE . ITEM), in BUFFER-NAME.
SOURCE-BUFFER is the original buffer where the request was made.
TITLE is used as the mode name.
VIEW-TYPE is either \='call or \='type.
OUTGOING-OR-DIRECTION specifies the direction of the hierarchy."
  (let ((buf (get-buffer-create buffer-name))
        (h (hierarchy-new))
        initial-nodes)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lsp-hierarchy-mode)
        (setq-local lsp-hierarchy--source-buffer source-buffer)
        (setq mode-name title)
        ;; Root entries retain the workspace that produced each protocol item.
        ;; Opaque item data must never be resolved by a different server.
        (dolist (entry lsp-roots)
          (let* ((workspace (car entry))
                 (root (cdr entry))
                 (item (lsp-hierarchy--make-node
                        :workspace workspace :name (lsp-get root :name)
                        :detail (lsp-get root :detail)
                        :kind (lsp-get root :kind)
                        :lsp-item root
                        :type 'symbol)))
            (setf (lsp-hierarchy--node-children-fn item)
                  (if (eq view-type 'call)
                      (lambda (it s cb err token)
                        (lsp-hierarchy--call-hierarchy-children it s cb outgoing-or-direction err token))
                    (lambda (it s cb err token)
                      (lsp-hierarchy--type-hierarchy-children it s cb outgoing-or-direction err token))))
            ;; selectionRange identifies the symbol name; range may also
            ;; include its documentation and body.  Roots are navigable in
            ;; both call and type views.
            (setf (lsp-hierarchy--node-goto-fn item)
                  (lambda () (lsp-hierarchy--open-file
                              (lsp-get root :uri) (lsp-get root :selectionRange) workspace)))

            ;; hierarchy.el uses equal keys.  Stable IDs keep mutable node
            ;; state out of its relation keys.
            (hierarchy-add-tree h (lsp-hierarchy--node-id item) nil)
            (setf (lsp-hierarchy--node-expanded item) nil)
            (puthash (lsp-hierarchy--node-id item) item lsp-hierarchy--nodes)
            (let ((start (point)))
              (lsp-hierarchy--insert-node item 0 h)
              (push (cons item (copy-marker start t)) initial-nodes)))))
      (goto-char (point-min))
      (unwind-protect
          (when (> lsp-hierarchy-expand-depth 0)
            (dolist (entry (reverse initial-nodes))
              (save-excursion
                (goto-char (cdr entry))
                (lsp-hierarchy--load-async (car entry) 0 h lsp-hierarchy-expand-depth))))
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
             (entry (gethash filename lsp-hierarchy--file-cache)))
        (unless (and entry (buffer-live-p (cdr entry)))
          (setq entry (cons nil (generate-new-buffer " *lsp-hierarchy-source*")))
          (puthash filename entry lsp-hierarchy--file-cache))
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

(defun lsp-hierarchy--call-hierarchy-children (item sb callback outgoing &optional error-handler token)
  "Fetch children for call hierarchy ITEM.
SB is the source buffer.  CALLBACK is called with the results.
OUTGOING is non-nil for outgoing calls.
ERROR-HANDLER handles failures; TOKEN identifies the cancellable request."
  (let* ((method (if outgoing "callHierarchy/outgoingCalls" "callHierarchy/incomingCalls"))
         (lsp-p (lsp-hierarchy--node-lsp-item item))
         (parent-uri (lsp-get lsp-p :uri))
         (workspace (lsp-hierarchy--node-workspace item)))
    (lsp-hierarchy--request sb
			    method (list :item lsp-p)
			    (lambda (res)
			      (funcall callback
				       (mapcar
					(lambda (call)
					  (let* ((tar (if outgoing (lsp:call-hierarchy-outgoing-call-to call) (lsp:call-hierarchy-incoming-call-from call)))
						 (uri (lsp-get tar :uri))
						 (call-uri (if outgoing parent-uri uri)))
					    (lsp-hierarchy--make-node :workspace workspace
								      :name (lsp-get tar :name) :detail (lsp-get tar :detail)
								      :kind (lsp-get tar :kind)
								      :lsp-item tar
								      :type 'symbol
								      :goto-fn (lambda () (lsp-hierarchy--open-file uri (lsp-get tar :selectionRange) workspace))
								      :children (mapcar (lambda (r)
											  (lsp-hierarchy--make-node :workspace workspace
														    :uri call-uri :range r
														    :type 'code
														    :goto-fn (lambda () (lsp-hierarchy--open-file call-uri r workspace))))
											(append (lsp-get call :fromRanges) nil))
								      :children-fn (lambda (it s cb err token)
										     (lsp-hierarchy--call-hierarchy-children it s cb outgoing err token)))))
					res)))
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

(defun lsp-hierarchy--type-hierarchy-children (item sb callback direction &optional error-handler token)
  "Fetch children for type hierarchy ITEM.
SB is the source buffer.  CALLBACK is called with the results.
DIRECTION is \='supertypes or \='subtypes.
ERROR-HANDLER handles failures; TOKEN identifies the cancellable request."
  (let ((method (if (eq direction 'supertypes) "typeHierarchy/supertypes" "typeHierarchy/subtypes"))
        (lsp-it (lsp-hierarchy--node-lsp-item item))
        (workspace (lsp-hierarchy--node-workspace item)))
    (lsp-hierarchy--request sb
			    method (list :item lsp-it)
			    (lambda (res)
			      (funcall callback
				       (mapcar (lambda (it)
						 (lsp-hierarchy--make-node :workspace workspace
									   :name (lsp-get it :name) :detail (lsp-get it :detail)
                          :annotation (if (eq direction 'supertypes) " ↑" " ↓")
									   :kind (lsp-get it :kind)
									   :lsp-item it
									   :type 'symbol
									   :goto-fn (lambda () (lsp-hierarchy--open-file (lsp-get it :uri) (lsp-get it :selectionRange) workspace))
									   :children-fn (lambda (it sb cb err token)
											  (lsp-hierarchy--type-hierarchy-children it sb cb direction err token))))
					       res)))
			    error-handler token (list workspace))))

(provide 'lsp-hierarchy)
;;; lsp-hierarchy.el ends here
