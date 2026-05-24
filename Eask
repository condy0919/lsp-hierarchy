;; -*- mode: eask; lexical-binding: t -*-

(package "lsp-hierarchy"
         "0.1.0"
         "LSP hierarchy views")

(website-url "https://github.com/condy0919/lsp-hierarchy")
(keywords "languages" "tools")

(package-file "lsp-hierarchy.el")

(script "test" "echo \"Error: no test specified\" && exit 1")

(source 'gnu)
(source 'melpa)

(depends-on "emacs" "29.1")
(depends-on "lsp-mode")
(depends-on "hierarchy")

(development
 (depends-on "ert-runner")
 (depends-on "package-lint"))

(add-hook 'eask-before-compile-hook
           (lambda (&rest _)
             (setq byte-compile-docstring-max-column 200)
             (setq byte-compile-error-on-warn t)))
