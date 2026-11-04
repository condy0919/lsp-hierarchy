# `lsp-hierarchy` 最简形式需求与代码精简方案

本文档定义了 `lsp-hierarchy` 在**最简形式（Minimal Viable Form）**下的核心需求边界，并基于当前 [lsp-hierarchy.el](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el)（1567 行）与 [test/lsp-hierarchy-test.el](file:///home/condy/workspace/lsp-hierarchy/test/lsp-hierarchy-test.el)（2812 行）梳理出所有可删减、可简化的代码模块，最后给出面向最简形式的重新实现架构。

---

## 一、 最简形式下的核心需求（Minimal Requirements）

`lsp-hierarchy` 的本质是一个**轻量、异步的树形源码导航探针**。用户在源码符号上触发命令，展开 1～3 层查看调用链或类型继承树，通过预览或跳转定位到目标源码即可完成任务。

### 1. 必备核心需求（Must-Have）
1. **四种查询视图**：
   - Call Hierarchy：Incoming Calls（默认）与 Outgoing Calls（`C-u` 前缀）。
   - Type Hierarchy：Subtypes（默认）与 Supertypes（`C-u` 前缀）。
2. **异步按需展开与状态机**：
   - 每个树节点具备独立状态：`unloaded` $\to$ `loading` $\to$ `loaded` / `error`。
   - 支持初始展开深度 `lsp-hierarchy-expand-depth`（具备基础的同路径递归环路截断，防止自递归重复请求）。
   - 支持在 `loading` 期间折叠节点（响应到达后静默缓存，不强行撑开已折叠分支）。
   - 请求失败时显示错误行，支持按 `TAB` 重试。
3. **惰性调用点源码展示（Lazy Call-Site Excerpts）**：
   - 仅当节点展开时，才读取并高亮显示该边上的调用点源码行（优先读取已打开的 Buffer，否则使用视图级文件缓存快照）。
4. **核心导航与源码交互（最小按键集）**：
   - `TAB`：展开/折叠节点、重试失败节点；在叶子节点上移至下一个可见符号。
   - `RET` / `mouse-1`：跳转到符号或调用点源码位置，并压入 `xref` 历史栈。
   - `SPC`：在另一窗口预览源码位置，焦点留在 Hierarchy 窗口，不污染 `xref` 栈。
   - `n` / `p`：上/下一行；`u` / `<left>`：折叠当前分支或回到父节点；`M-n` / `M-p`：同级兄弟节点跳转。
   - `d`：在原查询位置原地切换方向（Incoming $\leftrightarrow$ Outgoing，Subtypes $\leftrightarrow$ Supertypes）。
   - `g`：在原查询 `origin` marker 处重新发起查询。

### 2. 非核心/可舍弃需求（Out of Scope for Minimal Form）
- **无需 `reroot`（`r`）与查询历史栈**：跨符号深入探索直接使用 `RET` 跳到源码（已记录在 `xref` 栈中，随时可 `M-,` 返回）再调起查询。
- **无需内置正则过滤引擎（`/`）与多维排序（`s`）**：Hierarchy Buffer 本身就是普通只读文本 Buffer，搜索可见节点可直接使用 Emacs 原生 `isearch`（`C-s`）、`occur` 或 `consult-line`。
- **无需刷新时的复杂树状态与多窗口游标恢复**：按 `g` 刷新只需按初始深度重新请求根查询（或仅做最简单的路径集合展开），无需维护平行快照树、半途 `rebase` 和非活动窗口游标追踪。

---

## 二、 当前代码（`lsp-hierarchy.el`）可精简项清单

当前 [lsp-hierarchy.el](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el) 共 **1567 行**。经逐项审计，其中约 **60%（~900 行）** 属于低频特性、过度复杂的状态恢复或针对合成测试的防御性回滚，均可精简：

### 1. 移除刷新状态快照树、半途 `rebase` 与多窗口独立焦点恢复（可精简 ~220 行）
- **涉及代码**：
  - [`lsp-hierarchy--saved-node`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L141-L143) 结构体及 `node` 上的 `restore` 字段、`view` 上的 `restore` / `restore-focus` / `restore-window-focus` 字段（[L139-L154](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L139-L154)）
  - [`lsp-hierarchy--save-refresh-state`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1292-L1355)、[`lsp-hierarchy--match-restore`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1356-L1383)、[`lsp-hierarchy--resume-restore`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1384-L1403)
  - [`lsp-hierarchy--before-command`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1404-L1411)、[`lsp-hierarchy--cancel-restore-focus`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1413-L1417)、[`lsp-hierarchy--resolve-focus`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1419-L1437)、[`lsp-hierarchy--restore-focus`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1439-L1457)
- **原因**：为了处理“刷新加载到一半时用户又按了一次 `g`”、“同一个 Hierarchy Buffer 同时在多个非选中窗口展示且各自停在不同深层节点”、“过滤与刷新同时开启”等极端组合场景，引入了极其复杂的快照重映射状态机。
- **精简方式**：
  - **最简方案**：`g`（[`lsp-hierarchy-refresh`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1522-L1545)）直接按 `lsp-hierarchy-expand-depth` 在 `origin` 处重新 `prepare`，完全删除 `Refresh State` 章节。
  - **折中方案**：若仍想保留刷新后的展开状态，只需在 `view` 上维护一个 `expanded-paths` 哈希表（`:test 'equal`，键为从根到当前节点的 `refresh-key` 路径列表），新节点加载后查表决定是否继续展开即可，仅需 ~25 行代码。

### 2. 移除内置过滤投影（`/`）、排序切换（`s`）与 Header Line（可精简 ~180 行）
- **涉及代码**：
  - `lsp-hierarchy-sort-order`、`lsp-hierarchy-filter-regexp`、`lsp-hierarchy--header-line`、`lsp-hierarchy--filter-matches`（[L161-L179](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L161-L179)）
  - [`lsp-hierarchy--matching-nodes`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L426-L464)、[`lsp-hierarchy--location-less-p`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L466-L479)、[`lsp-hierarchy--display-nodes`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L481-L499)
  - [`lsp-hierarchy--expanded-for-display-p`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L501-L508)、[`lsp-hierarchy--filter-path-p`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L510-L518)
  - [`lsp-hierarchy-cycle-sort`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L644-L655)、[`lsp-hierarchy-filter`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L657-L674)
  - [`lsp-hierarchy--icon-properties`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L957-L961) 中的过滤提示分支
- **原因**：内置过滤只能搜索“已加载到内存的节点”，无法搜索服务端未展开的节点，功能上与 Emacs 原生 `isearch` / `occur` 高度重合，却带来了大量关于折叠态覆盖、图标提示和调用点懒加载的边界冲突。
- **精简方式**：移除 `/` 与 `s`，直接按服务端返回顺序渲染 `node-expanded` 为真的子树；方向信息已由 `mode-name` 呈现在 mode-line 上，无需额外维护 `header-line-format`。

### 3. 移除 `lsp-hierarchy-reroot`（`r`）及配套的逆向位置换算与工作区锁定（可精简 ~80 行）
- **涉及代码**：
  - [`lsp-hierarchy-reroot`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1459-L1494)
  - [`lsp-hierarchy--point-to-position`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1059-L1068)
  - `lsp-hierarchy--view` 的 `workspace` 字段（[L150](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L150)）及 [`lsp-hierarchy--prepare`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1215-L1236) 中的 `workspace` 过滤与校验分支
- **原因**：用户可通过 `RET` 跳到目标符号再发起查询；移除 `reroot` 后，`prepare` 永远在源 Buffer 当前关联的 workspaces 上直接调用 `(lsp--text-document-position-params)`，无需自行实现 `point -> position` 编码换算。

### 4. 移除针对“渲染函数抛异常”的合成事务回滚（Transactional Render Rollback）（可精简 ~70 行）
- **涉及代码**：
  - [`lsp-hierarchy-collapse-or-parent`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L761-L767)、[`lsp-hierarchy-toggle`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L780-L789) 中的 `condition-case` 状态回滚
  - [`lsp-hierarchy--render-expansion`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L794-L802) 包装器
  - [`lsp-hierarchy--load-async`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L845-L860) 中 `previous` 子列表备份与渲染异常回滚
  - [`lsp-hierarchy--render`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L592-L616) 中的 `with-temp-buffer` 离屏双缓冲渲染
- **原因**：[`lsp-hierarchy--extract-line`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1120) 已经用 `condition-case` 兜底了所有文件读取异常，纯内存数据结构向 Buffer 插入字符串在正常运行时不会抛出异常。当前代码为了通过“人为 mock `insert-node` 抛错”的合成测试，在每个修改模型状态的入口都写了事务回滚与离屏渲染。
- **精简方式**：直接在当前 Hierarchy Buffer 中 `erase-buffer` 并插入节点文本，删去所有围绕 `lsp-hierarchy--render` 的 `condition-case` 状态回滚代码。

### 5. 解除 `call-sites` 与 `children` 的节点混装（可精简 ~50 行并大幅降低心智负担）
- **涉及代码**：
  - [`lsp-hierarchy--call-nodes`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1169-L1177) 将 `call-sites` 构造成 `:type 'code` 的 `lsp-hierarchy--node` 并赋给 `children`
  - [`lsp-hierarchy--load-async`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L846) 的 `(append (lsp-hierarchy--node-call-sites node) children)`
  - 各处 `(eq (lsp-hierarchy--node-type node) 'symbol)` 的类型守卫
- **原因**：调用点（Call Site）只是某条调用边上的源码位置 `(uri . range)`，它没有子节点、不能展开、不发请求。将其伪装成 `node` 塞入 `children` 导致所有遍历 `children` 的地方都要区分 `'symbol` 和 `'code`。
- **精简方式**：`node-call-sites` 仅存储 `(cons uri range)` 列表；渲染展开的节点时，先遍历渲染 `node-call-sites`，再遍历渲染 `node-children`。

### 6. 移除行内相对路径展示 `lsp-hierarchy-show-location` 与非 Unicode 字符编码分支（可精简 ~65 行）
- **涉及代码**：
  - [`lsp-hierarchy-show-location`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L56-L62)、[`lsp-hierarchy--location-text`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L304-L328) 中的 URL hex/unhex 词法前缀剥离逻辑、[`lsp-hierarchy--insert-node`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L393-L399)
  - [`lsp-hierarchy--position-to-point`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L1047-L1052) 中针对超出 `#x10ffff` 的 Emacs 内部非 Unicode 字符集的 `encode-coding-string` 回退分支
- **原因**：
  - 鼠标悬停（或 `C-h .` `display-local-help`）以及按 `SPC` 预览已经能直接查看符号所在文件；无需在渲染层手写一套绕过 `lsp--uri-to-path` 的 URL 编解码逻辑。
  - LSP 协议传输的 JSON 文本在法理上只包含 Unicode 标量值（`0..#x10ffff`），无需考虑 Emacs 专有的五字节内部字符集。

### 7. 简化多窗口锚点与可见行位置索引（可精简 ~45 行）
- **涉及代码**：
  - `lsp-hierarchy--row-positions` 与 `lsp-hierarchy--render-positions`（[L171-L176](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L171-L176)）
  - [`lsp-hierarchy--render`](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el#L587-L591) 中的多窗口 `window-start` / `window-point` 遍历保存
- **原因**：Hierarchy Buffer 在绝大多数场景下仅在单个窗口中展示。若渲染时直接维护当前可见行数组或仅对当前 Buffer `point` 做祖先回退，几百行的树扫描耗时不足 0.1ms，无需维护双缓冲哈希索引表。

---

## 三、 最简形式下的重新实现方案（~450 行规模）

如果按上述精简原则重新实现，`lsp-hierarchy.el` 可以从 **1567 行收敛至 ~450 行**，且结构极其清晰：

### 1. 极简数据结构
```elisp
(cl-defstruct (lsp-hierarchy--node (:constructor lsp-hierarchy--make-node))
  workspace lsp-item
  name kind tags detail annotation uri range
  parent
  call-sites   ; list of (URI . RANGE) —— 仅存边位置，不混入 children
  children     ; list of `lsp-hierarchy--node' —— 仅存子符号节点
  expanded     ; boolean
  (load-state 'unloaded) ; 'unloaded | 'loading | 'loaded | 'error
  request error)

(cl-defstruct (lsp-hierarchy--view (:constructor lsp-hierarchy--make-view))
  source origin kind direction
  roots (status 'ready) error
  (generation (make-symbol "lsp-hierarchy-view"))
  (requests (make-hash-table :test 'eq))
  (file-cache (make-hash-table :test 'equal)))
```

### 2. 四层模块划分（单文件 ~450 行）

- [x] **1. 协议与位置换算层（~90 行）**
  - `lsp-hierarchy--method-requirements` 与 `lsp-hierarchy--cancel-request`
  - `lsp-hierarchy--request`（带 `generation` 与 `requests` 生命周期管理）
  - `lsp-hierarchy--position-to-point`（纯码点计算 UTF-8 / UTF-16 / UTF-32）
  - `lsp-hierarchy--source-snapshot` 与 `lsp-hierarchy--extract-line`（惰性读取调用点单行文本）

- [x] **2. 协议数据适配层（~60 行）**
  - `lsp-hierarchy--symbol-node`、`lsp-hierarchy--call-nodes`、`lsp-hierarchy--type-nodes`
  - `lsp-hierarchy--fetch-children`

- [x] **3. 直接渲染层（~120 行）**
  - `lsp-hierarchy--insert-node`（渲染单个符号行）与 `lsp-hierarchy--insert-call-site`（渲染单个调用点行）
  - `lsp-hierarchy--insert-subtree`（当 `node-expanded` 为真时，依次渲染 `call-sites`、`children` 和 `loading/error` 状态行）
  - `lsp-hierarchy--render`（直接重绘 Buffer 并按 `parent` 链恢复光标所在节点与列偏移）

- [x] **4. 交互命令与入口层（~180 行）**
  - 树导航：`lsp-hierarchy-next-line`（`n`）、`lsp-hierarchy-previous-line`（`p`）、`lsp-hierarchy-parent`（`u`）、`lsp-hierarchy-collapse-or-parent`（`<left>`）、`lsp-hierarchy-next-sibling`（`M-n`）、`lsp-hierarchy-previous-sibling`（`M-p`）
  - 展开与加载：`lsp-hierarchy-toggle`、`lsp-hierarchy-smart-tab`（`TAB`）、`lsp-hierarchy--load-async`（含批量加载 `lsp-hierarchy--expand-nodes` 与祖先环路检测 `lsp-hierarchy--recursive-occurrence-p`）
  - 源码跳转与预览：`lsp-hierarchy-goto`（`RET`）、`lsp-hierarchy-preview`（`SPC`）
  - 视图操作：`lsp-hierarchy-refresh`（`g`）、`lsp-hierarchy-switch-direction`（`d`）
  - 入口命令：`lsp-hierarchy-show-call`、`lsp-hierarchy-show-type`

---

## 四、 实施记录

四层模块已按上述职责落地；前文的行号与行数对应精简前的参考版本，以下记录本次实际改动。

1. **刷新状态恢复已移除**：删除快照树、连续刷新 rebase、待恢复焦点和多窗口游标追踪。`g` / `revert-buffer` 在原始 marker 处重新查询，每次使用 `lsp-hierarchy-expand-depth`。
2. **过滤、排序和 Header Line 已移除**：展开的子树按服务器顺序直接显示，方向由 mode line 表示；使用原生 `isearch` / `occur` 搜索可见文本。
3. **reroot 与工作区锁定已移除**：删除 `r` 命令和视图的固定 workspace 字段。保留 `lsp-hierarchy--point-to-position`，作为本项的必要例外：普通 prepare 也需按每个服务器协商的 UTF-8 / UTF-16 / UTF-32 单位分别计算列偏移，不能广播同一位置参数。每个服务器继续拥有独立的请求 token，防止部分响应后丢失取消能力。
4. **渲染事务与离屏 buffer 已移除**：直接重绘当前层级 buffer，删除展开/折叠入口的渲染失败回滚；源码读取失败仍显示行号作为降级结果。
5. **调用点与子符号已分离**：`call-sites` 保存 `(URI . RANGE)`，`children` 仅保存符号节点。展开后依次渲染调用点、子符号和请求状态行。
6. **行内路径和非 Unicode 特例已移除**：删除 `lsp-hierarchy-show-location` 及相对路径转换，位置由 hover / 源码预览提供；位置解码按 Unicode 编码单元计数。
7. **多窗口锚点与可见行索引已移除**：普通重绘仅保存当前 buffer point 的行归属和列偏移，通过文本属性定位；原行隐藏时沿 parent 链回退。刷新重新建树，不保存旧树中的游标位置。

README 已同步为保留功能的使用说明；最低 lsp-mode 版本及两种协议对象表示的 CI 验证继续保留。

本次主文件由 1633 行缩减为 833 行，测试由 3035 行缩减为 1212 行（132 项整理为 51 项）。在 Emacs 31.1 下，lsp-mode 9.0.0 / 10.0.1 × hash-table / plist 四组均严格编译通过，各 51 项 ERT 全部通过，package-lint 通过。真实 clangd 的 UTF-8 / UTF-16 × 四种查询方向共八组验证通过。

## 五、 第二轮精简记录

本轮继续减少重复状态，保留上一轮的功能边界和多服务器请求修复。

1. **请求 token 统一由请求层管理**：节点不再复制 token；请求表记录待完成请求，节点只保留加载状态及错误。
2. **源码 buffer 从 origin 推导**：视图只保存原始位置 marker，通过 `marker-buffer` 获取源码 buffer，删除重复的 `source` 字段。
3. **视图对象身份负责生命周期隔离**：删除 generation 字段；先使当前视图失效，再取消请求并释放资源。回调检查当前视图对象身份和 token 是否仍在请求表中，拒绝旧视图及重复完成的响应。
4. **符号元数据从原始协议项读取**：节点保留 workspace 和原始 LSP item，通过统一访问函数读取名称、位置、kind、tags、detail，删除复制字段。类型方向箭头由渲染器根据视图方向生成，不再存入节点 annotation。
5. **查询方向使用四值枚举**：以 incoming / outgoing / subtypes / supertypes 表示方向，统一推导请求方法、视图名称和相反方向，删除 kind 与方向布尔值的组合状态。
6. **展开命令与 TAB 合并**：统一处理展开、折叠、失败重试；在叶子或调用点行跳到下一个可见符号。`lsp-hierarchy-smart-tab` 保留为兼容别名。
7. **测试辅助逻辑合并**：集中节点查找、模拟响应和常用交互操作，减少重复构造，继续验证异步顺序、生命周期、源码位置和导航行为。

README 的模型与生命周期说明已同步；前文保留为原方案和第一轮实施记录。

在 Emacs 31.1 下，lsp-mode 9.0.0 / 10.0.1 × hash-table / plist 四组均严格编译通过，各 53 项 ERT 全部通过，package-lint 通过。新增回归覆盖销毁期间同步到达的旧响应，以及请求重复完成。真实 clangd 的 UTF-8 / UTF-16 × 四种查询方向共八组验证通过，涵盖刷新、方向切换、预览及加载中折叠。
