# `lsp-hierarchy` 最简形式需求与代码精简方案

本文档定义了 `lsp-hierarchy` 在**最简形式（Minimal Viable Form）**下的核心需求边界，并基于当前 [lsp-hierarchy.el](file:///home/condy/workspace/lsp-hierarchy/lsp-hierarchy.el)（1567 行）与 [test/lsp-hierarchy-test.el](file:///home/condy/workspace/lsp-hierarchy/test/lsp-hierarchy-test.el)（2812 行）梳理出所有可删减、可简化的代码模块，最后给出面向最简形式的重新实现架构。

第一节按当前需求维护；上述行数及第二至八节的方案和实施记录保留为历史，对应各轮修改时的版本。最新折叠命令简化见第九节。

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
   - `n` / `p`：使用 Emacs 内置命令移至下/上一逻辑行，采用标准列保持和边界行为；`u`：回到父节点或当前行所属符号；`<left>`：仅折叠当前行所属符号（含调用点和状态行），已闭合、未加载或叶子节点保持原位，不发起请求。
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

## 六、 第三轮精简记录：最低支持 lsp-mode 10.0

1. **最低依赖升级为 10.0**：包声明、Eask 和 README 使用同一最低版本。CI 的最低版本组合由 9.0.0 改为固定提交的 10.0.0，继续保留最新版本六组与最低版本两组，以及实际源码版本断言。
2. **位置换算复用原生 UTF 列函数**：使用 lsp-mode 10 的 UTF-8 / UTF-16 / UTF-32 列计数及移动函数，删除本地重复实现；每次换算仍依据所属服务器的编码，避免多服务器共用 buffer 设置导致坐标错误，并保留虚拟文档坐标约定。
3. **取消清理删除重复的 handler 操作**：响应处理器由 lsp-mode 原生取消路径释放；保留发送取消失败时的 token / hooks 清理兜底，避免残留引用。
4. **保留仍有必要的协议声明与回归**：lsp-mode 10.0.0 仍缺少部分层级方法的能力声明，因此本地能力声明继续保留。多服务器编码、动态注册、部分响应后取消、同步发送失败和源码关闭测试覆盖当前功能，不因最低版本升级而移除。

前两轮的 9.0 验证结果保留为历史记录，后续验证以 10.0.0 及更新版本为准。

在 Emacs 31.1 下，lsp-mode 10.0.0 / 10.0.1 × hash-table / plist 四组严格编译通过，各 53 项 ERT 全部通过，package-lint 通过。最低版本 10.0.0 下的真实 clangd UTF-8 / UTF-16 × 四种查询方向共八组验证通过。CI 的八种组合、Eask 依赖分支和最低版本断言也已检查。

---

## 七、 第四轮待精简项分析（基于 808 行版本）

经过前三轮重构，`lsp-hierarchy.el` 已精简至 808 行。在此基础上继续排查，仍有以下 **5 处（合计约 60～80 行）** 可进一步收拢与精简：

### 1. 移除子请求的冗余能力检查声明（节省 ~20 行）
- **位置**：`lsp-hierarchy--method-requirements`（第 172–188 行）与 `lsp-hierarchy--request`（第 215–216 行）
- **现状分析**：
  - `lsp-hierarchy--prepare`（第 395–397 行）在发起根查询时，已经通过 `lsp--find-workspaces-for` 按 `"textDocument/prepareCallHierarchy"` / `"textDocument/prepareTypeHierarchy"` 过滤出了支持对应能力的 `workspaces`。
  - 后续展开子节点调用 `lsp-hierarchy--request` 时，请求始终发往已通过校验的特定 `workspace`（`(lsp--buffer-workspaces (list workspace))`）。
  - 在 `lsp-mode` 中，`lsp--find-workspaces-for` 对未出现在 `lsp-method-requirements` 中的方法默认直接返回当前全部 `(lsp-workspaces)`。
- **精简方式**：
  - 删除 `lsp-hierarchy--call-supported-p`（第 181–183 行）与 `lsp-hierarchy--type-supported-p`（第 185–187 行）。
  - 删除 `lsp-hierarchy--method-requirements` 中后 4 条 `:check-command` 子方法声明（`callHierarchy/incomingCalls`、`callHierarchy/outgoingCalls`、`typeHierarchy/supertypes`、`typeHierarchy/subtypes`），仅保留 2 条 `prepare*` 的 `:capability` 声明供 `lsp-hierarchy--prepare` 使用。
  - 删除 `lsp-hierarchy--request` 中多余的 `(lsp-method-requirements (append lsp-hierarchy--method-requirements lsp-method-requirements))` 绑定。

**核验回复：采纳，已实施。** 保留两个 `prepare*` 能力声明及 `--prepare` 中的局部绑定，删除四个子方法声明、两个检查函数和 `--request` 的重复绑定。根请求仍负责能力筛选与动态注册识别，子请求仍检查服务器是否附着，并通过单元素 workspace 列表定向发送；不会因此扩大请求目标，也不修改全局能力表。

此结论有别于“删除全部能力声明”：两个根方法的声明仍不可删除。如果根查询完成后服务器撤销能力，后续展开由服务器拒绝并进入现有错误/重试路径，不再重复检查 prepare 能力；用户在全局配置中设置的子方法禁用规则仍由 lsp-mode 执行。

### 2. 简化源码快照缓存，移除每次渲染时的 `file-attributes` 系统调用（节省 ~15 行）
- **位置**：`lsp-hierarchy--source-snapshot`（第 247–268 行）与 `lsp-hierarchy--dispose`（第 160–162 行）
- **现状分析**：
  - `lsp-hierarchy--source-snapshot` 每次读取未打开文件的调用点源码时，都会先调用 `(file-attributes filename)` 获取 `(mtime size)` 并与缓存比对，且手动抛出 `file-missing`。
  - 实际上：① 已在 Emacs 中打开的文件已优先走 `(find-buffer-visiting filename)`；② 未打开的磁盘文件在单次未刷新的视图生命周期内，其 LSP `Range` 本就是静态快照，若磁盘文件被外部修改，旧 Range 在新文件内容上本就不具参考意义，而用户按 `g`（刷新）、`d`（切换方向）或关闭视图时都会触发 `lsp-hierarchy--dispose` 清空 `file-cache`；③ `insert-file-contents` 在文件不存在时原生就会抛出 `file-missing` 错误并被上层 `condition-case` 捕获降级。
- **精简方式**：
  - `file-cache` 直接存储 `filename -> snapshot-buffer`（不再包装 `(cons stamp buf)`）。
  - 移除 `file-attributes` 预检查与时间戳比对：若 `file-cache` 中已有存活的 buffer 则直接复用，否则新建隐式 buffer 并调用 `insert-file-contents` 写入缓存；`lsp-hierarchy--dispose` 中直接 `(kill-buffer entry)`。

**核验回复：采纳，已实施，明确调整缓存语义。** 缓存现在直接保存 `filename -> buffer`，不再查询文件属性或比较时间戳；首次读取后复用存活快照，刷新、切换方向或关闭视图时释放。已打开的源码 buffer 继续优先使用；快照被手动关闭后允许重新读取。

这里不是严格的“查询时刻快照”：调用点第一次显示时才读取文件，也不能保证文本与 LSP Range 同时产生。因此采纳依据是简化缓存生命周期，而非保证坐标与文件版本一致。保留 `unwind-protect` 清理读取失败产生的临时 buffer 和失效缓存项，错误仍由上层显示为行号，随后可以重试。README 已同步这一行为变化。

### 3. 统一展开深度分支与根节点构造（节省 ~15 行）
- **位置**：`lsp-hierarchy--prepare-requests`（第 373–377 行）、`lsp-hierarchy--expand-nodes`（第 572–578 行）、`lsp-hierarchy--load-async`（第 593–596 行）、`lsp-hierarchy--display`（第 602–609 行）
- **现状分析**：
  - `lsp-hierarchy--display` 与 `lsp-hierarchy--load-async` 中重复编写了 `(if (> depth 0) (lsp-hierarchy--expand-nodes ...) (lsp-hierarchy--render))` 分支。
  - `lsp-hierarchy--prepare-requests` 先将返回项包装为 `(cons workspace item)`，随后在 `lsp-hierarchy--display` 中再次 `mapcar` 拆包构造 `node`。
- **精简方式**：
  - 将 `(when (> depth 0) ...)` 下沉到 `lsp-hierarchy--expand-nodes` 内部，`lsp-hierarchy--display` 与 `lsp-hierarchy--load-async` 均先直接调用 `lsp-hierarchy--render`（或由 `expand-nodes` 统一处理 `depth <= 0` 时直接渲染），消除两处重复条件分支。
  - 在 `lsp-hierarchy--prepare-requests` 收集结果时直接调用 `lsp-hierarchy--make-node` 构造节点列表，省去中间 `cons` 包装与二次遍历。

**核验回复：采纳，已实施。** `--prepare-requests` 按服务器及返回项的原顺序直接构造根节点，`--display` 直接安装节点列表，删除每个 item 的中间 cons 和后续 mapcar。服务器响应聚合仍保留，以维持乱序响应下的显示顺序和“空结果也算成功”的行为。

`--expand-nodes` 统一处理深度：大于零时批量请求，零或负数时只渲染；根显示和子节点响应都调用这一入口。原来的两处条件并不完全相同，子节点响应还必须检查自身及祖先的折叠状态，这些检查已保留：折叠时传入零深度，只缓存并重绘，不重新展开或继续请求。递归截断与批量渲染也保持原有行为。

### 4. 统一 `lsp-hierarchy--position-to-point` 的参数签名（节省 ~5 行）
- **位置**：`lsp-hierarchy--position-to-point`（第 229–238 行）、`lsp-hierarchy--extract-line`（第 273 行）、`lsp-hierarchy--location-point`（第 299 行）
- **现状分析**：
  - `lsp-hierarchy--point-to-position` 接收 `(point workspace)`，而对称函数 `lsp-hierarchy--position-to-point` 却接收 `(position &optional encoding)`，导致所有调用方都必须额外写出 `(lsp-hierarchy--position-encoding workspace)`。
- **精简方式**：
  - 将 `lsp-hierarchy--position-to-point` 签名统一为 `(position workspace)`，在内部调用 `lsp-hierarchy--position-encoding`，简化所有调用点。

**核验回复：建议采纳，原签名描述有误。** 原实现实际为 `--point-to-position(workspace)`（读取当前 point）和 `--position-to-point(position encoding)`；前者没有显式 point 参数，后者的 encoding 也不是可选参数。

已将后者改为 `(position workspace)`，在函数内部选择编码，并更新源码摘录和跳转调用点。这样两个方向都接收 workspace，调用者不再维护额外的 encoding 局部变量；UTF-8/16/32 的选择及 narrowing 处理保持原有行为。

### 5. 收拢单次使用的薄包装函数与兼容别名（节省 ~20 行）
- **位置**：
  - `lsp-hierarchy--revert`（第 791–793 行）与 `lsp-hierarchy-refresh`（第 781 行）
  - `lsp-hierarchy-smart-tab`（第 692 行）
  - `lsp-hierarchy--symbol-node`（第 313–315 行）与 `lsp-hierarchy--call-nodes`（第 317–328 行）
  - `lsp-hierarchy--insert-call-site`（第 487–495 行）
- **精简方式**：
  - 为 `lsp-hierarchy-refresh` 增加可选参数 `(&rest _)`，并将 `revert-buffer-function` 直接设为 `#'lsp-hierarchy-refresh`，删除 `lsp-hierarchy--revert`。
  - 将测试文件 `test/lsp-hierarchy-test.el` 中仅剩的 2 处 `lsp-hierarchy-smart-tab` 调用改为 `lsp-hierarchy-toggle`，删除 `lsp-hierarchy-smart-tab` 兼容别名。
  - 在 `lsp-hierarchy--call-nodes` 中直接向 `lsp-hierarchy--make-node` 传入 `:call-sites`，省去先调 `lsp-hierarchy--symbol-node` 再 `setf` 的两步操作。
  - `lsp-hierarchy--insert-call-site` 仅在 `lsp-hierarchy--insert-subtree`（第 502–503 行）中调用一次，可与紧随其后的状态行一样直接内联。

**核验回复：采纳，已实施；“单次使用”需结合本轮其他改动判断。**

- `lsp-hierarchy-refresh` 接收并忽略 `revert-buffer` 传入的参数，模式直接将它设为刷新回调，删除 `--revert`。
- 删除 `lsp-hierarchy-smart-tab` 别名，测试及实际按键统一使用 `lsp-hierarchy-toggle`；旧自定义绑定需要改用后者，README 已注明。
- 调用节点通过 `--make-node` 一次设置 workspace、原始 item 和 call-sites，删除随后赋值的步骤。`--symbol-node` 原本有三个生产调用点，并非单次使用；结合第 3 项和调用节点改造后只剩类型节点构造，再直接调用构造器并移除薄包装。
- 将调用点行插入逻辑内联到 `--insert-subtree`，仍按调用点、子符号、状态行分段，保留各行的归属、源码位置和鼠标动作属性。这里的收益是减少阅读跳转，单次调用本身并不是必须内联的理由。

**本轮结果与验证：** 主文件由 808 行缩减为 773 行，净减少 35 行；原先合计 60～80 行的估计偏高，未为凑行数删除必要的失败清理和状态检查。测试调整为 54 项，新增刷新/切换方向后重建源码快照的回归，并更新固定快照、访问中 buffer 优先和读取失败可重试的测试。在 Emacs 31.1 下，lsp-mode 10.0.0 / 10.0.1 × hash-table / plist 四组严格编译及全部 54 项 ERT 通过，package-lint 通过；稳定版 10.0.0 下真实 clangd 的 UTF-8 / UTF-16 × 四方向八组验证通过，包含深度 0/2、加载中折叠、调用点导航、预览、刷新和方向切换。

## 八、 第五轮精简记录：复用内置行移动，移除同级导航

1. **行移动直接使用 Emacs 命令**：删除 `lsp-hierarchy--move-line`、`lsp-hierarchy-next-line` 和 `lsp-hierarchy-previous-line`，将 `n` / `p` 显式绑定到 `next-logical-line` / `previous-logical-line`。采用原生命令的列保持和边界行为，允许移到末尾空行；不再额外钳制到最后一个树行。`special-mode` 本身没有 `n` / `p` 绑定，因此保留模式中的显式绑定。
2. **删除同级导航功能**：移除 `lsp-hierarchy--move-sibling`、`lsp-hierarchy-next-sibling`、`lsp-hierarchy-previous-sibling` 及 `M-n` / `M-p` 绑定。仍可通过行移动、`TAB` 和父节点命令浏览树。
3. **调整导航测试与文档**：移除自定义行移动边界和同级跳转的测试要求，保留 `TAB` 在最终叶子或调用点停留、跳到后续符号及父节点导航的回归。README 已同步按键、标准行移动边界及旧命令迁移说明；第一节核心按键集同步更新，前几轮方案及验证结果保留为历史。

主文件由 773 行缩减为 734 行。在 Emacs 31.1 下，lsp-mode 10.0.0 / 10.0.1 × hash-table / plist 四组严格编译通过，各 54 项 ERT 全部通过，package-lint 通过。

## 九、 第六轮精简记录：折叠命令只负责折叠

1. **单独提供折叠命令**：将 `lsp-hierarchy-collapse-or-parent` 替换为 `lsp-hierarchy-collapse`，`<left>` 只折叠当前行所属符号。在调用点或加载/错误状态行操作时，折叠该行所属符号；已闭合、未加载或叶子节点保持原位，不发起子请求，也不跳到父节点。
2. **保留独立父节点导航**：`u` 继续调用 `lsp-hierarchy-parent`；在符号行回到父节点，在调用点或状态行回到所属符号。加载中的分支仍可折叠，响应到达后沿用缓存结果而不重新展开的行为。
3. **同步回归与文档**：折叠与父节点导航分别验证；README 和第一节核心按键集说明新的单一职责及旧自定义绑定迁移，前几轮记录保留为历史。

主文件由 734 行缩减为 731 行。在 Emacs 31.1 下，lsp-mode 10.0.0 / 10.0.1 × hash-table / plist 四组严格编译通过，各 55 项 ERT 全部通过，package-lint 通过。回归覆盖重复折叠不跳父节点、未加载/叶子节点不发请求，以及调用点和加载/错误行折叠所属符号。
