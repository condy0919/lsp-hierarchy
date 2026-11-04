;;; lsp-hierarchy-test.el --- Tests for lsp-hierarchy.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'lsp-hierarchy)

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

(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
