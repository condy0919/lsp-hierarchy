# lsp-hierarchy

LSP call and type hierarchy views for Emacs, fully powered by the built-in `hierarchy.el` data engine.

## Overview

`lsp-hierarchy` provides a clean, minimalistic way to explore symbol hierarchies (callers/callees and super/subtypes) provided by Language Servers via `lsp-mode`. Unlike other solutions that require external sidebars or complex UI frameworks, `lsp-hierarchy` uses standard Emacs buffers and the native `hierarchy.el` library (introduced in Emacs 29.1) to manage and render tree structures.

## Comparison with lsp-treemacs

| Feature          | lsp-hierarchy                         | lsp-treemacs                         |
|:-----------------|:--------------------------------------|:-------------------------------------|
| **Dependency**   | Lightweight (built-in `hierarchy.el`) | Heavy (requires `treemacs`)          |
| **UI Style**     | Standard Emacs buffer (outline-like)  | Dedicated sidebar with icons/widgets |
| **Performance**  | High (native data structures)         | Moderate (UI overhead)               |
| **UX**           | Minimalist, "vanilla" feel            | Rich, feature-packed IDE feel        |
| **Asynchronous** | Yes (non-blocking)                    | Yes                                  |

### Pros
- **Ultra-lightweight**: No need to install and configure `treemacs` or `posframe`.
- **Native Feel**: Leverages built-in Emacs features like `outline-minor-mode` for folding.
- **Minimalist**: Focuses purely on the data without visual clutter.
- **Extensible**: Uses standard text properties, making it easy to theme or script.

### Cons
- **No Icons**: Uses text-based indicators (▶/▼) instead of graphical icons.
- **Limited Interactivity**: Lacks the mouse-driven widgets and drag-and-drop features of Treemacs.
- **Basic UI**: No side-by-side file syncing by default (though jump-to-source is supported).

## Installation

### Melpa

``` elisp
(use-package lsp-hierarcy
  :ensure t)
```

### Manual
Ensure you have the dependencies installed: `lsp-mode`.
Clone this repository and add it to your `load-path`:
```elisp
(add-to-list 'load-path "/path/to/lsp-hierarchy")
(require 'lsp-hierarchy)
```

## Integration with lsp-mode

You can bind the primary commands to your preferred keys or add them to the `lsp-mode` map:

```elisp
(with-eval-after-load 'lsp-mode
  (define-key lsp-mode-map (kbd "g H c") #'lsp-hierarchy-show-call)
  (define-key lsp-mode-map (kbd "g H t") #'lsp-hierarchy-show-type))
```

### Usage
- `M-x lsp-hierarchy-show-call`: Show incoming calls.
  - Call with `C-u` prefix for **outgoing calls**.
- `M-x lsp-hierarchy-show-type`: Show subtypes.
  - Call with `C-u` prefix for **supertypes**.

### Keybindings (Hierarchy Buffer)
- `TAB`: Toggle node expansion.
- `RET`: Jump to source.
- `n`/`p`: Navigate between nodes.

### Screenshots

![lsp-incoming-calls](https://private-user-images.githubusercontent.com/4024656/597368061-a2ccaed8-9621-451a-89d7-03017c3735c2.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3Nzk2NjI0MjcsIm5iZiI6MTc3OTY2MjEyNywicGF0aCI6Ii80MDI0NjU2LzU5NzM2ODA2MS1hMmNjYWVkOC05NjIxLTQ1MWEtODlkNy0wMzAxN2MzNzM1YzIucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDUyNCUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjA1MjRUMjIzNTI3WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9ZDVlOTllOTUyNzM5NGVjNmUzZDBiYjEwZjk5NmMxODZkMzFkMWQ1MjMxNzk0OWJkMDdiZDQ4YjM2YzY3MzRmNCZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QmcmVzcG9uc2UtY29udGVudC10eXBlPWltYWdlJTJGcG5nIn0.do9z3AsLAcZu4j_kaFkMr2gtb-YyJ6YS3g3XAhoj4Ak "lsp-incoming-calls")

## Customization

```elisp
;; Initial expansion depth
(setq lsp-hierarchy-expand-depth 1)

;; Include signatures in symbol labels
(setq lsp-hierarchy-detailed-outline t)

;; Custom icons
(setq lsp-hierarchy-icon-open "▼")
(setq lsp-hierarchy-icon-close "▶")
```

## License
GPL-3.0-or-later
