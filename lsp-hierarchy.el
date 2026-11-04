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
  source kind direction roots (status 'ready) error
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

(defun lsp-hierarchy--single-line (text)
  "Return TEXT with line breaks and tabs replaced for a single display row."
  (replace-regexp-in-string "[\t\n\r]+" " " text))

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
       (insert (propertize (lsp-hierarchy--single-line (lsp-hierarchy--node-name item))
                           'face 'lsp-hierarchy-node-face))
       (when-let* ((detail (and lsp-hierarchy-detailed-outline
                               (lsp-hierarchy--node-detail item)))
                   ((not (string-empty-p detail))))
         (insert (propertize (concat " " (lsp-hierarchy--single-line (string-trim-left detail)))
                             'face 'lsp-hierarchy-detail-face)))
       (when-let* ((annotation (lsp-hierarchy--node-annotation item)))
         (insert (propertize annotation 'face 'lsp-hierarchy-detail-face)))))
    (insert "\n")
    (add-text-properties beg (point)
                         (list 'lsp-hierarchy-item item
                               'lsp-hierarchy-indent indent))))

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

(defun lsp-hierarchy--visible-p (node)
  "Return non-nil if all of NODE's ancestors are expanded."
  (let ((parent (lsp-hierarchy--node-parent node)))
    (or (null parent)
        (and (lsp-hierarchy--node-expanded parent)
             (eq (lsp-hierarchy--node-load-state parent) 'loaded)
             (lsp-hierarchy--visible-p parent)))))

(defun lsp-hierarchy--insert-subtree (node indent)
  "Render NODE and its visible descendants at INDENT."
  (lsp-hierarchy--insert-node node indent)
  (when (lsp-hierarchy--node-expanded node)
    (pcase (lsp-hierarchy--node-load-state node)
      ((or 'loading 'error)
       (let* ((loading (eq (lsp-hierarchy--node-load-state node) 'loading))
              (text (if loading "Loading..."
                      (concat (lsp-hierarchy--single-line
                               (lsp-hierarchy--error-message (lsp-hierarchy--node-error node)))
                              " (TAB to retry)"))))
         (insert (propertize (concat (make-string (* (1+ indent) 2) ?\s) "  " text "\n")
                             'face (if loading 'lsp-hierarchy-detail-face 'error)
                             'lsp-hierarchy-loading loading
                             'lsp-hierarchy-status-node node))))
      ('loaded
       (dolist (child (lsp-hierarchy--node-children node))
         (lsp-hierarchy--insert-subtree child (1+ indent)))))))

(defun lsp-hierarchy--anchor (position)
  "Describe POSITION by node, column and row kind rather than text offsets."
  (save-excursion
    (goto-char position)
    (if (and (eobp) (> (point-max) (point-min)))
        (list :end)
      (let ((status (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node)))
        (list (or (lsp-hierarchy--get-prop 'lsp-hierarchy-item) status)
              (current-column) (and status t))))))

(defun lsp-hierarchy--anchor-position (anchor)
  "Resolve ANCHOR, falling back to its nearest visible ancestor."
  (if (eq (car anchor) :end)
      (point-max)
    (let* ((node (car anchor))
           (position (and node (nth 2 anchor)
                          (text-property-any (point-min) (point-max)
                                             'lsp-hierarchy-status-node node))))
      (while (and node (not position))
        (setq position (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node)
              node (lsp-hierarchy--node-parent node)))
      (save-excursion
        (goto-char (or position (point-min)))
        (move-to-column (or (cadr anchor) 0))
        (point)))))

(defun lsp-hierarchy--render ()
  "Rebuild visible rows from the model without publishing a partial display.
Preserve point and each displaying window by node identity, since responses
can insert rows anywhere above the user's current position."
  (let* ((view lsp-hierarchy--view)
         (close-icon lsp-hierarchy-icon-close)
         (open-icon lsp-hierarchy-icon-open)
         (detailed lsp-hierarchy-detailed-outline)
         (anchor (lsp-hierarchy--anchor (point)))
         (windows (mapcar (lambda (window)
                            (list window
                                  (lsp-hierarchy--anchor (window-start window))
                                  (lsp-hierarchy--anchor (window-point window))))
                          (get-buffer-window-list (current-buffer) nil t)))
         (text (with-temp-buffer
                 (setq-local lsp-hierarchy--view view
                             lsp-hierarchy-icon-close close-icon
                             lsp-hierarchy-icon-open open-icon
                             lsp-hierarchy-detailed-outline detailed)
                 (pcase (lsp-hierarchy--view-status view)
                   ('loading (insert "Loading hierarchy...\n"))
                   ('error (insert "Unable to load hierarchy: "
                                   (lsp-hierarchy--error-message (lsp-hierarchy--view-error view)) "\n"))
                   (_ (if (lsp-hierarchy--view-roots view)
                          (dolist (node (lsp-hierarchy--view-roots view))
                            (lsp-hierarchy--insert-subtree node 0))
                        (insert "No hierarchy found.\n"))))
                 (buffer-string))))
    (let ((inhibit-read-only t))
      (atomic-change-group
        (erase-buffer)
        (insert text)))
    (goto-char (lsp-hierarchy--anchor-position anchor))
    (dolist (entry windows)
      (when (window-live-p (car entry))
        (set-window-start (car entry) (lsp-hierarchy--anchor-position (nth 1 entry)) t)
        (set-window-point (car entry) (lsp-hierarchy--anchor-position (nth 2 entry)))))
    (set-buffer-modified-p nil)))

;;; Core: Interaction Logic

(defun lsp-hierarchy--expandable-p (node)
  "Return non-nil if NODE has children or has not yet resolved them.
An empty successful response is a leaf; an error remains retryable."
  (and node
       (eq (lsp-hierarchy--node-type node) 'symbol)
       (or (not (eq (lsp-hierarchy--node-load-state node) 'loaded))
           (lsp-hierarchy--node-children node))))

(defun lsp-hierarchy--node-at-point ()
  "Return the node or status row owner at point."
  (or (lsp-hierarchy--get-prop 'lsp-hierarchy-item)
      (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node)))

(defun lsp-hierarchy-toggle ()
  "Toggle the node at point, loading its children when necessary."
  (interactive)
  (let ((node (lsp-hierarchy--node-at-point)))
    (unless node (user-error "No node here"))
    (cond
     ((not (lsp-hierarchy--expandable-p node)) (forward-line 1))
     ((memq (lsp-hierarchy--node-load-state node) '(unloaded error))
      (lsp-hierarchy--load-async node))
     (t
      (let ((expanded (lsp-hierarchy--node-expanded node)))
        (setf (lsp-hierarchy--node-expanded node) (not expanded))
        (condition-case err
            (lsp-hierarchy--render)
          (error
           (setf (lsp-hierarchy--node-expanded node) expanded)
           (signal (car err) (cdr err)))))))))

(defun lsp-hierarchy--load-async (node &optional depth)
  "Load NODE's children, automatically expanding at most DEPTH levels."
  (let ((depth (or depth 1))
        (token (make-symbol "lsp-hierarchy-node-request")))
    (setf (lsp-hierarchy--node-request node) token
          (lsp-hierarchy--node-load-state node) 'loading
          (lsp-hierarchy--node-error node) nil
          (lsp-hierarchy--node-expanded node) t)
    (cl-labels
        ((fail (err)
           (setf (lsp-hierarchy--node-request node) nil
                 (lsp-hierarchy--node-load-state node) 'error
                 (lsp-hierarchy--node-error node) err)
           (lsp-hierarchy--render)
           (message "LSP hierarchy: %s (TAB to retry)" (lsp-hierarchy--error-message err)))
         (succeed (children)
           (let ((previous (lsp-hierarchy--node-children node))
                 (nodes (append (lsp-hierarchy--node-call-sites node) children)))
             ;; The renderer builds the entire candidate display off-screen.
             ;; Publish the registry only once it succeeds; rollback the
             ;; candidate children on failure so retry cannot duplicate rows.
             (setf (lsp-hierarchy--node-children node) nodes
                   (lsp-hierarchy--node-load-state node) 'loaded
                   (lsp-hierarchy--node-request node) nil)
             (dolist (child nodes) (setf (lsp-hierarchy--node-parent child) node))
             (condition-case err
                 (progn
                   (lsp-hierarchy--render)
                   (dolist (child nodes)
                     (puthash (lsp-hierarchy--node-id child) child
                              (lsp-hierarchy--view-nodes lsp-hierarchy--view))))
               (error
                (setf (lsp-hierarchy--node-children node) previous)
                (fail err)))
             ;; A response may arrive under a folded ancestor.  Keep its
             ;; children cached, but do not start more automatic requests.
             (when (and (eq (lsp-hierarchy--node-load-state node) 'loaded)
                        (> depth 1) (lsp-hierarchy--node-expanded node)
                        (lsp-hierarchy--visible-p node))
               (dolist (child nodes)
                 (when (eq (lsp-hierarchy--node-type child) 'symbol)
                   (lsp-hierarchy--load-async child (1- depth))))))))
      (condition-case err
          (progn
            (lsp-hierarchy--render)
            (lsp-hierarchy--fetch-children
             node (lsp-hierarchy--view-source lsp-hierarchy--view) #'succeed #'fail token))
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
  "Toggle the node at point, or move to the next visible symbol."
  (interactive)
  (if (lsp-hierarchy--expandable-p (lsp-hierarchy--node-at-point))
      (lsp-hierarchy-toggle)
    (forward-line 1)
    (while (and (not (eobp))
                (let ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item)))
                  (not (and node (eq (lsp-hierarchy--node-type node) 'symbol)))))
      (forward-line 1))))

;;; Expansion Indicators

(defun lsp-hierarchy--icon-properties (item)
  "Return display properties for ITEM's expander."
  (list 'face 'lsp-hierarchy-icon-face
        'display (if (lsp-hierarchy--expandable-p item)
                     (if (lsp-hierarchy--node-expanded item)
                         lsp-hierarchy-icon-open
                       lsp-hierarchy-icon-close)
                   " ")
        'mouse-face 'highlight))

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

  (setq-local buffer-undo-list t)
  (setq-local buffer-read-only t)
  (setq-local indent-tabs-mode nil)
  (setq-local truncate-lines t)

  (setq-local lsp-hierarchy--view (lsp-hierarchy--make-view))
  (add-hook 'kill-buffer-hook #'lsp-hierarchy--dispose nil t)
  (add-hook 'change-major-mode-hook #'lsp-hierarchy--dispose nil t))

(defun lsp-hierarchy--display (roots)
  "Populate the current view from (WORKSPACE . ITEM) pairs in ROOTS."
  (let ((nodes (mapcar (lambda (entry)
                         (lsp-hierarchy--symbol-node (cdr entry) (car entry)))
                       roots)))
    (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) nodes
          (lsp-hierarchy--view-status lsp-hierarchy--view) 'ready)
    (lsp-hierarchy--render)
    (dolist (node nodes)
      (puthash (lsp-hierarchy--node-id node) node
               (lsp-hierarchy--view-nodes lsp-hierarchy--view)))
    (when (> lsp-hierarchy-expand-depth 0)
      (dolist (node nodes)
        (lsp-hierarchy--load-async node lsp-hierarchy-expand-depth)))))

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

(defun lsp-hierarchy--prepare-failed (err)
  "Record ERR and display a failed root request in the current view."
  (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) nil
        (lsp-hierarchy--view-status lsp-hierarchy--view) 'error
        (lsp-hierarchy--view-error lsp-hierarchy--view) err)
  (lsp-hierarchy--render))

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
      (setf (lsp-hierarchy--view-source lsp-hierarchy--view) source
            (lsp-hierarchy--view-kind lsp-hierarchy--view) view-type
            (lsp-hierarchy--view-direction lsp-hierarchy--view) direction
            (lsp-hierarchy--view-status lsp-hierarchy--view) 'loading)
      (setq mode-name (if (eq view-type 'call)
                          (if direction "Outgoing Calls" "Incoming Calls")
                        (if (eq direction 'supertypes) "Supertypes" "Subtypes")))
      (lsp-hierarchy--render)
      (lsp-hierarchy--request
       source
       method params
       (lambda (responses)
         (let (roots)
           (dolist (response responses)
             (seq-doseq (root (cdr response))
               (push (cons (car response) root) roots)))
           (condition-case err
               (lsp-hierarchy--display (nreverse roots))
             (error (lsp-hierarchy--prepare-failed err)))))
       #'lsp-hierarchy--prepare-failed
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
