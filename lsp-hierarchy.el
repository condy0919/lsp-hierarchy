;;; lsp-hierarchy.el --- LSP hierarchy views using hierarchy.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 emacs-lsp maintainers

;; Author: emacs-lsp maintainers
;; Keywords: languages, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (lsp-mode "9.0") (dash "2.18.0") (f "0.20.0"))
;; Homepage: https://github.com/emacs-lsp/lsp-hierarchy
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

;; LSP hierarchy views using Emacs' built-in `hierarchy.el'.
;;
;; Provides tree views for:
;; - Call hierarchy (incoming/outgoing)
;; - Type hierarchy (subtypes/supertypes)
;; - Document symbols
;; - References
;; - Implementations
;; - Error/diagnostic list
;;
;; Unlike `lsp-treemacs', this package does not depend on `treemacs'
;; and renders without icon dependencies.

;;; Code:

(require 'hierarchy)
(require 'wid-edit)
(require 'tree-widget)
(require 'lsp-mode)
(require 'dash)
(require 'f)


;;; Customization

(defgroup lsp-hierarchy nil
  "LSP hierarchy views using hierarchy.el."
  :group 'lsp-mode
  :tag "LSP Hierarchy")

(defcustom lsp-hierarchy-call-hierarchy-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-call-hierarchy'.
When nil, only root items are shown."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-type-hierarchy-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-type-hierarchy'."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-symbols-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-symbols'."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-references-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-references'."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-implementations-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-implementations'."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-error-list-expand-depth nil
  "Automatic expansion depth for `lsp-hierarchy-errors'."
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Depth"))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-error-list-severity 3
  "Maximum severity level for `lsp-hierarchy-errors'.
1=error, 2=warning, 3=info, 4=hint."
  :type '(choice (const :tag "Errors only" 1)
                 (const :tag "Errors & Warnings" 2)
                 (const :tag "Errors, Warnings & Info" 3)
                 (const :tag "All" 4))
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-after-jump-hook
  (list (lambda () (run-hooks 'xref-after-jump-hook)))
  "Hook run after jumping to a location from the hierarchy view."
  :type 'hook
  :group 'lsp-hierarchy)

(defcustom lsp-hierarchy-detailed-outline t
  "Whether `lsp-hierarchy-symbols' should include signatures."
  :type 'boolean
  :group 'lsp-hierarchy)


;;; Faces

(defface lsp-hierarchy-error-face
  '((t :inherit error))
  "Face for error diagnostics in hierarchy view."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-warning-face
  '((t :inherit warning))
  "Face for warning diagnostics in hierarchy view."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-info-face
  '((t :inherit success))
  "Face for info diagnostics in hierarchy view."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-hint-face
  '((t :inherit shadow))
  "Face for hint diagnostics in hierarchy view."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-detail-face
  '((t :inherit shadow))
  "Face for detail text in hierarchy labels."
  :group 'lsp-hierarchy)

(defface lsp-hierarchy-call-site-face
  '((t :inherit highlight))
  "Face for call site source lines."
  :group 'lsp-hierarchy)


;;; Core: item representation

;; Each node in the hierarchy is a plist:
;;   :label       - display string (required)
;;   :goto-fn     - function of no args to jump to location (optional)
;;   :lsp-item    - the underlying LSP protocol item (optional)
;;   :kind        - LSP symbol kind number (optional)
;;   :detail      - extra detail string (optional, shown after label)
;;   :leaf        - non-nil for leaf nodes (optional)
;;   :children    - pre-computed list of child plists (optional)
;;   :children-fn - function returning child plists for lazy loading (optional)

(defun lsp-hierarchy--make-item (label &rest plist)
  "Create a hierarchy item with LABEL and additional PLIST properties."
  (apply #'list :label label plist))

(defun lsp-hierarchy--kind-name (kind)
  "Return a human-readable name for LSP symbol KIND."
  (cl-case kind
    (1  "File")      (2  "Module")    (3  "Namespace")
    (4  "Package")   (5  "Class")     (6  "Method")
    (7  "Property")  (8  "Field")     (9  "Constructor")
    (10 "Enum")      (11 "Interface") (12 "Function")
    (13 "Variable")  (14 "Constant")  (15 "String")
    (16 "Number")    (17 "Boolean")   (18 "Array")
    (19 "Object")    (20 "Key")       (21 "Null")
    (22 "EnumMember") (23 "Struct")   (24 "Event")
    (25 "Operator")  (26 "TypeParameter")
    (t "Symbol")))

(defun lsp-hierarchy--kind-abbrev (kind)
  "Return a short abbreviation for LSP symbol KIND."
  (cl-case kind
    (5  "c")   (6  "m")   (9  "M")   (11 "I")
    (12 "f")   (23 "s")   (10 "e")   (14 "C")
    (7  "p")   (8  "v")   (1  "F")
    (t "")))


;;; Core: tree-widget display

(defun lsp-hierarchy--tree-display (hierarchy labelfn depth buffer-name title)
  "Display HIERARCHY as a tree in a buffer named BUFFER-NAME.
LABELFN is called with (item indent) and should insert the label text.
DEPTH is the maximum depth to auto-expand (nil means no auto-expand).
TITLE is used as the buffer's mode-line title.
Returns the buffer."
  (require 'wid-edit)
  (require 'tree-widget)
  (let* ((buf (get-buffer-create buffer-name))
         (tree-widget (lsp-hierarchy--convert-to-tree-widget hierarchy labelfn depth)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (widget-create tree-widget)
        (when depth
          (lsp-hierarchy--expand-tree-widgets (widget-get tree-widget :children)
                                              depth))
        (goto-char (point-min)))
      (lsp-hierarchy-mode)
      (setq mode-name title)
      (setq-local buffer-read-only t))
    (switch-to-buffer buf)
    buf))

(defun lsp-hierarchy--expand-tree-widgets (widgets depth)
  "Expand WIDGETS to DEPTH levels (DEPTH 0 = expand one level)."
  (when (and widgets (> depth 0))
    (dolist (w widgets)
      (when (widget-get w :expander)
        (widget-apply w :expander)
        (lsp-hierarchy--expand-tree-widgets
         (widget-get w :children)
         (1- depth))))))

(defun lsp-hierarchy--convert-to-tree-widget (hierarchy labelfn _depth)
  "Convert HIERARCHY to a tree-widget.
LABELFN is a function (item indent) that inserts the label.
Each tree-widget node stores :lsp-item for RET/goto."
  (hierarchy-map-tree
   (lambda (item indent children)
     (let ((delayed-childrenfn
            (map-elt (hierarchy--delaying-parents hierarchy) item)))
       (apply #'widget-convert
              (list 'tree-widget
                    :tag (lsp-hierarchy--labelfn-to-string labelfn item indent)
                    :lsp-item item
                    :depth indent
                    (if delayed-childrenfn :expander :args)
                    (if delayed-childrenfn
                        (lsp-hierarchy--create-delayed-expander
                         item labelfn indent delayed-childrenfn)
                      children)))))
   hierarchy))

(defun lsp-hierarchy--create-delayed-expander (item labelfn indent childrenfn)
  "Create a tree-widget expander for ITEM.
Calls CHILDRENFN synchronously to get children, then builds tree-widget nodes."
  (lambda (widget)
    (let ((children (condition-case err
                        (funcall childrenfn item)
                      (error
                       (lsp-warn "Failed to get children for %s: %s"
                                 (plist-get item :label)
                                 (error-message-string err))
                       nil))))
      (widget-put widget :args
                  (mapcar (lambda (child)
                            (widget-convert
                             'tree-widget
                             :tag (lsp-hierarchy--labelfn-to-string
                                   labelfn child (1+ indent))
                             :lsp-item child
                             :depth (1+ indent)
                             :args (when-let ((gc (plist-get child :children-fn)))
                                     nil)
                             :expander (when-let ((gc (plist-get child :children-fn)))
                                         (lsp-hierarchy--create-delayed-expander
                                          child labelfn (1+ indent) gc))))
                          children))
      (widget-apply widget :expander))))

(defun lsp-hierarchy--labelfn-to-string (labelfn item indent)
  "Execute LABELFN on ITEM and INDENT.  Return result as a string."
  (with-temp-buffer
    (funcall labelfn item indent)
    (buffer-substring (point-min) (point-max))))


;;; Core: lsp-hierarchy-mode

(defvar lsp-hierarchy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'lsp-hierarchy-goto)
    (define-key map (kbd "<mouse-1>") #'lsp-hierarchy-goto-mouse)
    (define-key map (kbd "g") #'lsp-hierarchy-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `lsp-hierarchy-mode'.")

(define-derived-mode lsp-hierarchy-mode special-mode "LSP-Hierarchy"
  "Major mode for LSP hierarchy tree views.

\\{lsp-hierarchy-mode-map}"
  (setq-local revert-buffer-function #'lsp-hierarchy--revert))

(defvar-local lsp-hierarchy--refresh-fn nil
  "Function to call when refreshing the hierarchy buffer.")

(defun lsp-hierarchy--revert (&optional _ignore-auto _noconfirm)
  "Revert the hierarchy buffer by calling `lsp-hierarchy--refresh-fn'."
  (when lsp-hierarchy--refresh-fn
    (funcall lsp-hierarchy--refresh-fn)))

(defun lsp-hierarchy-refresh ()
  "Refresh the current hierarchy view."
  (interactive)
  (lsp-hierarchy--revert))


;;; Core: goto

(defun lsp-hierarchy--widget-at-point ()
  "Return the tree-widget at point if any."
  (let ((wid (widget-at (point))))
    (when (and wid (eq (widget-type wid) 'tree-widget))
      wid)))

(defun lsp-hierarchy--item-at-point ()
  "Return the hierarchy item plist at point."
  (when-let ((wid (lsp-hierarchy--widget-at-point)))
    (widget-get wid :lsp-item)))

(defun lsp-hierarchy-goto (&rest _)
  "Jump to the location of the hierarchy item at point."
  (interactive)
  (if-let ((item (lsp-hierarchy--item-at-point))
           (goto-fn (plist-get item :goto-fn)))
      (progn
        (funcall goto-fn)
        (run-hooks 'lsp-hierarchy-after-jump-hook))
    (user-error "No location associated with this item")))

(defun lsp-hierarchy-goto-mouse (event)
  "Jump to the location of the item at mouse click EVENT."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (when pos
      (goto-char pos)
      (lsp-hierarchy-goto))))


;;; Core: label rendering

(defun lsp-hierarchy--item-label (item indent)
  "Insert the label for ITEM at indentation level INDENT."
  (let ((label (plist-get item :label))
        (detail (plist-get item :detail))
        (kind (plist-get item :kind)))
    (insert (make-string (* indent 2) ?\s))
    (when (and kind (not (plist-get item :leaf)))
      (let ((abbrev (lsp-hierarchy--kind-abbrev kind)))
        (unless (string-empty-p abbrev)
          (insert (propertize (format "[%s] " abbrev)
                              'face 'lsp-hierarchy-detail-face)))))
    (insert label)
    (when detail
      (insert " " (propertize detail 'face 'lsp-hierarchy-detail-face)))))


;;; View: Call Hierarchy

(defconst lsp-hierarchy--call-hierarchy-buffer-name "*LSP Call Hierarchy*")

(defun lsp-hierarchy--call-hierarchy-extract-line (filename start end)
  "Return the line of text in FILENAME between START and END positions."
  (let ((fn (lambda ()
              (-let* (((&Position :character start-char) start)
                      ((&Position :character end-char) end)
                      (start-point (lsp--position-to-point start))
                      (line (lsp-hierarchy--buffer-line-at start-point))
                      (len (length line)))
                (concat
                 (substring line 0 (min start-char len))
                 (propertize (substring line (min start-char len)
                                        (min end-char len))
                             'face 'lsp-hierarchy-call-site-face)
                 (when (< end-char len)
                   (substring line (min end-char len) len)))))))
    (if-let ((buf (find-buffer-visiting filename)))
        (with-current-buffer buf (funcall fn))
      (when (file-readable-p filename)
        (with-temp-buffer
          (insert-file-contents-literally filename)
          (funcall fn))))))

(defun lsp-hierarchy--buffer-line-at (point)
  "Return the line containing POINT."
  (let ((inhibit-field-text-motion t))
    (save-excursion
      (goto-char point)
      (buffer-substring (line-beginning-position)
                        (line-end-position)))))

(defun lsp-hierarchy--call-hierarchy-children (item outgoing)
  "Return children for call hierarchy ITEM.
OUTGOING is non-nil for outgoing calls, nil for incoming calls."
  (-let* ((lsp-item (plist-get item :lsp-item))
          (method (if outgoing
                      "callHierarchy/outgoingCalls"
                    "callHierarchy/incomingCalls"))
          (result (condition-case err
                      (lsp-request method (list :item lsp-item))
                    (error
                     (lsp-warn "Call hierarchy request failed: %s"
                               (error-message-string err))
                     nil))))
    (seq-mapcat
     (lambda (call)
       (-let* ((target (if outgoing
                           (lsp:call-hierarchy-outgoing-call-to call)
                         (lsp:call-hierarchy-incoming-call-from call)))
               (from-ranges (append (lsp-get call :fromRanges) nil))
               (from-uri (if outgoing
                             (lsp-get lsp-item :uri)
                           (lsp-get target :uri)))
               (filename (lsp--uri-to-path from-uri))
               ((&CallHierarchyItem :name :kind :detail? :uri :selection-range
                                    (&Range :start target-start)) target))
         (append
          ;; Call site leaf items
          (seq-map
           (lambda (range)
             (-let* (((&Range :start (start &as &Position :line start-line)
                              :end end) range)
                     (line-text (or (lsp-hierarchy--call-hierarchy-extract-line
                                     filename start end)
                                    "")))
               (lsp-hierarchy--make-item
                (string-trim line-text)
                :detail (format "%s:%d" (f-filename filename) (1+ start-line))
                :leaf t
                :goto-fn (lambda ()
                           (lsp-hierarchy--open-file-in-mru filename)
                           (goto-char (lsp--position-to-point start))))))
           from-ranges)
          ;; Callee/caller expandable item
          (list
           (lsp-hierarchy--make-item
            (lsp-render-symbol target lsp-hierarchy-detailed-outline)
            :kind kind
            :detail (when detail? detail?)
            :lsp-item target
            :goto-fn (lambda ()
                       (lsp-hierarchy--open-file-in-mru (lsp--uri-to-path uri))
                       (goto-char (lsp--position-to-point target-start)))
            :children-fn (lambda (it)
                           (lsp-hierarchy--call-hierarchy-children
                            it outgoing)))))))
     result)))

;;;###autoload
(defun lsp-hierarchy-call-hierarchy (outgoing)
  "Display the call hierarchy for the symbol at point.
Without prefix, show incoming calls (who calls this).
With prefix \\[universal-argument], show outgoing calls (what this calls)."
  (interactive "P")
  (unless (lsp-feature? "textDocument/prepareCallHierarchy")
    (user-error "Call hierarchy not supported by current server"))
  (let* ((roots (condition-case err
                    (lsp-request "textDocument/prepareCallHierarchy"
                                 (lsp--text-document-position-params))
                  (error
                   (user-error "Call hierarchy request failed: %s"
                               (error-message-string err)))))
         (hierarchy (hierarchy-new))
         (root-items
          (seq-map
           (lambda (item)
             (-let (((&CallHierarchyItem :name :kind :detail? :uri
                                         :selection-range (&Range :start)) item))
               (lsp-hierarchy--make-item
                (lsp-render-symbol item lsp-hierarchy-detailed-outline)
                :kind kind
                :detail (when detail? detail?)
                :lsp-item item
                :goto-fn (lambda ()
                           (lsp-hierarchy--open-file-in-mru (lsp--uri-to-path uri))
                           (goto-char (lsp--position-to-point start)))
                :children-fn (lambda (it)
                               (lsp-hierarchy--call-hierarchy-children
                                it outgoing)))))
           roots)))
    (when (seq-empty-p root-items)
      (user-error "No call hierarchy items found at point"))
    (dolist (root-item root-items)
      (hierarchy-add-tree hierarchy root-item
        nil
        (lambda (it)
          (when-let ((cfn (plist-get it :children-fn)))
            (funcall cfn it)))
        nil
        t))
    (lsp-hierarchy--tree-display
     hierarchy
     #'lsp-hierarchy--item-label
     lsp-hierarchy-call-hierarchy-expand-depth
     lsp-hierarchy--call-hierarchy-buffer-name
     (concat (if outgoing "Outgoing" "Incoming") " Call Hierarchy"))
    (setq-local lsp-hierarchy--refresh-fn
                (lambda () (interactive)
                  (lsp-hierarchy-call-hierarchy outgoing)))))


;;; View: Type Hierarchy

(defconst lsp-hierarchy--type-hierarchy-buffer-name "*LSP Type Hierarchy*")

(defconst lsp-hierarchy--type-sub 0
  "Direction constant for subtype hierarchy.")
(defconst lsp-hierarchy--type-super 1
  "Direction constant for supertype hierarchy.")
(defconst lsp-hierarchy--type-both 2
  "Direction constant for both subtype and supertype hierarchy.")

(defun lsp-hierarchy--type-hierarchy-children (item direction)
  "Return children for type hierarchy ITEM in DIRECTION."
  (-let* ((lsp-item (plist-get item :lsp-item))
          ((&TypeHierarchyItem :uri :range (&Range :start)) lsp-item)
          (result (condition-case err
                      (lsp-request
                       "textDocument/typeHierarchy"
                       (lsp-make-type-hierarchy-params
                        :text-document (lsp-make-text-document-item :uri uri)
                        :position start
                        :direction direction
                        :resolve 1))
                    (error
                     (lsp-warn "Type hierarchy request failed: %s"
                               (error-message-string err))
                     nil))))
    (seq-map
     (lambda (it)
       (-let (((&TypeHierarchyItem :name :kind :detail? :uri :range
                                   (&Range :start item-start)) it))
         (lsp-hierarchy--make-item
          (concat name
                  (cond
                   ((eq direction lsp-hierarchy--type-sub)
                    (propertize " \u2193" 'face 'lsp-hierarchy-detail-face))
                   ((eq direction lsp-hierarchy--type-super)
                    (propertize " \u2191" 'face 'lsp-hierarchy-detail-face))))
          :kind kind
          :detail (when detail? detail?)
          :lsp-item it
          :goto-fn (lambda ()
                     (lsp-hierarchy--open-file-in-mru (lsp--uri-to-path uri))
                     (goto-char (lsp--position-to-point item-start)))
          :children-fn (lambda (child-item)
                         (append
                          (when (or (eq direction lsp-hierarchy--type-sub)
                                    (eq direction lsp-hierarchy--type-both))
                            (lsp-hierarchy--type-hierarchy-children
                             child-item lsp-hierarchy--type-sub))
                          (when (or (eq direction lsp-hierarchy--type-super)
                                    (eq direction lsp-hierarchy--type-both))
                            (lsp-hierarchy--type-hierarchy-children
                             child-item lsp-hierarchy--type-super)))))))
     (cond
      ((eq direction lsp-hierarchy--type-sub)
       (append (lsp-get result :children?) nil))
      ((eq direction lsp-hierarchy--type-super)
       (append (lsp-get result :parents?) nil))
      (t
       (append (lsp-get result :children?) nil
               (lsp-get result :parents?) nil))))))

;;;###autoload
(defun lsp-hierarchy-type-hierarchy (direction)
  "Display the type hierarchy for the symbol at point.
Prefix: 0=subtypes, 1=supertypes, 2=both."
  (interactive "p")
  (unless (lsp-feature? "textDocument/typeHierarchy")
    (user-error "Type hierarchy not supported by current server"))
  (let ((direction (cond
                    ((= direction 1) lsp-hierarchy--type-sub)
                    ((= direction 4) lsp-hierarchy--type-super)
                    ((= direction 16) lsp-hierarchy--type-both)
                    (t lsp-hierarchy--type-sub))))
    (let* ((result (condition-case err
                       (lsp-request
                        "textDocument/typeHierarchy"
                        (-> (lsp--text-document-position-params)
                            (plist-put :direction direction)
                            (plist-put :resolve 1)))
                     (error
                      (user-error "Type hierarchy request failed: %s"
                                  (error-message-string err)))))
           (hierarchy (hierarchy-new))
           (root-item
            (when result
              (-let* ((vec (if (vectorp result) result (vector result)))
                      (it (aref vec 0)))
                (-let (((&TypeHierarchyItem :name :kind :detail? :uri
                                            :range (&Range :start)) it))
                  (lsp-hierarchy--make-item
                   name
                   :kind kind
                   :detail (when detail? detail?)
                   :lsp-item it
                   :goto-fn (lambda ()
                              (lsp-hierarchy--open-file-in-mru (lsp--uri-to-path uri))
                              (goto-char (lsp--position-to-point start)))
                   :children-fn (lambda (child-item)
                                  (append
                                   (when (or (eq direction lsp-hierarchy--type-sub)
                                             (eq direction lsp-hierarchy--type-both))
                                     (lsp-hierarchy--type-hierarchy-children
                                      child-item lsp-hierarchy--type-sub))
                                   (when (or (eq direction lsp-hierarchy--type-super)
                                             (eq direction lsp-hierarchy--type-both))
                                     (lsp-hierarchy--type-hierarchy-children
                                      child-item lsp-hierarchy--type-super))))))))))
      (unless root-item
        (user-error "No type hierarchy found at point"))
      (hierarchy-add-tree hierarchy root-item
        nil
        (lambda (it)
          (when-let ((cfn (plist-get it :children-fn)))
            (funcall cfn it)))
        nil
        t)
      (lsp-hierarchy--tree-display
       hierarchy
       #'lsp-hierarchy--item-label
       lsp-hierarchy-type-hierarchy-expand-depth
       lsp-hierarchy--type-hierarchy-buffer-name
       (concat (cond
                ((eq direction lsp-hierarchy--type-sub) "Sub")
                ((eq direction lsp-hierarchy--type-super) "Super")
                (t "Sub/Super"))
               " Type Hierarchy"))
      (setq-local lsp-hierarchy--refresh-fn
                  (lambda () (interactive)
                    (lsp-hierarchy-type-hierarchy direction))))))


;;; View: Document Symbols

(defconst lsp-hierarchy--symbols-buffer-name "*LSP Symbols*")

(defvar-local lsp-hierarchy--symbols-data nil
  "Current document symbols data.")
(defvar-local lsp-hierarchy--symbols-buffer nil
  "Source buffer for the symbols view.")

(defun lsp-hierarchy--symbols->items (symbols &optional parent-key)
  "Convert SYMBOLS (DocumentSymbol or SymbolInformation) to hierarchy items.
PARENT-KEY groups flat SymbolInformation by containerName."
  (if (and symbols
           (lsp-symbol-information? (lsp-seq-first symbols)))
      ;; Flat SymbolInformation: group by containerName
      (-let [(current rest) (-separate
                             (-lambda ((&SymbolInformation :container-name?))
                               (equal container-name? parent-key))
                             (append symbols nil))]
        (seq-map
         (-lambda ((&SymbolInformation :name :kind :container-name?
                                       :location
                                       (&Location :range
                                                  (&Range :start start-range))))
           (lsp-hierarchy--make-item
            name
            :kind kind
            :goto-fn (lambda ()
                       (pop-to-buffer lsp-hierarchy--symbols-buffer)
                       (goto-char (lsp--position-to-point start-range)))
            :children (lsp-hierarchy--symbols->items rest name)))
         current))
    ;; Hierarchical DocumentSymbol
    (seq-map
     (-lambda ((&DocumentSymbol :name :kind :detail?
                                :selection-range (&Range :start start-range)
                                :children?))
       (lsp-hierarchy--make-item
        (lsp-render-symbol (lsp-make-document-symbol
                            :name name :kind kind :detail? detail?)
                           lsp-hierarchy-detailed-outline)
        :kind kind
        :detail (when detail? detail?)
        :goto-fn (lambda ()
                   (pop-to-buffer lsp-hierarchy--symbols-buffer)
                   (goto-char (lsp--position-to-point start-range)))
        :children (unless (seq-empty-p children?)
                    (lsp-hierarchy--symbols->items children? name))))
     symbols)))

;;;###autoload
(defun lsp-hierarchy-symbols ()
  "Display document symbols in a hierarchy tree view."
  (interactive)
  (unless (lsp-feature? "textDocument/documentSymbol")
    (user-error "Document symbols not supported by current server"))
  (let* ((buffer (current-buffer))
         (symbols (condition-case err
                      (lsp-request "textDocument/documentSymbol"
                                   (lsp-make-document-symbol-params
                                    :text-document (lsp--text-document-identifier)))
                    (error
                     (user-error "Document symbols request failed: %s"
                                 (error-message-string err)))))
         (items (lsp-hierarchy--symbols->items symbols))
         (hierarchy (hierarchy-new)))
    (dolist (item items)
      (hierarchy-add-tree hierarchy item
        nil
        (lambda (it) (plist-get it :children))
        nil
        nil))
    (lsp-hierarchy--tree-display
     hierarchy
     #'lsp-hierarchy--item-label
     lsp-hierarchy-symbols-expand-depth
     lsp-hierarchy--symbols-buffer-name
     "LSP Symbols")
    (setq-local lsp-hierarchy--symbols-data symbols)
    (setq-local lsp-hierarchy--symbols-buffer buffer)
    (setq-local lsp-hierarchy--refresh-fn
                (lambda () (interactive)
                  (with-current-buffer buffer
                    (lsp-hierarchy-symbols))))))


;;; View: References & Implementations (shared engine)

(defconst lsp-hierarchy--references-buffer-name "*LSP References*")
(defconst lsp-hierarchy--implementations-buffer-name "*LSP Implementations*")

(defun lsp-hierarchy--get-xrefs (file-locs)
  "Convert FILE-LOCS (cons FILENAME . LOCATIONS) to hierarchy items."
  (-let (((filename . locs) file-locs))
    (append
     (list (lsp-hierarchy--make-item
            (format "%s (%d reference%s)"
                    (f-filename filename)
                    (length locs)
                    (if (= (length locs) 1) "" "s"))
            :goto-fn (lambda ()
                       (lsp-hierarchy--open-file-in-mru filename))))
     (seq-map
      (lambda (loc)
        (-let* (((&Range :start (start &as &Position :line start-line
                                         :character start-char)
                         :end (&Position :character end-char)) loc)
                (start-point (lsp--position-to-point start))
                (line-text
                 (condition-case nil
                     (if-let ((buf (find-buffer-visiting filename)))
                         (with-current-buffer buf
                           (lsp-hierarchy--buffer-line-at start-point))
                       (when (file-readable-p filename)
                         (with-temp-buffer
                           (insert-file-contents-literally filename)
                           (goto-char start-point)
                           (lsp-hierarchy--buffer-line-at start-point))))
                   (error nil)))
                (len (length (or line-text ""))))
          (lsp-hierarchy--make-item
           (if line-text
               (string-trim
                (concat
                 (substring line-text 0 (min start-char len))
                 (propertize
                  (substring line-text (min start-char len)
                             (min end-char len))
                  'face 'lsp-hierarchy-call-site-face)
                 (when (< end-char len)
                   (substring line-text (min end-char len) len))))
             "")
           :detail (format "line %d" (1+ start-line))
           :leaf t
           :goto-fn (lambda ()
                      (lsp-hierarchy--open-file-in-mru filename)
                      (goto-char start-point)))))
      locs))))

;;;###autoload
(defun lsp-hierarchy-references (arg)
  "Display references for the symbol at point in a tree view.
With prefix ARG, populate the buffer without selecting it."
  (interactive "P")
  (unless (lsp-feature? "textDocument/references")
    (user-error "References not supported by current server"))
  (lsp-hierarchy--do-search
   "textDocument/references"
   `(:context (:includeDeclaration t) ,@(lsp--text-document-position-params))
   "References"
   lsp-hierarchy--references-buffer-name
   lsp-hierarchy-references-expand-depth
   arg))

;;;###autoload
(defun lsp-hierarchy-implementations (arg)
  "Display implementations for the symbol at point in a tree view.
With prefix ARG, populate the buffer without selecting it."
  (interactive "P")
  (unless (lsp-feature? "textDocument/implementation")
    (user-error "Implementations not supported by current server"))
  (lsp-hierarchy--do-search
   "textDocument/implementation"
   (lsp--text-document-position-params)
   "Implementations"
   lsp-hierarchy--implementations-buffer-name
   lsp-hierarchy-implementations-expand-depth
   arg))

(defun lsp-hierarchy--do-search (method params label buffer-name expand-depth arg)
  "Perform a workspace symbol search and display results in a tree."
  (let* ((results (condition-case err
                      (lsp-request method params)
                    (error
                     (user-error "%s request failed: %s" label
                                 (error-message-string err)))))
         (grouped (lsp-hierarchy--group-locations results))
         (hierarchy (hierarchy-new))
         (root-items
          (seq-map
           (lambda (group)
             (-let (((dir . files) group))
               (lsp-hierarchy--make-item
                (abbreviate-file-name dir)
                :children (seq-map
                           (lambda (file-group)
                             (apply #'lsp-hierarchy--get-xrefs
                                    (list file-group)))
                           files))))
           grouped)))
    (dolist (root-item root-items)
      (hierarchy-add-tree hierarchy root-item
        nil
        (lambda (it) (plist-get it :children))
        nil
        nil))
    (lsp-hierarchy--tree-display
     hierarchy
     #'lsp-hierarchy--item-label
     expand-depth
     buffer-name
     (format "LSP %s (%d)" label (length results)))
    (setq-local lsp-hierarchy--refresh-fn
                (lambda () (interactive)
                  (lsp-hierarchy--do-search
                   method params label buffer-name expand-depth arg)))))

(defun lsp-hierarchy--group-locations (locations)
  "Group LOCATIONS by directory, then by file.
Returns an alist of (DIR . ((FILE . RANGES) ...))."
  (->> locations
       (-map (lambda (loc)
               (-let* ((uri (if (lsp-location? loc)
                                (lsp:location-uri loc)
                              (lsp:location-link-target-uri loc)))
                       (range (if (lsp-location? loc)
                                  (lsp:location-range loc)
                                (or (lsp:location-link-target-selection-range loc)
                                    (lsp:location-link-target-range loc))))
                       (filename (lsp--uri-to-path uri)))
                 (cons filename range))))
       (-group-by (lambda (pair) (f-dirname (car pair))))
       (ht-map (lambda (dir file-pairs)
                 (cons dir
                       (->> file-pairs
                            (-group-by #'car)
                            (ht-map (lambda (file ranges)
                                      (cons file (seq-map #'cdr ranges))))
                            (ht-values)))))
       (append nil)))


;;; View: Error List

(defconst lsp-hierarchy--errors-buffer-name "*LSP Errors*")

(defun lsp-hierarchy--diagnostic-face (severity)
  "Return the face for diagnostic SEVERITY."
  (cl-case severity
    (1 'lsp-hierarchy-error-face)
    (2 'lsp-hierarchy-warning-face)
    (3 'lsp-hierarchy-info-face)
    (4 'lsp-hierarchy-hint-face)
    (t 'lsp-hierarchy-info-face)))

(defun lsp-hierarchy--diagnostic-label (severity)
  "Return a short label for diagnostic SEVERITY."
  (cl-case severity
    (1 "ERR")
    (2 "WRN")
    (3 "INF")
    (4 "HNT")
    (t "???")))

(defun lsp-hierarchy--build-diagnostic-item (file diag)
  "Create a hierarchy item for a single diagnostic DIAG in FILE."
  (-let* (((&Diagnostic :severity? :message :source?
                        :range (&Range :start (&Position :line :character))) diag)
          (severity (or severity? 3))
          (label (propertize (lsp-hierarchy--diagnostic-label severity)
                             'face (lsp-hierarchy--diagnostic-face severity)))
          (source (if source? (format "[%s]" source?) ""))
          (msg (string-join (mapcar #'string-trim (string-lines message)) ", "))
          (start (lsp--position-to-point
                  (lsp-make-position :line line :character character))))
    (lsp-hierarchy--make-item
     (format "%s %s %s" label source msg)
     :detail (format "(%d:%d)" (1+ line) (1+ character))
     :leaf t
     :goto-fn (lambda ()
                (lsp-hierarchy--open-file-in-mru file)
                (goto-char start)))))

(defun lsp-hierarchy--build-file-items (folder file)
  "Build hierarchy items for diagnostics in FILE under FOLDER."
  (let* ((diags (-filter #'lsp-hierarchy--match-diagnostic-severity
                         (gethash file (lsp-diagnostics))))
         (counts (lsp-diagnostics-stats-for file)))
    (when diags
      (list
       (lsp-hierarchy--make-item
        (format "%s %s"
                (f-filename file)
                (lsp-hierarchy--format-diag-counts counts))
        :detail (f-relative file folder)
        :goto-fn (lambda ()
                   (lsp-hierarchy--open-file-in-mru file))
        :children (seq-map (lambda (d)
                             (lsp-hierarchy--build-diagnostic-item file d))
                           (sort diags
                                 (lambda (a b)
                                   (-let (((&Diagnostic :range
                                            (&Range :start
                                             (&Position :line la :character ca))) a)
                                          ((&Diagnostic :range
                                            (&Range :start
                                             (&Position :line lb :character cb))) b))
                                     (if (= la lb) (< ca cb) (< la lb)))))))))))

(defun lsp-hierarchy--match-diagnostic-severity (diag)
  "Return non-nil if DIAG's severity <= `lsp-hierarchy-error-list-severity'."
  (<= (lsp:diagnostic-severity? diag)
      lsp-hierarchy-error-list-severity))

(defun lsp-hierarchy--format-diag-counts (counts)
  "Format diagnostic COUNTS as a compact string like '2E/1W/3I'."
  (string-join
   (delq nil
         (list
          (when (> (nth 0 counts) 0)
            (propertize (format "%dE" (nth 0 counts))
                        'face 'lsp-hierarchy-error-face))
          (when (> (nth 1 counts) 0)
            (propertize (format "%dW" (nth 1 counts))
                        'face 'lsp-hierarchy-warning-face))
          (when (> (nth 2 counts) 0)
            (propertize (format "%dI" (nth 2 counts))
                        'face 'lsp-hierarchy-info-face))
          (when (> (nth 3 counts) 0)
            (propertize (format "%dH" (nth 3 counts))
                        'face 'lsp-hierarchy-hint-face))))
   "/"))

(defun lsp-hierarchy--build-error-tree ()
  "Build the error hierarchy tree from current diagnostics."
  (let ((all-diags (lsp-diagnostics))
        (folders (lsp-session-folders (lsp-session)))
        (items nil))
    (dolist (folder folders)
      (let ((file-items nil))
        (maphash
         (lambda (file _diags)
           (when (and (lsp-f-ancestor-of? folder file)
                      (file-exists-p file))
             (when-let ((item (lsp-hierarchy--build-file-items folder file)))
               (setq file-items (append file-items item)))))
         all-diags)
        (when file-items
          (push
           (lsp-hierarchy--make-item
            (abbreviate-file-name folder)
            :children file-items)
           items))))
    (nreverse items)))

;;;###autoload
(defun lsp-hierarchy-errors ()
  "Display diagnostics in a tree view grouped by file."
  (interactive)
  (let* ((root-items (lsp-hierarchy--build-error-tree))
         (hierarchy (hierarchy-new)))
    (dolist (root-item root-items)
      (hierarchy-add-tree hierarchy root-item
        nil
        (lambda (it) (plist-get it :children))
        nil
        nil))
    (if (hierarchy-empty-p hierarchy)
        (message "No diagnostics found")
      (lsp-hierarchy--tree-display
       hierarchy
       #'lsp-hierarchy--item-label
       lsp-hierarchy-error-list-expand-depth
       lsp-hierarchy--errors-buffer-name
       "LSP Errors")
      (setq-local lsp-hierarchy--refresh-fn
                  (lambda () (interactive)
                    (lsp-hierarchy-errors))))))


;;; Utility

(defun lsp-hierarchy--open-file-in-mru (file)
  "Open FILE in the most-recently-used window."
  (select-window (get-mru-window (selected-frame) nil :not-selected))
  (find-file file))

(provide 'lsp-hierarchy)
;;; lsp-hierarchy.el ends here
