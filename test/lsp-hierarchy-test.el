;;; lsp-hierarchy-test.el --- Tests for lsp-hierarchy.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'lsp-hierarchy)

(defvar lsp-hierarchy-test--source nil)
(defvar lsp-hierarchy-test--workspaces nil)
(defvar lsp-hierarchy-test--sent nil)

(defun lsp-hierarchy-test--workspace (id &optional capabilities registrations)
  "Make a test workspace with ID, CAPABILITIES and REGISTRATIONS."
  (make-lsp--workspace
   :proc id :client (make-lsp--client :server-id id)
   :server-capabilities (or capabilities (lsp-make-server-capabilities))
   :registered-server-capabilities registrations))

(defun lsp-hierarchy-test--send (body process)
  "Record BODY sent to PROCESS, including the real response handlers."
  (when-let* ((id (plist-get body :id))
              (workspace (seq-find (lambda (ws) (eq process (lsp--workspace-proc ws)))
                                   lsp-hierarchy-test--workspaces))
              (handlers (gethash id (lsp--client-response-handlers
                                     (lsp--workspace-client workspace)))))
    ;; Retain handlers even after cancellation to exercise already-queued
    ;; responses which arrive after a view has been replaced or killed.
    (push (list :body body :workspace workspace
                :success (car handlers) :error (cadr handlers))
          lsp-hierarchy-test--sent)))

(defmacro lsp-hierarchy-test--with-session (&rest body)
  "Run BODY with isolated source/view buffers and a controllable transport."
  (declare (indent 0) (debug t))
  (let ((source (make-symbol "source")))
    (list
     'let*
     (list
      (list source '(generate-new-buffer " *hierarchy-test-source*"))
      (list 'lsp-hierarchy-test--source source)
      '(lsp-hierarchy-test--workspaces
        (list (lsp-hierarchy-test--workspace
               'server-a
               (lsp-make-server-capabilities :call-hierarchy-provider? t
                                             :type-hierarchy-provider? t))))
      '(lsp-hierarchy-test--sent nil)
      '(lsp-hierarchy-expand-depth 0)
      '(lsp--cancelable-requests (make-hash-table :test 'eq))
      '(lsp--request-cleanup-hooks (make-hash-table :test 'eql))
      '(lsp--last-active-workspaces nil)
      '(lsp-last-id 0))
     (list 'cl-letf
           '(((symbol-function 'lsp--send-no-wait) #'lsp-hierarchy-test--send)
             ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (get-buffer buffer))))
           (list 'unwind-protect
                 (cons 'progn body)
                 '(dolist (name '("*LSP Call Hierarchy*" "*LSP Type Hierarchy*"))
                    (when-let* ((buffer (get-buffer name))) (kill-buffer buffer)))
                 (list 'when (list 'buffer-live-p source) (list 'kill-buffer source)))))))

(defun lsp-hierarchy-test--show (&optional type direction)
  "Request TYPE in DIRECTION and return the target view buffer."
  (with-current-buffer lsp-hierarchy-test--source
    (setq-local buffer-file-name "/tmp/lsp-hierarchy-test.c")
    (setq-local lsp--buffer-workspaces lsp-hierarchy-test--workspaces)
    (if (eq type 'type)
        (lsp-hierarchy-show-type (eq direction 'supertypes))
      (lsp-hierarchy-show-call direction)))
  (get-buffer (if (eq type 'type) "*LSP Type Hierarchy*" "*LSP Call Hierarchy*")))

(defun lsp-hierarchy-test--reply (request result &optional errorp)
  "Deliver RESULT to REQUEST, using its error handler when ERRORP."
  (with-lsp-workspace (plist-get request :workspace)
    (funcall (plist-get request (if errorp :error :success)) result)))

(defun lsp-hierarchy-test--range (line start end &optional end-line)
  "Make a range from LINE/START to END-LINE/END."
  (lsp-make-range :start (lsp-make-position :line line :character start)
                  :end (lsp-make-position :line (or end-line line) :character end)))

(defun lsp-hierarchy-test--item (name &optional uri data)
  "Make a protocol hierarchy item named NAME with URI and opaque DATA."
  (lsp-make-type-hierarchy-item
   :name name :kind 12 :uri (or uri "file:///tmp/lsp-hierarchy-test.c")
   :range (lsp-hierarchy-test--range 0 0 20)
   :selection-range (lsp-hierarchy-test--range 0 5 8)
   :data? data))

(defun lsp-hierarchy-test--call (name &optional uri ranges)
  "Make an incoming call from NAME at URI with RANGES."
  (lsp-make-call-hierarchy-incoming-call
   :from (lsp-hierarchy-test--item name uri) :from-ranges (or ranges [])))

(defun lsp-hierarchy-test--node (name)
  "Find the node with NAME in the current view."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (let* ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item))
               (item (plist-get node :lsp-item)))
          (when (and item (equal name (lsp-get item :name))) (setq found node)))
        (forward-line 1))
      (or found (ert-fail (format "Missing node %s" name))))))

(defun lsp-hierarchy-test--toggle (name)
  "Toggle the node with NAME in the current view."
  (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-item
                                (lsp-hierarchy-test--node name)))
  (lsp-hierarchy-toggle))

(defun lsp-hierarchy-test--roots (&rest names)
  "Reply to the latest prepare request with roots named NAMES."
  (lsp-hierarchy-test--reply
   (car lsp-hierarchy-test--sent)
   (vconcat (mapcar #'lsp-hierarchy-test--item names))))


(ert-deftest lsp-hierarchy-kind-abbrev-test ()
  "Test kind abbreviation mapping."
  (should (equal (lsp-hierarchy--kind-abbrev 5) "c"))
  (should (equal (lsp-hierarchy--kind-abbrev 6) "m"))
  (should (equal (lsp-hierarchy--kind-abbrev 12) "f"))
  (should (equal (lsp-hierarchy--kind-abbrev 999) "")))

(ert-deftest lsp-hierarchy-mode-init-test ()
  "Test major mode initialization."
  (with-temp-buffer
    (lsp-hierarchy-mode)
    (should (eq major-mode 'lsp-hierarchy-mode))
    (should (bound-and-true-p lsp-hierarchy--state-table))))

(ert-deftest lsp-hierarchy-fontify-bare-symbol-test ()
  "A symbol without a detail field must fontify without an exception."
  (dolist (label '("foo" "foo signature"))
    (with-temp-buffer
      (lsp-hierarchy-mode)
      (let ((inhibit-read-only t))
        (lsp-hierarchy--insert-node
         (list :type 'symbol :kind 12 :label label) 0 (hierarchy-new)))
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "foo")
      (should (eq (get-text-property (1- (point)) 'face) 'lsp-hierarchy-node-face)))))

(ert-deftest lsp-hierarchy-latest-prepare-wins ()
  (lsp-hierarchy-test--with-session
    (let* ((view (lsp-hierarchy-test--show))
           (old (car lsp-hierarchy-test--sent)))
      (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "new")
      (lsp-hierarchy-test--reply old (vector (lsp-hierarchy-test--item "old")))
      (with-current-buffer view
        (should (string-match-p "new" (buffer-string)))
        (should-not (string-match-p "old" (buffer-string)))
        (should (string-match-p "new" (buffer-string)))))))

(ert-deftest lsp-hierarchy-refresh-ignores-old-children ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "old")
      (lsp-hierarchy-test--toggle "old")
      (let ((old (car lsp-hierarchy-test--sent)))
        (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "new")
        (lsp-hierarchy-test--reply old (vector (lsp-hierarchy-test--call "stale"))))
      (should-not (string-match-p "stale" (buffer-string)))
      (should (string-match-p "new" (buffer-string))))))

(ert-deftest lsp-hierarchy-killed-view-is-not-recreated ()
  (lsp-hierarchy-test--with-session
    (let* ((view (lsp-hierarchy-test--show))
           (request (car lsp-hierarchy-test--sent)))
      (kill-buffer view)
      (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "late")))
      (should-not (buffer-live-p view))
      (should-not (get-buffer "*LSP Call Hierarchy*"))
      (should-not (get-buffer "*LSP Call Hierarchy*")))))

(ert-deftest lsp-hierarchy-error-is-retryable ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (lsp-make-json-error :code -32603 :message "Server failure") t)
      (let ((root (lsp-hierarchy-test--node "root")))
        (should (not (gethash root lsp-hierarchy--loading-table)))
        (should-not (gethash root lsp-hierarchy--loaded-table))
        (should-not (string-match-p "Loading" (buffer-string)))
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) nil)
        (should (gethash root lsp-hierarchy--loaded-table))
        (should-not (gethash root lsp-hierarchy--loading-table))
        (should (= 0 (hash-table-count lsp-hierarchy--requests)))))))

(ert-deftest lsp-hierarchy-send-error-is-retryable ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (cl-letf (((symbol-function 'lsp--send-no-wait) (lambda (&rest _) (error "Send failed"))))
        (lsp-hierarchy-test--toggle "root"))
      (should (not (gethash (lsp-hierarchy-test--node "root") lsp-hierarchy--loading-table)))
      (should (= 0 (hash-table-count lsp-hierarchy--requests)))
      (should (= 0 (hash-table-count lsp--cancelable-requests)))
      (should (= 0 (hash-table-count lsp--request-cleanup-hooks)))
      (should-not (string-match-p "Loading" (buffer-string))))))

(ert-deftest lsp-hierarchy-source-kill-releases-pending-node ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (kill-buffer lsp-hierarchy-test--source)
      (should (not (gethash (lsp-hierarchy-test--node "root") lsp-hierarchy--loading-table)))
      (should (= 0 (hash-table-count lsp-hierarchy--requests)))
      (lsp-hierarchy-test--toggle "root")
      (should (not (gethash (lsp-hierarchy-test--node "root") lsp-hierarchy--loading-table))))))

(ert-deftest lsp-hierarchy-failed-prepare-clears-loading ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (lsp-make-json-error :code -32603 :message "Server failure") t)
      (should (string-match-p "Unable to load hierarchy" (buffer-string)))
      (should-not (string-match-p "Loading" (buffer-string))))))

(ert-deftest lsp-hierarchy-rejects-unsupported-servers ()
  (lsp-hierarchy-test--with-session
    (setq lsp-hierarchy-test--workspaces
          (list (lsp-hierarchy-test--workspace 'unsupported)))
    (should-error (lsp-hierarchy-test--show 'call) :type 'user-error)
    (should-error (lsp-hierarchy-test--show 'type) :type 'user-error)
    (should-not lsp-hierarchy-test--sent)))

(ert-deftest lsp-hierarchy-accepts-dynamic-registrations ()
  (dolist (kind '(call type))
    (lsp-hierarchy-test--with-session
      (let ((method (if (eq kind 'call)
                        "textDocument/prepareCallHierarchy" "textDocument/prepareTypeHierarchy")))
        (setq lsp-hierarchy-test--workspaces
              (list (lsp-hierarchy-test--workspace
                     'dynamic nil
                     (list (make-lsp--registered-capability :id "test" :method method)))))
        (with-current-buffer (lsp-hierarchy-test--show kind)
          (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                         method))
          (lsp-hierarchy-test--roots "foo")
          (lsp-hierarchy-test--toggle "foo")
          (should (= 2 (length lsp-hierarchy-test--sent))))))))

(ert-deftest lsp-hierarchy-filters-workspaces-without-global-mutation ()
  (lsp-hierarchy-test--with-session
    (let ((requirements (copy-tree lsp-method-requirements)))
      (setq lsp-hierarchy-test--workspaces
            (append lsp-hierarchy-test--workspaces
                    (list (lsp-hierarchy-test--workspace 'unsupported))))
      (lsp-hierarchy-test--show 'type)
      (should (= 1 (length lsp-hierarchy-test--sent)))
      (should (eq (plist-get (car lsp-hierarchy-test--sent) :workspace)
                  (car lsp-hierarchy-test--workspaces)))
      (should (equal requirements lsp-method-requirements)))))

(ert-deftest lsp-hierarchy-preserves-workspace-and-opaque-data ()
  (lsp-hierarchy-test--with-session
    (let* ((a (car lsp-hierarchy-test--workspaces))
           (b (lsp-hierarchy-test--workspace
               'server-b (lsp-make-server-capabilities :call-hierarchy-provider? t)))
           (item-a (lsp-hierarchy-test--item "same" nil '("opaque" [1 2 3])))
           (item-b (lsp-hierarchy-test--item "same" nil '("other"))))
      (setq lsp-hierarchy-test--workspaces (list a b))
      (with-current-buffer (lsp-hierarchy-test--show)
        (let ((requests (copy-sequence lsp-hierarchy-test--sent)))
          (dolist (request requests)
            (lsp-hierarchy-test--reply
             request (vector (if (eq a (plist-get request :workspace)) item-a item-b)))))
        (should (= (hash-table-count lsp-hierarchy--state-table) 2))
        (let* ((nodes (hash-table-keys lsp-hierarchy--state-table))
               (node-a (seq-find (lambda (node) (eq (plist-get node :workspace) a)) nodes))
               (node-b (seq-find (lambda (node) (eq (plist-get node :workspace) b)) nodes)))
          (should-not (eq (plist-get node-a :id) (plist-get node-b :id)))
          (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node-a))
          (lsp-hierarchy-toggle)
          (let* ((request (car lsp-hierarchy-test--sent))
                 (params (plist-get (plist-get request :body) :params)))
            (should (eq (plist-get request :workspace) a))
            (should (eq (plist-get params :item) item-a))))))))

(ert-deftest lsp-hierarchy-loading-rows-are-request-local ()
  "Finishing beta first must preserve alpha's loading row, including on error."
  (dolist (errorp '(nil t))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "alpha" "beta")
        (lsp-hierarchy-test--toggle "alpha")
        (let ((alpha-request (car lsp-hierarchy-test--sent)))
          (lsp-hierarchy-test--toggle "beta")
          (lsp-hierarchy-test--reply
           (car lsp-hierarchy-test--sent)
           (if errorp (lsp-make-json-error :code -32603 :message "Failed")
             (vector (lsp-hierarchy-test--call "child-beta"))) errorp)
          (let ((alpha (lsp-hierarchy-test--node "alpha"))
                (beta (lsp-hierarchy-test--node "beta")))
            (should (gethash alpha lsp-hierarchy--loading-table))
            (should-not (gethash beta lsp-hierarchy--loading-table))
            (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-item alpha))
            (forward-line 1)
            (should (get-text-property (point) 'lsp-hierarchy-loading))
            (lsp-hierarchy-test--reply alpha-request (vector (lsp-hierarchy-test--call "child-alpha")))
            (should-not (string-match-p "Loading" (buffer-string)))
            (should (< (string-match "child-alpha" (buffer-string))
                       (string-match "beta" (buffer-string))))))))))

(defun lsp-hierarchy-test--node-position (node)
  "Return the position of rendered NODE in the current view."
  (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node))

(ert-deftest lsp-hierarchy-folding-survives-pending-descendants ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "alpha")
                                         (lsp-hierarchy-test--call "beta")))
      (lsp-hierarchy-test--toggle "alpha")
      (let ((pending (car lsp-hierarchy-test--sent)))
        (lsp-hierarchy-test--toggle "root")
        (should (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "beta"))))
        (lsp-hierarchy-test--reply pending (vector (lsp-hierarchy-test--call "grandchild")))
        (should (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild"))))
        (lsp-hierarchy-test--toggle "root")
        (should-not (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild"))))
        (lsp-hierarchy-test--toggle "alpha")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--toggle "root")
        (should (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild"))))))))

(ert-deftest lsp-hierarchy-can-fold-while-node-is-loading ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "child")))
      (should (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child"))))
      (lsp-hierarchy-test--toggle "root")
      (should-not (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))))))

(ert-deftest lsp-hierarchy-symbol-jumps-use-selection-range ()
  (dolist (kind '(call type))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show kind)
        (lsp-hierarchy-test--roots "root")
        (let ((root (lsp-hierarchy-test--node "root"))
              jumped)
          (goto-char (lsp-hierarchy-test--node-position root))
          (cl-letf (((symbol-function 'lsp-hierarchy--open-file)
                     (lambda (uri range workspace)
                       (setq jumped (list uri range workspace)))))
            (lsp-hierarchy-goto))
          (should (eq (nth 1 jumped) (lsp-get (plist-get root :lsp-item) :selectionRange)))
          (should (eq (nth 2 jumped) (plist-get root :workspace))))))))

(ert-deftest lsp-hierarchy-type-child-jump-selects-name ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "Root")
      (lsp-hierarchy-test--toggle "Root")
      (let ((child (lsp-hierarchy-test--item "Child")) jumped)
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector child))
        (goto-char (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "Child")))
        (cl-letf (((symbol-function 'lsp-hierarchy--open-file)
                   (lambda (_uri range &optional _workspace) (setq jumped range))))
          (lsp-hierarchy-goto))
        (should (eq jumped (lsp-get child :selectionRange)))))))

(ert-deftest lsp-hierarchy-unicode-call-site-and-narrowing ()
  (dolist (encoding '("utf-16" "utf-8" "utf-32"))
    (with-temp-buffer
      (let ((source (current-buffer))
            (workspace (lsp-hierarchy-test--workspace
                        'encoding (lsp-make-server-capabilities :positionEncoding encoding))))
        (insert "header\n😀foo();\nfooter\n")
        (narrow-to-region 8 14)
        (goto-char 9)
        (cl-letf (((symbol-function 'find-buffer-visiting) (lambda (_) source)))
          (with-temp-buffer
            (lsp-hierarchy-mode)
            (let* ((column (cond ((equal encoding "utf-16") 2)
                                 ((equal encoding "utf-8") 4) (t 1)))
                   (text (lsp-hierarchy--extract-line
                          "file:///tmp/unicode.c"
                          (lsp-hierarchy-test--range 1 column (+ column 3)) workspace))
                   (start (text-property-any 0 (length text) 'face
                                             'lsp-hierarchy-call-site-face text))
                   (end (and start (next-single-property-change start 'face text))))
              (should (equal (and start (substring-no-properties text start end)) "foo")))))
        (should (buffer-narrowed-p))
        (should (= (point) 9))))))

(ert-deftest lsp-hierarchy-multiline-call-site-clips-to-first-line ()
  (with-temp-buffer
    (let ((source (current-buffer)))
      (insert "  foo(\nbar)\n")
      (cl-letf (((symbol-function 'find-buffer-visiting) (lambda (_) source)))
        (with-temp-buffer
          (lsp-hierarchy-mode)
          (let ((text (lsp-hierarchy--extract-line
                       "file:///tmp/multiline.c" (lsp-hierarchy-test--range 0 2 3 1))))
            (should (equal (substring-no-properties text) "foo( (line 1)"))))))))

(ert-deftest lsp-hierarchy-missing-source-file-fallback ()
  (with-temp-buffer
    (lsp-hierarchy-mode)
    (should (equal (lsp-hierarchy--extract-line
                    "file:///nonexistent/hierarchy-test.c" (lsp-hierarchy-test--range 3 0 2))
                   "call at line 4"))))

(ert-deftest lsp-hierarchy-open-file-uses-workspace-encoding-and-xref ()
  (let ((file (make-temp-file "hierarchy-jump-" nil ".c" "head\n😀foo();\n")) target)
    (unwind-protect
        (with-temp-buffer
          (let* ((origin (current-buffer))
                 (workspace (lsp-hierarchy-test--workspace
                             'encoding (lsp-make-server-capabilities :positionEncoding "utf-16")))
                 pushed jumped
                 (xref-after-jump-hook (list (lambda () (setq jumped (current-buffer))))))
            (setf (lsp--client-uri->path-fn (lsp--workspace-client workspace)) (lambda (_) file))
            (setq target (find-file-noselect file))
            (with-current-buffer target (narrow-to-region 1 5))
            (cl-letf (((symbol-function 'xref-push-marker-stack) (lambda () (setq pushed (current-buffer))))
                      ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (set-buffer buffer))))
              (lsp-hierarchy--open-file "custom://symbol" (lsp-hierarchy-test--range 1 2 5) workspace)
              (should (eq pushed origin))
              (should (eq jumped target))
              (should (looking-at-p "foo"))
              (should-not (buffer-narrowed-p)))))
      (when (buffer-live-p target) (kill-buffer target))
      (delete-file file))))

(ert-deftest lsp-hierarchy-initial-expansion-depth ()
  (dolist (depth '(0 1 2))
    (lsp-hierarchy-test--with-session
      (let ((lsp-hierarchy-expand-depth depth))
        (with-current-buffer (lsp-hierarchy-test--show)
          (lsp-hierarchy-test--roots "root")
          (should (= (length lsp-hierarchy-test--sent) (if (= depth 0) 1 2)))
          (when (> depth 0)
            (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                       (vector (lsp-hierarchy-test--call "child")))
            (should (= (length lsp-hierarchy-test--sent) (if (= depth 1) 2 3)))))))))

(ert-deftest lsp-hierarchy-auto-expansion-stops-after-folding ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 3))
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "root")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (vector (lsp-hierarchy-test--call "child")))
        (should (= 2 (length lsp-hierarchy-test--sent)))
        (should (invisible-p (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child"))))))))

(ert-deftest lsp-hierarchy-auto-expands-each-workspaces-roots ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 1))
      (push (lsp-hierarchy-test--workspace
             'server-b (lsp-make-server-capabilities :call-hierarchy-provider? t))
            lsp-hierarchy-test--workspaces)
      (with-current-buffer (lsp-hierarchy-test--show)
        (dolist (request (copy-sequence lsp-hierarchy-test--sent))
          (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "same"))))
        (should (= 4 (length lsp-hierarchy-test--sent)))
        (let ((children (seq-filter
                         (lambda (request)
                           (equal (plist-get (plist-get request :body) :method) "callHierarchy/incomingCalls"))
                         lsp-hierarchy-test--sent)))
          (should (= 2 (length children)))
          (should-not (eq (plist-get (car children) :workspace)
                          (plist-get (cadr children) :workspace))))))))

(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
