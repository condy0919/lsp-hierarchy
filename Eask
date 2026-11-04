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
;; The compatibility jobs build the minimum supported release from its exact
;; commit; ordinary development continues to use the current archive package.
(if (equal (getenv "LSP_HIERARCHY_LSP_MODE_VERSION") "9.0.0")
    (depends-on "lsp-mode"
                :fetcher 'github
                :repo "emacs-lsp/lsp-mode"
                :commit "a478e03cd1a5dc84ad496234fd57241ff9dca57a"
                :files '(:defaults "clients/*.el"))
  (depends-on "lsp-mode" "9.0"))

(development
 (depends-on "ert-runner")
 (depends-on "package-lint"))

(add-hook 'eask-before-compile-hook
           (lambda (&rest _)
             (setq byte-compile-docstring-max-column 200)
             (setq byte-compile-error-on-warn t)))
