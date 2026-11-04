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
  "Find a model node with NAME, whether or not its row is visible."
  (or (seq-find (lambda (node)
                  (equal name (lsp-hierarchy--node-name node)))
                (hash-table-values (lsp-hierarchy--view-nodes lsp-hierarchy--view)))
      (ert-fail (format "Missing node %s" name))))

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
  (dolist (kind (number-sequence 1 26))
    (should-not (string-empty-p (lsp-hierarchy--kind-abbrev kind))))
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
    (should (lsp-hierarchy--view-p lsp-hierarchy--view))))

(ert-deftest lsp-hierarchy-fontify-bare-symbol-test ()
  "A symbol without a detail field must fontify without an exception."
  (dolist (label '("foo" "foo signature"))
    (with-temp-buffer
      (lsp-hierarchy-mode)
      (let ((inhibit-read-only t))
        (lsp-hierarchy--insert-node
         (lsp-hierarchy--make-node :type 'symbol :kind 12 :name label) 0))
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
        (should (not (eq (lsp-hierarchy--node-load-state root) 'loading)))
        (should-not (eq (lsp-hierarchy--node-load-state root) 'loaded))
        (should-not (string-match-p "Loading" (buffer-string)))
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) nil)
        (should (eq (lsp-hierarchy--node-load-state root) 'loaded))
        (should-not (eq (lsp-hierarchy--node-load-state root) 'loading))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))))))

(ert-deftest lsp-hierarchy-send-error-is-retryable ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (cl-letf (((symbol-function 'lsp--send-no-wait) (lambda (&rest _) (error "Send failed"))))
        (lsp-hierarchy-test--toggle "root"))
      (should (not (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading)))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
      (should (= 0 (hash-table-count lsp--cancelable-requests)))
      (should (= 0 (hash-table-count lsp--request-cleanup-hooks)))
      (should-not (string-match-p "Loading" (buffer-string))))))

(ert-deftest lsp-hierarchy-source-kill-releases-pending-node ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (kill-buffer lsp-hierarchy-test--source)
      (should (not (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading)))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
      (lsp-hierarchy-test--toggle "root")
      (should (not (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading))))))

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
        (should (= (hash-table-count (lsp-hierarchy--view-nodes lsp-hierarchy--view)) 2))
        (let* ((nodes (hash-table-values (lsp-hierarchy--view-nodes lsp-hierarchy--view)))
               (node-a (seq-find (lambda (node) (eq (lsp-hierarchy--node-workspace node) a)) nodes))
               (node-b (seq-find (lambda (node) (eq (lsp-hierarchy--node-workspace node) b)) nodes)))
          (should-not (eq (lsp-hierarchy--node-id node-a) (lsp-hierarchy--node-id node-b)))
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
            (should (eq (lsp-hierarchy--node-load-state alpha) 'loading))
            (should-not (eq (lsp-hierarchy--node-load-state beta) 'loading))
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

(ert-deftest lsp-hierarchy-folding-hides-whole-lines-without-ellipsis ()
  "Repeated folds must not prefix the next visible row with an ellipsis."
  (lsp-hierarchy-test--with-session
   (with-current-buffer (lsp-hierarchy-test--show)
     (lsp-hierarchy-test--roots "root" "next-root")
     (lsp-hierarchy-test--toggle "root")
     (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
				(vector (lsp-hierarchy-test--call "alpha")
					(lsp-hierarchy-test--call "beta")))
     (lsp-hierarchy-test--toggle "alpha")
     (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
				(vector (lsp-hierarchy-test--call "grandchild")))
     (lsp-hierarchy-test--toggle "alpha")
     (dotimes (_ 3)
       (lsp-hierarchy-test--toggle "root")
       (dolist (name '("alpha" "grandchild" "beta"))
         ;; Folded nodes remain in the model but contribute no display row.
         (should-not (lsp-hierarchy-test--node-position
                      (lsp-hierarchy-test--node name))))
       (should (lsp-hierarchy-test--node-position
                (lsp-hierarchy-test--node "next-root")))
       (lsp-hierarchy-test--toggle "root")
       (dolist (name '("alpha" "beta"))
         (should (lsp-hierarchy-test--node-position
                  (lsp-hierarchy-test--node name))))
       (should-not (lsp-hierarchy-test--node-position
                    (lsp-hierarchy-test--node "grandchild"))))
     (lsp-hierarchy-test--toggle "alpha")
     (should (lsp-hierarchy-test--node-position
              (lsp-hierarchy-test--node "grandchild"))))))

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
       (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "beta")))
       (lsp-hierarchy-test--reply pending (vector (lsp-hierarchy-test--call "grandchild")))
       (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild")))
       (lsp-hierarchy-test--toggle "root")
       (should (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild")))
       (lsp-hierarchy-test--toggle "alpha")
       (lsp-hierarchy-test--toggle "root")
       (lsp-hierarchy-test--toggle "root")
       (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "grandchild")))))))

(ert-deftest lsp-hierarchy-can-fold-while-node-is-loading ()
  (lsp-hierarchy-test--with-session
   (with-current-buffer (lsp-hierarchy-test--show)
     (lsp-hierarchy-test--roots "root")
     (lsp-hierarchy-test--toggle "root")
     (lsp-hierarchy-test--toggle "root")
     (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                (vector (lsp-hierarchy-test--call "child")))
     (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))
     (lsp-hierarchy-test--toggle "root")
     (should (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child"))))))

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
          (should (eq (nth 1 jumped) (lsp-get (lsp-hierarchy--node-lsp-item root) :selectionRange)))
          (should (eq (nth 2 jumped) (lsp-hierarchy--node-workspace root))))))))

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
                 (lsp-hierarchy-display-buffer-action '(display-buffer-pop-up-window))
                 pushed jumped
                 (xref-after-jump-hook (list (lambda () (setq jumped (current-buffer))))))
            (setf (lsp--client-uri->path-fn (lsp--workspace-client workspace)) (lambda (_) file))
            (setq target (find-file-noselect file))
            (with-current-buffer target (narrow-to-region 1 5))
            (cl-letf (((symbol-function 'xref-push-marker-stack) (lambda () (setq pushed (current-buffer))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer action)
                         (should (equal action lsp-hierarchy-display-buffer-action))
                         (set-buffer buffer))))
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
       (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))))))

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

(ert-deftest lsp-hierarchy-lazy-call-sites-and-file-cache ()
  (let ((file (make-temp-file "hierarchy-sites-" nil ".c" "foo(); foo();\n")))
    (unwind-protect
        (lsp-hierarchy-test--with-session
          (with-current-buffer (lsp-hierarchy-test--show)
            (lsp-hierarchy-test--roots "root")
            (lsp-hierarchy-test--toggle "root")
            (let ((uri (lsp--path-to-uri file))
                  (reads 0)
                  (read-file (symbol-function 'insert-file-contents)))
              (cl-letf (((symbol-function 'insert-file-contents)
                         (lambda (filename &rest args)
                           (when (equal filename file) (cl-incf reads))
                           (apply read-file filename args))))
                (lsp-hierarchy-test--reply
                 (car lsp-hierarchy-test--sent)
                 (vector (lsp-hierarchy-test--call
                          "caller" uri (vector (lsp-hierarchy-test--range 0 0 3)
                                               (lsp-hierarchy-test--range 0 7 10)))))
                (should (= reads 0))
                (lsp-hierarchy-test--toggle "caller")
                (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) nil)
                (should (= reads 1))
                (should (= 1 (hash-table-count (lsp-hierarchy--view-file-cache lsp-hierarchy--view))))
                (font-lock-ensure)
                (should (string-match-p "foo();" (buffer-string)))
                (let ((snapshot (cdr (gethash file (lsp-hierarchy--view-file-cache lsp-hierarchy--view)))))
                  (kill-buffer (current-buffer))
                  (should-not (buffer-live-p snapshot)))))))
      (delete-file file))))

(ert-deftest lsp-hierarchy-file-cache-refresh-and-live-buffer-precedence ()
  (let ((file (make-temp-file "hierarchy-cache-" nil ".c" "old();\n"))
        visited)
    (unwind-protect
        (with-temp-buffer
          (lsp-hierarchy-mode)
          (let* ((uri (lsp--path-to-uri file))
                 (range (lsp-hierarchy-test--range 0 0 3)))
            (should (string-prefix-p "old" (lsp-hierarchy--extract-line uri range)))
            (with-temp-file file (insert "updated();\n"))
            (should (string-prefix-p "updated" (lsp-hierarchy--extract-line uri range)))
            (setq visited (find-file-noselect file))
            (with-current-buffer visited (erase-buffer) (insert "unsaved();\n"))
            (should (string-prefix-p "unsaved" (lsp-hierarchy--extract-line uri range)))
            (should (buffer-modified-p visited))))
      (when (buffer-live-p visited)
        (with-current-buffer visited (set-buffer-modified-p nil))
        (kill-buffer visited))
      (delete-file file))))

(ert-deftest lsp-hierarchy-empty-node-becomes-a-leaf ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "empty" "next")
      (lsp-hierarchy-test--toggle "empty")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (font-lock-ensure)
      (let* ((node (lsp-hierarchy-test--node "empty"))
             (pos (lsp-hierarchy-test--node-position node))
             (requests (length lsp-hierarchy-test--sent)))
        (should (equal (get-text-property pos 'display) " "))
        (goto-char pos)
        (lsp-hierarchy-smart-tab)
        (should (eq (lsp-hierarchy--get-prop 'lsp-hierarchy-item)
                    (lsp-hierarchy-test--node "next")))
        (lsp-hierarchy-test--toggle "empty")
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-styles-structured-name-and-detail ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (let ((item (lsp-hierarchy-test--item "operator new")))
        (lsp-put item :detail "  (size_t size)")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector item))
        (goto-char (point-min))
        (search-forward "operator new")
        (should (eq (get-text-property (1- (point)) 'face) 'lsp-hierarchy-node-face))
        (search-forward "size_t")
        (should (eq (get-text-property (1- (point)) 'face) 'lsp-hierarchy-detail-face))
        (should (equal (lsp-get item :name) "operator new"))))))

(ert-deftest lsp-hierarchy-normalizes-call-edge-locations ()
  (let* ((workspace (lsp-hierarchy-test--workspace 'server))
         (parent (lsp-hierarchy--symbol-node
                  (lsp-hierarchy-test--item "parent" "file:///parent.c") workspace))
         (item (lsp-hierarchy-test--item "child" "file:///child.c" '(opaque)))
         (range (lsp-hierarchy-test--range 0 1 4)))
    (dolist (outgoing '(nil t))
      (let* ((call (if outgoing
                       (lsp-make-call-hierarchy-outgoing-call :to item :from-ranges (vector range))
                     (lsp-make-call-hierarchy-incoming-call :from item :from-ranges (vector range))))
             (node (car (lsp-hierarchy--call-nodes (vector call) parent outgoing)))
             (site (car (lsp-hierarchy--node-call-sites node))))
        (should (eq (lsp-hierarchy--node-lsp-item node) item))
        (should (eq (lsp-hierarchy--node-workspace node) workspace))
        (should (eq (lsp-hierarchy--node-range site) range))
        (should (equal (lsp-hierarchy--node-uri site)
                       (if outgoing "file:///parent.c" "file:///child.c")))))))

(ert-deftest lsp-hierarchy-shared-symbol-has-independent-occurrences ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "a" "b")
      (let ((item (lsp-hierarchy-test--item "shared")))
        (dolist (name '("a" "b"))
          (lsp-hierarchy-test--toggle name)
          (lsp-hierarchy-test--reply
           (car lsp-hierarchy-test--sent)
           (vector (lsp-make-call-hierarchy-incoming-call :from item :from-ranges [])))))
      (let* ((a (lsp-hierarchy-test--node "a"))
             (b (lsp-hierarchy-test--node "b"))
             (a-child (car (lsp-hierarchy--node-children a)))
             (b-child (car (lsp-hierarchy--node-children b))))
        (should (eq (lsp-hierarchy--node-parent a-child) a))
        (should (eq (lsp-hierarchy--node-parent b-child) b))
        (should-not (eq (lsp-hierarchy--node-id a-child) (lsp-hierarchy--node-id b-child)))
        (goto-char (lsp-hierarchy-test--node-position a-child))
        (lsp-hierarchy-toggle)
        (should (eq (lsp-hierarchy--node-load-state a-child) 'loading))
        (should (eq (lsp-hierarchy--node-load-state b-child) 'unloaded))
        (should-not (lsp-hierarchy--node-expanded b-child))))))

(ert-deftest lsp-hierarchy-render-failure-does-not-publish-partial-children ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root" "sibling")
      (lsp-hierarchy-test--toggle "root")
      (let ((insert-node (symbol-function 'lsp-hierarchy--insert-node))
            (response (vector (lsp-hierarchy-test--call "alpha")
                              (lsp-hierarchy-test--call "beta"))))
        (cl-letf (((symbol-function 'lsp-hierarchy--insert-node)
                   (lambda (node indent)
                     (when (equal (lsp-hierarchy--node-name node) "beta")
                       (error "Cannot render beta"))
                     (funcall insert-node node indent))))
          (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) response))
        (should-not (string-match-p "alpha" (buffer-string)))
        (should (string-match-p "sibling" (buffer-string)))
        (should-not (lsp-hierarchy--node-children (lsp-hierarchy-test--node "root")))
        (should (= 2 (hash-table-count (lsp-hierarchy--view-nodes lsp-hierarchy--view))))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) response)
        (should (= 2 (length (lsp-hierarchy--node-children (lsp-hierarchy-test--node "root")))))
        (should (= 1 (how-many "alpha" (point-min) (point-max))))))))

(ert-deftest lsp-hierarchy-model-can-rebuild-visible-rows ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "child")))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (let ((inhibit-read-only t)) (erase-buffer))
        (lsp-hierarchy--render)
        (should (equal text (buffer-substring-no-properties (point-min) (point-max)))))
      (lsp-hierarchy-test--toggle "root")
      (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))
      (should-not (overlays-in (point-min) (point-max)))
      (should-not (bound-and-true-p outline-minor-mode)))))

(ert-deftest lsp-hierarchy-redraw-preserves-point-and-window-anchor ()
  (lsp-hierarchy-test--with-session
    (save-window-excursion
      (let ((view (lsp-hierarchy-test--show)))
        (set-window-buffer (selected-window) view)
        (with-current-buffer view
          (lsp-hierarchy-test--roots "root" "second" "third")
          (lsp-hierarchy-test--toggle "root")
          (let ((node (lsp-hierarchy-test--node "third")))
            (goto-char (lsp-hierarchy-test--node-position node))
            (set-window-start (selected-window) (point) t)
            (forward-char 4)
            (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                       (vector (lsp-hierarchy-test--call "child")))
            (should (eq (lsp-hierarchy--get-prop 'lsp-hierarchy-item) node))
            (should (= 4 (current-column)))
            (should (eq (get-text-property (window-start) 'lsp-hierarchy-item) node))))))))

(ert-deftest lsp-hierarchy-late-response-after-major-mode-change-is-ignored ()
  (lsp-hierarchy-test--with-session
    (let* ((view (lsp-hierarchy-test--show))
           (request (car lsp-hierarchy-test--sent)))
      (with-current-buffer view
        (fundamental-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Another view")))
      (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "late")))
      (with-current-buffer view
        (should (eq major-mode 'fundamental-mode))
        (should (equal (buffer-string) "Another view"))))))

(ert-deftest lsp-hierarchy-eob-anchor-stays-at-eob ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "alpha" "beta")
      (lsp-hierarchy-test--toggle "alpha")
      (goto-char (point-max))
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector (lsp-hierarchy-test--call "child")))
      (should (eobp)))))
(ert-deftest lsp-hierarchy-loading-row-anchor-stays-on-loading-row ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "alpha" "beta")
      (lsp-hierarchy-test--toggle "alpha")
      (let ((alpha-request (car lsp-hierarchy-test--sent)))
        (lsp-hierarchy-test--toggle "beta")
        (forward-line 1)
        (should (get-text-property (point) 'lsp-hierarchy-loading))
        (lsp-hierarchy-test--reply alpha-request (vector (lsp-hierarchy-test--call "child")))
        (should (get-text-property (point) 'lsp-hierarchy-loading))))))
(ert-deftest lsp-hierarchy-render-honors-buffer-local-customization ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (setq-local lsp-hierarchy-icon-close "+")
      (lsp-hierarchy-test--roots "root")
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'display) "+")))))


(ert-deftest lsp-hierarchy-multiline-labels-stay-on-one-row ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (let ((item (lsp-hierarchy-test--item "operator\nnew")))
        (lsp-put item :detail "(\n int\t size)")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector item))
        (should (= 1 (count-lines (point-min) (point-max))))
        (should (string-match-p "operator new" (buffer-string)))
        (should (equal (lsp-get item :name) "operator\nnew"))
        (should (equal (lsp-get item :detail) "(\n int\t size)"))))))

(ert-deftest lsp-hierarchy-empty-prepare-is-explained ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (should (equal (buffer-string) "No hierarchy found.\n"))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))

(ert-deftest lsp-hierarchy-error-row-can-retry-its-owner ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (lsp-make-json-error :code -32603 :message "Failed") t)
      (should (string-match-p "Failed.*TAB to retry" (buffer-string)))
      (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-status-node
                                    (lsp-hierarchy-test--node "root")))
      (lsp-hierarchy-smart-tab)
      (should (= 3 (length lsp-hierarchy-test--sent)))
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "child")))
      (should-not (string-match-p "Failed" (buffer-string)))
      (should (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child"))))))

(ert-deftest lsp-hierarchy-failure-respects-folding-while-loading ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (lsp-make-json-error :code -32603 :message "Failed") t)
      (let ((node (lsp-hierarchy-test--node "root")))
        (should (eq (lsp-hierarchy--node-load-state node) 'error))
        (should-not (lsp-hierarchy--node-expanded node)))
      (should-not (string-match-p "Failed" (buffer-string))))))

(ert-deftest lsp-hierarchy-refresh-keeps-source-position-and-rejects-old-replies ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source
      (insert "first\nsecond\nthird\n")
      (goto-char 10))
    (with-current-buffer (lsp-hierarchy-test--show 'call t)
      (lsp-hierarchy-test--roots "old")
      (lsp-hierarchy-test--toggle "old")
      (let ((old-request (car lsp-hierarchy-test--sent))
            (old-origin (lsp-hierarchy--view-origin lsp-hierarchy--view)))
        (setq-local lsp-hierarchy-icon-close "+")
        (with-current-buffer lsp-hierarchy-test--source (goto-char (point-max)))
        (revert-buffer nil t)
        (should-not (marker-buffer old-origin))
        (let* ((request (car lsp-hierarchy-test--sent))
               (params (plist-get (plist-get request :body) :params))
               (position (plist-get params :position)))
          (should (= 1 (plist-get position :line)))
          (should (= 3 (plist-get position :character))))
        (lsp-hierarchy-test--roots "new")
        (lsp-hierarchy-test--reply old-request (vector (lsp-hierarchy-test--call "stale")))
        (should-not (string-match-p "stale" (buffer-string)))
        (should (equal (get-text-property (point-min) 'display) "+"))
        (lsp-hierarchy-test--toggle "new")
        (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                       "callHierarchy/outgoingCalls"))))))

(ert-deftest lsp-hierarchy-refresh-releases-owned-resources ()
  (let ((file (make-temp-file "hierarchy-refresh-" nil ".c" "call();\n")))
    (unwind-protect
        (lsp-hierarchy-test--with-session
          (with-current-buffer (lsp-hierarchy-test--show)
            (lsp-hierarchy-test--roots "root")
            (let ((snapshot (lsp-hierarchy--source-snapshot file))
                  (origin (lsp-hierarchy--view-origin lsp-hierarchy--view)))
              (lsp-hierarchy-test--toggle "root")
              (lsp-hierarchy-refresh)
              (should-not (buffer-live-p snapshot))
              (should-not (marker-buffer origin))
              (should (= 1 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
              (setq origin (lsp-hierarchy--view-origin lsp-hierarchy--view))
              (kill-buffer (current-buffer))
              (should-not (marker-buffer origin)))))
      (delete-file file))))

(ert-deftest lsp-hierarchy-refresh-rejects-killed-source ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (kill-buffer lsp-hierarchy-test--source)
      (should-error (lsp-hierarchy-refresh) :type 'user-error)
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))

(ert-deftest lsp-hierarchy-auto-expansion-batches-loading-rows ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 2))
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "root")
        (let ((render (symbol-function 'lsp-hierarchy--render)) (renders 0))
          (cl-letf (((symbol-function 'lsp-hierarchy--render)
                     (lambda () (cl-incf renders) (funcall render))))
            (lsp-hierarchy-test--reply
             (car lsp-hierarchy-test--sent)
             (vconcat (cl-loop for index below 50
                              collect (lsp-hierarchy-test--call (format "child-%d" index))))))
          ;; Publish the response, then all automatic loading rows together.
          (should (<= renders 2))
          (should (= 50 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
          (should (= 50 (how-many "Loading" (point-min) (point-max)))))))))

(ert-deftest lsp-hierarchy-batched-expansion-publishes-send-errors ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 1))
      (with-current-buffer (lsp-hierarchy-test--show)
        (cl-letf (((symbol-function 'lsp--send-no-wait)
                   (lambda (&rest _) (error "Unavailable"))))
          (lsp-hierarchy-test--roots "a" "b"))
        (should (= 2 (how-many "Unavailable.*TAB" (point-min) (point-max))))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))))))

(ert-deftest lsp-hierarchy-known-call-sites-survive-pending-and-failed-relations ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "target")
      (lsp-hierarchy-test--toggle "target")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-hierarchy-test--call "caller" nil
                                        (vector (lsp-hierarchy-test--range 0 0 6)))))
      (let* ((caller (lsp-hierarchy-test--node "caller"))
             (site (car (lsp-hierarchy--node-call-sites caller))))
        (should-not (lsp-hierarchy-test--node-position site))
        (lsp-hierarchy-test--toggle "caller")
        (should (lsp-hierarchy-test--node-position site))
        (should (string-match-p "target();" (buffer-string)))
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (lsp-make-json-error :code -32603 :message "Unavailable") t)
        (should (lsp-hierarchy-test--node-position site))
        (lsp-hierarchy-test--toggle "caller")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
        (should (eq site (car (lsp-hierarchy--node-children caller))))
        (should (= 1 (how-many "target();" (point-min) (point-max))))
        (should (lsp-hierarchy--expandable-p caller))))))

(ert-deftest lsp-hierarchy-navigates-parents-and-siblings-without-requests ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root" "other-root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "alpha")
                                         (lsp-hierarchy-test--call "beta")))
      (lsp-hierarchy-test--toggle "alpha")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "grandchild")))
      (let ((requests (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "alpha"))
        (lsp-hierarchy-next-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "beta")))
        (let ((position (point)))
          (should-error (lsp-hierarchy-next-sibling) :type 'user-error)
          (should (= position (point))))
        (lsp-hierarchy-previous-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "alpha")))
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "root")))
        (lsp-hierarchy-next-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "other-root")))
        (should-error (lsp-hierarchy-parent) :type 'user-error)
        (lsp-hierarchy-previous-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "root")))
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-left-folds-loading-and-error-rows-without-retrying ()
  (dolist (fail '(nil t))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "root")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (vector (lsp-hierarchy-test--call "branch")))
        (lsp-hierarchy-test--toggle "branch")
        (when fail
          (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                     (lsp-make-json-error :code -32603 :message "Failed") t))
        (let ((branch (lsp-hierarchy-test--node "branch"))
              (requests (length lsp-hierarchy-test--sent)))
          (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-status-node branch))
          (lsp-hierarchy-collapse-or-parent)
          (should (eq (lsp-hierarchy--node-at-point) branch))
          (should-not (lsp-hierarchy--node-expanded branch))
          (should (eq (lsp-hierarchy--node-load-state branch) (if fail 'error 'loading)))
          (should (= requests (length lsp-hierarchy-test--sent)))
          (lsp-hierarchy-collapse-or-parent)
          (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "root"))))))))

(ert-deftest lsp-hierarchy-call-sites-participate-in-sibling-navigation-once ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-hierarchy-test--call "caller" nil
                (vector (lsp-hierarchy-test--range 0 0 3)
                        (lsp-hierarchy-test--range 1 0 3)))))
      (lsp-hierarchy-test--toggle "caller")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "ancestor")))
      (let* ((caller (lsp-hierarchy-test--node "caller"))
             (sites (lsp-hierarchy--node-call-sites caller))
             (requests (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy--goto-node (car sites))
        (lsp-hierarchy-next-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (cadr sites)))
        (lsp-hierarchy-next-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "ancestor")))
        (lsp-hierarchy-previous-sibling)
        (should (eq (lsp-hierarchy--node-at-point) (cadr sites)))
        (lsp-hierarchy-collapse-or-parent)
        (should (eq (lsp-hierarchy--node-at-point) caller))
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-sibling-navigation-follows-visible-order ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "first" "hidden" "last")
      (let ((first (lsp-hierarchy-test--node "first"))
            (last (lsp-hierarchy-test--node "last"))
            (inhibit-read-only t))
        ;; The model remains unchanged while presentation reorders and hides
        ;; siblings.  Navigation must follow that presentation without I/O.
        (erase-buffer)
        (lsp-hierarchy--insert-node last 0)
        (lsp-hierarchy--insert-node first 0)
        (lsp-hierarchy--goto-node last)
        (lsp-hierarchy-next-sibling)
        (should (eq (lsp-hierarchy--node-at-point) first))
        (lsp-hierarchy-previous-sibling)
        (should (eq (lsp-hierarchy--node-at-point) last))
        (should (= 1 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-preview-preserves-focus-and-xref-history ()
  (let ((file (make-temp-file "hierarchy-preview-" nil ".c" "head\n😀foo();\n")) target)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-temp-buffer
            (lsp-hierarchy-mode)
            (let* ((view (current-buffer))
                   (origin-window (selected-window))
                   (source-window (split-window-right))
                   (workspace (lsp-hierarchy-test--workspace
                               'encoding (lsp-make-server-capabilities :positionEncoding "utf-16")))
                   (display-buffer-alist nil)
                   pushed jumped)
              (setf (lsp--client-uri->path-fn (lsp--workspace-client workspace)) (lambda (_) file))
              (setq target (find-file-noselect file))
              (with-current-buffer target (narrow-to-region 1 5))
              (set-window-buffer source-window target)
              (set-window-buffer origin-window view)
              (let ((inhibit-read-only t))
                (lsp-hierarchy--insert-node
                 (lsp-hierarchy--make-node :type 'symbol :name "foo" :uri "custom://symbol"
                                          :range (lsp-hierarchy-test--range 1 2 5)
                                          :workspace workspace) 0))
              (goto-char 3)
              (let ((xref-after-jump-hook (list (lambda () (setq jumped t)))))
                (cl-letf (((symbol-function 'xref-push-marker-stack) (lambda () (setq pushed t))))
                  (lsp-hierarchy-preview)))
              (should (eq (selected-window) origin-window))
              (should (eq (current-buffer) view))
              (should (= (point) 3))
              (should-not pushed)
              (should-not jumped)
              (should (eq (window-buffer source-window) target))
              (with-current-buffer target
                (should-not (buffer-narrowed-p))
                (goto-char (window-point source-window))
                (should (looking-at-p "foo"))
                ;; A second preview inside an existing restriction must not
                ;; widen it or move the buffer's independent point.
                (narrow-to-region (line-beginning-position) (line-end-position))
                (goto-char (point-max)))
              (lsp-hierarchy-preview)
              (with-current-buffer target
                (should (buffer-narrowed-p))
                (should (= (point) (point-max)))
                (save-excursion
                  (goto-char (window-point source-window))
                  (should (looking-at-p "foo")))))))
      (when (buffer-live-p target) (kill-buffer target))
      (delete-file file))))

(ert-deftest lsp-hierarchy-preview-honors-user-display-rules ()
  (let ((file (make-temp-file "hierarchy-preview-rule-" nil ".c" "foo();\n")) target)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-temp-buffer
            (lsp-hierarchy-mode)
            (let* ((view (current-buffer))
                   (origin-window (selected-window))
                   (source-window (split-window-right))
                   (lsp-hierarchy-display-buffer-action
                    (list (lambda (&rest _) (ert-fail "Fallback overrode user display rule"))))
                   (display-buffer-alist
                    (list (list (regexp-quote (file-name-nondirectory file))
                                (lambda (buffer _alist)
                                  (set-window-buffer source-window buffer)
                                  source-window)))))
              (set-window-buffer origin-window view)
              (setq target (find-file-noselect file))
              (let ((inhibit-read-only t))
                (lsp-hierarchy--insert-node
                 (lsp-hierarchy--make-node :type 'symbol :name "foo" :uri (lsp--path-to-uri file)
                                          :range (lsp-hierarchy-test--range 0 0 3)) 0))
              (goto-char (point-min))
              (lsp-hierarchy-preview)
              (should (eq (selected-window) origin-window))
              (should (eq (window-buffer source-window) target)))))
      (when (buffer-live-p target) (kill-buffer target))
      (delete-file file))))

(ert-deftest lsp-hierarchy-preview-rejects-same-window-display-safely ()
  (let ((file (make-temp-file "hierarchy-preview-same-" nil ".c" "foo();\n")) target)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-temp-buffer
            (lsp-hierarchy-mode)
            (let* ((view (current-buffer))
                   (window (selected-window))
                   (display-buffer-alist
                    '((".*" display-buffer-same-window (inhibit-same-window . nil)))))
              (set-window-buffer window view)
              (setq target (find-file-noselect file))
              (let ((inhibit-read-only t))
                (lsp-hierarchy--insert-node
                 (lsp-hierarchy--make-node :type 'symbol :name "foo" :uri (lsp--path-to-uri file)
                                          :range (lsp-hierarchy-test--range 0 0 3)) 0))
              (goto-char 3)
              (should-error (lsp-hierarchy-preview) :type 'user-error)
              (should (eq (window-buffer window) view))
              (should (eq (selected-window) window))
              (should (= (point) 3)))))
      (when (buffer-live-p target) (kill-buffer target))
      (delete-file file))))

(defun lsp-hierarchy-test--click (position)
  "Dispatch a mouse-1 event through the text keymap at POSITION."
  (set-window-buffer (selected-window) (current-buffer))
  (funcall (lookup-key (get-text-property position 'keymap) [mouse-1])
           (list 'mouse-1 (list (selected-window) position '(0 . 0) 0))))

(ert-deftest lsp-hierarchy-mouse-reuses-keyboard-actions ()
  (save-window-excursion
    (lsp-hierarchy-test--with-session
      (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--roots "root")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply
         (car lsp-hierarchy-test--sent)
         (vector (lsp-hierarchy-test--call "caller" nil
                                          (vector (lsp-hierarchy-test--range 0 0 6)))))
        (lsp-hierarchy-test--toggle "caller")
        (let* ((root (lsp-hierarchy-test--node "root"))
               (site (car (lsp-hierarchy--node-call-sites (lsp-hierarchy-test--node "caller"))))
               (arrow (lsp-hierarchy-test--node-position root))
               (name (text-property-any arrow (point-max) 'lsp-hierarchy-action
                                        #'lsp-hierarchy-goto))
               (code (text-property-any (lsp-hierarchy-test--node-position site) (point-max)
                                        'lsp-hierarchy-action #'lsp-hierarchy-goto))
               actions)
          (cl-letf (((symbol-function 'lsp-hierarchy-toggle)
                     (lambda () (interactive)
                       (push (cons 'toggle (lsp-hierarchy--node-at-point)) actions)))
                    ((symbol-function 'lsp-hierarchy-goto)
                     (lambda () (interactive)
                       (push (cons 'goto (lsp-hierarchy--node-at-point)) actions))))
            (dolist (position (list arrow name code))
              (goto-char (point-max))
              (lsp-hierarchy-test--click position)
              (should (= position (point)))
              (should (stringp (get-text-property position 'help-echo)))
              (should (eq (key-binding (kbd "TAB")) #'lsp-hierarchy-smart-tab))
              (should (eq (key-binding (kbd "?")) #'describe-mode))))
          (should (equal (nreverse actions)
                         (list (cons 'toggle root) (cons 'goto root) (cons 'goto site)))))))))

(ert-deftest lsp-hierarchy-mouse-status-folds-or-retries-owner ()
  (save-window-excursion
    (dolist (failed '(nil t))
      (lsp-hierarchy-test--with-session
        (with-current-buffer (lsp-hierarchy-test--show)
          (lsp-hierarchy-test--roots "root")
          (lsp-hierarchy-test--toggle "root")
          (when failed
            (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                       (lsp-make-json-error :code -32603 :message "Failed") t))
          (let* ((root (lsp-hierarchy-test--node "root"))
                 (status (text-property-any (point-min) (point-max)
                                            'lsp-hierarchy-status-node root)))
            (lsp-hierarchy-test--click status)
            (should (eq (lsp-hierarchy--node-load-state root) 'loading))
            (should (eq (lsp-hierarchy--node-expanded root) failed))
            (should (= (length lsp-hierarchy-test--sent) (if failed 3 2)))))))))

(ert-deftest lsp-hierarchy-leaf-expander-has-no-mouse-action ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (goto-char (point-min))
      (should-not (get-text-property (point) 'keymap))
      (should-not (get-text-property (point) 'lsp-hierarchy-action))
      (should-not (get-text-property (point) 'help-echo)))))

(defun lsp-hierarchy-test--location-help (node)
  "Return the location hover text on NODE's name or source code."
  (save-excursion
    (lsp-hierarchy--goto-node node)
    (let ((position (text-property-any (point) (line-end-position)
                                       'lsp-hierarchy-action #'lsp-hierarchy-goto)))
      (get-text-property position 'help-echo))))

(ert-deftest lsp-hierarchy-location-help-distinguishes-same-named-roots ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (cl-letf (((symbol-function 'lsp--uri-to-path)
                 (lambda (&rest _) (ert-fail "Rendering should not resolve or open URIs"))))
        (lsp-hierarchy-test--reply
         (car lsp-hierarchy-test--sent)
         (vector (lsp-hierarchy-test--item "同名😀\n函数" "file:///项目/一.c")
                 (lsp-hierarchy-test--item "同名😀\n函数" "virtual:///项目/二\n文件.c")))
        (let ((roots (lsp-hierarchy--view-roots lsp-hierarchy--view)))
          (should (equal (lsp-hierarchy-test--location-help (car roots))
                         "mouse-1, RET: Visit this symbol\nfile:///项目/一.c:1"))
          (should (equal (lsp-hierarchy-test--location-help (cadr roots))
                         "mouse-1, RET: Visit this symbol\nvirtual:///项目/二 文件.c:1")))
        (should (= 2 (count-lines (point-min) (point-max))))
        (should (= 2 (how-many "同名😀 函数" (point-min) (point-max))))
        (should-not (string-match-p "site" (buffer-string)))
        (should (= 1 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-closed-node-site-counts-need-no-source-reads ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (cl-letf (((symbol-function 'lsp-hierarchy--extract-line)
                 (lambda (&rest _) (ert-fail "Closed nodes must not read call-site source")))
                ((symbol-function 'lsp-hierarchy--source-snapshot)
                 (lambda (&rest _) (ert-fail "Metadata must not open source snapshots"))))
        (lsp-hierarchy-test--reply
         (car lsp-hierarchy-test--sent)
         (vector (lsp-hierarchy-test--call "once" nil
                                          (vector (lsp-hierarchy-test--range 0 0 3)))
                 (lsp-hierarchy-test--call "twice" nil
                                          (vector (lsp-hierarchy-test--range 0 0 3)
                                                  (lsp-hierarchy-test--range 1 0 3)))
                 (lsp-hierarchy-test--call "unknown")))
        (should (string-match-p "once (1 site)" (buffer-string)))
        (should (string-match-p "twice (2 sites)" (buffer-string)))
        (should-not (string-match-p "0 sites" (buffer-string)))
        (setq-local lsp-hierarchy-detailed-outline nil)
        (lsp-hierarchy--render)
        (should-not (string-match-p "sites?" (buffer-string)))
        (should (string-match-p "file:///tmp/lsp-hierarchy-test.c:1"
                                (lsp-hierarchy-test--location-help (lsp-hierarchy-test--node "twice"))))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-file-cache lsp-hierarchy--view))))
        (should (= 2 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-outgoing-site-help-identifies-caller-source ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source (insert "😀target();\n"))
    (with-current-buffer (lsp-hierarchy-test--show 'call t)
      (lsp-hierarchy-test--roots "caller")
      (lsp-hierarchy-test--toggle "caller")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-make-call-hierarchy-outgoing-call
                :to (lsp-hierarchy-test--item "target" "file:///tmp/callee.c")
                :from-ranges (vector (lsp-hierarchy-test--range 0 2 8)))))
      (let* ((callee (lsp-hierarchy-test--node "target"))
             (site (car (lsp-hierarchy--node-call-sites callee))))
        (should (equal (lsp-hierarchy-test--location-help callee)
                       "mouse-1, RET: Visit this symbol\nfile:///tmp/callee.c:1"))
        (lsp-hierarchy-test--toggle "target")
        (should (equal (lsp-hierarchy-test--location-help site)
                       "mouse-1, RET: Visit this call site\nfile:///tmp/lsp-hierarchy-test.c:1"))
        (should (string-match-p "😀target(); (line 1)" (buffer-string)))
        (should (= 4 (count-lines (point-min) (point-max))))
        (should (= 3 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-batch-redraw-failure-keeps-request-owners ()
  (dolist (root-batch '(nil t))
    (lsp-hierarchy-test--with-session
      (let ((lsp-hierarchy-expand-depth 3))
        (with-current-buffer (lsp-hierarchy-test--show)
          (unless root-batch (lsp-hierarchy-test--roots "root"))
          (let ((render (symbol-function 'lsp-hierarchy--render)) failed)
            (cl-letf (((symbol-function 'lsp-hierarchy--render)
                       (lambda ()
                         (if (and (not failed)
                                  (> (hash-table-count
                                      (lsp-hierarchy--view-requests lsp-hierarchy--view)) 1))
                             (progn (setq failed t) (error "Batch redraw failed"))
                           (funcall render)))))
              (if root-batch
                  (lsp-hierarchy-test--roots "a" "b")
                (lsp-hierarchy-test--reply
                 (car lsp-hierarchy-test--sent)
                 (vector (lsp-hierarchy-test--call "a")
                         (lsp-hierarchy-test--call "b")))))
            (should failed))
          (should (eq (lsp-hierarchy--view-status lsp-hierarchy--view) 'ready))
          (let* ((parent (lsp-hierarchy-test--node (if root-batch "b" "root")))
                 (b (lsp-hierarchy-test--node "b"))
                 (request (car lsp-hierarchy-test--sent))
                 (sent (length lsp-hierarchy-test--sent)))
            (unless root-batch
              (should (eq (lsp-hierarchy--node-load-state parent) 'loaded)))
            ;; A fold must remain a fold, not retry a falsely failed parent.
            (lsp-hierarchy--goto-node parent)
            (lsp-hierarchy-toggle)
            (should (= sent (length lsp-hierarchy-test--sent)))
            (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--call "child")))
            (let ((child (lsp-hierarchy-test--node "child")))
              (should (eq (lsp-hierarchy--node-parent child) b))
              (should (memq child (lsp-hierarchy--node-children b))))
            (should (= sent (length lsp-hierarchy-test--sent)))
            (should (= (hash-table-count (lsp-hierarchy--view-nodes lsp-hierarchy--view))
                       (if root-batch 3 4)))
            (lsp-hierarchy-test--toggle (if root-batch "b" "root"))
            (should (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))))))))


(defun lsp-hierarchy-test--visible-nodes ()
  "Return model nodes in the order their rows appear."
  (save-excursion
    (goto-char (point-min))
    (let (nodes)
      (while (not (eobp))
        (when-let* ((node (lsp-hierarchy--get-prop 'lsp-hierarchy-item)))
          (push node nodes))
        (forward-line 1))
      (nreverse nodes))))

(ert-deftest lsp-hierarchy-sort-is-stable-and-preserves-model-order ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "z" "b" "a" "b")
      (let* ((roots (lsp-hierarchy--view-roots lsp-hierarchy--view))
             (server-order (copy-sequence roots))
             (selected (nth 3 roots))
             (requests (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy--goto-node selected)
        (lsp-hierarchy-cycle-sort)
        (should (equal (lsp-hierarchy-test--visible-nodes)
                       (list (nth 2 roots) (nth 1 roots) (nth 3 roots) (nth 0 roots))))
        (should (eq selected (lsp-hierarchy--node-at-point)))
        ;; Identical locations preserve the server's original tie order.
        (lsp-hierarchy-cycle-sort)
        (should (equal (lsp-hierarchy-test--visible-nodes) server-order))
        (lsp-hierarchy-cycle-sort)
        (should-not lsp-hierarchy-sort-order)
        (should (equal (lsp-hierarchy-test--visible-nodes) server-order))
        (should (eq roots (lsp-hierarchy--view-roots lsp-hierarchy--view)))
        (should (equal roots server-order))
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-sort-keeps-call-sites-and-orders-locations ()
  (with-temp-buffer
    (lsp-hierarchy-mode)
    (let* ((first-site (lsp-hierarchy--make-node :type 'code :range (lsp-hierarchy-test--range 1 0 1)))
           (second-site (lsp-hierarchy--make-node :type 'code :range (lsp-hierarchy-test--range 2 0 1)))
           (far (lsp-hierarchy--make-node :type 'symbol :name "a" :uri "file:///b.c"
                                        :range (lsp-hierarchy-test--range 0 0 1) :load-state 'loaded))
           (late (lsp-hierarchy--make-node :type 'symbol :name "b" :uri "file:///a.c"
                                         :range (lsp-hierarchy-test--range 10 0 1) :load-state 'loaded))
           (early (lsp-hierarchy--make-node :type 'symbol :name "c" :uri "file:///a.c"
                                          :range (lsp-hierarchy-test--range 2 0 1) :load-state 'loaded))
           (later-column (lsp-hierarchy--make-node :type 'symbol :name "d" :uri "file:///a.c"
                                                  :range (lsp-hierarchy-test--range 2 3 4) :load-state 'loaded))
           (children (list first-site second-site far late later-column early))
           (root (lsp-hierarchy--make-node :type 'symbol :name "root" :expanded t
                                         :load-state 'loaded :children children)))
      (setf (lsp-hierarchy--view-roots lsp-hierarchy--view) (list root))
      (lsp-hierarchy--register-node root)
      (cl-letf (((symbol-function 'lsp-hierarchy--extract-line) (lambda (&rest _) "call();")))
        (lsp-hierarchy--render)
        (lsp-hierarchy-cycle-sort)
        (should (equal (lsp-hierarchy-test--visible-nodes)
                       (list root first-site second-site far late early later-column)))
        (lsp-hierarchy-cycle-sort)
        (should (equal (lsp-hierarchy-test--visible-nodes)
                       (list root first-site second-site early later-column late far))))
      (should (eq children (lsp-hierarchy--node-children root)))
      (should (equal children (list first-site second-site far late later-column early))))))

(ert-deftest lsp-hierarchy-sort-errors-preserve-display-and-order ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "second" "first")
      (let ((before (buffer-string)))
        (cl-letf (((symbol-function 'lsp-hierarchy--insert-node)
                   (lambda (&rest _) (error "Render failure"))))
          (should-error (lsp-hierarchy-cycle-sort)))
        (should-not lsp-hierarchy-sort-order)
        (should (equal before (buffer-string)))))))


(ert-deftest lsp-hierarchy-filter-reveals-loaded-paths-without-expanding ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                               (vector (lsp-hierarchy-test--call "branch")
                                       (lsp-hierarchy-test--call "other")))
      (lsp-hierarchy-test--toggle "branch")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                               (vector (lsp-hierarchy-test--call "target")
                                       (lsp-hierarchy-test--call "hidden")))
      (lsp-hierarchy-test--toggle "branch")
      (lsp-hierarchy-test--toggle "root")
      (let* ((root (lsp-hierarchy-test--node "root"))
             (branch (lsp-hierarchy-test--node "branch"))
             (target (lsp-hierarchy-test--node "target"))
             (ids (mapcar #'lsp-hierarchy--node-id (list root branch target)))
             (requests (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy-filter "target")
        (should (equal (lsp-hierarchy-test--visible-nodes) (list root branch target)))
        (should-not (lsp-hierarchy--node-expanded root))
        (should-not (lsp-hierarchy--node-expanded branch))
        (should-not (lsp-hierarchy--node-expanded target))
        (should (equal ids (mapcar #'lsp-hierarchy--node-id (list root branch target))))
        (goto-char (point-min))
        (should (equal (get-text-property (point) 'display) lsp-hierarchy-icon-open))
        (lsp-hierarchy--goto-node target)
        (should-error (lsp-hierarchy-next-sibling) :type 'user-error)
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) branch))
        ;; Folding changes the stored choice, while the filter keeps the
        ;; loaded path visible until it is cleared.
        (lsp-hierarchy-toggle)
        (should (lsp-hierarchy--node-expanded branch))
        (lsp-hierarchy-collapse-or-parent)
        (should-not (lsp-hierarchy--node-expanded branch))
        (should (equal (lsp-hierarchy-test--visible-nodes) (list root branch target)))
        (lsp-hierarchy-collapse-or-parent)
        (should (eq (lsp-hierarchy--node-at-point) root))
        (lsp-hierarchy--goto-node target)
        (lsp-hierarchy-filter "")
        (should (equal (lsp-hierarchy-test--visible-nodes) (list root)))
        (should (eq (lsp-hierarchy--node-at-point) root))
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-filter-matches-details-and-handles-empty-results ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "first" "second")
      (let ((second (lsp-hierarchy-test--node "second")))
        (setf (lsp-hierarchy--node-detail second) "special signature")
        (lsp-hierarchy-filter "special")
        (should (equal (lsp-hierarchy-test--visible-nodes) (list second)))
        (lsp-hierarchy-filter "absent")
        (should-not (lsp-hierarchy-test--visible-nodes))
        (should (string-match-p "No loaded symbols match" (buffer-string)))
        ;; Interactive empty input must clear instead of accepting the old regexp.
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
          (call-interactively #'lsp-hierarchy-filter))
        (should (= 2 (length (lsp-hierarchy-test--visible-nodes))))))))

(ert-deftest lsp-hierarchy-filter-errors-preserve-display-and-regexp ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "first" "second")
      (lsp-hierarchy-filter "first")
      (let ((before (buffer-string)))
        (should-error (lsp-hierarchy-filter "[") :type 'invalid-regexp)
        (should (equal lsp-hierarchy-filter-regexp "first"))
        (should (equal before (buffer-string)))
        (cl-letf (((symbol-function 'lsp-hierarchy--insert-node)
                   (lambda (&rest _) (error "Render failure"))))
          (should-error (lsp-hierarchy-filter "second")))
        (should (equal lsp-hierarchy-filter-regexp "first"))
        (should (equal before (buffer-string)))))))


(defun lsp-hierarchy-test--type-children (&rest names)
  "Reply to the latest type relationship request with NAMES."
  (lsp-hierarchy-test--reply
   (car lsp-hierarchy-test--sent)
   (vconcat (mapcar #'lsp-hierarchy-test--item names))))

(ert-deftest lsp-hierarchy-refresh-restores-path-with-new-items ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--toggle "child")
      (lsp-hierarchy-test--type-children "grandchild")
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "grandchild"))
      (move-to-column 8)
      (let ((old-id (lsp-hierarchy--node-id (lsp-hierarchy-test--node "root")))
            (root-item (lsp-hierarchy-test--item "root" nil '(fresh-root)))
            (child-item (lsp-hierarchy-test--item "child" nil '(fresh-child))))
        (lsp-hierarchy-refresh)
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector root-item))
        (should (eq (plist-get (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :params) :item)
                    root-item))
        (should-not (eq old-id (lsp-hierarchy--node-id (lsp-hierarchy-test--node "root"))))
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector child-item))
        (should (eq (plist-get (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :params) :item)
                    child-item))
        (lsp-hierarchy-test--type-children "grandchild")
        (should (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "root")))
        (should (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "child")))
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "grandchild")))
        (should (= 8 (current-column)))
        (should-not (lsp-hierarchy--view-restore-focus lsp-hierarchy--view))
        (should (= 6 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-refresh-preserves-folded-roots-and-prefix-resets ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 1))
      (with-current-buffer (lsp-hierarchy-test--show 'type)
        (lsp-hierarchy-test--roots "root")
        (lsp-hierarchy-test--type-children "child")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-refresh)
        (lsp-hierarchy-test--roots "root")
        (should-not (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "root")))
        (should (= 3 (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy-refresh t)
        (lsp-hierarchy-test--roots "root")
        (should (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading))
        (should (= 5 (length lsp-hierarchy-test--sent)))
        (should-not (lsp-hierarchy--view-restore lsp-hierarchy--view))))))

(ert-deftest lsp-hierarchy-refresh-matches-workspaces-by-identity ()
  (lsp-hierarchy-test--with-session
    (let* ((a (car lsp-hierarchy-test--workspaces))
           (b (lsp-hierarchy-test--workspace
               'server-b (lsp-make-server-capabilities :type-hierarchy-provider? t))))
      (setq lsp-hierarchy-test--workspaces (list a b))
      (with-current-buffer (lsp-hierarchy-test--show 'type)
        (dolist (request (copy-sequence lsp-hierarchy-test--sent))
          (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "same"))))
        (lsp-hierarchy--goto-node
         (seq-find (lambda (node) (eq a (lsp-hierarchy--node-workspace node)))
                   (lsp-hierarchy--view-roots lsp-hierarchy--view)))
        (lsp-hierarchy-toggle)
        (lsp-hierarchy-test--type-children "child")
        (lsp-hierarchy-refresh)
        (dolist (request (seq-take lsp-hierarchy-test--sent 2))
          (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "same"))))
        (dolist (node (lsp-hierarchy--view-roots lsp-hierarchy--view))
          (should (eq (lsp-hierarchy--node-expanded node)
                      (eq (lsp-hierarchy--node-workspace node) a))))
        (should (eq (plist-get (car lsp-hierarchy-test--sent) :workspace) a))
        (should (= 6 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-refresh-keeps-duplicate-occurrences-independent ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "a" "b")
      (dolist (name '("a" "b"))
        (lsp-hierarchy-test--toggle name)
        (lsp-hierarchy-test--type-children "same" "same"))
      (lsp-hierarchy--goto-node
       (car (lsp-hierarchy--node-children (lsp-hierarchy-test--node "a"))))
      (lsp-hierarchy-toggle)
      (lsp-hierarchy-test--type-children "leaf")
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "a" "b")
      (let ((requests (seq-take lsp-hierarchy-test--sent 2)))
        (dolist (request requests)
          (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "same")
                                                     (lsp-hierarchy-test--item "same")))))
      (let ((a (lsp-hierarchy--node-children (lsp-hierarchy-test--node "a")))
            (b (lsp-hierarchy--node-children (lsp-hierarchy-test--node "b"))))
        (should (eq (lsp-hierarchy--node-load-state (car a)) 'loading))
        (should-not (lsp-hierarchy--node-expanded (cadr a)))
        (should-not (lsp-hierarchy--node-expanded (car b)))
        (should-not (lsp-hierarchy--node-expanded (cadr b)))
        (should-not (eq (lsp-hierarchy--node-id (car a)) (lsp-hierarchy--node-id (cadr a)))))
      (should (= 8 (length lsp-hierarchy-test--sent))))))

(ert-deftest lsp-hierarchy-refresh-folding-suspends-and-resumes-descent ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--toggle "child")
      (lsp-hierarchy-test--type-children "grandchild")
      (lsp-hierarchy-test--toggle "grandchild")
      (lsp-hierarchy-test--type-children "leaf")
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--type-children "child")
      (let ((child-request (car lsp-hierarchy-test--sent)))
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply child-request (vector (lsp-hierarchy-test--item "grandchild")))
        (should-not (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "root")))
        (should (eq child-request (car lsp-hierarchy-test--sent)))
        (should (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "grandchild")) 'unloaded))
        (lsp-hierarchy-test--toggle "root")
        (should (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "grandchild")) 'loading))
        (should (= 8 (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-refresh-user-command-cancels-late-focus ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root" "sibling")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "child"))
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "root" "sibling")
      (should (lsp-hierarchy--view-restore-focus lsp-hierarchy--view))
      (run-hooks 'pre-command-hook)
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "sibling"))
      (lsp-hierarchy-test--type-children "child")
      (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "sibling")))
      (should-not (lsp-hierarchy--view-restore-focus lsp-hierarchy--view)))))

(ert-deftest lsp-hierarchy-refresh-missing-selection-falls-back-to-parent ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--toggle "child")
      (lsp-hierarchy-test--type-children "removed")
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "removed"))
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--type-children "other")
      (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "child")))
      (should-not (lsp-hierarchy--view-restore-focus lsp-hierarchy--view)))))

(ert-deftest lsp-hierarchy-refresh-failed-restoration-requires-explicit-retry ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--toggle "child")
      (lsp-hierarchy-test--type-children "leaf")
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "leaf"))
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (lsp-make-json-error :code -32603 :message "Retry later") t)
      (should (= 6 (length lsp-hierarchy-test--sent)))
      (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "child")))
      (should-not (lsp-hierarchy--view-restore-focus lsp-hierarchy--view))
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--toggle "root")
      (should (= 6 (length lsp-hierarchy-test--sent)))
      (lsp-hierarchy-test--toggle "child")
      (should (= 7 (length lsp-hierarchy-test--sent)))
      (lsp-hierarchy-test--type-children "leaf")
      (should (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "leaf"))))))

(ert-deftest lsp-hierarchy-refresh-retains-saved-descendants-below-closed-root ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (lsp-hierarchy-test--toggle "child")
      (lsp-hierarchy-test--type-children "leaf")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-refresh)
      (lsp-hierarchy-test--roots "root")
      (should (= 4 (length lsp-hierarchy-test--sent)))
      (should-not (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "root")))
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--type-children "child")
      (should (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "child")) 'loading))
      (should (= 6 (length lsp-hierarchy-test--sent))))))

(ert-deftest lsp-hierarchy-refresh-restores-known-call-site-before-child-reply ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--roots "root")
      (lsp-hierarchy-test--toggle "root")
      (let ((calls (vector (lsp-hierarchy-test--call
                            "caller" nil (vector (lsp-hierarchy-test--range 0 0 6))))))
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) calls)
        (lsp-hierarchy-test--toggle "caller")
        (lsp-hierarchy--goto-node
         (car (lsp-hierarchy--node-call-sites (lsp-hierarchy-test--node "caller"))))
        (move-to-column 7)
        (lsp-hierarchy-refresh)
        (lsp-hierarchy-test--roots "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) calls)
        (let ((caller (lsp-hierarchy-test--node "caller")))
          (should (eq (lsp-hierarchy--node-load-state caller) 'loading))
          (should (eq (lsp-hierarchy--node-at-point)
                      (car (lsp-hierarchy--node-call-sites caller))))
          (should (= 7 (current-column)))
          (should-not (lsp-hierarchy--view-restore-focus lsp-hierarchy--view)))))))


(ert-deftest lsp-hierarchy-refresh-indexes-reordered-siblings-and-duplicates ()
  (let* ((workspace-a (lsp-hierarchy-test--workspace 'server))
         ;; Equal structs still represent distinct server connections.
         (workspace-b (copy-sequence workspace-a))
         (key-function (symbol-function 'lsp-hierarchy--refresh-key))
         (key-count 0) nodes snapshots duplicates)
    (should (equal workspace-a workspace-b))
    (should-not (eq workspace-a workspace-b))
    (dotimes (index 400)
      (let ((node (lsp-hierarchy--make-node :workspace workspace-a :type 'symbol
                                           :name (number-to-string index))))
        (push node nodes)
        (push (lsp-hierarchy--make-saved-node :workspace workspace-a
                                             :key (lsp-hierarchy--refresh-key node)) snapshots)))
    (setq snapshots (nreverse snapshots))
    ;; Repeat the same key in both workspaces.  Fresh duplicate occurrences
    ;; consume saved choices in order even when unique siblings are reversed.
    (dolist (workspace (list workspace-a workspace-b workspace-a workspace-b))
      (let* ((node (lsp-hierarchy--make-node :workspace workspace :type 'symbol :name "same"))
             (saved (lsp-hierarchy--make-saved-node
                     :workspace workspace :key (lsp-hierarchy--refresh-key node)
                     :expanded (< (length duplicates) 2))))
        (push (cons node saved) duplicates)))
    (setq duplicates (nreverse duplicates)
          nodes (append nodes (mapcar #'car duplicates))
          snapshots (append snapshots (mapcar #'cdr duplicates)))
    (cl-letf (((symbol-function 'lsp-hierarchy--refresh-key)
               (lambda (node) (cl-incf key-count) (funcall key-function node))))
      (lsp-hierarchy--match-restore nodes snapshots))
    ;; This bounds key construction without a flaky elapsed-time assertion.
    (should (= key-count (length nodes)))
    (dolist (node nodes)
      (should (equal (lsp-hierarchy--refresh-key node)
                     (lsp-hierarchy--saved-node-key (lsp-hierarchy--node-restore node)))))
    (dolist (pair duplicates)
      (should (eq (lsp-hierarchy--node-restore (car pair)) (cdr pair)))
      (should (eq (lsp-hierarchy--node-expanded (car pair))
                  (lsp-hierarchy--saved-node-expanded (cdr pair)))))))


(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
