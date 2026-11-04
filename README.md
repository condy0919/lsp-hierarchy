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

| Key | Action |
| --- | --- |
| `TAB` | Expand or fold a node; retry a failed request. At a leaf, move to the next visible symbol. |
| `RET` | Jump to source and record the departure in xref history. |
| `SPC` | Preview source in another window, keeping focus in the hierarchy. |
| `n` / `p` | Move between visible rows. |
| `u` | Move to the parent node. |
| `M-n` / `M-p` | Move between visible siblings, skipping descendants. |
| Left arrow | Fold the current branch, or move to its parent if already closed. |
| `r` | Start a fresh hierarchy at the selected symbol. |
| `d` | Switch between callers/callees or subtypes/supertypes at the original query position. |
| `g` | Refresh while restoring matching branches and the selected location. |
| `C-u g` | Refresh with the initial expansion depth, discarding saved tree state. |
| `s` | Cycle through server order, name order, and source location order. |
| `/` | Filter loaded symbol names and details by regexp; empty input clears the filter. |
| `?` | Show mode help. |

The header shows the current hierarchy direction, sort order, and active filter throughout loading and refresh.

Click an arrow to expand or fold, a symbol name or call site to visit source, or an error row to retry. Hover over names and call sites to see their full URI and line number. Symbol labels cover all standard LSP symbol kinds; detailed labels also show the number of known call sites on that edge. Deprecated symbol names use strike-through styling while their signatures retain the ordinary detail face.

Nodes can be folded while loading. Known call sites appear immediately on expansion, while deeper relationships load independently. A response arriving under a folded node is cached without reopening it. A node with no child symbols or call sites becomes a leaf and loses its expansion arrow; an empty root result displays `No hierarchy found.` If the initial request fails, use `g` to retry.

Refresh repeats the query at its original source marker and in the same direction. The marker follows edits; moving point elsewhere in the source buffer does not change the query. Refresh cancels pending requests and releases source snapshots, then restores state on matching paths using fresh server results. Matching uses the workspace, symbol identity and exact source range within each parent path; symbols moved or removed by edits may not retain their state. User interaction stops pending cursor restoration, so late replies do not take point away. `M-x revert-buffer` also refreshes; `C-u g` starts from `lsp-hierarchy-expand-depth`. Closing or replacing the view releases its requests and snapshots.

Sorting and filtering operate on already loaded nodes without requesting more hierarchy data. Sorting keeps equal keys in server order and leaves call sites in their original order. Filtering reveals paths to matching loaded symbols even beneath folded ancestors; it keeps the stored expansion choices, which take effect again when the filter is cleared. Open branches retain their loading and error rows so refresh progress and retry actions remain accessible. Ordinary incremental search still searches only the displayed rows.

`r` prepares a fresh hierarchy at the selected symbol. Its source buffer must be managed by the server that returned that symbol; otherwise the view is retained and the command asks you to activate that server in the source buffer. After re-rooting, refresh and direction changes use the new source marker and stay with the same server.

### Example

An incoming-call view after expanding a caller:

```text
▼ [f] target
  ▼ [f] caller (1 site)
        int caller() { return target(1); } (line 5)
```

## Customization

```elisp
;; Initial expansion depth: 0 keeps roots closed; 1 loads their children
(setq lsp-hierarchy-expand-depth 1)

;; Include signatures and known call-site counts in symbol labels
(setq lsp-hierarchy-detailed-outline t)

;; Custom icons
(setq lsp-hierarchy-icon-open "▼")
(setq lsp-hierarchy-icon-close "▶")
```

Call-site text is read only for visible rows. Open buffers supply their current contents, including unsaved edits; other files use view-local snapshots refreshed when the file changes.

`lsp-hierarchy-display-buffer-action` controls source jumps and previews through the standard Emacs display functions. Matching `display-buffer-alist` rules retain priority. Previews require another window and do not add xref history entries or run jump hooks.

## Architecture and upstream integration

The implementation separates protocol conversion, model updates, and rendering:

- A view owns its query context, roots, requests, and source snapshots.
- A node represents one occurrence of a symbol along a tree path. Repeated symbols have independent state. Expansion is separate from loading (`unloaded`, `loading`, `loaded`, or `error`), so a request may finish while its node is folded.
- Protocol adapters preserve the originating workspace and raw LSP item, including opaque server data. They return node data without inserting text or creating UI callbacks.
- The renderer builds visible rows in a temporary buffer before replacing the display. Point and window positions are restored by node identity. Text properties locate model nodes; buffer indentation does not define the tree.

Automatic expansion starts sibling requests as a batch and publishes their loading rows together. Sorting and filtering are display projections: they do not reorder the model or overwrite its expansion state. Mouse actions resolve the current row through shared commands rather than retaining callbacks per node.

Refresh snapshots contain path identity and presentation state, not old protocol items or request tokens. Fresh nodes always use the new response's opaque server data. Restoring expansion and restoring point are separate, so a user can stop a pending branch expansion or move away while requests finish.

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

The request tests use lsp-mode's response handlers with a controllable transport to cover stale responses, cancellation, retries, server routing, and out-of-order completion. Other tests cover folding, render batching and rollback, refresh restoration, navigation, mouse actions, source previews, sorting/filtering, point/window preservation, structured labels, Unicode positions, and source caching.

CI tests hash-table and plist protocol objects in separate environments. For a local plist build, set `LSP_USE_PLISTS=true` before installing and compiling dependencies; changing it after compilation does not change generated LSP accessors.

## License

GPL-3.0-or-later
