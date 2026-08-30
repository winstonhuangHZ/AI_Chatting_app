# 进度跟踪：Agentic Features（feat/agentic-features 分支）

> 第一梯队 4 个功能的实施进度。每完成一步在此勾选。

## 任务总览

- [x] **功能 1 & 2：工具调用 + 联网搜索**
- [x] **功能 3：准确 Token 计数**
- [x] **功能 4：历史全文搜索**
- [x] **附加：自定义价格（缓存 / 输入 / 输出）**
- [ ] **收尾：全量构建 + 打包 + 冒烟测试**

---

## 功能 1 & 2：工具调用（Function Calling）+ 联网搜索

### 目标
扩展 `OpenAIService` 支持 OpenAI 标准 `tools` / `tool_calls` 字段，内置 3 个工具（`get_time` / `calc` / `web_search`），服务层内部维护 tool-call 循环（最多 3 轮），保持流式体验不变；联网搜索 = `web_search` 工具（DuckDuckGo，零 key）。

### 子任务
- [x] 创建 `advices.md`（整合建议文档）
- [x] 创建进度跟踪文件 `track_progress.md`
- [x] **设计决策**：工具调用做成**独立模式**，默认关闭 → 普通聊天完全不受影响（请求不带 `tools` 字段，prompt cache 字节稳定）
- [x] **`Services/ChatTools.swift`**（新建）：工具定义 + 执行器 + WebSearch 后端
  - [x] 工具注册表 `ChatTools.all`（calc / web_search / web_fetch / weather；get_time 因系统已内置时间戳注入而省略）
  - [x] `execute(name:argumentsJSON:)`
  - [x] `WebSearch`（DDG Instant Answer + HTML 降级）
- [x] **`OpenAIService.swift`**：
  - [x] `StreamChunk` 增加 `tool_calls` delta 解析（index/id/name/arguments 分片累积）
  - [x] 新增 Payload 类型：`PayloadTool` / `PayloadToolFunction` / `PayloadJSON`（任意 schema 编码）
  - [x] 新增 `PayloadItem` 枚举，统一 `message` / `toolCall` / `toolResult`
  - [x] `ChatPayload` 增加可选 `tools`（仅非 nil 时编码，保持缓存字节稳定）
  - [x] `payloadMessages` 返回 `[PayloadItem]`
  - [x] 新增 `ChatStreamEvent`（`.text` / `.toolActivity` / `.toolFinished`）
  - [x] 新增 `streamChatWithTools`（内部 tool 循环，max 3 轮 + 收尾答案轮）
- [x] **`APIServerConfig.swift`**：增加 `toolsEnabled: Bool = false`（默认关闭，Codable 兼容）
- [x] **`ChatViewModel.swift`**：startGeneration 按 `toolsEnabled` 路由 + consumeToolEvents 事件循环，发送时按模式路由（关闭→原 `streamChat`，开启→`streamChatWithTools`）
- [x] **`ChatView.swift` TopBarView**：Agent 模式切换（持久化到 profile）
- [x] **`AppLanguage.swift`**：新增 `agent.mode` 等本地化文案
- [x] 构建验证

### 设计要点
- 工具循环在服务层内部，`ChatMessage` 模型不改（历史里不持久化 tool_calls，重试会重新触发工具）
- 有 tool_calls 时不 yield 半截文本，只 yield 工具活动；无 tool_calls 时正常流式 yield
- 工具执行在后台线程（Task 内），失败返回可读文本让模型自行调整

---

## 功能 3：准确 Token 计数

### 目标
用 cl100k_base 官方近似算法替换现在的字符启发式，误差从 ~20% 降到 <5%；并计入 PDF 附件页数。

### 子任务
- [x] **`Services/AccurateTokenCounter.swift`**（新建）：cl100k 近似（英文 4/数字 3.4/空白 3.6/符号 4/非 ASCII 按字节，CJK 微调 1 token/字）
- [x] **`TokenUsage.swift`**：`estimateTokens` 改调新计数器；`summarize` 计入 `documentAttachments` 页数
- [x] 构建验证 + 数值抽查（CJK 修正、英文误差 ±1）

---

## 功能 4：历史全文搜索

### 目标
侧栏加搜索框，全量检索会话标题 + 消息内容，命中跳转到会话并高亮消息。

### 子任务
- [x] **`ChatViewModel.swift`**：`searchQuery` / `highlightMessageID` / `searchResults`（大小写不敏感）/ `selectSearchResult`（跳转 + 高亮自动消失）
- [x] **`SidebarView.swift`**：顶部搜索框 + 结果列表（替换会话列表）
- [x] **`ChatView.swift`**：MessageList 接收 `highlightMessageID`，滚动到命中消息 + 高亮背景
- [x] **`AppLanguage.swift`**：`search.placeholder` / `search.no.results`
- [ ] 构建验证

---

## 收尾
- [x] `swift build --skip-update` 全量通过
- [x] `./build.sh --package` 打包 + 启动冒烟测试
- [x] 逻辑验证：calc 计算、恶意表达式拦截、DDG 在线搜索、tokenizer 数值抽查、价格优先级（custom > relay > 内置表 + 缓存档成本）
- [x] git 提交（feat/agentic-features）

---

## 附加：自定义价格（缓存 / 输入 / 输出）

- [x] **`APIServerConfig.swift`**：新增 `CustomPrice { input, output, cachedInput? }` + `customPrice` 字段（Codable 兼容，默认 nil）
- [x] **`TokenUsage.swift`**：`pricing(for:dynamicPrices:customPrice:)` 优先级 custom > relay > 内置表；`estimatedCost` 返回 `CostEstimate(full, cached)`
- [x] **`SettingsView.swift`**：ProfileEditView 新增「自定义价格」区块（开关 + 输入/输出/缓存读取三个输入框）
- [x] **`ChatView.swift`**：UsageBar 显示 `≈ $X` + 缓存命中档 `（若命中缓存 ≈ $Y）` + 「自定义价格」来源标签
- [x] **`AppLanguage.swift`**：`custom.price.*` / `usage.cost.cached` 六语言文案
- [x] 数值验证：优先级 + 缓存成本计算全对（full=1.686 / cached=0.576）
- [x] 移除冗余 `get_time` 工具（系统已内置时间戳注入）

---

## 附加：Claude 风格主题（米白背景 + 橙色消息框）

- [x] **配色来源**：联网抓取 Claude-inspired 主题（`Xv-Bowen/claude-like-typora-theme`）的完整 CSS 变量：
  - 背景 `#F9F9F7` / 侧栏 `#F4F4F2` / 抬升面 `#FFFFFF`
  - 粘土橙 `#CC7D5E`（用户气泡）/ 深橙 `#A95639` / 主文本 `#2D2D2B` / 次要文本 `#6B6B67`
- [x] **`AppearanceStore.swift`**：新增 `ChatTheme`（system / claude）+ `theme` 持久化 + Claude 调色板常量 + 各区域取色 helper（chatBackground / userBubbleColor / userBubbleTextColor / assistantBubbleColor / sidebarBackground）
- [x] **`AppMain.swift`**：Claude 主题强制 `.preferredColorScheme(.light)`
- [x] **`ChatView.swift`**：聊天区米白背景、用户消息粘土橙实心气泡 + 白字、AI 消息纯白气泡
- [x] **`SidebarView.swift`**：侧栏米灰表面（List `scrollContentBackground(.hidden)`）
- [x] **`AppearancePickerView.swift`**：设置页「主题」选择器（跟随系统 / Claude 米白橙）
- [x] **`AppLanguage.swift`**：`appearance.theme` / `theme.system` / `theme.claude` 六语言文案
- [x] 构建 + 打包 + 启动冒烟通过


---

## 附加：工具集扩充与收尾轮修复

- [x] **`OpenAIService.swift`**：工具循环重构——单轮逻辑抽 `performToolRound`；循环耗尽仍无文本答案时追加一轮**不带 tools** 的收尾请求强制给出最终答案；工具执行失败容错（错误文本回传模型而非中断整个流）
- [x] **`ChatTools.swift`**：新增 `web_fetch`（抓网页全文，纯文本 ≤8000 字符，复用 DDG 去标签逻辑）与 `weather`（Open-Meteo 零 key：城市名 geocoding 解析 + 当前天气 + 3 天预报，中文 WMO 描述；description 明确约束"仅用户明确询问天气时使用，禁止主动查询"）
- [x] `web_fetch` 解析 WebPageReader（script/style 剔除 → 块级标签转行 → 去标签 → 实体解码 → 空白折叠）
- [x] 构建 + 打包 + 启动冒烟通过；geocoding / forecast API 返回结构与解析逻辑逐字段核对

