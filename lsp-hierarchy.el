;;; lsp-hierarchy.el --- LSP hierarchy views -*- lexical-binding: t; -*-

;; Copyright (C) 2026-2026 Zhiwei Chen

;; Author: Zhiwei Chen <condy0919@gmail.com>
;; Keywords: languages, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lsp-mode "10.0"))
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
  "Include signatures and known call-site counts in symbol labels.
Site counts describe source locations along the hierarchy edge, not
execution counts."
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

(defcustom lsp-hierarchy-display-buffer-action
  '((display-buffer-reuse-window display-buffer-use-some-window display-buffer-pop-up-window)
    (inhibit-same-window . t))
  "Display action for source jumps and previews.
This is passed to `display-buffer' and `pop-to-buffer', so matching rules
in `display-buffer-alist' retain priority.  Preview requires a window
other than the hierarchy window."
  :type 'sexp
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-node-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for symbol/function nodes."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-deprecated-face
  '((t :inherit lsp-hierarchy-node-face :strike-through t))
  "Face for symbol names marked deprecated by the language server."
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
  ;; Cover every standard SymbolKind using plain text, including kinds that
  ;; type hierarchies may return in languages without classes or methods.
  (cl-case kind
    (1 "F") (2 "mod") (3 "ns") (4 "pkg") (5 "c") (6 "m")
    (7 "p") (8 "v") (9 "M") (10 "e") (11 "I") (12 "f")
    (13 "var") (14 "C") (15 "str") (16 "num") (17 "bool")
    (18 "arr") (19 "obj") (20 "key") (21 "null") (22 "em")
    (23 "s") (24 "evt") (25 "op") (26 "T")
    (t "")))

;;; Model and rendering

(cl-defstruct (lsp-hierarchy--node (:constructor lsp-hierarchy--make-node))
  "One symbol occurrence; its children contain only symbol nodes.
CALL-SITES holds (URI . RANGE) pairs on the incoming edge.  Expansion is
independent of loading, so a response can be cached while folded."
  workspace lsp-item parent call-sites children expanded (load-state 'unloaded) error)

(defun lsp-hierarchy--item-get (node field)
  "Read protocol FIELD from NODE's original item without copying its data."
  (lsp-get (lsp-hierarchy--node-lsp-item node) field))

(cl-defstruct (lsp-hierarchy--view (:constructor lsp-hierarchy--make-view))
  "Query context and resources owned by one hierarchy buffer."
  origin direction roots (status 'ready) error
  (requests (make-hash-table :test 'eq))
  (file-cache (make-hash-table :test 'equal)))

(defvar-local lsp-hierarchy--view nil "The current hierarchy model.")
(defvar lsp-hierarchy--batch-loading nil
  "Non-nil while sibling requests start, including synchronous send failures.")

;;; Protocol and owned resources

(defun lsp-hierarchy--cancel-request (token)
  "Cancel TOKEN and release handlers even if the server disconnected."
  (let ((lsp--cur-workspace nil)
        (request (gethash token lsp--cancelable-requests)))
    (unwind-protect
        (ignore-errors (lsp-cancel-request-by-token token))
      ;; lsp-mode removes the handler before notifying the server, but a send
      ;; error skips its hook/token cleanup.
      (when request
        (lsp--request-cleanup-hooks (car request))
        (remhash token lsp--cancelable-requests)))))

(defun lsp-hierarchy--dispose ()
  "Invalidate this view and release its requests, marker and snapshots."
  (let ((view lsp-hierarchy--view))
    ;; Invalidate before cancellation, which can invoke callbacks synchronously.
    (setq lsp-hierarchy--view nil)
    (when (lsp-hierarchy--view-p view)
      (when-let* ((origin (lsp-hierarchy--view-origin view)))
        (set-marker origin nil))
      (maphash (lambda (token _) (lsp-hierarchy--cancel-request token))
               (lsp-hierarchy--view-requests view))
      (clrhash (lsp-hierarchy--view-requests view))
      (maphash (lambda (_ entry)
                 (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
               (lsp-hierarchy--view-file-cache view))
      (clrhash (lsp-hierarchy--view-file-cache view)))))

(defun lsp-hierarchy--error-message (err)
  "Format protocol error, Lisp condition or string ERR."
  (cond ((stringp err) err)
        ((and (consp err) (symbolp (car err)) (get (car err) 'error-conditions))
         (error-message-string err))
        (t (or (ignore-errors (lsp--error-string err)) (format "%s" err)))))

(defconst lsp-hierarchy--method-requirements
  '(("textDocument/prepareCallHierarchy" :capability :callHierarchyProvider)
    ("textDocument/prepareTypeHierarchy" :capability :typeHierarchyProvider)
    ("callHierarchy/incomingCalls" :check-command lsp-hierarchy--call-supported-p)
    ("callHierarchy/outgoingCalls" :check-command lsp-hierarchy--call-supported-p)
    ("typeHierarchy/supertypes" :check-command lsp-hierarchy--type-supported-p)
    ("typeHierarchy/subtypes" :check-command lsp-hierarchy--type-supported-p))
  "Local capability declarations for lsp-mode versions missing these methods.")

(defun lsp-hierarchy--call-supported-p (workspace)
  "Return whether WORKSPACE supports call hierarchies."
  (with-lsp-workspace workspace (lsp-feature? "textDocument/prepareCallHierarchy")))

(defun lsp-hierarchy--type-supported-p (workspace)
  "Return whether WORKSPACE supports type hierarchies."
  (with-lsp-workspace workspace (lsp-feature? "textDocument/prepareTypeHierarchy")))

(defun lsp-hierarchy--request (workspace method params success &optional failure cancelled)
  "Send METHOD and PARAMS to WORKSPACE from this view's source marker.
Complete at most once through SUCCESS, FAILURE or CANCELLED.
CANCELLED defaults to FAILURE; the view owns the cancellation token."
  (let* ((buffer (current-buffer))
         (view lsp-hierarchy--view)
         (source (marker-buffer (lsp-hierarchy--view-origin view)))
         (token (make-symbol "hierarchy-request")))
    (puthash token t (lsp-hierarchy--view-requests view))
    (cl-labels ((finish (callback result)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     ;; Reject replaced/disposed views and duplicate completions.
                     (when (and (eq view lsp-hierarchy--view)
                                (gethash token (lsp-hierarchy--view-requests view)))
                       (remhash token (lsp-hierarchy--view-requests view))
                       (when callback (funcall callback result)))))))
      (condition-case err
          (progn
            (unless (buffer-live-p source)
              (user-error "The hierarchy source buffer has been killed"))
            (with-current-buffer source
              (let ((lsp--cur-workspace nil))
                (unless (memq workspace (lsp-workspaces))
                  (user-error "The hierarchy language server is no longer attached"))
                (let ((lsp--buffer-workspaces (list workspace))
                      (lsp-method-requirements
                       (append lsp-method-requirements lsp-hierarchy--method-requirements)))
                  (lsp-request-async
                   method params (lambda (result) (finish success result))
                   :error-handler (lambda (err) (finish failure err))
                   :cancel-handler (lambda () (finish (or cancelled failure) "Request cancelled"))
                   :cancel-token token :mode 'alive)))))
        (error (lsp-hierarchy--cancel-request token) (finish failure err))))))

(defun lsp-hierarchy--position-encoding (workspace)
  "Return WORKSPACE's position encoding, defaulting to UTF-16."
  (or (and workspace (lsp-get (lsp--workspace-server-capabilities workspace) :positionEncoding))
      "utf-16"))

(defun lsp-hierarchy--position-to-point (position encoding)
  "Move to LSP POSITION using ENCODING in the widened current buffer."
  (goto-char (point-min))
  (forward-line (lsp-get position :line))
  (funcall (pcase encoding
             ("utf-8" #'lsp--move-to-utf-8-column)
             ("utf-32" #'lsp--move-to-utf-32-column)
             (_ #'lsp--move-to-utf-16-column))
           (lsp-get position :character)))

(defun lsp-hierarchy--point-to-position (workspace)
  "Return point as an LSP position for WORKSPACE in the widened buffer."
  (list :line (1- (line-number-at-pos))
        :character (funcall (pcase (lsp-hierarchy--position-encoding workspace)
                              ("utf-8" #'lsp--utf-8-column)
                              ("utf-32" #'lsp--utf-32-column)
                              (_ #'lsp--utf-16-column)))))

(defun lsp-hierarchy--source-snapshot (filename)
  "Return FILENAME's visiting buffer or a current view-owned snapshot."
  (or (find-buffer-visiting filename)
      (let* ((cache (lsp-hierarchy--view-file-cache lsp-hierarchy--view))
             (entry (gethash filename cache)) (snapshot (cdr entry)) complete)
        (unwind-protect
            (let* ((attrs (or (file-attributes filename)
                              (signal 'file-missing (list "Source file is missing" filename))))
                   (signature (list (file-attribute-modification-time attrs) (file-attribute-size attrs))))
              (unless (buffer-live-p snapshot)
                (setq snapshot (generate-new-buffer " *lsp-hierarchy-source*") entry nil))
              (unless (equal (car entry) signature)
                (with-current-buffer snapshot
                  (erase-buffer)
                  (insert-file-contents filename))
                (puthash filename (cons signature snapshot) cache))
              (setq complete t)
              snapshot)
          ;; Failed reads must not retain an empty or partly replaced snapshot.
          (unless complete
            (when (buffer-live-p snapshot) (kill-buffer snapshot))
            (remhash filename cache))))))

(defun lsp-hierarchy--extract-line (uri range &optional workspace)
  "Extract RANGE's first line at URI using WORKSPACE's position encoding."
  (let ((line (lsp-get (lsp-get range :start) :line))
        (encoding (lsp-hierarchy--position-encoding workspace)))
    (condition-case nil
        (with-current-buffer (lsp-hierarchy--source-snapshot
                              (with-lsp-workspace workspace (lsp--uri-to-path uri)))
          (save-restriction
            (widen)
            (save-excursion
              (let* ((start (lsp-hierarchy--position-to-point (lsp-get range :start) encoding))
                     (beg (line-beginning-position)) (eol (line-end-position))
                     ;; Multi-line ranges highlight only the first displayed line.
                     (end (max start (min eol (lsp-hierarchy--position-to-point
                                              (lsp-get range :end) encoding)))))
                (concat (string-trim-left (buffer-substring-no-properties beg start))
                        (propertize (buffer-substring-no-properties start end)
                                    'face 'lsp-hierarchy-call-site-face)
                        (buffer-substring-no-properties end eol)
                        (propertize (format " (line %d)" (1+ line))
                                    'face 'lsp-hierarchy-detail-face))))))
      (error (format "call at line %d" (1+ line))))))

(defun lsp-hierarchy--location-point (range workspace)
  "Return RANGE's start for WORKSPACE; widen only if it is inaccessible."
  (let ((target (save-restriction
                  (widen)
                  (save-excursion
                    (lsp-hierarchy--position-to-point
                     (lsp-get range :start) (lsp-hierarchy--position-encoding workspace))))))
    (unless (<= (point-min) target (point-max)) (widen))
    target))

(defun lsp-hierarchy--open-file (uri range &optional workspace)
  "Visit URI at RANGE using WORKSPACE, recording the departure in xref."
  (let ((filename (with-lsp-workspace workspace (lsp--uri-to-path uri))))
    (xref-push-marker-stack)
    (pop-to-buffer (find-file-noselect filename) lsp-hierarchy-display-buffer-action)
    (goto-char (lsp-hierarchy--location-point range workspace))
    (run-hooks 'xref-after-jump-hook)))

;;; Protocol adapters

(defun lsp-hierarchy--symbol-node (item workspace)
  "Describe one occurrence of ITEM from WORKSPACE, preserving opaque data."
  (lsp-hierarchy--make-node :workspace workspace :lsp-item item))

(defun lsp-hierarchy--call-nodes (calls parent outgoing)
  "Convert CALLS under PARENT to symbol nodes in the OUTGOING direction."
  (mapcar
   (lambda (call)
     (let* ((item (lsp-get call (if outgoing :to :from)))
            (node (lsp-hierarchy--symbol-node item (lsp-hierarchy--node-workspace parent)))
            ;; fromRanges belong to the caller: parent for outgoing calls.
            (uri (if outgoing (lsp-hierarchy--item-get parent :uri) (lsp-get item :uri))))
       (setf (lsp-hierarchy--node-call-sites node)
             (mapcar (lambda (range) (cons uri range)) (append (lsp-get call :fromRanges) nil)))
       node))
   calls))

(defun lsp-hierarchy--fetch-children (node callback error-handler)
  "Request NODE's children; deliver nodes to CALLBACK or failures to ERROR-HANDLER."
  (let* ((direction (lsp-hierarchy--view-direction lsp-hierarchy--view))
         (workspace (lsp-hierarchy--node-workspace node))
         (method (pcase direction
                   ('incoming "callHierarchy/incomingCalls")
                   ('outgoing "callHierarchy/outgoingCalls")
                   ('subtypes "typeHierarchy/subtypes")
                   ('supertypes "typeHierarchy/supertypes"))))
    (lsp-hierarchy--request
     workspace method (list :item (lsp-hierarchy--node-lsp-item node))
     (lambda (result)
       (funcall callback
                (if (memq direction '(incoming outgoing))
                    (lsp-hierarchy--call-nodes result node (eq direction 'outgoing))
                  (mapcar (lambda (item) (lsp-hierarchy--symbol-node item workspace)) result))))
     error-handler)))

(defun lsp-hierarchy--prepare-failed (err)
  "Record ERR and display a failed root request."
  (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) nil
        (lsp-hierarchy--view-status lsp-hierarchy--view) 'error
        (lsp-hierarchy--view-error lsp-hierarchy--view) err)
  (lsp-hierarchy--render))

(defun lsp-hierarchy--prepare-requests (method queries)
  "Send METHOD for each (WORKSPACE . PARAMS) in QUERIES.
Display successful results once all requests finish; cancellation aborts."
  ;; Each server needs its own token: lsp-mode's multi-server requests can
  ;; release cancellation hooks after the first response, before aggregation.
  (let ((remaining (length queries)) responses errors done)
    (cl-labels
        ((cancel (err)
           (unless done (setq done t) (lsp-hierarchy--prepare-failed err)))
         (finish (workspace result failed)
           (unless done
             (if failed (push result errors) (push (cons workspace result) responses))
             (when (zerop (cl-decf remaining))
               (setq done t)
               (if (null responses)
                   (lsp-hierarchy--prepare-failed
                    (mapconcat #'lsp-hierarchy--error-message (nreverse errors) "; "))
                 ;; Empty replies count as success; preserve server/item order.
                 (let (roots)
                   (dolist (query queries)
                     (seq-doseq (item (cdr (assq (car query) responses)))
                       (push (cons (car query) item) roots)))
                   (lsp-hierarchy--display (nreverse roots))))))))
      ;; Count all queries first: send failures can complete synchronously.
      (dolist (query queries)
        (unless done
          (let ((workspace (car query)))
            (lsp-hierarchy--request
             workspace method (cdr query)
             (lambda (result) (finish workspace result nil))
             (lambda (err) (finish workspace err t)) #'cancel)))))))

(defun lsp-hierarchy--prepare (direction &optional target)
  "Prepare DIRECTION, replacing TARGET or the default view.
DIRECTION is `incoming', `outgoing', `subtypes' or `supertypes'."
  (let* ((call (memq direction '(incoming outgoing)))
         (method (if call
                     "textDocument/prepareCallHierarchy" "textDocument/prepareTypeHierarchy"))
         (lsp-method-requirements
          (append lsp-method-requirements lsp-hierarchy--method-requirements))
         (workspaces (let ((lsp--cur-workspace nil))
                       (or (lsp--find-workspaces-for method)
                           (user-error "%s hierarchy is not supported by the current servers" direction))))
         ;; Virtual adapters own their coordinates.  Ordinary positions and
         ;; URI handling must use each server's negotiated conventions.
         (queries (mapcar
                   (lambda (workspace)
                     (cons workspace
                           (with-lsp-workspace workspace
                             (lsp--text-document-position-params
                              nil (or (lsp-virtual-buffer-call :cur-position)
                                      (save-restriction
                                        (widen)
                                        (lsp-hierarchy--point-to-position workspace)))))))
                   workspaces))
         (view (or target (get-buffer-create
                           (if call "*LSP Call Hierarchy*" "*LSP Type Hierarchy*"))))
         (origin (copy-marker (point))))
    (with-current-buffer view
      (lsp-hierarchy--dispose)
      (unless (derived-mode-p 'lsp-hierarchy-mode) (lsp-hierarchy-mode))
      (setq lsp-hierarchy--view
            (lsp-hierarchy--make-view :origin origin :direction direction :status 'loading)
            mode-name (pcase direction
                        ('incoming "Incoming Calls") ('outgoing "Outgoing Calls")
                        ('subtypes "Subtypes") ('supertypes "Supertypes")))
      (lsp-hierarchy--render)
      (goto-char (point-min))
      (lsp-hierarchy--prepare-requests method queries))
    (if target view (pop-to-buffer view))))

;;; Rendering

(defvar lsp-hierarchy--mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'lsp-hierarchy-mouse-action)
    (define-key map [mouse-2] #'lsp-hierarchy-mouse-action)
    map)
  "Mouse bindings shared by all rows.")

(defun lsp-hierarchy--action-properties (action help)
  "Return shared text properties for ACTION and HELP."
  (list 'keymap lsp-hierarchy--mouse-map 'mouse-face 'highlight
        'follow-link t 'help-echo help 'lsp-hierarchy-action action))

(defun lsp-hierarchy--single-line (text)
  "Replace line breaks and tabs in TEXT for display on one row."
  (replace-regexp-in-string "[\t\n\r]+" " " text))

(defun lsp-hierarchy--location-help (uri range)
  "Describe URI and RANGE for hover help."
  (format "%s:%d" uri (1+ (lsp-get (lsp-get range :start) :line))))

(defun lsp-hierarchy--expandable-p (node)
  "Return non-nil if NODE has contents or has not resolved its children."
  (and node (or (not (eq (lsp-hierarchy--node-load-state node) 'loaded))
                (lsp-hierarchy--node-children node)
                (lsp-hierarchy--node-call-sites node))))

(defun lsp-hierarchy--insert-node (node indent)
  "Insert a symbol NODE at INDENT."
  (let ((beg (point))
        (kind (lsp-hierarchy--kind-abbrev (lsp-hierarchy--item-get node :kind))))
    (insert (make-string (* 2 indent) ?\s)
            (if (lsp-hierarchy--expandable-p node)
                (apply #'propertize
                       (if (lsp-hierarchy--node-expanded node)
                           lsp-hierarchy-icon-open lsp-hierarchy-icon-close)
                       'face 'lsp-hierarchy-icon-face
                       (lsp-hierarchy--action-properties #'lsp-hierarchy-toggle "Expand, fold or retry"))
              " ")
            " " (if (string-empty-p kind) "" (concat "[" kind "] ")))
    (insert (apply #'propertize (lsp-hierarchy--single-line (lsp-hierarchy--item-get node :name))
                   'face (if (seq-contains-p (lsp-hierarchy--item-get node :tags) 1)
                             'lsp-hierarchy-deprecated-face 'lsp-hierarchy-node-face)
                   (lsp-hierarchy--action-properties
                    #'lsp-hierarchy-goto
                    (lsp-hierarchy--location-help (lsp-hierarchy--item-get node :uri)
                                                  (lsp-hierarchy--item-get node :selectionRange)))))
    (when lsp-hierarchy-detailed-outline
      (when-let* ((detail (lsp-hierarchy--item-get node :detail)))
        (insert (propertize (concat " " (lsp-hierarchy--single-line (string-trim detail)))
                            'face 'lsp-hierarchy-detail-face)))
      (when-let* ((sites (lsp-hierarchy--node-call-sites node)))
        (insert (propertize (format " (%d site%s)" (length sites) (if (cdr sites) "s" ""))
                            'face 'lsp-hierarchy-detail-face))))
    (when (lsp-hierarchy--node-parent node)
      (insert (pcase (lsp-hierarchy--view-direction lsp-hierarchy--view)
                ('subtypes " ↓") ('supertypes " ↑") (_ ""))))
    (insert "\n")
    (add-text-properties beg (point) (list 'lsp-hierarchy-item node))))

(defun lsp-hierarchy--insert-call-site (node site indent)
  "Insert the source excerpt for NODE's SITE at INDENT."
  (insert (apply #'propertize
                 (concat (make-string (* 2 indent) ?\s) "    "
                         (lsp-hierarchy--extract-line (car site) (cdr site)
                                                      (lsp-hierarchy--node-workspace node)) "\n")
                 'lsp-hierarchy-item node 'lsp-hierarchy-call-site site
                 (lsp-hierarchy--action-properties
                  #'lsp-hierarchy-goto (lsp-hierarchy--location-help (car site) (cdr site))))))

(defun lsp-hierarchy--insert-subtree (node indent)
  "Insert NODE and its expanded contents at INDENT."
  (lsp-hierarchy--insert-node node indent)
  (when (lsp-hierarchy--node-expanded node)
    ;; Edge locations are already known, even while the next level loads.
    (dolist (site (lsp-hierarchy--node-call-sites node))
      (lsp-hierarchy--insert-call-site node site (1+ indent)))
    (dolist (child (lsp-hierarchy--node-children node))
      (lsp-hierarchy--insert-subtree child (1+ indent)))
    (when (memq (lsp-hierarchy--node-load-state node) '(loading error))
      (insert (apply #'propertize
                     (concat (make-string (* 2 (1+ indent)) ?\s)
                             (if (eq (lsp-hierarchy--node-load-state node) 'loading)
                                 "Loading..."
                               (concat (lsp-hierarchy--single-line
                                        (lsp-hierarchy--error-message (lsp-hierarchy--node-error node)))
                                       " (TAB to retry)")) "\n")
                     'lsp-hierarchy-item node 'lsp-hierarchy-status-node node
                     'face 'lsp-hierarchy-detail-face
                     (lsp-hierarchy--action-properties #'lsp-hierarchy-toggle "Fold or retry"))))))

(defun lsp-hierarchy--get-prop (property)
  "Return PROPERTY on the current row."
  (get-text-property (line-beginning-position) property))

(defun lsp-hierarchy--node-at-point ()
  "Return the current row's symbol owner."
  (lsp-hierarchy--get-prop 'lsp-hierarchy-item))

(defun lsp-hierarchy--render ()
  "Redraw the tree, keeping point on its row or nearest visible ancestor."
  (unless lsp-hierarchy--batch-loading
    (let ((node (lsp-hierarchy--node-at-point))
          (site (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site))
          (status (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node))
          (column (current-column)) (inhibit-read-only t) position)
      (erase-buffer)
      (pcase (lsp-hierarchy--view-status lsp-hierarchy--view)
        ('loading (insert "Loading hierarchy...\n"))
        ('error (insert "Unable to load hierarchy: "
                        (lsp-hierarchy--error-message (lsp-hierarchy--view-error lsp-hierarchy--view)) "\n"))
        (_ (if-let* ((roots (lsp-hierarchy--view-roots lsp-hierarchy--view)))
               (dolist (root roots) (lsp-hierarchy--insert-subtree root 0))
             (insert "No hierarchy found.\n"))))
      (setq position
            (or (and site (text-property-any (point-min) (point-max) 'lsp-hierarchy-call-site site))
                (and status (text-property-any (point-min) (point-max) 'lsp-hierarchy-status-node status))))
      (while (and node (not position))
        (setq position (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node)
              node (lsp-hierarchy--node-parent node)))
      (goto-char (or position (point-min)))
      (move-to-column column)
      (set-buffer-modified-p nil))))

;;; Loading and tree navigation

(defun lsp-hierarchy--ancestors-expanded-p (node)
  "Return non-nil if NODE's ancestors are all expanded."
  (let ((parent (lsp-hierarchy--node-parent node)))
    (or (null parent) (and (lsp-hierarchy--node-expanded parent)
                          (lsp-hierarchy--ancestors-expanded-p parent)))))

(defun lsp-hierarchy--recursive-occurrence-p (node)
  "Return non-nil if NODE repeats a symbol on its ancestor path."
  (let ((parent (lsp-hierarchy--node-parent node)) found)
    (while (and parent (not found))
      (setq found (and (eq (lsp-hierarchy--node-workspace node) (lsp-hierarchy--node-workspace parent))
                       (equal (lsp-hierarchy--item-get node :uri) (lsp-hierarchy--item-get parent :uri))
                       ;; Protocol objects may be hash tables or plists.
                       (lsp--position-equal (lsp-get (lsp-hierarchy--item-get node :selectionRange) :start)
                                            (lsp-get (lsp-hierarchy--item-get parent :selectionRange) :start))
                       (equal (lsp-hierarchy--item-get node :name) (lsp-hierarchy--item-get parent :name)))
            parent (lsp-hierarchy--node-parent parent)))
    found))

(defun lsp-hierarchy--expand-nodes (nodes depth)
  "Expand NODES to DEPTH, batching sibling loading rows."
  (let ((lsp-hierarchy--batch-loading t))
    (dolist (node nodes)
      (unless (lsp-hierarchy--recursive-occurrence-p node)
        (lsp-hierarchy--load-async node depth))))
  (lsp-hierarchy--render))

(defun lsp-hierarchy--load-async (node &optional depth)
  "Request NODE's children and optionally expand to DEPTH."
  (setf (lsp-hierarchy--node-load-state node) 'loading
        (lsp-hierarchy--node-error node) nil
        (lsp-hierarchy--node-expanded node) t)
  (lsp-hierarchy--render)
  (lsp-hierarchy--fetch-children
   node
   (lambda (children)
     (setf (lsp-hierarchy--node-children node) children
           (lsp-hierarchy--node-load-state node) 'loaded)
     (dolist (child children) (setf (lsp-hierarchy--node-parent child) node))
     ;; Folded nodes cache replies without reopening or loading deeper paths.
     (if (and (> (or depth 1) 1) (lsp-hierarchy--node-expanded node)
              (lsp-hierarchy--ancestors-expanded-p node))
         (lsp-hierarchy--expand-nodes children (1- depth))
       (lsp-hierarchy--render)))
   (lambda (err)
     (setf (lsp-hierarchy--node-load-state node) 'error
           (lsp-hierarchy--node-error node) err)
     (lsp-hierarchy--render))))

(defun lsp-hierarchy--display (roots)
  "Install (WORKSPACE . ITEM) pairs in ROOTS and apply initial expansion."
  (let ((nodes (mapcar (lambda (entry) (lsp-hierarchy--symbol-node (cdr entry) (car entry))) roots)))
    (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) nodes
          (lsp-hierarchy--view-status lsp-hierarchy--view) 'ready)
    (if (> lsp-hierarchy-expand-depth 0)
        (lsp-hierarchy--expand-nodes nodes lsp-hierarchy-expand-depth)
      (lsp-hierarchy--render))))

(defun lsp-hierarchy--move-line (count)
  "Move COUNT rows, clamping at the last nonempty row."
  (let ((column (current-column)))
    (forward-line count)
    (when (and (eobp) (bolp) (not (bobp))) (forward-line -1))
    (move-to-column column)))

(defun lsp-hierarchy-next-line (&optional count)
  "Move forward COUNT rows."
  (interactive "p")
  (lsp-hierarchy--move-line (or count 1)))

(defun lsp-hierarchy-previous-line (&optional count)
  "Move backward COUNT rows."
  (interactive "p")
  (lsp-hierarchy--move-line (- (or count 1))))

(defun lsp-hierarchy--goto-node (node)
  "Go to NODE's symbol row."
  (goto-char (or (and node (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node))
                 (user-error "Node is not visible"))))

(defun lsp-hierarchy-parent ()
  "Go to the parent symbol, or the owner of a call-site or status row."
  (interactive)
  (let ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here"))))
    (lsp-hierarchy--goto-node
     (if (or (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site)
             (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node))
         node (or (lsp-hierarchy--node-parent node) (user-error "No parent node"))))))

(defun lsp-hierarchy--move-sibling (backward)
  "Go to a sibling, moving BACKWARD when non-nil."
  (let* ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here")))
         (site (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site))
         (parent (lsp-hierarchy--node-parent node))
         (siblings (cond (site (lsp-hierarchy--node-call-sites node))
                         (parent (lsp-hierarchy--node-children parent))
                         (t (lsp-hierarchy--view-roots lsp-hierarchy--view))))
         (next (cadr (memq (or site node) (if backward (reverse siblings) siblings)))))
    (unless next (user-error "No %s sibling" (if backward "previous" "next")))
    (if site (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-call-site next))
      (lsp-hierarchy--goto-node next))))

(defun lsp-hierarchy-next-sibling ()
  "Go to the next sibling, skipping descendants."
  (interactive) (lsp-hierarchy--move-sibling nil))

(defun lsp-hierarchy-previous-sibling ()
  "Go to the previous sibling, skipping descendants."
  (interactive) (lsp-hierarchy--move-sibling t))

(defun lsp-hierarchy-collapse-or-parent ()
  "Fold the current branch, or go to its parent if already closed."
  (interactive)
  (let ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here"))))
    (if (and (not (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site))
             (lsp-hierarchy--node-expanded node) (lsp-hierarchy--expandable-p node))
        (progn (setf (lsp-hierarchy--node-expanded node) nil)
               (lsp-hierarchy--render)
               (lsp-hierarchy--goto-node node))
      (lsp-hierarchy-parent))))

(defun lsp-hierarchy-toggle ()
  "Toggle or retry the current branch; at a leaf or site, go to the next symbol."
  (interactive)
  (let ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here"))))
    (cond ((or (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site)
               (not (lsp-hierarchy--expandable-p node)))
           (when-let* ((next (save-excursion
                              (cl-loop while (and (zerop (forward-line 1)) (not (eobp)))
                                       when (and (lsp-hierarchy--node-at-point)
                                                 (not (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site))
                                                 (not (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node)))
                                       return (point)))))
             (goto-char next)))
          ((memq (lsp-hierarchy--node-load-state node) '(unloaded error))
           (lsp-hierarchy--load-async node))
          (t (setf (lsp-hierarchy--node-expanded node) (not (lsp-hierarchy--node-expanded node)))
             (lsp-hierarchy--render)))))

(defalias 'lsp-hierarchy-smart-tab #'lsp-hierarchy-toggle)

(defun lsp-hierarchy--location-at-point ()
  "Return (WORKSPACE URI RANGE) for the symbol or call site at point."
  (let ((node (lsp-hierarchy--node-at-point))
        (site (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site)))
    (unless (and node (not (lsp-hierarchy--get-prop 'lsp-hierarchy-status-node)))
      (user-error "No source location here"))
    (list (lsp-hierarchy--node-workspace node)
          (if site (car site) (lsp-hierarchy--item-get node :uri))
          (if site (cdr site) (lsp-hierarchy--item-get node :selectionRange)))))

(defun lsp-hierarchy-goto ()
  "Visit source and record the departure in xref history."
  (interactive)
  (pcase-let ((`(,workspace ,uri ,range) (lsp-hierarchy--location-at-point)))
    (lsp-hierarchy--open-file uri range workspace)))

(defun lsp-hierarchy-preview ()
  "Preview source in another window without changing focus or xref history."
  (interactive)
  (pcase-let* ((`(,workspace ,uri ,range) (lsp-hierarchy--location-at-point))
               (buffer (find-file-noselect (with-lsp-workspace workspace (lsp--uri-to-path uri))))
               (origin (selected-window)) (tree (current-buffer)) (point (point)))
    (save-selected-window
      (save-excursion
        (let ((window (display-buffer buffer lsp-hierarchy-display-buffer-action)))
          (unless (window-live-p window) (user-error "No window available for source preview"))
          (when (eq window origin)
            (set-window-buffer origin tree)
            (set-window-point origin point)
            (user-error "Source preview needs another window; adjust its display action"))
          (with-current-buffer buffer
            (set-window-point window (lsp-hierarchy--location-point range workspace))))))))

(defun lsp-hierarchy-mouse-action (event)
  "Invoke the action at mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (call-interactively (or (get-text-property (point) 'lsp-hierarchy-action)
                          (user-error "No hierarchy action here"))))

;;; Mode and query commands

(defvar lsp-hierarchy-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("n" . lsp-hierarchy-next-line) ("p" . lsp-hierarchy-previous-line)
                       ("u" . lsp-hierarchy-parent) ("<left>" . lsp-hierarchy-collapse-or-parent)
                       ("M-n" . lsp-hierarchy-next-sibling) ("M-p" . lsp-hierarchy-previous-sibling)
                       ("TAB" . lsp-hierarchy-toggle) ("<tab>" . lsp-hierarchy-toggle)
                       ("RET" . lsp-hierarchy-goto) ("SPC" . lsp-hierarchy-preview)
                       ("d" . lsp-hierarchy-switch-direction) ("g" . lsp-hierarchy-refresh)
                       ("?" . describe-mode)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Keymap for `lsp-hierarchy-mode'.")

(define-derived-mode lsp-hierarchy-mode special-mode "LSP-Hierarchy"
  "Browse call and type hierarchies, loading children on demand.
\\{lsp-hierarchy-mode-map}"
  :interactive nil
  :group 'lsp-hierarchy
  (setq-local buffer-undo-list t truncate-lines t indent-tabs-mode nil
              revert-buffer-function #'lsp-hierarchy--revert
              lsp-hierarchy--view (lsp-hierarchy--make-view))
  (add-hook 'kill-buffer-hook #'lsp-hierarchy--dispose nil t)
  (add-hook 'change-major-mode-hook #'lsp-hierarchy--dispose nil t))

(defun lsp-hierarchy--restart (switch)
  "Repeat the query at its source marker, reversing direction if SWITCH."
  (unless (and (derived-mode-p 'lsp-hierarchy-mode) lsp-hierarchy--view)
    (user-error "Not in a hierarchy view"))
  (let ((target (current-buffer))
        (origin (lsp-hierarchy--view-origin lsp-hierarchy--view))
        (direction (lsp-hierarchy--view-direction lsp-hierarchy--view)))
    (unless (and (markerp origin) (marker-buffer origin))
      (user-error "The hierarchy source buffer has been killed"))
    (when switch
      (setq direction (pcase direction
                        ('incoming 'outgoing) ('outgoing 'incoming)
                        ('subtypes 'supertypes) ('supertypes 'subtypes))))
    (with-current-buffer (marker-buffer origin)
      (save-restriction
        (widen)
        (save-excursion
          (goto-char origin)
          (lsp-hierarchy--prepare direction target))))))

(defun lsp-hierarchy-refresh ()
  "Query again at the original source marker, using the initial expansion depth."
  (interactive)
  (lsp-hierarchy--restart nil))

(defun lsp-hierarchy-switch-direction ()
  "Switch callers/callees or subtypes/supertypes at the original source marker."
  (interactive)
  (lsp-hierarchy--restart t))

(defun lsp-hierarchy--revert (_ignore-auto _noconfirm)
  "Refresh the hierarchy through `revert-buffer'."
  (lsp-hierarchy-refresh))

;;;###autoload
(defun lsp-hierarchy-show-call (&optional outgoing)
  "Show incoming calls, or OUTGOING calls with a prefix argument."
  (interactive "P")
  (lsp-hierarchy--prepare (if outgoing 'outgoing 'incoming)))

;;;###autoload
(defun lsp-hierarchy-show-type (&optional super)
  "Show subtypes, or supertypes with a prefix argument SUPER."
  (interactive "P")
  (lsp-hierarchy--prepare (if super 'supertypes 'subtypes)))

(provide 'lsp-hierarchy)
;;; lsp-hierarchy.el ends here
