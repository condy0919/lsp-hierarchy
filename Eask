;; -*- mode: eask; lexical-binding: t -*-

(package "lsp-hierarchy"
         "0.1.0"
         "LSP hierarchy views")

(website-url "https://github.com/condy0919/lsp-hierarchy")
(keywords "languages" "tools")

(package-file "lsp-hierarchy.el")

(script "test" "eask test ert ./test/lsp-hierarchy-test.el")

(source 'gnu)
(source 'melpa)

(depends-on "emacs" "29.1")
;; The minimum-version jobs build the supported baseline from its exact
;; commit; ordinary development continues to use the current archive package.
(if (equal (getenv "LSP_HIERARCHY_LSP_MODE_VERSION") "10.0.0")
    (depends-on "lsp-mode"
                :fetcher 'github
                :repo "emacs-lsp/lsp-mode"
                :commit "913a6c07f163205cb568bc68d7dfe677dbc358ab"
                :files '(:defaults "clients/*.el"))
  (depends-on "lsp-mode" "10.0"))

(development
 (depends-on "ert-runner")
 (depends-on "package-lint"))

(add-hook 'eask-before-compile-hook
           (lambda (&rest _)
             (setq byte-compile-docstring-max-column 200)
             (setq byte-compile-error-on-warn t)))
