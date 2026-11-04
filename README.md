# lsp-hierarchy

Explore LSP call and type hierarchies in a standard Emacs buffer.

## Overview

`lsp-hierarchy` explores callers, callees, subtypes, and supertypes through `lsp-mode`. It uses built-in `hierarchy.el` for tree relationships and `outline-minor-mode` for folding.

## Comparison with lsp-treemacs

| Feature          | lsp-hierarchy                         | lsp-treemacs                         |
|:-----------------|:--------------------------------------|:-------------------------------------|
| **UI dependency** | Built-in Emacs libraries             | `treemacs`                           |
| **UI Style**     | Standard Emacs buffer (outline-like)  | Dedicated sidebar with icons/widgets |
| **UX**           | Minimalist, "vanilla" feel            | Rich, feature-packed IDE feel        |
| **LSP requests** | Asynchronous                          | Asynchronous                         |

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

Requires Emacs 29.1 or newer and lsp-mode 9.0 or newer.

### Melpa

``` elisp
(use-package lsp-hierarchy
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
- `n`/`p`: Navigate between visible rows.

If expansion fails, press `TAB` on the node to retry. Nodes can be folded while loading. Closing the view or starting a new view cancels its pending requests.

### Example

An incoming-call view after expanding a caller:

```text
▼ [f] target
  ▼ [f] caller
        int caller() { return target(1); } (line 5)
```

## Customization

```elisp
;; Initial expansion depth: 0 keeps roots closed; 1 loads their children
(setq lsp-hierarchy-expand-depth 1)

;; Include signatures in symbol labels
(setq lsp-hierarchy-detailed-outline t)

;; Custom icons
(setq lsp-hierarchy-icon-open "▼")
(setq lsp-hierarchy-icon-close "▶")
```

Call-site text is read when its row is first shown. Open buffers supply their current contents, including unsaved edits; other files use view-local snapshots refreshed when the file changes. Closing or replacing the view releases these snapshots.

## Development

With Emacs and Eask installed:

```sh
make install
make compile
make lint
make test
```

The request tests use lsp-mode's response handlers with a controllable transport to cover stale responses, cancellation, retries, server routing, and out-of-order completion. Other tests cover folding, navigation, Unicode positions, and source caching.

CI tests hash-table and plist protocol objects in separate environments. For a local plist build, set `LSP_USE_PLISTS=true` before installing and compiling dependencies; changing it after compilation does not change generated LSP accessors.

## License
GPL-3.0-or-later
