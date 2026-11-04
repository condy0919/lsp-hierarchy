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

(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
