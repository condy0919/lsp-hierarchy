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

(defun lsp-hierarchy-test--type-workspaces (&rest ids)
  "Make type-hierarchy workspaces with server IDS."
  (mapcar (lambda (id)
            (lsp-hierarchy-test--workspace
             id (lsp-make-server-capabilities :type-hierarchy-provider? t)))
          ids))

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
    `(let* ((,source (generate-new-buffer " *hierarchy-test-source*"))
            (lsp-hierarchy-test--source ,source)
            (lsp-hierarchy-test--workspaces
             (list (lsp-hierarchy-test--workspace
                    'server-a (lsp-make-server-capabilities
                               :call-hierarchy-provider? t :type-hierarchy-provider? t))))
            (lsp-hierarchy-test--sent nil)
            (lsp-hierarchy-expand-depth 0)
            (lsp--cancelable-requests (make-hash-table :test 'eq))
            (lsp--request-cleanup-hooks (make-hash-table :test 'eql))
            (lsp--last-active-workspaces nil)
            (lsp-last-id 0))
       (cl-letf (((symbol-function 'lsp--send-no-wait) #'lsp-hierarchy-test--send)
                 ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (get-buffer buffer))))
         (unwind-protect
             (progn ,@body)
           (dolist (name '("*LSP Call Hierarchy*" "*LSP Type Hierarchy*"))
             (when-let* ((buffer (get-buffer name))) (kill-buffer buffer)))
           (when (buffer-live-p ,source) (kill-buffer ,source)))))))

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

(defun lsp-hierarchy-test--nodes ()
  "Return all currently attached nodes, including folded descendants."
  (let ((pending (copy-sequence (lsp-hierarchy--view-roots lsp-hierarchy--view)))
        nodes)
    (while pending
      (let ((node (pop pending)))
        (push node nodes)
        (setq pending (append (lsp-hierarchy--node-children node) pending))))
    (nreverse nodes)))

(defun lsp-hierarchy-test--node (name)
  "Find a model node with NAME, whether or not its row is visible."
  (or (seq-find (lambda (node)
                  (equal name (lsp-hierarchy--item-get node :name)))
                (lsp-hierarchy-test--nodes))
      (ert-fail (format "Missing node %s" name))))

(defun lsp-hierarchy-test--toggle (name)
  "Toggle the node with NAME in the current view."
  (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-item
                                (lsp-hierarchy-test--node name)))
  (lsp-hierarchy-toggle))

(defun lsp-hierarchy-test--reply-items (&rest names)
  "Reply to the latest prepare or type request with items named NAMES."
  (lsp-hierarchy-test--reply
   (car lsp-hierarchy-test--sent)
   (vconcat (mapcar #'lsp-hierarchy-test--item names))))

(defun lsp-hierarchy-test--node-position (node)
  "Return the position of rendered NODE in the current view."
  (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node))

(defun lsp-hierarchy-test--site-position (site)
  "Find the displayed row for the call-site pair SITE."
  (text-property-any (point-min) (point-max) 'lsp-hierarchy-call-site site))

(defun lsp-hierarchy-test--click (position)
  "Dispatch a mouse-1 event through the text keymap at POSITION."
  (set-window-buffer (selected-window) (current-buffer))
  (funcall (lookup-key (get-text-property position 'keymap) [mouse-1])
           (list 'mouse-1 (list (selected-window) position '(0 . 0) 0))))

(ert-deftest lsp-hierarchy-latest-prepare-wins ()
  (lsp-hierarchy-test--with-session
    (let* ((view (lsp-hierarchy-test--show))
           (old (car lsp-hierarchy-test--sent)))
      (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "new")
      (lsp-hierarchy-test--reply old (vector (lsp-hierarchy-test--item "old")))
      (with-current-buffer view
        (should (string-match-p "new" (buffer-string)))
        (should-not (string-match-p "old" (buffer-string)))))))

(ert-deftest lsp-hierarchy-killed-view-is-not-recreated ()
  (lsp-hierarchy-test--with-session
    (let* ((view (lsp-hierarchy-test--show))
           (request (car lsp-hierarchy-test--sent)))
      (kill-buffer view)
      (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item "late")))
      (should-not (buffer-live-p view))
      (should-not (get-buffer "*LSP Call Hierarchy*")))))

(ert-deftest lsp-hierarchy-disposal-rejects-synchronous-late-response ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (let ((pending (car lsp-hierarchy-test--sent))
            (old-view lsp-hierarchy--view)
            (cancel (symbol-function 'lsp-hierarchy--cancel-request))
            displayed)
        ;; Cancellation can dispatch an already queued response before returning.
        (cl-letf (((symbol-function 'lsp-hierarchy--cancel-request)
                   (lambda (token)
                     (lsp-hierarchy-test--reply pending (vector (lsp-hierarchy-test--item "stale")))
                     (funcall cancel token)))
                  ((symbol-function 'lsp-hierarchy--display)
                   (lambda (_nodes) (setq displayed t))))
          (lsp-hierarchy-refresh))
        (should-not displayed)
        (should-not (eq old-view lsp-hierarchy--view))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-requests old-view))))
        (should (eq (lsp-hierarchy--view-status lsp-hierarchy--view) 'loading))
        (lsp-hierarchy-test--reply-items "fresh")
        (should (string-match-p "fresh" (buffer-string)))
        (should-not (string-match-p "stale" (buffer-string)))))))

(ert-deftest lsp-hierarchy-request-completes-only-once ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "root")
      (let (callbacks)
        (cl-letf (((symbol-function 'lsp-request-async)
                   (lambda (_method _params callback &rest options)
                     (setq callbacks (list callback (plist-get options :error-handler)
                                           (plist-get options :cancel-handler))))))
          (lsp-hierarchy-test--toggle "root"))
        (funcall (car callbacks) (vector (lsp-hierarchy-test--call "child")))
        ;; Neither repeated success, failure nor cancellation may replace it.
        (funcall (car callbacks) (vector (lsp-hierarchy-test--call "duplicate")))
        (funcall (cadr callbacks) (lsp-make-json-error :code -32603 :message "Late failure"))
        (funcall (nth 2 callbacks))
        (let ((root (lsp-hierarchy-test--node "root")))
          (should (eq (lsp-hierarchy--node-load-state root) 'loaded))
          (should (equal (mapcar (lambda (node) (lsp-hierarchy--item-get node :name))
                                 (lsp-hierarchy--node-children root))
                         '("child"))))
        (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))))))

(ert-deftest lsp-hierarchy-error-is-retryable ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "root")
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
      (lsp-hierarchy-test--reply-items "root")
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
      (lsp-hierarchy-test--reply-items "root")
      (lsp-hierarchy-test--toggle "root")
      (kill-buffer lsp-hierarchy-test--source)
      (should (not (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading)))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
      (lsp-hierarchy-test--toggle "root")
      (should (not (eq (lsp-hierarchy--node-load-state (lsp-hierarchy-test--node "root")) 'loading))))))

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
          (lsp-hierarchy-test--reply-items "foo")
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
        (should (= (length (lsp-hierarchy-test--nodes)) 2))
        (let* ((nodes (lsp-hierarchy-test--nodes))
               (node-a (seq-find (lambda (node) (eq (lsp-hierarchy--node-workspace node) a)) nodes))
               (node-b (seq-find (lambda (node) (eq (lsp-hierarchy--node-workspace node) b)) nodes)))
          (should-not (eq node-a node-b))
          (goto-char (text-property-any (point-min) (point-max) 'lsp-hierarchy-item node-a))
          (lsp-hierarchy-toggle)
          (let* ((request (car lsp-hierarchy-test--sent))
                 (params (plist-get (plist-get request :body) :params)))
            (should (eq (plist-get request :workspace) a))
            (should (eq (plist-get params :item) item-a))))))))

(ert-deftest lsp-hierarchy-prepare-uses-each-workspaces-uri-and-encoding ()
  (lsp-hierarchy-test--with-session
    (let ((cases '((server-utf8 "utf-8" 6)
                   (server-utf16 "utf-16" 3)
                   (server-utf32 "utf-32" 2))))
      (setq lsp-hierarchy-test--workspaces
            (mapcar
             (lambda (entry)
               (let ((workspace (lsp-hierarchy-test--workspace
                                 (car entry)
                                 (lsp-make-server-capabilities
                                  :type-hierarchy-provider? t :positionEncoding (cadr entry))))
                     (uri (format "custom://%s/source" (car entry))))
                 (setf (lsp--client-path->uri-fn (lsp--workspace-client workspace))
                       (lambda (_) uri))
                 workspace))
             cases))
      (with-current-buffer lsp-hierarchy-test--source
        (insert "head\n😀é target\ntail\n")
        (goto-char (point-min))
        (search-forward "é")
        (narrow-to-region (line-beginning-position) (line-end-position))
        ;; Buffer-local conventions cannot represent all three servers.
        (setq-local lsp--position-column-function (lambda () 99))
        (let ((origin (point)) (minimum (point-min)) (maximum (point-max)))
          (lsp-hierarchy-test--show 'type)
          (should (= origin (point)))
          (should (= minimum (point-min)))
          (should (= maximum (point-max)))))
      (should (= 3 (length lsp-hierarchy-test--sent)))
      (dolist (request lsp-hierarchy-test--sent)
        (let* ((workspace (plist-get request :workspace))
               (id (lsp--client-server-id (lsp--workspace-client workspace)))
               (params (plist-get (plist-get request :body) :params)))
          (should (equal (plist-get params :position)
                         (list :line 1 :character (nth 2 (assq id cases)))))
          (should (equal (plist-get (plist-get params :textDocument) :uri)
                         (format "custom://%s/source" id))))))))

(ert-deftest lsp-hierarchy-prepare-preserves-virtual-document-position ()
  (lsp-hierarchy-test--with-session
    (setq lsp-hierarchy-test--workspaces
          (lsp-hierarchy-test--type-workspaces 'server-a 'server-b))
    (let (view restrictions)
      (with-current-buffer lsp-hierarchy-test--source
        (insert "Heading\nSource block\n  target\n")
        (goto-char (point-min))
        (search-forward "target")
        (narrow-to-region (line-beginning-position) (line-end-position))
        ;; A virtual document owns its coordinates and sees its workspace.
        (setq-local lsp--virtual-buffer
                    (list :buffer-uri "virtual://source-block"
                          :cur-position
                          (lambda ()
                            (push (buffer-narrowed-p) restrictions)
                            (list :line 0 :character
                                  (if (eq lsp--cur-workspace (car lsp-hierarchy-test--workspaces)) 6 9))))))
      (dolist (refresh '(nil t))
        (if refresh
            (with-current-buffer view (lsp-hierarchy-refresh))
          (setq view (lsp-hierarchy-test--show 'type)))
        (dolist (request (seq-take lsp-hierarchy-test--sent 2))
          (let ((params (plist-get (plist-get request :body) :params))
                (owner (plist-get request :workspace)))
            (should (equal (plist-get (plist-get params :textDocument) :uri) "virtual://source-block"))
            (should (equal (plist-get params :position)
                           (list :line 0 :character
                                 (if (eq owner (car lsp-hierarchy-test--workspaces)) 6 9)))))
          (lsp-hierarchy-test--reply request []))
        ;; Initial queries preserve narrowing for virtual hooks.  Refresh
        ;; already widens around the source marker, then restores restriction.
        (should (equal restrictions (if refresh '(nil nil t t) '(t t))))
        (with-current-buffer lsp-hierarchy-test--source
          (should (buffer-narrowed-p)))))))

(ert-deftest lsp-hierarchy-prepare-keeps-workspace-order-after-reversed-replies ()
  (lsp-hierarchy-test--with-session
    (setq lsp-hierarchy-test--workspaces
          (lsp-hierarchy-test--type-workspaces 'server-a 'server-b 'server-c))
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (let ((requests (copy-sequence lsp-hierarchy-test--sent)))
        ;; The transport records newest first, reversing dispatch order.
        (dolist (request requests)
          (should (eq 'loading (lsp-hierarchy--view-status lsp-hierarchy--view)))
          (let ((id (lsp--client-server-id
                     (lsp--workspace-client (plist-get request :workspace)))))
            (lsp-hierarchy-test--reply request (vector (lsp-hierarchy-test--item (symbol-name id)))))))
      (should (eq 'ready (lsp-hierarchy--view-status lsp-hierarchy--view)))
      (should (equal (mapcar (lambda (node) (lsp-hierarchy--item-get node :name)) (lsp-hierarchy--view-roots lsp-hierarchy--view))
                     '("server-a" "server-b" "server-c")))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))

(ert-deftest lsp-hierarchy-prepare-keeps-success-when-another-workspace-fails ()
  (dolist (empty '(nil t))
    (dolist (error-first '(nil t))
      (lsp-hierarchy-test--with-session
        (setq lsp-hierarchy-test--workspaces
              (lsp-hierarchy-test--type-workspaces 'server-a 'server-b))
        (with-current-buffer (lsp-hierarchy-test--show 'type)
          (let* ((requests (copy-sequence lsp-hierarchy-test--sent))
                 (failed (car requests)))
            (dolist (request (if error-first requests (reverse requests)))
              (should (eq 'loading (lsp-hierarchy--view-status lsp-hierarchy--view)))
              (if (eq request failed)
                  (lsp-hierarchy-test--reply request
                                             (lsp-make-json-error :code -32603 :message "Unavailable") t)
                (lsp-hierarchy-test--reply request
                                           (unless empty (vector (lsp-hierarchy-test--item "available")))))))
          (should (eq 'ready (lsp-hierarchy--view-status lsp-hierarchy--view)))
          (should (string-match-p (if empty "No hierarchy found" "available") (buffer-string)))
          (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))))

(ert-deftest lsp-hierarchy-prepare-all-failures-exit-loading-and-clean-requests ()
  (dolist (sync-failures '(nil (server-a) (server-a server-b)))
    (lsp-hierarchy-test--with-session
      (setq lsp-hierarchy-test--workspaces
            (lsp-hierarchy-test--type-workspaces 'server-a 'server-b))
      (cl-letf (((symbol-function 'lsp--send-no-wait)
                 (lambda (body process)
                   (when (and (plist-get body :id) (memq process sync-failures))
                     (error "Send failed for %s" process))
                   (lsp-hierarchy-test--send body process))))
        (with-current-buffer (lsp-hierarchy-test--show 'type)
          (dolist (request (copy-sequence lsp-hierarchy-test--sent))
            (should (eq 'loading (lsp-hierarchy--view-status lsp-hierarchy--view)))
            (lsp-hierarchy-test--reply request
                                       (lsp-make-json-error :code -32603 :message "Unavailable") t))
          (should (eq 'error (lsp-hierarchy--view-status lsp-hierarchy--view)))
          (should (string-match-p "Unable to load hierarchy" (buffer-string)))
          (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))
        (should (= 0 (hash-table-count lsp--cancelable-requests)))
        (should (= 0 (hash-table-count lsp--request-cleanup-hooks)))))))

(ert-deftest lsp-hierarchy-partial-prepare-cancels-outstanding-on-close-or-refresh ()
  (dolist (refresh '(nil t))
    (lsp-hierarchy-test--with-session
      (setq lsp-hierarchy-test--workspaces
            (lsp-hierarchy-test--type-workspaces 'server-a 'server-b))
      (let* ((view (lsp-hierarchy-test--show 'type))
             (requests (copy-sequence lsp-hierarchy-test--sent))
             (pending (cadr requests))
             (id (plist-get (plist-get pending :body) :id))
             (workspace (plist-get pending :workspace)))
        (lsp-hierarchy-test--reply (car requests) (vector (lsp-hierarchy-test--item "old")))
        (with-current-buffer view
          (should (eq 'loading (lsp-hierarchy--view-status lsp-hierarchy--view)))
          (if refresh (lsp-hierarchy-refresh) (kill-buffer view)))
        (should-not (gethash id (lsp--client-response-handlers (lsp--workspace-client workspace))))
        (should-not (gethash id lsp--request-cleanup-hooks))
        (should (= (if refresh 2 0) (hash-table-count lsp--cancelable-requests)))
        ;; Already queued replies must not enter the new aggregation.
        (lsp-hierarchy-test--reply pending (vector (lsp-hierarchy-test--item "stale")))
        (if refresh
            (with-current-buffer view
              (should (eq 'loading (lsp-hierarchy--view-status lsp-hierarchy--view)))
              (dolist (request (seq-take lsp-hierarchy-test--sent 2))
                (lsp-hierarchy-test--reply request []))
              (should (eq 'ready (lsp-hierarchy--view-status lsp-hierarchy--view)))
              (should (string-match-p "No hierarchy found" (buffer-string))))
          (should-not (buffer-live-p view)))))))

(ert-deftest lsp-hierarchy-partial-prepare-source-kill-exits-loading ()
  (lsp-hierarchy-test--with-session
    (setq lsp-hierarchy-test--workspaces
          (lsp-hierarchy-test--type-workspaces 'server-a 'server-b))
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--item "partial")))
      (kill-buffer lsp-hierarchy-test--source)
      (should (eq 'error (lsp-hierarchy--view-status lsp-hierarchy--view)))
      (should (string-match-p "Unable to load hierarchy" (buffer-string)))
      (should-not (lsp-hierarchy--view-roots lsp-hierarchy--view))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view))))
      (should (= 0 (hash-table-count lsp--cancelable-requests)))
      (should (= 0 (hash-table-count lsp--request-cleanup-hooks))))))

(ert-deftest lsp-hierarchy-loading-rows-are-request-local ()
  "Finishing beta first must preserve alpha's loading row, including on error."
  (dolist (errorp '(nil t))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--reply-items "alpha" "beta")
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
            (should (eq (get-text-property (point) 'lsp-hierarchy-status-node) alpha))
            (lsp-hierarchy-test--reply alpha-request (vector (lsp-hierarchy-test--call "child-alpha")))
            (should-not (string-match-p "Loading" (buffer-string)))
            (should (< (string-match "child-alpha" (buffer-string))
                       (string-match "beta" (buffer-string))))))))))

(ert-deftest lsp-hierarchy-folding-survives-pending-descendants ()
  (lsp-hierarchy-test--with-session
   (with-current-buffer (lsp-hierarchy-test--show)
     (lsp-hierarchy-test--reply-items "root")
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
     (lsp-hierarchy-test--reply-items "root")
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
        (lsp-hierarchy-test--reply-items "root")
        (let ((root (lsp-hierarchy-test--node "root"))
              jumped)
          (goto-char (lsp-hierarchy-test--node-position root))
          (cl-letf (((symbol-function 'lsp-hierarchy--open-file)
                     (lambda (uri range workspace)
                       (setq jumped (list uri range workspace)))))
            (lsp-hierarchy-goto))
          (should (eq (nth 1 jumped) (lsp-get (lsp-hierarchy--node-lsp-item root) :selectionRange)))
          (should (eq (nth 2 jumped) (lsp-hierarchy--node-workspace root))))))))

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
          (lsp-hierarchy-test--reply-items "root")
          (should (= (length lsp-hierarchy-test--sent) (if (= depth 0) 1 2)))
          (when (> depth 0)
            (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                       (vector (lsp-hierarchy-test--call "child")))
            (should (= (length lsp-hierarchy-test--sent) (if (= depth 1) 2 3)))))))))

(ert-deftest lsp-hierarchy-auto-expansion-stops-after-folding ()
  (lsp-hierarchy-test--with-session
   (let ((lsp-hierarchy-expand-depth 3))
     (with-current-buffer (lsp-hierarchy-test--show)
       (lsp-hierarchy-test--reply-items "root")
       (lsp-hierarchy-test--toggle "root")
       (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                  (vector (lsp-hierarchy-test--call "child")))
       (should (= 2 (length lsp-hierarchy-test--sent)))
       (should-not (lsp-hierarchy-test--node-position (lsp-hierarchy-test--node "child")))))))

(ert-deftest lsp-hierarchy-lazy-call-sites-and-file-cache ()
  (let ((file (make-temp-file "hierarchy-sites-" nil ".c" "foo(); foo();\n")))
    (unwind-protect
        (lsp-hierarchy-test--with-session
          (with-current-buffer (lsp-hierarchy-test--show)
            (lsp-hierarchy-test--reply-items "root")
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
                (let ((snapshot (gethash file (lsp-hierarchy--view-file-cache lsp-hierarchy--view))))
                  (kill-buffer (current-buffer))
                  (should-not (buffer-live-p snapshot)))))))
      (delete-file file))))

(ert-deftest lsp-hierarchy-file-cache-keeps-snapshot-and-prefers-live-buffer ()
  (let ((file (make-temp-file "hierarchy-cache-" nil ".c" "old();\n"))
        visited)
    (unwind-protect
        (with-temp-buffer
          (lsp-hierarchy-mode)
          (let* ((uri (lsp--path-to-uri file))
                 (range (lsp-hierarchy-test--range 0 0 3)))
            (should (string-prefix-p "old" (lsp-hierarchy--extract-line uri range)))
            (with-temp-file file (insert "updated();\n"))
            ;; Existing ranges and their source snapshot stay together until
            ;; the view is refreshed or the snapshot is explicitly killed.
            (should (string-prefix-p "old" (lsp-hierarchy--extract-line uri range)))
            (kill-buffer (lsp-hierarchy--source-snapshot file))
            (should (string-prefix-p "updated" (lsp-hierarchy--extract-line uri range)))
            (setq visited (find-file-noselect file))
            (with-current-buffer visited (erase-buffer) (insert "unsaved();\n"))
            (should (string-prefix-p "unsaved" (lsp-hierarchy--extract-line uri range)))
            (lsp-hierarchy--dispose)
            (should (buffer-live-p visited))
            (should (buffer-modified-p visited))))
      (when (buffer-live-p visited)
        (with-current-buffer visited (set-buffer-modified-p nil))
        (kill-buffer visited))
      (delete-file file))))

(ert-deftest lsp-hierarchy-refresh-and-direction-switch-replace-source-snapshots ()
  (dolist (command '(lsp-hierarchy-refresh lsp-hierarchy-switch-direction))
    (let ((file (make-temp-file "hierarchy-snapshot-reset-" nil ".c" "old();\n")))
      (unwind-protect
          (lsp-hierarchy-test--with-session
            (with-current-buffer (lsp-hierarchy-test--show 'type)
              (lsp-hierarchy-test--reply-items "root")
              (let* ((uri (lsp--path-to-uri file))
                     (range (lsp-hierarchy-test--range 0 0 3))
                     (snapshot (lsp-hierarchy--source-snapshot file)))
                (with-temp-file file (insert "new();\n"))
                (should (string-prefix-p "old" (lsp-hierarchy--extract-line uri range)))
                (funcall command)
                (should-not (buffer-live-p snapshot))
                (should (= 0 (hash-table-count (lsp-hierarchy--view-file-cache lsp-hierarchy--view))))
                (lsp-hierarchy-test--reply-items "root")
                (should (string-prefix-p "new" (lsp-hierarchy--extract-line uri range))))))
        (delete-file file)))))

(ert-deftest lsp-hierarchy-empty-node-becomes-a-leaf ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "empty" "next")
      (lsp-hierarchy-test--toggle "empty")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (font-lock-ensure)
      (let* ((node (lsp-hierarchy-test--node "empty"))
             (pos (lsp-hierarchy-test--node-position node))
             (requests (length lsp-hierarchy-test--sent)))
        (should-not (lsp-hierarchy--expandable-p node))
        (goto-char pos)
        (lsp-hierarchy-toggle)
        (should (eq (lsp-hierarchy--get-prop 'lsp-hierarchy-item)
                    (lsp-hierarchy-test--node "next")))
        (lsp-hierarchy-test--toggle "empty")
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-normalizes-call-edge-locations ()
  (let* ((workspace (lsp-hierarchy-test--workspace 'server))
         (parent (lsp-hierarchy--make-node
                  :lsp-item (lsp-hierarchy-test--item "parent" "file:///parent.c")
                  :workspace workspace))
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
        (should-not (lsp-hierarchy--node-children node))
        (should (eq (cdr site) range))
        (should (equal (car site)
                       (if outgoing "file:///parent.c" "file:///child.c")))))))

(ert-deftest lsp-hierarchy-shared-symbol-has-independent-occurrences ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "a" "b")
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
        (should-not (eq a-child b-child))
        (goto-char (lsp-hierarchy-test--node-position a-child))
        (lsp-hierarchy-toggle)
        (should (eq (lsp-hierarchy--node-load-state a-child) 'loading))
        (should (eq (lsp-hierarchy--node-load-state b-child) 'unloaded))
        (should-not (lsp-hierarchy--node-expanded b-child))))))

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

(ert-deftest lsp-hierarchy-empty-prepare-is-explained ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (should (equal (buffer-string) "No hierarchy found.\n"))
      (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))

(ert-deftest lsp-hierarchy-refresh-keeps-source-position-and-rejects-old-replies ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source
      (insert "first\nsecond\nthird\n")
      (goto-char 10))
    (with-current-buffer (lsp-hierarchy-test--show 'call t)
      (lsp-hierarchy-test--reply-items "old")
      (lsp-hierarchy-test--toggle "old")
      (let ((old-request (car lsp-hierarchy-test--sent))
            (old-origin (lsp-hierarchy--view-origin lsp-hierarchy--view)))
        (with-current-buffer lsp-hierarchy-test--source (goto-char (point-max)))
        (revert-buffer nil t)
        (should-not (marker-buffer old-origin))
        (let* ((request (car lsp-hierarchy-test--sent))
               (params (plist-get (plist-get request :body) :params))
               (position (plist-get params :position)))
          (should (= 1 (plist-get position :line)))
          (should (= 3 (plist-get position :character))))
        (lsp-hierarchy-test--reply-items "new")
        (lsp-hierarchy-test--reply old-request (vector (lsp-hierarchy-test--call "stale")))
        (should-not (string-match-p "stale" (buffer-string)))
        (lsp-hierarchy-test--toggle "new")
        (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                       "callHierarchy/outgoingCalls"))))))

(ert-deftest lsp-hierarchy-refresh-releases-owned-resources ()
  (let ((file (make-temp-file "hierarchy-refresh-" nil ".c" "call();\n")))
    (unwind-protect
        (lsp-hierarchy-test--with-session
          (with-current-buffer (lsp-hierarchy-test--show)
            (lsp-hierarchy-test--reply-items "root")
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

(ert-deftest lsp-hierarchy-known-call-sites-survive-pending-and-failed-relations ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "target")
      (lsp-hierarchy-test--toggle "target")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-hierarchy-test--call "caller" nil
                                        (vector (lsp-hierarchy-test--range 0 0 6)))))
      (let* ((caller (lsp-hierarchy-test--node "caller"))
             (site (car (lsp-hierarchy--node-call-sites caller))))
        (should-not (lsp-hierarchy-test--site-position site))
        (lsp-hierarchy-test--toggle "caller")
        (should (lsp-hierarchy-test--site-position site))
        (should (string-match-p "target();" (buffer-string)))
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (lsp-make-json-error :code -32603 :message "Unavailable") t)
        (should (lsp-hierarchy-test--site-position site))
        (lsp-hierarchy-test--toggle "caller")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
        (should (eq site (car (lsp-hierarchy--node-call-sites caller))))
        (should-not (lsp-hierarchy--node-children caller))
        (should (= 1 (how-many "target();" (point-min) (point-max))))
        (should (lsp-hierarchy--expandable-p caller))))))

(ert-deftest lsp-hierarchy-navigates-rows-and-parents-without-requests ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "root" "other-root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "alpha")
                                         (lsp-hierarchy-test--call "beta")))
      (lsp-hierarchy-test--toggle "alpha")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                 (vector (lsp-hierarchy-test--call "grandchild")))
      (let ((requests (length lsp-hierarchy-test--sent)))
        (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "alpha"))
        (call-interactively (key-binding (kbd "n")))
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "grandchild")))
        (call-interactively (key-binding (kbd "n")))
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "beta")))
        (call-interactively (key-binding (kbd "p")))
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "grandchild")))
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "alpha")))
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "root")))
        (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "other-root"))
        (should-error (lsp-hierarchy-parent) :type 'user-error)
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-left-folds-loading-and-error-rows-without-retrying ()
  (dolist (fail '(nil t))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--reply-items "root")
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
          (call-interactively (key-binding (kbd "<left>")))
          (should (eq (lsp-hierarchy--node-at-point) branch))
          (should-not (lsp-hierarchy--node-expanded branch))
          (should (eq (lsp-hierarchy--node-load-state branch) (if fail 'error 'loading)))
          (call-interactively (key-binding (kbd "<left>")))
          (should (eq (lsp-hierarchy--node-at-point) branch))
          (should (= requests (length lsp-hierarchy-test--sent))))))))

(ert-deftest lsp-hierarchy-left-does-not-expand-or-leave-a-leaf ()
  (dolist (loaded '(nil t))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--reply-items "root")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (vector (lsp-hierarchy-test--call "leaf")))
        (when loaded
          (lsp-hierarchy-test--toggle "leaf")
          (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) []))
        (let ((leaf (lsp-hierarchy-test--node "leaf"))
              (requests (length lsp-hierarchy-test--sent)))
          (lsp-hierarchy--goto-node leaf)
          (move-to-column 5)
          (let ((position (point)))
            (dotimes (_ 2)
              (call-interactively (key-binding (kbd "<left>")))
              (should (= position (point)))
              (should (eq (lsp-hierarchy--node-at-point) leaf))
              (should-not (lsp-hierarchy--node-expanded leaf))))
          (should (eq (lsp-hierarchy--node-load-state leaf) (if loaded 'loaded 'unloaded)))
          (should (= requests (length lsp-hierarchy-test--sent))))))))

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
                 (let ((item (lsp-hierarchy-test--item "foo" "custom://symbol")))
                   (lsp-put item :selectionRange (lsp-hierarchy-test--range 1 2 5))
                   (lsp-hierarchy--make-node :lsp-item item :workspace workspace)) 0))
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
                 (lsp-hierarchy--make-node
                  :lsp-item (lsp-hierarchy-test--item "foo" (lsp--path-to-uri file))) 0))
              (goto-char 3)
              (should-error (lsp-hierarchy-preview) :type 'user-error)
              (should (eq (window-buffer window) view))
              (should (eq (selected-window) window))
              (should (= (point) 3)))))
      (when (buffer-live-p target) (kill-buffer target))
      (delete-file file))))

(ert-deftest lsp-hierarchy-mouse-reuses-keyboard-actions ()
  (save-window-excursion
    (lsp-hierarchy-test--with-session
      (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--reply-items "root")
        (lsp-hierarchy-test--toggle "root")
        (lsp-hierarchy-test--reply
         (car lsp-hierarchy-test--sent)
         (vector (lsp-hierarchy-test--call "caller" nil
                                          (vector (lsp-hierarchy-test--range 0 0 6)))))
        (lsp-hierarchy-test--toggle "caller")
        (let* ((root (lsp-hierarchy-test--node "root"))
               (caller (lsp-hierarchy-test--node "caller"))
               (site (car (lsp-hierarchy--node-call-sites caller)))
               (arrow (lsp-hierarchy-test--node-position root))
               (name (text-property-any arrow (point-max) 'lsp-hierarchy-action
                                        #'lsp-hierarchy-goto))
               (code (text-property-any (lsp-hierarchy-test--site-position site) (point-max)
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
              (should (eq (key-binding (kbd "TAB")) #'lsp-hierarchy-toggle))
              (should (eq (key-binding (kbd "?")) #'describe-mode))))
          (should (equal (nreverse actions)
                         (list (cons 'toggle root) (cons 'goto root) (cons 'goto caller)))))))))

(ert-deftest lsp-hierarchy-tab-stays-on-final-leaf ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "leaf")
      (lsp-hierarchy-test--toggle "leaf")
      (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
      (goto-char (point-min))
      (move-to-column 4)
      (let ((position (point))
            (leaf (lsp-hierarchy-test--node "leaf")))
        (lsp-hierarchy-toggle)
        (should (= position (point)))
        (should (eq (lsp-hierarchy--node-at-point) leaf))))))

(ert-deftest lsp-hierarchy-tab-keeps-final-call-site-and-finds-later-symbol ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer lsp-hierarchy-test--source (insert "target();\n"))
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-hierarchy-test--call "caller" nil
                                        (vector (lsp-hierarchy-test--range 0 0 6)))))
      (lsp-hierarchy-test--toggle "caller")
      (let* ((caller (lsp-hierarchy-test--node "caller"))
             (site (car (lsp-hierarchy--node-call-sites caller))))
        (goto-char (lsp-hierarchy-test--site-position site))
        (move-to-column 9)
        (let ((position (point)))
          ;; A trailing Loading row is not a next symbol either.
          (lsp-hierarchy-toggle)
          (should (= position (point))))
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) [])
        (let ((position (point)))
          (lsp-hierarchy-toggle)
          (should (= position (point)))
          (should (equal (lsp-hierarchy--location-at-point)
                         (list (lsp-hierarchy--node-workspace caller) (car site) (cdr site)))))
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) caller))
        (let ((later (lsp-hierarchy--make-node
                      :lsp-item (lsp-hierarchy-test--item "later")
                      :workspace (lsp-hierarchy--node-workspace caller))))
          (setf (lsp-hierarchy--node-parent later) caller
                (lsp-hierarchy--node-children caller) (list later))
          (lsp-hierarchy--render)
          (goto-char (lsp-hierarchy-test--site-position site))
          (lsp-hierarchy-toggle)
          (should (eq (lsp-hierarchy--node-at-point) later)))))))

(ert-deftest lsp-hierarchy-auto-expansion-stops-self-recursion-but-allows-manual-paths ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 6))
      (with-current-buffer (lsp-hierarchy-test--show)
        (lsp-hierarchy-test--reply-items "recursive")
        (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                   (vector (lsp-hierarchy-test--call "recursive")))
        (let* ((root (car (lsp-hierarchy--view-roots lsp-hierarchy--view)))
               (recursive (car (lsp-hierarchy--node-children root))))
          (should (= 2 (length lsp-hierarchy-test--sent)))
          (should-not (lsp-hierarchy--node-expanded recursive))
          (should (eq (lsp-hierarchy--node-load-state recursive) 'unloaded))
          (should (lsp-hierarchy-test--node-position recursive))
          (lsp-hierarchy--goto-node recursive)
          (lsp-hierarchy-toggle)
          (should (= 3 (length lsp-hierarchy-test--sent)))
          (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent)
                                     (vector (lsp-hierarchy-test--call "recursive")))
          (should (= 3 (length lsp-hierarchy-test--sent)))
          (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))))

(ert-deftest lsp-hierarchy-auto-expansion-stops-mutual-outgoing-recursion ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 10))
      (with-current-buffer (lsp-hierarchy-test--show 'call t)
        (lsp-hierarchy-test--reply-items "a")
        (dolist (name '("b" "a"))
          (lsp-hierarchy-test--reply
           (car lsp-hierarchy-test--sent)
           (vector (lsp-make-call-hierarchy-outgoing-call
                    :to (lsp-hierarchy-test--item name) :from-ranges []))))
        (let* ((root (car (lsp-hierarchy--view-roots lsp-hierarchy--view)))
               (child (car (lsp-hierarchy--node-children root)))
               (recursive (car (lsp-hierarchy--node-children child))))
          (should (equal (lsp-hierarchy--item-get recursive :name) "a"))
          (should-not (lsp-hierarchy--node-expanded recursive))
          (should (eq (lsp-hierarchy--node-load-state recursive) 'unloaded))
          (should (= 3 (length lsp-hierarchy-test--sent)))
          (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))))

(ert-deftest lsp-hierarchy-failed-snapshot-reads-clean-up-and-remain-retryable ()
  (let ((file (make-temp-file "hierarchy-read-failure-" nil ".c" "old();\n")))
    (unwind-protect
        (with-temp-buffer
          (lsp-hierarchy-mode)
          (let ((cache (lsp-hierarchy--view-file-cache lsp-hierarchy--view))
                failed-buffer)
            (cl-letf (((symbol-function 'insert-file-contents)
                       (lambda (&rest _)
                         (setq failed-buffer (current-buffer))
                         (insert "partial")
                         (signal 'file-error '("Unreadable source")))))
              (should-error (lsp-hierarchy--source-snapshot file) :type 'file-error))
            (should-not (buffer-live-p failed-buffer))
            (should (= 0 (hash-table-count cache)))
            (let ((snapshot (lsp-hierarchy--source-snapshot file)))
              (should (equal (with-current-buffer snapshot (buffer-string)) "old();\n"))
              (kill-buffer snapshot)
              (with-temp-file file (insert "changed source();\n"))
              (cl-letf (((symbol-function 'insert-file-contents)
                         (lambda (&rest _)
                           (setq failed-buffer (current-buffer))
                           (signal 'file-error '("Read interrupted")))))
                (should-error (lsp-hierarchy--source-snapshot file) :type 'file-error))
              (should-not (buffer-live-p failed-buffer))
              (should (= 0 (hash-table-count cache)))
              (should (equal (with-current-buffer (lsp-hierarchy--source-snapshot file) (buffer-string))
                             "changed source();\n")))))
      (delete-file file))))

(ert-deftest lsp-hierarchy-direction-switch-resets-paths-and-cancels-old-requests ()
  (dolist (kind '(call type))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show kind)
        (lsp-hierarchy-test--reply-items "root")
        (lsp-hierarchy-test--toggle "root")
        (let* ((pending (car lsp-hierarchy-test--sent))
               (request-id (plist-get (plist-get pending :body) :id))
               (handlers (lsp--client-response-handlers
                          (lsp--workspace-client (plist-get pending :workspace)))))
          (lsp-hierarchy-switch-direction)
          (should (equal (lsp-hierarchy--view-direction lsp-hierarchy--view)
                         (if (eq kind 'call) 'outgoing 'supertypes)))
          (should-not (gethash request-id handlers))
          (lsp-hierarchy-test--reply-items "root")
          (lsp-hierarchy-test--reply
           pending (vector (if (eq kind 'call)
                               (lsp-hierarchy-test--call "stale")
                             (lsp-hierarchy-test--item "stale"))))
          (should (= 1 (length (lsp-hierarchy--view-roots lsp-hierarchy--view))))
          (let ((root (lsp-hierarchy-test--node "root")))
            (should-not (lsp-hierarchy--node-expanded root))
            (should-not (lsp-hierarchy--node-children root)))
          (lsp-hierarchy-test--toggle "root")
          (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                         (if (eq kind 'call) "callHierarchy/outgoingCalls" "typeHierarchy/supertypes")))
          (lsp-hierarchy-switch-direction)
          (should (equal (lsp-hierarchy--view-direction lsp-hierarchy--view)
                         (if (eq kind 'call) 'incoming 'subtypes))))))))

(ert-deftest lsp-hierarchy-four-query-directions-use-correct-methods ()
  (dolist (entry '((call nil "textDocument/prepareCallHierarchy" "callHierarchy/incomingCalls")
                   (call t "textDocument/prepareCallHierarchy" "callHierarchy/outgoingCalls")
                   (type subtypes "textDocument/prepareTypeHierarchy" "typeHierarchy/subtypes")
                   (type supertypes "textDocument/prepareTypeHierarchy" "typeHierarchy/supertypes")))
    (lsp-hierarchy-test--with-session
      (with-current-buffer (lsp-hierarchy-test--show (car entry) (cadr entry))
        (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                       (nth 2 entry)))
        (lsp-hierarchy-test--reply-items "root")
        (lsp-hierarchy-test--toggle "root")
        (should (equal (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :method)
                       (nth 3 entry)))))))

(ert-deftest lsp-hierarchy-refresh-starts-fresh-at-initial-depth ()
  (lsp-hierarchy-test--with-session
    (let ((lsp-hierarchy-expand-depth 1))
      (with-current-buffer (lsp-hierarchy-test--show 'type)
        (lsp-hierarchy-test--reply-items "root")
        (lsp-hierarchy-test--reply-items "child")
        (lsp-hierarchy-test--toggle "child")
        (lsp-hierarchy-test--reply-items "grandchild")
        (lsp-hierarchy-test--toggle "root")
        (let ((old-root (lsp-hierarchy-test--node "root"))
              (fresh (lsp-hierarchy-test--item "root" nil '(fresh-data))))
          (lsp-hierarchy-refresh)
          (lsp-hierarchy-test--reply (car lsp-hierarchy-test--sent) (vector fresh))
          (should-not (eq old-root (lsp-hierarchy-test--node "root")))
          (should (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "root")))
          (should (eq (plist-get (plist-get (plist-get (car lsp-hierarchy-test--sent) :body) :params) :item)
                      fresh))
          (lsp-hierarchy-test--reply-items "child")
          (let ((child (lsp-hierarchy-test--node "child")))
            (should-not (lsp-hierarchy--node-expanded child))
            (should-not (lsp-hierarchy--node-children child)))
          (should (= 0 (hash-table-count (lsp-hierarchy--view-requests lsp-hierarchy--view)))))))))

(ert-deftest lsp-hierarchy-call-site-rows-navigate-jump-and-fold-owner ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show)
      (lsp-hierarchy-test--reply-items "root")
      (lsp-hierarchy-test--toggle "root")
      (lsp-hierarchy-test--reply
       (car lsp-hierarchy-test--sent)
       (vector (lsp-hierarchy-test--call "caller" "file:///caller.c"
                                        (vector (lsp-hierarchy-test--range 2 1 4)
                                                (lsp-hierarchy-test--range 3 2 5)))))
      (lsp-hierarchy-test--toggle "caller")
      (let* ((caller (lsp-hierarchy-test--node "caller"))
             (sites (lsp-hierarchy--node-call-sites caller))
             (requests (length lsp-hierarchy-test--sent)) jumped)
        (goto-char (lsp-hierarchy-test--site-position (car sites)))
        (call-interactively (key-binding (kbd "n")))
        (should (eq (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site) (cadr sites)))
        (cl-letf (((symbol-function 'lsp-hierarchy--open-file)
                   (lambda (uri range workspace) (setq jumped (list uri range workspace)))))
          (lsp-hierarchy-goto))
        (should (equal jumped (list (car (cadr sites)) (cdr (cadr sites))
                                   (lsp-hierarchy--node-workspace caller))))
        (call-interactively (key-binding (kbd "p")))
        (should (eq (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site) (car sites)))
        (lsp-hierarchy-parent)
        (should (eq (lsp-hierarchy--node-at-point) caller))
        (should-not (lsp-hierarchy--get-prop 'lsp-hierarchy-call-site))
        (should-not (lsp-hierarchy--node-children caller))
        (goto-char (lsp-hierarchy-test--site-position (car sites)))
        (call-interactively (key-binding (kbd "<left>")))
        (should (eq (lsp-hierarchy--node-at-point) caller))
        (should-not (lsp-hierarchy--node-expanded caller))
        (should-not (lsp-hierarchy-test--site-position (car sites)))
        (should (= requests (length lsp-hierarchy-test--sent)))))))

(ert-deftest lsp-hierarchy-redraw-keeps-cursor-or-falls-back-to-visible-parent ()
  (lsp-hierarchy-test--with-session
    (with-current-buffer (lsp-hierarchy-test--show 'type)
      (lsp-hierarchy-test--reply-items "alpha" "beta")
      (lsp-hierarchy-test--toggle "alpha")
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "beta"))
      (move-to-column 5)
      (lsp-hierarchy-test--reply-items "child")
      (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "beta")))
      (should (= 5 (current-column)))
      (lsp-hierarchy--goto-node (lsp-hierarchy-test--node "child"))
      (move-to-column 5)
      (setf (lsp-hierarchy--node-expanded (lsp-hierarchy-test--node "alpha")) nil)
      (lsp-hierarchy--render)
      (should (eq (lsp-hierarchy--node-at-point) (lsp-hierarchy-test--node "alpha")))
      (should (= 5 (current-column))))))

(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
