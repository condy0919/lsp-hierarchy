# lsp-hierarchy

Explore LSP call and type hierarchies in a standard Emacs buffer.

`lsp-hierarchy` is a small, asynchronous tree navigator built on `lsp-mode` and `special-mode`. Expand a few levels, preview a call site, or jump to a symbol's source. The buffer contains ordinary visible text, so `isearch` (`C-s`) and `occur` search the displayed rows.

## Installation

Requires Emacs 29.1 or newer and lsp-mode 10.0 or newer.

```elisp
(use-package lsp-hierarchy
  :ensure t)
```

For a manual installation, install `lsp-mode`, clone this repository, and add it to your load path:

```elisp
(add-to-list 'load-path "/path/to/lsp-hierarchy")
(require 'lsp-hierarchy)
```

## Usage

Run a command with point on a symbol in an LSP-managed source buffer:

| Command | Default | With `C-u` |
| --- | --- | --- |
| `M-x lsp-hierarchy-show-call` | Incoming calls | Outgoing calls |
| `M-x lsp-hierarchy-show-type` | Subtypes | Supertypes |

For example, bind the commands in `lsp-mode-map`:

```elisp
(with-eval-after-load 'lsp-mode
  (define-key lsp-mode-map (kbd "g H c") #'lsp-hierarchy-show-call)
  (define-key lsp-mode-map (kbd "g H t") #'lsp-hierarchy-show-type))
```

In the hierarchy buffer:

| Key | Action |
| --- | --- |
| `TAB` | Expand or fold a node; retry a failed request. At a leaf or call site, move to the next visible symbol. |
| `RET` | Jump to source and record the departure in xref history. |
| `SPC` | Preview source in another window, keeping focus in the hierarchy. |
| `C-n` / `C-p` | Move to the next or previous line using standard Emacs navigation. |
| `g` | Start a fresh query in the current direction at the original position, using the initial expansion depth. |
| `?` | Show mode help. |

Click an arrow to expand or fold, a symbol or call site to visit source, or an error row to retry. Hover over a symbol or call site to see its URI and line number. The mode line shows the current hierarchy direction.

For custom bindings, use `lsp-hierarchy-toggle` for `TAB`. For line movement, use the standard Emacs `C-n` / `C-p` bindings. Standalone parent, sibling, collapse, and direction-switch commands have been removed.

Nodes load independently and can be folded while a request is pending. Late responses are cached without reopening folded branches. Known call sites appear as soon as their node is expanded, while deeper relationships load separately. Empty nodes become leaves; an empty root response displays `No hierarchy found.` Use `g` to retry a failed root query.

Refresh uses a source marker that follows edits. Moving point elsewhere in the source buffer does not change this query position. `g` and `M-x revert-buffer` rebuild the tree in the current direction using `lsp-hierarchy-expand-depth`. Replacing or closing a view cancels its pending requests and releases its source snapshots. To query another symbol or direction, run `lsp-hierarchy-show-call` or `lsp-hierarchy-show-type` at the source symbol, with or without `C-u` as shown above.

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

(setq lsp-hierarchy-icon-open "▼")
(setq lsp-hierarchy-icon-close "▶")
```

Automatic expansion stops when a symbol repeats along its ancestor path; the repeated occurrence can still be expanded manually. Symbol labels cover standard LSP kinds, and deprecated names use strike-through styling.

Call-site text is read only for displayed call sites. Open source buffers supply their current contents, including unsaved edits; other files use snapshots captured on first read and retained for that view. Use `g` to rebuild the view and read updated files. Failed reads fall back to a line-number label.

`lsp-hierarchy-display-buffer-action` controls source jumps and previews through the standard Emacs display functions. Matching `display-buffer-alist` rules retain priority. Previews require another window and do not add xref history entries or run jump hooks.

## Implementation

A view owns its source marker, roots, requests, and source snapshots; the marker identifies the source buffer. Each node represents one occurrence of a symbol, with separate expansion and loading state, and reads its metadata from the original LSP item. Its children are symbol nodes; its call sites are source locations on the incoming edge. The renderer inserts the visible tree directly into the buffer and uses text properties to associate rows with their model data. Ordinary redraws keep buffer point on the same row or its nearest visible ancestor.

Protocol adapters retain each item's originating workspace and opaque server data. Prepare requests use each server's URI handling and negotiated position encoding, with separate cancellation tokens. Successful results are collected in workspace order; an empty response counts as success, and the query fails if all servers fail. Closing the source buffer during preparation cancels the query. Replies are accepted only for the current view object and a pending request token; disposal invalidates the view before cancelling its requests.

## Development

With Emacs and Eask installed:

```sh
make install
make compile
make lint
make test
```

The tests use lsp-mode's response handlers with a controllable transport to exercise cancellation, stale replies, retries, server routing, and out-of-order responses. They also cover expansion, folding, navigation, source previews, Unicode positions, and source caching.

CI tests hash-table and plist protocol objects in separate environments, including lsp-mode 10.0.0 on the minimum supported Emacs version. For a local plist build, set `LSP_USE_PLISTS=true` before installing and compiling dependencies; changing it after compilation does not change generated LSP accessors. To test the minimum lsp-mode release locally, set `LSP_HIERARCHY_LSP_MODE_VERSION=10.0.0` for all Eask commands in a clean Eask environment.

## License

GPL-3.0-or-later
