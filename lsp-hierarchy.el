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
  "Include signatures and known call-site counts in symbol labels.
Site counts describe source locations along the hierarchy edge, not
execution counts."
  :type 'boolean
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-show-location nil
  "Show a source path and line number beside each symbol.
Use a workspace-relative path for ordinary file URIs under a known local
workspace root.  Otherwise show the full URI.  This only formats existing
node data; it never reads source files or invokes URI handlers."
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

;;; Core: View and Node State

(cl-defstruct (lsp-hierarchy--node (:constructor lsp-hierarchy--make-node))
  "One occurrence of an LSP item in a hierarchy view.
Each occurrence has independent expansion and request state, even when
several paths lead to the same protocol item.  The node object itself is
its identity; view roots and parent/child links own the model."
  ;; Protocol items belong to their server, including any opaque `data'.
  workspace lsp-item type name kind tags detail annotation uri range
  ;; call-sites describe the incoming edge, not the shared symbol itself.
  ;; children starts with known call sites; relationship children are added
  ;; when their independent request completes.
  parent children call-sites
  ;; Expansion is a user choice; loading can finish while a node is folded.
  ;; load-state is one of unloaded/loading/loaded/error.  A loaded empty
  ;; children list is a known leaf; an error remains retryable.
  expanded (load-state 'unloaded) request error
  ;; A refresh snapshot contains identities and UI choices, never old LSP data.
  restore)

(cl-defstruct (lsp-hierarchy--saved-node (:constructor lsp-hierarchy--make-saved-node))
  "Immutable identity and expansion state of one occurrence before refresh."
  workspace key expanded children)

(cl-defstruct (lsp-hierarchy--view (:constructor lsp-hierarchy--make-view))
  "Resources and query context owned by one hierarchy buffer."
  ;; origin follows source edits and is detached when this view is disposed.
  source origin kind direction roots (status 'ready) error
  ;; Re-rooted queries stay with the server owning the selected symbol.
  workspace
  ;; Keep pending focus separate: a user command cancels cursor restoration,
  ;; while expansion can continue asynchronously until the saved path loads.
  restore restore-focus restore-window-focus
  (generation (make-symbol "lsp-hierarchy-view"))
  (requests (make-hash-table :test 'eq))
  (file-cache (make-hash-table :test 'equal)))

(defvar-local lsp-hierarchy--view nil
  "The model and resources owned by this buffer.")

(defvar-local lsp-hierarchy-sort-order nil
  "Sibling order in this view: nil for server order, `name', or `location'.")

(defvar-local lsp-hierarchy-filter-regexp nil
  "Regexp matching loaded symbol names and details, or nil for all nodes.
Filtering reveals matching ancestor paths without changing expansion state.")

(defvar-local lsp-hierarchy--header-line nil
  "Direction, sort order and filter of the last successful render.")

(defvar-local lsp-hierarchy--row-positions nil
  "Positions of the currently displayed node and status rows, keyed by node.")

(defvar lsp-hierarchy--render-positions nil
  "Row positions being built by the current render, before publication.")

(defvar lsp-hierarchy--filter-matches nil
  "Nodes retained by the current render's filter projection, or nil.")

(defun lsp-hierarchy--cancel-request (token)
  "Cancel TOKEN and release handlers even when sending cancellation fails."
  ;; Keep this compatibility boundary until lsp-mode's cancellation cleanup
  ;; is unconditional: UI code must not manage protocol handler tables.
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
    (when-let* ((origin (lsp-hierarchy--view-origin lsp-hierarchy--view)))
      (set-marker origin nil))
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

(defvar lsp-hierarchy--mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'lsp-hierarchy-mouse-action)
    (define-key map [mouse-2] #'lsp-hierarchy-mouse-action)
    map)
  "Shared mouse bindings for hierarchy actions.
Keyboard bindings fall through to `lsp-hierarchy-mode-map', including TAB.")

(defun lsp-hierarchy--action-properties (action help)
  "Return text properties invoking ACTION and displaying HELP."
  (list 'keymap lsp-hierarchy--mouse-map 'mouse-face 'highlight
        'follow-link t 'help-echo help 'lsp-hierarchy-action action))

(defun lsp-hierarchy--single-line (text)
  "Return TEXT with line breaks and tabs replaced for a single display row."
  (replace-regexp-in-string "[\t\n\r]+" " " text))

(defun lsp-hierarchy--location-text (node &optional relative)
  "Return NODE's URI and line, using a relative path when RELATIVE permits."
  (when-let* ((uri (lsp-hierarchy--node-uri node)))
    (let* ((range (lsp-hierarchy--node-range node))
           (start (and range (lsp-get range :start)))
           (workspace (lsp-hierarchy--node-workspace node))
           (root (and relative workspace (lsp--workspace-root workspace)))
           ;; Compare URI prefixes lexically.  Calling URI handlers here can
           ;; materialize virtual files; remote paths also keep their URI.
           (prefix (and (stringp root) (string-prefix-p "/" root)
                        (not (string-match-p "\\`/[^/]+:" root))
                        (concat "file://"
                                (url-hexify-string
                                 (concat (string-remove-suffix "/" root) "/")
                                 lsp--url-path-allowed-chars))))
           (label (if (and prefix (string-prefix-p prefix uri))
                      (decode-coding-string
                       (url-unhex-string (substring uri (length prefix))) 'utf-8)
                    uri)))
      (concat (lsp-hierarchy--single-line label)
              (when start
                ;; Protocol columns may count encoding units rather than
                ;; display characters; converting them would need source.
                (format ":%d" (1+ (lsp-get start :line))))))))

(defun lsp-hierarchy--location-help (node action)
  "Return ACTION with NODE's full source location for its hover help."
  (if-let* ((location (lsp-hierarchy--location-text node)))
      (concat action "\n" location)
    action))

(defun lsp-hierarchy--display-detail (node)
  "Return NODE's visible detail text, or nil when omitted."
  (when-let* ((detail (and lsp-hierarchy-detailed-outline
                          (lsp-hierarchy--node-detail node)))
              (text (lsp-hierarchy--single-line (string-trim-left detail)))
              ((not (string-empty-p text))))
    text))

(defun lsp-hierarchy--insert-node (item indent)
  "Insert ITEM at INDENT using its structured name and location."
  (let ((beg (point)))
    (when lsp-hierarchy--render-positions
      (puthash item (cons beg nil) lsp-hierarchy--render-positions))
    (insert (make-string (* indent 2) ?\s))
    (pcase (lsp-hierarchy--node-type item)
      ('code
       ;; Source reads stay lazy: unopened siblings contain only locations.
       (insert "    "
               (apply #'propertize
                      (lsp-hierarchy--extract-line
                       (lsp-hierarchy--node-uri item)
                       (lsp-hierarchy--node-range item)
                       (lsp-hierarchy--node-workspace item))
                      (lsp-hierarchy--action-properties
                       #'lsp-hierarchy-goto
                       (lsp-hierarchy--location-help item "mouse-1, RET: Visit this call site")))))
      ('symbol
       (insert (apply #'propertize "@" 'lsp-hierarchy-icon-marker t
                      (lsp-hierarchy--icon-properties item)) " ")
       (let ((abbrev (lsp-hierarchy--kind-abbrev (lsp-hierarchy--node-kind item))))
         (unless (string-empty-p abbrev)
           (insert (propertize (concat "[" abbrev "] ")
                               'face 'lsp-hierarchy-detail-face))))
       ;; Names may contain spaces.  Style protocol fields directly instead
       ;; of parsing a formatted label back into name and signature.
       (insert (apply #'propertize
                      (lsp-hierarchy--single-line (lsp-hierarchy--node-name item))
                      ;; SymbolTag.Deprecated is 1.  Unknown tags leave the
                      ;; ordinary symbol style intact; details remain separate.
                      'face (if (seq-contains-p (lsp-hierarchy--node-tags item) 1)
                                'lsp-hierarchy-deprecated-face
                              'lsp-hierarchy-node-face)
                      (lsp-hierarchy--action-properties
                       #'lsp-hierarchy-goto
                       (lsp-hierarchy--location-help item "mouse-1, RET: Visit this symbol"))))
       (when-let* ((detail (lsp-hierarchy--display-detail item)))
         (insert (propertize (concat " " detail)
                             'face 'lsp-hierarchy-detail-face)))
       ;; These locations belong to this occurrence's incoming edge.  The
       ;; same symbol elsewhere in the tree may have a different site count.
       (when-let* ((sites (and lsp-hierarchy-detailed-outline
                              (lsp-hierarchy--node-call-sites item))))
         (let ((count (length sites)))
           (insert (propertize (format " (%d site%s)" count (if (= count 1) "" "s"))
                               'face 'lsp-hierarchy-detail-face
                               'help-echo "Known source call sites on this hierarchy edge"))))
       (when-let* ((annotation (lsp-hierarchy--node-annotation item)))
         (insert (propertize annotation 'face 'lsp-hierarchy-detail-face)))
       (when-let* ((location (and lsp-hierarchy-show-location
                                 (lsp-hierarchy--location-text item t))))
         (insert (apply #'propertize (concat " — " location)
                        'face 'lsp-hierarchy-detail-face
                        (lsp-hierarchy--action-properties
                         #'lsp-hierarchy-goto
                         (lsp-hierarchy--location-help item "mouse-1, RET: Visit this symbol")))))))
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
             (lsp-hierarchy--visible-p parent)))))

(defun lsp-hierarchy--matching-nodes (roots)
  "Return a table of ROOTS' loaded matches and ancestors, or nil.
Only protocol labels are searched; filtering never reads hidden source files
or asks a language server to discover more nodes."
  (when lsp-hierarchy-filter-regexp
    (let ((matches (make-hash-table :test 'eq)))
      (cl-labels
          ((visit (node)
             (let ((direct (and (eq (lsp-hierarchy--node-type node) 'symbol)
                                (string-match-p
                                 lsp-hierarchy-filter-regexp
                                 (concat (lsp-hierarchy--single-line (lsp-hierarchy--node-name node))
                                         (when-let* ((detail (lsp-hierarchy--display-detail node)))
                                           (concat " " detail))))))
                   descendant)
               ;; Visit every loaded child, even beneath folded ancestors.
               (dolist (child (lsp-hierarchy--node-children node))
                 (when (visit child) (setq descendant t)))
               ;; Filtering may reveal a path of symbol names, but source
               ;; excerpts still require the user's expansion choice.
               (when (and direct (lsp-hierarchy--node-expanded node))
                 (dolist (site (lsp-hierarchy--node-call-sites node))
                   (puthash site t matches)))
               ;; Refresh replaces the cached descendants before loading
               ;; them again.  Keep open loading/error branches reachable
               ;; even if only those missing descendants match the filter.
               (when (or direct descendant
                         (and (lsp-hierarchy--node-expanded node)
                              (or (memq (lsp-hierarchy--node-load-state node) '(loading error))
                                  ;; Restored nodes render once before their
                                  ;; request starts.  Keep reachable pending
                                  ;; paths visible so focus is not completed
                                  ;; on a temporary filtered-out row.
                                  (and (eq (lsp-hierarchy--node-load-state node) 'unloaded)
                                       (lsp-hierarchy--node-restore node)
                                       (lsp-hierarchy--visible-p node)))))
                 (puthash node t matches)))))
        (mapc #'visit roots))
      matches)))

(defun lsp-hierarchy--location-less-p (left right)
  "Return non-nil if LEFT precedes RIGHT by URI and source position."
  (let ((left-uri (or (lsp-hierarchy--node-uri left) ""))
        (right-uri (or (lsp-hierarchy--node-uri right) ""))
        (left-start (lsp-get (lsp-hierarchy--node-range left) :start))
        (right-start (lsp-get (lsp-hierarchy--node-range right) :start)))
    (if (equal left-uri right-uri)
        (let ((left-line (or (lsp-get left-start :line) 0))
              (right-line (or (lsp-get right-start :line) 0)))
          (if (= left-line right-line)
              (< (or (lsp-get left-start :character) 0)
                 (or (lsp-get right-start :character) 0))
            (< left-line right-line)))
      (string-lessp left-uri right-uri))))

(defun lsp-hierarchy--display-nodes (nodes)
  "Return NODES in presentation order without changing the model lists."
  (let ((visible (if lsp-hierarchy--filter-matches
                     (seq-filter (lambda (node) (gethash node lsp-hierarchy--filter-matches)) nodes)
                   nodes)))
    (if (null lsp-hierarchy-sort-order)
        visible
      (let* ((symbol-p (lambda (node) (eq (lsp-hierarchy--node-type node) 'symbol)))
             (symbols (seq-filter symbol-p visible))
             (sites (seq-remove symbol-p visible)))
        ;; Stable sorting keeps server order for equal keys.  Call sites
        ;; retain source order before the independently sorted symbols.
        (append sites
                (cl-stable-sort
                 symbols (if (eq lsp-hierarchy-sort-order 'location)
                             #'lsp-hierarchy--location-less-p
                           (lambda (left right)
                             (string-lessp (lsp-hierarchy--node-name left)
                                           (lsp-hierarchy--node-name right))))))))))

(defun lsp-hierarchy--expanded-for-display-p (node)
  "Return non-nil when NODE's children should appear in this projection."
  (if lsp-hierarchy--filter-matches
      (or (seq-some (lambda (child) (gethash child lsp-hierarchy--filter-matches))
                    (lsp-hierarchy--node-children node))
          (and (lsp-hierarchy--node-expanded node)
               (memq (lsp-hierarchy--node-load-state node) '(loading error))))
    (lsp-hierarchy--node-expanded node)))

(defun lsp-hierarchy--filter-path-p (node)
  "Return non-nil if the filter keeps a symbol path below NODE visible."
  ;; Call sites follow folding, whereas matching symbol paths stay visible
  ;; even after a fold.  Only the latter need the filter override hint.
  (and lsp-hierarchy--filter-matches
       (seq-some (lambda (child)
                   (and (eq (lsp-hierarchy--node-type child) 'symbol)
                        (gethash child lsp-hierarchy--filter-matches)))
                 (lsp-hierarchy--node-children node))))

(defun lsp-hierarchy--insert-subtree (node indent)
  "Render NODE and its visible descendants at INDENT."
  (lsp-hierarchy--insert-node node indent)
  (when (lsp-hierarchy--expanded-for-display-p node)
    ;; Call sites are already known from the incoming edge.  They remain
    ;; usable while the next level of relationships is loading or fails.
    (dolist (child (lsp-hierarchy--display-nodes (lsp-hierarchy--node-children node)))
      (lsp-hierarchy--insert-subtree child (1+ indent)))
    (when (memq (lsp-hierarchy--node-load-state node) '(loading error))
      (let* ((loading (eq (lsp-hierarchy--node-load-state node) 'loading))
             (text (if loading "Loading..."
                     (concat (lsp-hierarchy--single-line
                              (lsp-hierarchy--error-message (lsp-hierarchy--node-error node)))
                             " (TAB to retry)"))))
        (when lsp-hierarchy--render-positions
          (setcdr (gethash node lsp-hierarchy--render-positions) (point)))
        (insert (apply #'propertize
                       (concat (make-string (* (1+ indent) 2) ?\s) "  " text "\n")
                       'face (if loading 'lsp-hierarchy-detail-face 'error)
                       'lsp-hierarchy-loading loading
                       'lsp-hierarchy-status-node node
                       (lsp-hierarchy--action-properties
                        #'lsp-hierarchy-toggle
                        (if loading "mouse-1, TAB: Fold this branch"
                          "mouse-1, TAB: Retry loading children"))))))))

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
           (rows lsp-hierarchy--row-positions)
           (position (and node rows (nth 2 anchor) (cdr (gethash node rows)))))
      ;; Hidden descendants have no row entry.  Walking their parent links
      ;; needs only table lookups, rather than scanning all text at each level.
      (while (and node rows (not position))
        (setq position (car (gethash node rows))
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
         (lsp-hierarchy--render-positions (make-hash-table :test 'eq))
         (close-icon lsp-hierarchy-icon-close)
         (open-icon lsp-hierarchy-icon-open)
         (detailed lsp-hierarchy-detailed-outline)
         (show-location lsp-hierarchy-show-location)
         (sort-order lsp-hierarchy-sort-order)
         (lsp-hierarchy--filter-matches
          (lsp-hierarchy--matching-nodes (lsp-hierarchy--view-roots view)))
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
                             lsp-hierarchy-detailed-outline detailed
                             lsp-hierarchy-show-location show-location
                             lsp-hierarchy-sort-order sort-order)
                 (pcase (lsp-hierarchy--view-status view)
                   ('loading (insert "Loading hierarchy...\n"))
                   ('error (insert "Unable to load hierarchy: "
                                   (lsp-hierarchy--error-message (lsp-hierarchy--view-error view)) "\n"))
                   (_ (if (lsp-hierarchy--view-roots view)
                          (let ((roots (lsp-hierarchy--display-nodes (lsp-hierarchy--view-roots view))))
                            (if roots
                                (dolist (node roots) (lsp-hierarchy--insert-subtree node 0))
                              (insert "No loaded symbols match the filter.\n")))
                        (insert "No hierarchy found.\n"))))
                 (buffer-string))))
    (let ((inhibit-read-only t))
      (atomic-change-group
        (erase-buffer)
        (insert text)))
    ;; Positions describe the candidate text, so publish them only after the
    ;; same text has replaced the buffer successfully.
    (setq lsp-hierarchy--row-positions lsp-hierarchy--render-positions)
    (goto-char (lsp-hierarchy--anchor-position anchor))
    (dolist (entry windows)
      (when (window-live-p (car entry))
        (set-window-start (car entry) (lsp-hierarchy--anchor-position (nth 1 entry)) t)
        (set-window-point (car entry) (lsp-hierarchy--anchor-position (nth 2 entry)))))
    (setq lsp-hierarchy--header-line
          (format " %s | Sort: %s | Filter: %s"
                  mode-name (or lsp-hierarchy-sort-order 'server)
                  (if lsp-hierarchy-filter-regexp
                      (prin1-to-string lsp-hierarchy-filter-regexp)
                    "none")))
    (force-mode-line-update)
    (set-buffer-modified-p nil)
    (lsp-hierarchy--restore-focus)))

;;; Core: Interaction Logic

(defun lsp-hierarchy-mouse-action (event)
  "Invoke the hierarchy action at mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  ;; Store command symbols on the text, not closures over individual nodes.
  ;; Both mouse and keyboard actions resolve the current model row at point.
  (let ((action (get-text-property (point) 'lsp-hierarchy-action)))
    (unless action (user-error "No hierarchy action here"))
    (call-interactively action)))

(defun lsp-hierarchy-cycle-sort ()
  "Cycle this view through server, name, and source location order."
  (interactive)
  (let ((previous lsp-hierarchy-sort-order))
    (setq lsp-hierarchy-sort-order
          (pcase previous ('nil 'name) ('name 'location) (_ nil)))
    (condition-case err
        (lsp-hierarchy--render)
      (error
       (setq lsp-hierarchy-sort-order previous)
       (signal (car err) (cdr err))))
    (message "Hierarchy order: %s" (or lsp-hierarchy-sort-order 'server))))

(defun lsp-hierarchy-filter (regexp)
  "Show loaded symbols matching REGEXP and their ancestor paths.
Match symbol names and details.  Empty REGEXP clears the filter and
restores the model's folding state.  While filtering, matching paths remain
visible even when their underlying nodes are folded.  No language-server
requests are sent."
  (interactive (list (read-string "Filter loaded symbols (empty clears): "
                                  lsp-hierarchy-filter-regexp)))
  ;; Validate before changing presentation state, so a typo preserves the view.
  (unless (string-empty-p regexp) (string-match-p regexp ""))
  (let ((previous lsp-hierarchy-filter-regexp))
    (setq lsp-hierarchy-filter-regexp (unless (string-empty-p regexp) regexp))
    (condition-case err
        (lsp-hierarchy--render)
      (error
       (setq lsp-hierarchy-filter-regexp previous)
       (signal (car err) (cdr err))))))

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

(defun lsp-hierarchy--move-line (count)
  "Move COUNT rows without stopping on the trailing empty line."
  (let ((column (current-column)))
    (forward-line count)
    ;; Every rendered row ends with a newline.  Its trailing empty line has
    ;; no node or status owner, so it is not a useful navigation destination.
    (when (and (eobp) (bolp) (not (bobp)))
      (forward-line -1))
    (move-to-column column)))

(defun lsp-hierarchy-next-line (&optional count)
  "Move forward COUNT rows, stopping at the last nonempty row."
  (interactive "p")
  (lsp-hierarchy--move-line (or count 1)))

(defun lsp-hierarchy-previous-line (&optional count)
  "Move backward COUNT rows, stopping at the first row."
  (interactive "p")
  (lsp-hierarchy--move-line (- (or count 1))))

(defun lsp-hierarchy--goto-node (node)
  "Move to the start of NODE's visible row."
  (let ((position (and node (text-property-any (point-min) (point-max)
                                              'lsp-hierarchy-item node))))
    (unless position (user-error "Node is not visible"))
    (goto-char position)))

(defun lsp-hierarchy-parent ()
  "Move to the parent of the node at point."
  (interactive)
  (let* ((node (lsp-hierarchy--node-at-point))
         (parent (and node (lsp-hierarchy--node-parent node))))
    (unless parent (user-error "No parent node"))
    (lsp-hierarchy--goto-node parent)))

(defun lsp-hierarchy--visible-siblings (node)
  "Return NODE's visible siblings in their displayed order."
  (let ((parent (lsp-hierarchy--node-parent node))
        (position (point-min)) siblings)
    ;; Scan the visible rows once.  Looking up every model sibling separately
    ;; would repeatedly scan the buffer when a node has thousands of children.
    (while (< position (point-max))
      (let ((candidate (get-text-property position 'lsp-hierarchy-item)))
        (when (and candidate (eq (lsp-hierarchy--node-parent candidate) parent))
          (push candidate siblings)))
      (setq position (next-single-property-change position 'lsp-hierarchy-item nil (point-max))))
    (nreverse siblings)))

(defun lsp-hierarchy--move-sibling (backward)
  "Move to the next sibling, or the previous one when BACKWARD is non-nil."
  (let* ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here")))
         (siblings (lsp-hierarchy--visible-siblings node))
         (target (cadr (memq node (if backward (reverse siblings) siblings)))))
    (unless target (user-error "No %s sibling" (if backward "previous" "next")))
    (lsp-hierarchy--goto-node target)))

(defun lsp-hierarchy-next-sibling ()
  "Move to the next visible sibling, skipping descendants."
  (interactive)
  (lsp-hierarchy--move-sibling nil))

(defun lsp-hierarchy-previous-sibling ()
  "Move to the previous visible sibling, skipping descendants."
  (interactive)
  (lsp-hierarchy--move-sibling t))

(defun lsp-hierarchy-collapse-or-parent ()
  "Collapse the current branch, or move to its parent if already closed.
A loading or failed branch is folded without cancelling or retrying it."
  (interactive)
  (let ((node (or (lsp-hierarchy--node-at-point) (user-error "No node here"))))
    (if (and (lsp-hierarchy--node-expanded node) (lsp-hierarchy--expandable-p node))
        (progn
          (setf (lsp-hierarchy--node-expanded node) nil)
          (condition-case err
              (lsp-hierarchy--render)
            (error
             (setf (lsp-hierarchy--node-expanded node) t)
             (signal (car err) (cdr err))))
          (lsp-hierarchy--goto-node node))
      (lsp-hierarchy-parent))))

(defun lsp-hierarchy-toggle ()
  "Toggle the node at point, loading its children when necessary."
  (interactive)
  (let ((node (lsp-hierarchy--node-at-point)))
    (unless node (user-error "No node here"))
    (cond
     ((not (lsp-hierarchy--expandable-p node)) (lsp-hierarchy-next-line))
     ((memq (lsp-hierarchy--node-load-state node) '(unloaded error))
      (lsp-hierarchy--load-async node))
     (t
      (let ((expanded (lsp-hierarchy--node-expanded node)))
        (setf (lsp-hierarchy--node-expanded node) (not expanded))
        (condition-case err
            (progn
              (lsp-hierarchy--render)
              (when (lsp-hierarchy--node-expanded node)
                (lsp-hierarchy--resume-restore (list node))))
          (error
           (setf (lsp-hierarchy--node-expanded node) expanded)
           (signal (car err) (cdr err)))))))))

(defvar lsp-hierarchy--batch-loading nil
  "Non-nil while starting a group of automatic expansion requests.")

(defun lsp-hierarchy--render-expansion ()
  "Publish automatic expansion states without invalidating loaded data."
  ;; Requests have already started and their nodes belong to the tree.  A display
  ;; error here must not turn a successful parent response into a failed one:
  ;; retrying that parent would replace children whose requests are still live.
  (condition-case err
      (lsp-hierarchy--render)
    (error (message "LSP hierarchy: could not redraw expansion: %s"
                    (lsp-hierarchy--error-message err)))))

(defun lsp-hierarchy--recursive-occurrence-p (node)
  "Return non-nil if NODE repeats a symbol on its own ancestor path."
  (let ((workspace (lsp-hierarchy--node-workspace node))
        (key (lsp-hierarchy--refresh-key node))
        (ancestor (lsp-hierarchy--node-parent node)))
    (while (and ancestor
                (not (and (eq workspace (lsp-hierarchy--node-workspace ancestor))
                          (equal key (lsp-hierarchy--refresh-key ancestor)))))
      (setq ancestor (lsp-hierarchy--node-parent ancestor)))
    ancestor))

(defun lsp-hierarchy--expand-nodes (nodes depth)
  "Start expansion of NODES to DEPTH and publish their loading states together."
  (when nodes
    ;; Sending a request can also fail synchronously.  Both loading and error
    ;; rows are published once after the batch, instead of once per sibling.
    (let ((lsp-hierarchy--batch-loading t))
      (dolist (node nodes)
        ;; Depth already bounds recursion, but querying the same ancestor
        ;; again adds no new relationship information.  Keep the occurrence
        ;; closed for explicit expansion; other sibling paths stay independent.
        (unless (lsp-hierarchy--recursive-occurrence-p node)
          (lsp-hierarchy--load-async node depth))))
    (unless lsp-hierarchy--batch-loading (lsp-hierarchy--render-expansion))))

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
           (unless lsp-hierarchy--batch-loading (lsp-hierarchy--render))
           (message "LSP hierarchy: %s (TAB to retry)" (lsp-hierarchy--error-message err)))
         (succeed (children)
           (let ((previous (lsp-hierarchy--node-children node))
                 (nodes (append (lsp-hierarchy--node-call-sites node) children)))
             ;; The renderer builds the entire candidate display off-screen.
             ;; Roll back candidate children on failure so retry cannot
             ;; duplicate rows or leave unreachable model occurrences.
             (setf (lsp-hierarchy--node-children node) nodes
                   (lsp-hierarchy--node-load-state node) 'loaded
                   (lsp-hierarchy--node-request node) nil)
             (dolist (child nodes) (setf (lsp-hierarchy--node-parent child) node))
             (when-let* ((saved (lsp-hierarchy--node-restore node)))
               (lsp-hierarchy--match-restore nodes (lsp-hierarchy--saved-node-children saved)))
             (condition-case err
                 (lsp-hierarchy--render)
               (error
                (setf (lsp-hierarchy--node-children node) previous)
                (fail err)))
             (when (eq (lsp-hierarchy--node-load-state node) 'loaded)
               (lsp-hierarchy--resume-restore (list node)))
             ;; A response may arrive under a folded ancestor.  Keep its
             ;; children cached, but do not start more automatic requests.
             (when (and (eq (lsp-hierarchy--node-load-state node) 'loaded)
                        (> depth 1) (lsp-hierarchy--node-expanded node)
                        (lsp-hierarchy--visible-p node))
               (lsp-hierarchy--expand-nodes
                (seq-filter (lambda (child) (eq (lsp-hierarchy--node-type child) 'symbol)) nodes)
                (1- depth))))))
      (condition-case err
          (progn
            (unless lsp-hierarchy--batch-loading (lsp-hierarchy--render))
            (lsp-hierarchy--fetch-children
             node (lsp-hierarchy--view-source lsp-hierarchy--view) #'succeed #'fail token))
        (error (fail err))))))

(defun lsp-hierarchy--location-node-at-point ()
  "Return the node at point, signaling an error if it has no source location."
  (let ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item)))
    (unless (and node (lsp-hierarchy--node-uri node) (lsp-hierarchy--node-range node))
      (user-error "No location for this node"))
    node))

(defun lsp-hierarchy-goto ()
  "Jump to the source location of the node at point."
  (interactive)
  (let ((node (lsp-hierarchy--location-node-at-point)))
    (lsp-hierarchy--open-file (lsp-hierarchy--node-uri node)
                             (lsp-hierarchy--node-range node)
                             (lsp-hierarchy--node-workspace node))))

(defun lsp-hierarchy-preview ()
  "Show the source location at point while keeping focus in the hierarchy.
Preview does not add an xref history entry or run jump hooks."
  (interactive)
  (let* ((node (lsp-hierarchy--location-node-at-point))
         (workspace (lsp-hierarchy--node-workspace node))
         (filename (with-lsp-workspace workspace
                     (lsp--uri-to-path (lsp-hierarchy--node-uri node))))
         (buffer (find-file-noselect filename))
         (origin-window (selected-window))
         (origin-buffer (current-buffer))
         (origin-point (point)))
    (save-selected-window
      (save-excursion
        (let ((window (display-buffer buffer lsp-hierarchy-display-buffer-action)))
          (unless (window-live-p window)
            (user-error "No window available for source preview"))
          ;; Respect the user's display rule, but never replace the tree with
          ;; a preview.  Explain an incompatible same-window rule instead.
          (when (eq window origin-window)
            (set-window-buffer origin-window origin-buffer)
            (set-window-point origin-window origin-point)
            (user-error "Source preview needs another window; adjust its display action"))
          (with-current-buffer buffer
            (set-window-point window
                              (lsp-hierarchy--location-point
                               (lsp-hierarchy--node-range node) workspace))))))))

(defun lsp-hierarchy-smart-tab ()
  "Toggle the node at point, or move to the next visible symbol.
Keep point unchanged when there is no later symbol."
  (interactive)
  (if (lsp-hierarchy--expandable-p (lsp-hierarchy--node-at-point))
      (lsp-hierarchy-toggle)
    (when-let* ((next
                (save-excursion
                  (let (found)
                    (while (and (not found) (zerop (forward-line 1)) (not (eobp)))
                      (when-let* ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
                                  ((eq (lsp-hierarchy--node-type node) 'symbol)))
                        (setq found (point))))
                    found))))
      (goto-char next))))

;;; Expansion Indicators

(defun lsp-hierarchy--icon-properties (item)
  "Return display properties for ITEM's expander."
  (let ((expandable (lsp-hierarchy--expandable-p item)))
    (append
     (list 'face 'lsp-hierarchy-icon-face
           'display (if expandable
                        (if (lsp-hierarchy--expanded-for-display-p item)
                            lsp-hierarchy-icon-open
                          lsp-hierarchy-icon-close)
                      " "))
     (when expandable
       (lsp-hierarchy--action-properties
        #'lsp-hierarchy-toggle
        (concat
         (cond ((eq (lsp-hierarchy--node-load-state item) 'error)
                "mouse-1, TAB: Retry loading children")
               ((lsp-hierarchy--node-expanded item) "mouse-1, TAB: Fold this branch")
               (t "mouse-1, TAB: Expand this branch"))
         (cond ((lsp-hierarchy--filter-path-p item)
                "\nFilter keeps matching paths visible; clear it to apply folding")
               ((and (lsp-hierarchy--node-expanded item)
                     (not (lsp-hierarchy--expanded-for-display-p item)))
                "\nChildren are hidden by the filter"))))))))

;;; Major Mode Definition

(defvar lsp-hierarchy-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'lsp-hierarchy-next-line)
    (define-key map (kbd "p") #'lsp-hierarchy-previous-line)
    (define-key map (kbd "u") #'lsp-hierarchy-parent)
    (define-key map (kbd "<left>") #'lsp-hierarchy-collapse-or-parent)
    (define-key map (kbd "M-n") #'lsp-hierarchy-next-sibling)
    (define-key map (kbd "M-p") #'lsp-hierarchy-previous-sibling)
    (define-key map (kbd "TAB") #'lsp-hierarchy-smart-tab)
    (define-key map (kbd "<tab>") #'lsp-hierarchy-smart-tab)
    (define-key map (kbd "RET") #'lsp-hierarchy-goto)
    (define-key map (kbd "SPC") #'lsp-hierarchy-preview)
    (define-key map (kbd "s") #'lsp-hierarchy-cycle-sort)
    (define-key map (kbd "/") #'lsp-hierarchy-filter)
    (define-key map (kbd "d") #'lsp-hierarchy-switch-direction)
    (define-key map (kbd "r") #'lsp-hierarchy-reroot)
    (define-key map (kbd "g") #'lsp-hierarchy-refresh)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for `lsp-hierarchy-mode'.")

(define-derived-mode lsp-hierarchy-mode special-mode "LSP-Hierarchy"
  "Major mode for viewing LSP hierarchy views.
Click an arrow to fold or expand a branch, or a name or call site to visit it.
Failed requests can be retried by clicking their status row.
\\{lsp-hierarchy-mode-map}"
  :interactive nil
  :group 'lsp-hierarchy

  (setq-local buffer-undo-list t)
  (setq-local buffer-read-only t)
  (setq-local indent-tabs-mode nil)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'lsp-hierarchy--revert)
  ;; A symbol's string value is literal in mode/header lines, so percent
  ;; constructs in a user's regexp cannot expand into unrelated buffer data.
  (setq-local header-line-format '("" lsp-hierarchy--header-line))

  (setq-local lsp-hierarchy--view (lsp-hierarchy--make-view))
  (add-hook 'pre-command-hook #'lsp-hierarchy--before-command nil t)
  (add-hook 'kill-buffer-hook #'lsp-hierarchy--dispose nil t)
  (add-hook 'change-major-mode-hook #'lsp-hierarchy--dispose nil t))

(defun lsp-hierarchy--display (roots)
  "Populate the current view from (WORKSPACE . ITEM) pairs in ROOTS."
  (let ((nodes (mapcar (lambda (entry)
                         (lsp-hierarchy--symbol-node (cdr entry) (car entry)))
                       roots)))
    (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) nodes
          (lsp-hierarchy--view-status lsp-hierarchy--view) 'ready)
    (when-let* ((state (lsp-hierarchy--view-restore lsp-hierarchy--view)))
      (lsp-hierarchy--match-restore nodes (plist-get state :roots)))
    (lsp-hierarchy--render)
    (if (lsp-hierarchy--view-restore lsp-hierarchy--view)
        (lsp-hierarchy--resume-restore nodes)
      (when (> lsp-hierarchy-expand-depth 0)
        (lsp-hierarchy--expand-nodes nodes lsp-hierarchy-expand-depth)))))

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
                      ("utf-8"
                       (cond ((<= char #x7f) 1)
                             ((<= char #x7ff) 2)
                             ((<= char #xffff) 3)
                             ((<= char #x10ffff) 4)
                             ;; Emacs can also hold raw bytes and characters
                             ;; outside Unicode.  Keep its encoder's behavior
                             ;; there; ordinary source text allocates nothing.
                             (t (string-bytes
                                 (encode-coding-string (char-to-string char) 'utf-8)))))
                      ("utf-32" 1)
                      (_ (if (> char #xffff) 2 1)))))
        (setq remaining (- remaining units))
        (forward-char 1)))
    (point)))

(defun lsp-hierarchy--point-to-position (workspace)
  "Return point as an LSP position in WORKSPACE's negotiated encoding.
The caller must widen the source buffer before converting."
  (let* ((prefix (buffer-substring-no-properties (line-beginning-position) (point)))
         (column (pcase (lsp-hierarchy--position-encoding workspace)
                   ("utf-8" (string-bytes (encode-coding-string prefix 'utf-8)))
                   ("utf-32" (length prefix))
                   (_ (cl-loop for char across prefix sum (if (> char #xffff) 2 1))))))
    (list :line (1- (line-number-at-pos)) :character column)))

(defun lsp-hierarchy--source-snapshot (filename)
  "Return a current buffer for FILENAME, reusing owned snapshots."
  (or (find-buffer-visiting filename)
      (let* ((cache (lsp-hierarchy--view-file-cache lsp-hierarchy--view))
             (entry (gethash filename cache))
             (snapshot (cdr entry))
             complete)
        (unwind-protect
            (let* ((attrs (or (file-attributes filename)
                              (signal 'file-missing (list "Source file is missing" filename))))
                   (signature (list (file-attribute-modification-time attrs)
                                    (file-attribute-size attrs))))
              ;; A missing file needs no buffer.  Publish new cache entries
              ;; only after reading succeeds, including on remote I/O errors.
              (unless (buffer-live-p snapshot)
                (setq snapshot (generate-new-buffer " *lsp-hierarchy-source*")
                      entry nil))
              (unless (equal (car entry) signature)
                (with-current-buffer snapshot
                  (erase-buffer)
                  (insert-file-contents filename))
                (puthash filename (cons signature snapshot) cache))
              (setq complete t)
              snapshot)
          ;; Failed refreshes can leave a formerly valid snapshot empty or
          ;; partially read.  It is owned by this view, never a visited buffer.
          (unless complete
            (when (buffer-live-p snapshot) (kill-buffer snapshot))
            (remhash filename cache))))))

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

(defun lsp-hierarchy--location-point (range workspace)
  "Return RANGE's start in the current source buffer for WORKSPACE.
Keep existing narrowing when it contains the location; otherwise widen so
that the destination window can display the target."
  (let ((target (save-restriction
                  (widen)
                  (save-excursion
                    (lsp-hierarchy--position-to-point
                     (lsp-get range :start) (lsp-hierarchy--position-encoding workspace))))))
    (unless (<= (point-min) target (point-max)) (widen))
    target))

(defun lsp-hierarchy--open-file (uri range &optional workspace)
  "Open URI at RANGE using WORKSPACE's URI handling and xref history."
  (let ((filename (with-lsp-workspace workspace (lsp--uri-to-path uri))))
    (xref-push-marker-stack)
    (pop-to-buffer (find-file-noselect filename) lsp-hierarchy-display-buffer-action)
    (goto-char (lsp-hierarchy--location-point range workspace))
    (run-hooks 'xref-after-jump-hook)))

(defun lsp-hierarchy--symbol-node (item workspace &optional annotation)
  "Describe one occurrence of protocol ITEM owned by WORKSPACE.
ANNOTATION is optional view text.  Keep ITEM intact, including opaque data;
selectionRange identifies the name rather than its whole declaration."
  (lsp-hierarchy--make-node
   :workspace workspace :lsp-item item :type 'symbol
   :name (lsp-get item :name) :kind (lsp-get item :kind)
   :tags (lsp-get item :tags)
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
                       (append (lsp-get call :fromRanges) nil))
               (lsp-hierarchy--node-children node) (lsp-hierarchy--node-call-sites node))
         (dolist (site (lsp-hierarchy--node-call-sites node))
           (setf (lsp-hierarchy--node-parent site) node))
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

(defun lsp-hierarchy--prepare (view-type direction &optional target restore workspace)
  "Prepare VIEW-TYPE in DIRECTION, replacing TARGET or the default view.
RESTORE is an optional snapshot of expansion and point before refresh.
WORKSPACE, when non-nil, restricts the query to that attached server."
  (let* ((source (current-buffer))
         (method (if (eq view-type 'call)
                     "textDocument/prepareCallHierarchy" "textDocument/prepareTypeHierarchy"))
         (lsp-method-requirements
          (append lsp-method-requirements lsp-hierarchy--method-requirements))
         (workspaces
          (let* ((lsp--cur-workspace nil)
                 (supported (lsp--find-workspaces-for method)))
            (if workspace
                (if (memq workspace supported) (list workspace)
                  (user-error "The symbol's language server is not attached or no longer supports this hierarchy"))
              (or supported
                  (user-error "%s hierarchy is not supported by the current servers"
                              (capitalize (symbol-name view-type)))))))
         (params (if workspace
                     (with-lsp-workspace workspace
                       (lsp--text-document-position-params nil (lsp-hierarchy--point-to-position workspace)))
                   (lsp--text-document-position-params)))
         (name (if (eq view-type 'call) "*LSP Call Hierarchy*" "*LSP Type Hierarchy*"))
         (view (or target (get-buffer-create name)))
         (origin (copy-marker (point))))
    (with-current-buffer view
      ;; Replacing the model cancels old requests and frees snapshots, while
      ;; retaining the user's buffer-local display preferences and mode hooks.
      (if (derived-mode-p 'lsp-hierarchy-mode)
          (progn
            (lsp-hierarchy--dispose)
            (setq lsp-hierarchy--view (lsp-hierarchy--make-view)))
        (lsp-hierarchy-mode))
      (setf (lsp-hierarchy--view-source lsp-hierarchy--view) source
            (lsp-hierarchy--view-origin lsp-hierarchy--view) origin
            (lsp-hierarchy--view-kind lsp-hierarchy--view) view-type
            (lsp-hierarchy--view-direction lsp-hierarchy--view) direction
            (lsp-hierarchy--view-workspace lsp-hierarchy--view) workspace
            (lsp-hierarchy--view-status lsp-hierarchy--view) 'loading
            (lsp-hierarchy--view-restore lsp-hierarchy--view) restore
            (lsp-hierarchy--view-restore-focus lsp-hierarchy--view) (plist-get restore :focus)
            (lsp-hierarchy--view-restore-window-focus lsp-hierarchy--view)
            (plist-get restore :window-focus))
      (setq mode-name (if (eq view-type 'call)
                          (if direction "Outgoing Calls" "Incoming Calls")
                        (if (eq direction 'supertypes) "Supertypes" "Subtypes")))
      (lsp-hierarchy--render)
      (goto-char (point-min))
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
    ;; Refreshing an existing view can run from `revert-buffer' in the
    ;; background.  Only opening a new query should choose a window.
    (if target view (pop-to-buffer view))))

;;; Refresh State

(defun lsp-hierarchy--refresh-key (node)
  "Return NODE's scalar identity, independent of protocol representation."
  (let* ((range (lsp-hierarchy--node-range node))
         (start (and range (lsp-get range :start)))
         (end (and range (lsp-get range :end))))
    (list (lsp-hierarchy--node-type node) (lsp-hierarchy--node-uri node)
          (lsp-hierarchy--node-name node) (lsp-hierarchy--node-kind node)
          (and start (lsp-get start :line)) (and start (lsp-get start :character))
          (and end (lsp-get end :line)) (and end (lsp-get end :character)))))

(defun lsp-hierarchy--save-refresh-state ()
  "Snapshot expansion and point without retaining old nodes or server data."
  (let ((anchor (lsp-hierarchy--anchor (point)))
        (pending (lsp-hierarchy--view-restore-focus lsp-hierarchy--view))
        (windows (mapcar (lambda (window)
                           (cons window (lsp-hierarchy--anchor (window-point window))))
                         (get-buffer-window-list (current-buffer) nil t)))
        (replacements (make-hash-table :test 'eq)) focus window-focus)
    (cl-labels
        ((rebase (saved-focus)
           (cons (mapcar (lambda (old) (or (gethash old replacements) old))
                         (car saved-focus))
                 (cdr saved-focus)))
         (pending-windows ()
           ;; Each window owns its cursor, including when another buffer is
           ;; selected.  Keep only windows still displaying this view.
           (dolist (entry (lsp-hierarchy--view-restore-window-focus lsp-hierarchy--view))
             (when (assq (car entry) windows)
               (setf (alist-get (car entry) window-focus) (rebase (cdr entry)))))
           window-focus)
         (save-node (node path)
           (let* ((saved (lsp-hierarchy--make-saved-node
                          :workspace (lsp-hierarchy--node-workspace node)
                          :key (lsp-hierarchy--refresh-key node)
                          :expanded (lsp-hierarchy--node-expanded node)))
                  (path (append path (list saved))))
             (when-let* ((previous (lsp-hierarchy--node-restore node)))
               (puthash previous saved replacements))
             (when (eq node (car anchor))
               (setq focus (list path (cadr anchor) (nth 2 anchor))))
             (dolist (entry windows)
               (when (eq node (cadr entry))
                 (push (cons (car entry) (list path (nth 2 entry) (nth 3 entry))) window-focus)))
             (setf (lsp-hierarchy--saved-node-children saved)
                   (mapcar (lambda (child) (save-node child path))
                           (lsp-hierarchy--node-children node)))
             (when-let* (((not (eq (lsp-hierarchy--node-load-state node) 'loaded)))
                         (previous (lsp-hierarchy--node-restore node)))
               ;; Another refresh may interrupt restoration.  Keep paths not
               ;; loaded yet; snapshots of current rows override their old
               ;; choices, including a branch the user has since folded.
               (let ((replaced (make-hash-table :test 'eq)))
                 (dolist (child (lsp-hierarchy--node-children node))
                   (puthash (lsp-hierarchy--node-restore child) t replaced))
                 (setf (lsp-hierarchy--saved-node-children saved)
                       (append (lsp-hierarchy--saved-node-children saved)
                               (seq-remove (lambda (child) (gethash child replaced))
                                           (lsp-hierarchy--saved-node-children previous))))))
             saved)))
      (if-let* ((roots (lsp-hierarchy--view-roots lsp-hierarchy--view)))
          (let ((saved (mapcar (lambda (node) (save-node node nil)) roots)))
            ;; Point may only have reached an ancestor of the pending target.
            ;; Rebase that deeper path onto snapshots created for fresh rows;
            ;; unloaded descendants still share their immutable saved records.
            (when pending
              (setq focus (rebase pending)))
            (list :roots saved :focus focus :window-focus (pending-windows)))
        ;; Before prepare finishes there are no new rows to snapshot.  Only
        ;; the live focus slot may survive; the original snapshot's focus
        ;; could already have been cancelled by a user command.
        (when-let* (((memq (lsp-hierarchy--view-status lsp-hierarchy--view) '(loading error)))
                    (roots (plist-get (lsp-hierarchy--view-restore lsp-hierarchy--view) :roots)))
          (list :roots roots :focus pending :window-focus (pending-windows)))))))

(defun lsp-hierarchy--match-restore (nodes snapshots)
  "Match fresh NODES to sibling SNAPSHOTS, preserving each occurrence.
Workspaces compare by identity; equal siblings consume snapshots in order.
Matching stays within one parent so shared symbols keep independent state."
  (when snapshots
    (let ((workspaces (make-hash-table :test 'eq)))
      ;; Workspace structs are mutable: only scalar keys belong in an equal
      ;; table.  Reversed insertion makes each bucket a queue in sibling order.
      (dolist (saved (reverse snapshots))
        (let* ((workspace (lsp-hierarchy--saved-node-workspace saved))
               (items (or (gethash workspace workspaces)
                          (puthash workspace (make-hash-table :test 'equal) workspaces)))
               (key (lsp-hierarchy--saved-node-key saved)))
          (puthash key (cons saved (gethash key items)) items)))
      (dolist (node nodes)
        (when-let* ((items (gethash (lsp-hierarchy--node-workspace node) workspaces))
                    (key (lsp-hierarchy--refresh-key node))
                    (queue (gethash key items))
                    (saved (car queue)))
          (puthash key (cdr queue) items)
          ;; Known call sites may have been matched before this response.
          ;; Consume their snapshot, but preserve any subsequent user choice.
          (unless (lsp-hierarchy--node-restore node)
            (setf (lsp-hierarchy--node-restore node) saved
                  (lsp-hierarchy--node-expanded node) (lsp-hierarchy--saved-node-expanded saved))
            (lsp-hierarchy--match-restore (lsp-hierarchy--node-children node)
                                          (lsp-hierarchy--saved-node-children saved))))))))

(defun lsp-hierarchy--resume-restore (nodes)
  "Continue saved expansions below visible, open NODES.
A folded ancestor suspends descent.  Failed requests need an explicit retry;
only unloaded nodes may start automatically, using their new protocol items."
  (let (started)
    (let ((lsp-hierarchy--batch-loading t))
      (dolist (node nodes)
        (when (and (lsp-hierarchy--node-restore node)
                   (lsp-hierarchy--node-expanded node)
                   (lsp-hierarchy--visible-p node))
          (if (eq (lsp-hierarchy--node-load-state node) 'unloaded)
              (progn
                (setq started t)
                (lsp-hierarchy--load-async node))
            (when (lsp-hierarchy--resume-restore (lsp-hierarchy--node-children node))
              (setq started t))))))
    (when (and started (not lsp-hierarchy--batch-loading))
      (lsp-hierarchy--render-expansion))
    started))

(defun lsp-hierarchy--before-command ()
  "Preserve pending focus for refresh; let other commands take ownership."
  ;; A second g/revert continues the same restoration.  Prefix g explicitly
  ;; requests a reset, while navigation and other actions cancel late jumps.
  (unless (and (memq this-command '(lsp-hierarchy-refresh revert-buffer revert-buffer-quick))
               (or (not (eq this-command 'lsp-hierarchy-refresh))
                   (null current-prefix-arg)))
    (lsp-hierarchy--cancel-restore-focus)))

(defun lsp-hierarchy--cancel-restore-focus ()
  "Clear pending focus without changing saved expansion choices."
  (when (lsp-hierarchy--view-p lsp-hierarchy--view)
    (setf (lsp-hierarchy--view-restore-focus lsp-hierarchy--view) nil
          (lsp-hierarchy--view-restore-window-focus lsp-hierarchy--view) nil)))

(defun lsp-hierarchy--resolve-focus (focus)
  "Return (POSITION . PENDING) for the saved FOCUS path.
POSITION is its deepest visible match.  PENDING means an open ancestor is
still loading the missing path, or prepare has failed and remains retryable."
  (let ((path (car focus))
        (nodes (lsp-hierarchy--view-roots lsp-hierarchy--view))
        node next)
    (while (and path
                (setq next (seq-find (lambda (candidate)
                                       (eq (car path) (lsp-hierarchy--node-restore candidate)))
                                     nodes)))
      (setq node next path (cdr path)
            nodes (and (lsp-hierarchy--node-expanded node)
                       (lsp-hierarchy--node-children node))))
    (cons (and node (lsp-hierarchy--anchor-position
                     (list node (cadr focus) (and (null path) (nth 2 focus)))))
          (or (memq (lsp-hierarchy--view-status lsp-hierarchy--view) '(loading error))
              (and path node (lsp-hierarchy--node-expanded node)
                   (memq (lsp-hierarchy--node-load-state node) '(unloaded loading)))))))

(defun lsp-hierarchy--restore-focus ()
  "Restore pending buffer and window points without selecting any window."
  (when-let* ((focus (lsp-hierarchy--view-restore-focus lsp-hierarchy--view)))
    (let ((result (lsp-hierarchy--resolve-focus focus)))
      (when (car result) (goto-char (car result)))
      (unless (cdr result)
        (setf (lsp-hierarchy--view-restore-focus lsp-hierarchy--view) nil))))
  ;; `goto-char' only updates buffer point.  Nonselected windows need an
  ;; explicit update, using their own saved path rather than the main cursor.
  (setf (lsp-hierarchy--view-restore-window-focus lsp-hierarchy--view)
        (delq nil
              (mapcar
               (lambda (entry)
                 (let ((window (car entry)))
                   (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
                     (let ((result (lsp-hierarchy--resolve-focus (cdr entry))))
                       (when (car result) (set-window-point window (car result)))
                       (and (cdr result) entry)))))
               (lsp-hierarchy--view-restore-window-focus lsp-hierarchy--view)))))

(defun lsp-hierarchy-reroot ()
  "Start this hierarchy afresh at the symbol at point.
The source buffer must be managed by the symbol's owning language server.
If necessary, activate LSP in that source buffer and retry.  Subsequent
refreshes and direction changes stay with that server and source marker."
  (interactive)
  (let* ((node (lsp-hierarchy--location-node-at-point))
         (workspace (lsp-hierarchy--node-workspace node))
         (target (current-buffer))
         (kind (lsp-hierarchy--view-kind lsp-hierarchy--view))
         (direction (lsp-hierarchy--view-direction lsp-hierarchy--view)))
    (unless (eq (lsp-hierarchy--node-type node) 'symbol)
      (user-error "Re-root requires a symbol node"))
    (unless workspace (user-error "No language server owns this symbol"))
    (let ((source (find-file-noselect
                   (with-lsp-workspace workspace
                     (lsp--uri-to-path (lsp-hierarchy--node-uri node))))))
      (save-selected-window
        (with-current-buffer source
          ;; Opening a file can run the user's LSP hooks.  Require an actual
          ;; attachment; this UI must not invent workspace membership or
          ;; duplicate lsp-mode's didOpen/lifecycle machinery.
          (let ((lsp--cur-workspace nil))
            (unless (memq workspace (lsp-workspaces))
              (user-error "Activate LSP server %s in %s, then retry re-root"
                          (lsp--client-server-id (lsp--workspace-client workspace))
                          (buffer-name source))))
          (save-restriction
            (widen)
            (save-excursion
              (goto-char (lsp-hierarchy--position-to-point
                          (lsp-get (lsp-hierarchy--node-range node) :start)
                          (lsp-hierarchy--position-encoding workspace)))
              ;; Re-prepare at the target location instead of reusing stale
              ;; opaque item data.  All validation precedes view replacement.
              (lsp-hierarchy--prepare kind direction target nil workspace))))))))

(defun lsp-hierarchy-switch-direction ()
  "Switch between callers/callees or subtypes/supertypes at the same origin.
Start a fresh tree for the new relationships while retaining this view's
sorting, filtering, and other display preferences."
  (interactive)
  (unless (and (derived-mode-p 'lsp-hierarchy-mode) lsp-hierarchy--view)
    (user-error "Not in a hierarchy view"))
  (let* ((target (current-buffer))
         (kind (lsp-hierarchy--view-kind lsp-hierarchy--view))
         (previous (lsp-hierarchy--view-direction lsp-hierarchy--view))
         (direction (if (eq kind 'call) (not previous)
                      (if (eq previous 'supertypes) 'subtypes 'supertypes)))
         (origin (lsp-hierarchy--view-origin lsp-hierarchy--view))
         (workspace (lsp-hierarchy--view-workspace lsp-hierarchy--view)))
    (unless (and (markerp origin) (marker-buffer origin))
      (user-error "The hierarchy source buffer has been killed"))
    (save-selected-window
      (with-current-buffer (marker-buffer origin)
        (save-restriction
          (widen)
          (save-excursion
            (goto-char origin)
            ;; Opposite relationships have different paths: expansion and
            ;; pending focus from the previous direction must not be restored.
            (lsp-hierarchy--prepare kind direction target nil workspace)))))))

(defun lsp-hierarchy-refresh (&optional reset)
  "Refresh this view at its original source position.
The source marker follows edits, but moving point in the source buffer does
not change the query.  Expansion and point are restored where paths still
match; nodes and server data are always fetched afresh.  With prefix RESET,
start over using `lsp-hierarchy-expand-depth' instead of preserving state."
  (interactive "P")
  (unless (and (derived-mode-p 'lsp-hierarchy-mode) lsp-hierarchy--view)
    (user-error "Not in a hierarchy view"))
  (let ((target (current-buffer))
        (kind (lsp-hierarchy--view-kind lsp-hierarchy--view))
        (direction (lsp-hierarchy--view-direction lsp-hierarchy--view))
        (origin (lsp-hierarchy--view-origin lsp-hierarchy--view))
        (workspace (lsp-hierarchy--view-workspace lsp-hierarchy--view))
        (restore (unless reset (lsp-hierarchy--save-refresh-state))))
    (unless (and (markerp origin) (marker-buffer origin))
      (user-error "The hierarchy source buffer has been killed"))
    (with-current-buffer (marker-buffer origin)
      (save-restriction
        (widen)
        (save-excursion
          (goto-char origin)
          (lsp-hierarchy--prepare kind direction target restore workspace))))))

(defun lsp-hierarchy--revert (_ignore-auto _noconfirm)
  "Refresh the current hierarchy through `revert-buffer'."
  (lsp-hierarchy-refresh))

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
