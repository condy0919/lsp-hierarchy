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

(provide 'lsp-hierarchy-test)
;;; lsp-hierarchy-test.el ends here
