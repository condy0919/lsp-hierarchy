# lsp-hierarchy

Explore LSP call and type hierarchies in a standard Emacs buffer.

## Overview

`lsp-hierarchy` explores callers, callees, subtypes, and supertypes through `lsp-mode`. Nodes load asynchronously as you expand them. The interface uses `special-mode`, text properties, and text arrows (▶/▼), without an additional tree UI package.

The tree lives in an explicit node/view model. The buffer contains its visible rows; folding removes descendant rows from the display while retaining their data and expansion state. Ordinary incremental search therefore searches visible rows only.

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

- `TAB`: Toggle node expansion, or retry a failed expansion from its node or error row. At a leaf, move to the next visible symbol.
- `RET`: Jump to source.
- `n`/`p`: Navigate between visible rows.
- `g`: Refresh the hierarchy. `M-x revert-buffer` does the same.

Nodes can be folded while loading. A response arriving under a folded node is cached without reopening it. A node with no child symbols or call sites becomes a leaf and loses its expansion arrow; an empty root result displays `No hierarchy found.` If the initial request fails, use `g` to retry.

Refresh repeats the query at its original source marker and in the same direction. The marker follows edits; moving point elsewhere in the source buffer does not change the query. Refresh cancels pending requests, releases source snapshots, and rebuilds the tree using `lsp-hierarchy-expand-depth`. Closing or replacing the view also releases its requests and snapshots.

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

Call-site text is read only for visible rows. Open buffers supply their current contents, including unsaved edits; other files use view-local snapshots refreshed when the file changes.

## Architecture and upstream integration

The implementation separates protocol conversion, model updates, and rendering:

- A view owns its query context, roots, node registry, requests, and source snapshots.
- A node represents one occurrence of a symbol along a tree path. Repeated symbols have independent state. Expansion is separate from loading (`unloaded`, `loading`, `loaded`, or `error`), so a request may finish while its node is folded.
- Protocol adapters preserve the originating workspace and raw LSP item, including opaque server data. They return node data without inserting text or creating UI callbacks.
- The renderer builds visible rows in a temporary buffer before replacing the display. Point and window positions are restored by node identity. Text properties locate model nodes; buffer indentation does not define the tree.

Parent/child links are stored directly on nodes. The implementation no longer depends on `hierarchy.el` or `outline-minor-mode`; one model controls both the arrows and which rows appear. View generations and request tokens reject responses belonging to a replaced or closed view.

The intended destination is `lsp-mode`. While this remains a standalone package supporting lsp-mode 9.0, it retains local method-capability declarations, defensive request cleanup, and explicit position-encoding conversion for source snapshots. Moving those shared concerns into lsp-mode core is a separate integration step; the compatibility helpers can be removed when equivalent core support is available.

## Development

With Emacs and Eask installed:

```sh
make install
make compile
make lint
make test
```

The request tests use lsp-mode's response handlers with a controllable transport to cover stale responses, cancellation, retries, server routing, and out-of-order completion. Other tests cover folding, rendering failures, refresh, point/window preservation, structured labels, Unicode positions, and source caching.

CI tests hash-table and plist protocol objects in separate environments. For a local plist build, set `LSP_USE_PLISTS=true` before installing and compiling dependencies; changing it after compilation does not change generated LSP accessors.

## License

GPL-3.0-or-later
