# 待改进点分析

当前项目（`lsp-hierarchy.el` 与 `test/lsp-hierarchy-test.el`）整体架构非常扎实：模型与视图分离、异步代数（generation）隔离、批量加载渲染、错误回滚与刷新状态恢复等细节都经过了精心设计。

在此基础上，结合代码逐行审查，整理出以下**潜在 Bug / 边界缺陷**、**性能与资源管理**以及**交互与功能演进**三方面的待改进点：

---

## 一、 潜在 Bug 与边界情况

### 1. 过滤（Filter）会强制展开未展开节点的调用点并读取隐藏源文件（违背惰性读取约束）
- **位置**：`lsp-hierarchy--matching-nodes`（L366-L394）与 `lsp-hierarchy--expanded-for-display-p`（L431-L436）
- **原因**：在 `lsp-hierarchy--call-nodes`（L992-L1013）中，节点创建时（尚未展开）就已将 `call-sites` 放入 `children`。当执行过滤且某折叠节点匹配时，`lsp-hierarchy--matching-nodes`（L381-L383）无条件把它的 `call-sites` 加入 `matches`；随后 `lsp-hierarchy--expanded-for-display-p`（L433-L436）发现 `children` 中有匹配项，便将该折叠节点判定为“显示展开”。
- **后果**：
  1. 违背了文档注释 *"filtering never reads hidden source files"* 的约束——过滤会立刻触发所有匹配的折叠节点读取磁盘源文件（调用 `lsp-hierarchy--extract-line`）。
  2. 在过滤状态下，用户无法通过 `TAB` 折叠匹配节点下的 `call-sites`。
- **建议**：仅当 `(lsp-hierarchy--node-expanded node)` 为非空时才将其 `call-sites` 放入 `matches`，或者在 `lsp-hierarchy--expanded-for-display-p` 中仅检查 `'symbol` 类型的子节点。

**核查与处理（已修复）**

- 问题存在。新增回归用例确认：仅过滤一个未展开的匹配节点，就会调用一次源码读取函数。
- 修改 `lsp-hierarchy--matching-nodes`，仅在匹配节点本身已展开时保留它的调用位置。过滤仍可显示通往匹配符号的祖先路径，源码片段遵循用户的展开状态，`TAB` 可以收起调用位置。
- 验证：覆盖折叠节点过滤不读取源码、手动展开后显示片段、再折叠停止读取；88 项 ERT 全部通过。

### 2. 过滤匹配拼接空格导致行尾正则（如 `foo$`）失效，且未跟随 `lsp-hierarchy-detailed-outline`
- **位置**：`lsp-hierarchy--matching-nodes`（L375-L379）
- **原因**：`(concat (lsp-hierarchy--node-name node) " " (lsp-hierarchy--node-detail node))` 在 `detail` 为 `nil` 或空字符串时仍会在名字末尾拼接一个空格 `" "`。
- **后果**：当节点没有 `detail` 时，用户输入正则 `foo$` 或 `foo\'` 无法匹配名为 `"foo"` 的符号；此外当 `lsp-hierarchy-detailed-outline` 为 `nil` 时，界面不显示 `detail`，但过滤依然会命中隐藏的 `detail` 文本。

**核查与处理（已修复）**

- 问题存在：无详情时确实多拼接了空格；关闭详细显示后也仍搜索隐藏详情。
- 提取 `lsp-hierarchy--display-detail`，渲染与过滤共用详情的显示规则。只有实际显示的非空详情才追加分隔空格，名称和详情采用相同的单行规范化，过滤不搜索被显示选项隐藏的详情。
- 验证：覆盖 `foo$`、字符串结尾锚点、nil/空白详情、隐藏详情和多行名称；89 项 ERT 全部通过。

### 3. 过滤状态下部分节点的展开图标与提示信息失真
- **位置**：`lsp-hierarchy--icon-properties`（L804-L824）
- **原因**：当某个已展开节点（`expanded = t`）自身匹配过滤正则，但其所有子节点均不匹配时，`lsp-hierarchy--expanded-for-display-p`（L431-L436）仍返回 `t`。
- **后果**：该节点下方没有任何可见子节点，但图标仍显示为展开态 `▼`，且 `help-echo` 提示 *"Filter keeps matching paths visible; clear it to apply folding"*（实际上此时按 `TAB` 是可以直接折叠的）。

**核查与处理（已修复）**

- 问题存在。过滤后的显示展开状态此前直接复用了模型的 `expanded`，也把可以正常折叠的调用位置当成了强制显示的路径。
- 过滤期间，箭头现在依据实际保留的子行或加载/错误状态行显示。只有过滤保留了子符号路径时才显示“清除过滤后应用折叠”的提示；子项全部被隐藏时显示收起箭头并说明原因。模型中的展开选择保持不变。
- 验证：覆盖自身匹配但子项全隐藏、祖先路径被强制显示、只有调用位置的可折叠分支；91 项 ERT 全部通过。

### 4. 刷新（Refresh）期间再次按 `g` 或 `prepare` 失败重试会丢失待恢复的光标焦点（`restore-focus`）
- **位置**：`lsp-hierarchy--cancel-restore-focus`（L1198-L1201）、`lsp-hierarchy--restore-focus`（L1203-L1223）、`lsp-hierarchy--save-refresh-state`（L1112-L1149）
- **原因**：
  1. `pre-command-hook` 挂载了 `lsp-hierarchy--cancel-restore-focus`（L863）。当用户在加载过程中再次交互式按 `g`（`lsp-hierarchy-refresh`）时，`pre-command-hook` 会在进入 `lsp-hierarchy-refresh` **之前**先把 `restore-focus` 清空。
  2. 当根节点请求失败进入 `'error` 状态时，`lsp-hierarchy--prepare-failed`（L1043-L1048）调用 `lsp-hierarchy--render`，进而使 `lsp-hierarchy--restore-focus`（L1220-L1223）立即取消 `restore-focus`，导致 `lsp-hierarchy--save-refresh-state`（L1146-L1148）中专门为 `'error` 保留 `:focus` 的分支实际上永远拿不到焦点。
  3. 当根节点已返回但深层子节点仍在加载时再次刷新，`lsp-hierarchy--save-refresh-state`（L1140-L1142）只保存了当前 `(point)` 所在的浅层节点，丢失了尚未加载完成的深层 `restore-focus` 路径。

**核查与处理（已修复）**

- 三个原因均成立。此前的“任意命令取消待恢复焦点”规则也覆盖了普通刷新，prepare 失败和中途重新拍摄快照还会分别清空、缩短目标路径。
- 新的命令前钩子保留普通 `g`/revert 的恢复意图；导航、其他操作和 `C-u g` 仍取消它。prepare 失败时保留待恢复路径供重试；半完成刷新通过旧快照到新快照的身份映射重定位深层目标，避免把临时停留的祖先当成最终目标。
- 验证：覆盖 prepare 等待时再次 `g`、失败后 revert、深层加载中再次刷新以及移动/重置后的取消；95 项 ERT 全部通过。

**组合回归补充（已修复）**

过滤与刷新同时启用时，待恢复祖先在发起请求前可能被短暂过滤掉，导致焦点提前落到另一个根节点。现在保留即将自动加载且祖先链已展开的恢复节点，直到其状态可正常显示；折叠祖先下暂停的路径不会因此被展示或加载。新增 buffer/非选中窗口回归及暂停路径检查，115 项 ERT 全部通过。

### 5. 非当前选中窗口显示 Hierarchy Buffer 时，异步恢复焦点未同步 `window-point`
- **位置**：`lsp-hierarchy--render`（L526-L532）与 `lsp-hierarchy--restore-focus`（L1203-L1223）
- **原因**：`lsp-hierarchy--render`（L527-L530）先对所有展示该 buffer 的窗口调用 `set-window-point` 恢复旧锚点，最后在 L532 调用 `lsp-hierarchy--restore-focus`（L1218）仅执行了 `(goto-char ...)`。如果异步响应到达时 Hierarchy 窗口不是 `selected-window`（单元测试中 mock 了 `pop-to-buffer` 故未覆盖真实窗口），`goto-char` 不会更新非活动窗口的 `window-point`。

**核查与处理（已修复）**

- 问题存在；真实非选中窗口的回归用例在修复前失败，仅改变 buffer point 无法完成窗口游标恢复。
- 为每个展示层级视图的窗口分别保存和重定位目标路径，异步恢复时调用 `set-window-point`，不选中窗口。多窗口各自保留位置；窗口已关闭或改显其他 buffer 时跳过，用户导航后取消待恢复位置。
- 验证：覆盖后台显示、两个窗口独立位置、连续刷新与用户移动、窗口换 buffer；99 项 ERT 全部通过。

### 6. 在最后一个节点按 `TAB`（`lsp-hierarchy-smart-tab`）或 `n` 会将光标移到缓冲区末尾空行（`eobp`）
- **位置**：`lsp-hierarchy-smart-tab`（L791-L800）
- **原因**：当光标位于最后一个叶子节点或最后的 `code` 行时，按 `TAB` 会向后搜索下一个可见符号直至 `eobp`（最后一行 `\n` 之后的空行）且不回退光标。此时光标停留在无任何属性的空行上，后续按 `u`、`RET`、`SPC`、`M-p`、`<left>` 都会报错 `"No node here"`。
- **建议**：若未找到下一个可见符号，应 `save-excursion` 保持原位置不变（或给出提示）。

**核查与处理（已修复）**

- 问题存在。末尾空行没有节点属性，原来的 TAB 搜索和通用 `next-line` 都可能把光标留在那里。
- TAB 先在 `save-excursion` 中查找下一个可见符号，找不到则保持原位置。`n/p` 改用有边界的行导航，支持次数参数并保留加载/错误行；直接切换叶子时也采用相同边界。
- 验证：覆盖最后一个叶子、最后一个调用位置、跳过状态行寻找符号、前后边界及次数参数；102 项 ERT 全部通过。

### 7. 递归/环路调用在自动展开（`lsp-hierarchy-expand-depth > 1`）时缺少环检测
- **位置**：`lsp-hierarchy--load-async`（L735-L740）
- **原因**：当存在直接递归（`A -> A`）或相互递归（`A -> B -> A`）且 `lsp-hierarchy-expand-depth > 1` 时，自动展开不会检查当前祖先链上是否已存在相同符号（相同 `workspace` + `refresh-key`），会沿环路重复发起请求直到深度耗尽。

**核查与处理（部分成立，已优化）**

- 缺少环检测确实存在，但不会无限请求：原实现每层递减深度。实测深度 6 的自递归最终发出 7 次请求（含 prepare）后结束。
- 自动展开现在按工作区身份和符号位置检查当前祖先链；遇到重复符号保留一个可见、可手动展开的节点，不继续自动请求。不同兄弟路径仍独立，手动展开及刷新重放已展开的递归路径仍可用。
- 验证：覆盖直接递归、相互递归、共享兄弟路径和手动/刷新行为；105 项 ERT 全部通过。

---

## 二、 性能与资源管理优化

### 1. 源文件不存在时 `lsp-hierarchy--source-snapshot` 会泄漏空白缓存 Buffer
- **位置**：`lsp-hierarchy--source-snapshot`（L918-L933）
- **原因**：当 `filename` 不存在时，`(file-attributes filename)` 返回 `nil`，但函数仍会先执行 `(generate-new-buffer " *lsp-hierarchy-source*")` 并写入 `file-cache`，随后在 `insert-file-contents` 时抛错被外层捕获。这会在 `file-cache` 中残留一个空白 buffer，且每次重绘都会重试 `insert-file-contents`。
- **建议**：当 `attrs` 为 `nil`（或文件不可读）时直接抛错或提前返回，或在 `insert-file-contents` 失败时清理 buffer。

**核查与处理（部分成立，已修复）**

- 失败读取会残留无效 buffer/缓存项，但不是完全失去引用的泄漏：原来的视图清理仍会释放它们。问题在于视图存活期间保留空缓存，重绘继续尝试读取。
- 文件不存在时在分配 buffer 前报错；新缓存只在读取成功后发布。读取或更新失败时用 `unwind-protect` 清理该视图拥有的快照和缓存项。已访问文件的 buffer 优先使用，不因磁盘文件消失而清理用户的未保存内容。
- 验证：覆盖不存在文件的重复读取、首次/更新时读取失败、部分读入和已访问文件；108 项 ERT 全部通过。

### 2. UTF-8 列位置换算在循环中逐字符分配字符串并调用编码器
- **位置**：`lsp-hierarchy--position-to-point`（L908-L915）
- **原因**：`"utf-8"` 分支在逐字符循环中调用 `(string-bytes (encode-coding-string (char-to-string char) 'utf-8))`，每次循环都会分配单字符字符串并进行编码转换。
- **建议**：直接根据字符码点判断 UTF-8 字节数（`<= #x7f` 为 1，`<= #x7ff` 为 2，`<= #xffff` 为 3，其余为 4），可实现零内存分配。

**核查与处理（已优化）**

- 问题存在，原 UTF-8 分支每经过一个字符就构造字符串并调用编码器。
- Unicode 字符改为按码点直接计算 1–4 字节宽度。Emacs 还可保存原始字节和非 Unicode 字符，不能一律按 4 字节处理，因此仅这些少见字符保留原编码器路径。
- 验证：覆盖各码点边界、字符中间/行尾偏移，并断言常规 Unicode 路径不调用编码器；另验证非 Unicode 字符和原始字节兼容性。110 项 ERT 全部通过。

### 3. 冗余的节点注册表 `lsp-hierarchy--view-nodes`
- **位置**：`lsp-hierarchy--node`（L114）、`lsp-hierarchy--view`（L142）、`lsp-hierarchy--register-node`（L867-L873）
- **原因**：每个节点都会生成 `(make-symbol "lsp-hierarchy-node")` 并通过 `lsp-hierarchy--register-node` 注册到哈希表 `lsp-hierarchy--view-nodes` 中，但 `lsp-hierarchy.el` 本体代码**没有任何地方读取**该哈希表或 `node-id`（目前仅测试辅助函数 `lsp-hierarchy-test--node` 在使用）。

**核查与处理（已移除）**

- 问题存在。生产代码只写入 `node-id`/`view-nodes`，实际渲染、导航和状态恢复都使用节点对象身份及父子链接；读取注册表的是测试辅助函数。
- 删除每节点生成的 ID、视图注册表、注册函数及调用，使用 roots/children 持有模型。协议转换和异步结果安装时已有的 parent 链继续保留。测试改为遍历实际模型并以节点对象 `eq` 验证身份，同时更新 README。
- 验证：原有多工作区、重复符号、回滚、隐藏节点和刷新身份测试继续有效；110 项 ERT 全部通过。

### 4. 全量重绘时的锚点查找开销
- **位置**：`lsp-hierarchy--anchor-position`（L472-L486）
- **原因**：当深层节点被折叠或过滤隐藏时，`while` 循环沿着 `parent` 链每一层都从 `point-min` 到 `point-max` 全文扫描一次 `text-property-any`。实际上在 `lsp-hierarchy--insert-subtree`（L438-L460）渲染期间即可直接记录可见节点的行首位置，或先通过模型判断祖先是否可见再扫描 buffer。

**核查与处理（已优化）**

- 问题存在：隐藏节点每向上一层都会重新扫描整个 buffer，多个窗口会重复这项工作。
- 渲染时记录可见节点行和状态行的位置，文本成功发布后同步发布位置索引。锚点恢复沿 parent 链做哈希查找，避免每层全文扫描；失败渲染继续使用原文本及原索引。该索引只描述当前可见行，并直接用于运行时定位，不再维护额外的完整模型注册表。
- 验证：覆盖 30 层隐藏祖先回退且禁止全文扫描、排序后位置变化、状态行回退、渲染失败不发布索引；112 项 ERT 全部通过。

---

## 三、 交互体验与功能完善建议

### 1. 刷新（`lsp-hierarchy-refresh`）不应无条件调用 `pop-to-buffer`
- 在 `lsp-hierarchy--prepare`（L1098）末尾无条件调用了 `(pop-to-buffer view)`。当传入 `target`（即 `g` 或 `revert-buffer` 刷新已有视图）时，若从后台或非当前窗口触发 `revert-buffer`，会强行抢占窗口焦点。建议仅在 `target` 为 `nil`（初次打开视图）时 `pop-to-buffer`。

**核查与处理（已修复）**

- 问题存在，`--prepare` 原来对已有 target 也无条件调用 `pop-to-buffer`。
- 现在只有打开新查询时才选择显示窗口；刷新已有视图直接返回目标 buffer，允许后台 revert 保持当前窗口及光标。
- 验证：使用真实窗口分别测试视图已显示/未显示的后台刷新，禁止调用 `pop-to-buffer`，检查源窗口位置不变且请求正常发出；113 项 ERT 全部通过。

### 2. 缺少视图状态（过滤条件 / 排序方式 / 层次方向）的直观展示
- 当前激活 `/` 过滤（`lsp-hierarchy-filter-regexp`）或 `s` 切换排序（`lsp-hierarchy-sort-order`）后，除了回显区短暂的 `message` 外，Buffer 和 Mode-line 没有任何持久标识。建议利用 `header-line-format` 或 `mode-line-process` 展示当前的排序模式与过滤正则。

**核查与处理（部分成立，已补充）**

- 排序与过滤确实缺少持久提示；层级方向原本已通过 `mode-name` 显示在 mode line，并非完全没有标识。
- 新增 header line，统一显示方向、当前排序和过滤正则。状态在成功渲染后更新，渲染失败不会提前显示未生效的选项；通过符号的字面字符串值显示正则，避免 `%b` 等被解释成 mode-line 替换。
- 验证：检查初始状态、排序切换、含 `%` 的正则及清空过滤后的状态；113 项 ERT 全部通过。

### 3. 支持在 Hierarchy 视图内直接切换方向或以当前节点重设根节点（Re-root）
- 在探索深层调用链或类型树时，常见的两个高频操作是：
  - **原地切换方向**（Incoming $\leftrightarrow$ Outgoing，Subtypes $\leftrightarrow$ Supertypes）；
  - **以当前光标下的节点为新 Root 重新展开层次树**（无需先 `RET` 跳回源文件再执行 `M-x lsp-hierarchy-show-*`）。

### 4. 支持 LSP 3.16+ `SymbolTag`（如 Deprecated 符号样式）与键盘用户的同名符号消歧
- `CallHierarchyItem` / `TypeHierarchyItem` 支持 `:tags`（如 `SymbolTag.Deprecated = 1`），可为废弃符号添加删除线属性。
- 对于同名且无 `:detail` 的符号，目前仅能通过鼠标悬停 `help-echo` 查看 URI 区分，终端或纯键盘用户较难直观区分，可考虑支持可选的简短文件名/路径后缀显示。
