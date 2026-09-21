# Qevigo

macOS 菜单栏划词翻译：选中文字，按一下全局快捷键，弹出翻译窗口。

Qevigo 基于 [mohist-club/Poptro](https://github.com/mohist-club/Poptro)（MIT）v1.6.0 重构。功能保持对齐，
设置窗口改为 **macOS 原生的工具栏标签页样式**（`NSTabViewController`，与系统 App 的设置窗口同一套控件），
并新增**多服务自动故障转移**，解决免费额度下"有时候翻译没有响应"的问题。

## 功能

- **划词翻译**：Accessibility 读取选中文字，失败时自动用「模拟 ⌘C 并恢复剪贴板」兜底；没有选中内容时弹出输入框手动翻译
- **翻译服务**：智谱 GLM、OpenAI、DeepL、Groq、Google AI (Gemini)、Cerebras、Together AI、本地 Ollama、自定义 OpenAI 兼容端点
- **自动故障转移**（新）：限流 / 额度用尽 / 长时间无响应时切换到下一个服务，出错的服务会被临时跳过
- **智能方向**：自动识别原文语言（NaturalLanguage，50+ 种），翻成「默认目标语言」，原文已是该语言则翻成「备用语言」
- **读取可用模型**、**验证并测速**（首字耗时 / 总耗时 / 字符每秒）
- **全局快捷键**：绑定应用、快捷指令、系统操作（锁屏、睡眠等，危险操作二次确认）、Shell / AppleScript / JXA 脚本
- 浮窗可拖动、缩放、记住位置和大小、可锁定；朗读、复制、互换语言；浅色 / 深色 / 自动；中英文界面
- 从原版 Poptro 一键导入配置（服务、API Key、快捷键、偏好）：设置 → 高级

## 自动故障转移

设置 → 翻译服务：勾选「自动故障转移」，拖动左侧列表调整优先级，勾选要参与的服务。

一次翻译的顺序：**你选中的服务 → 列表中其余可用服务**。某个服务出现下列情况就换下一个：

| 情况 | 处理 | 该服务的冷却时间 |
| --- | --- | --- |
| HTTP 429（限流） | 切换 | `Retry-After`，缺省 60 秒（10 秒–10 分钟） |
| 额度用尽（402 / 456） | 切换 | 1 小时 |
| Key 无效（401 / 403） | 切换 | 15 分钟 |
| 首字超时（默认 6–10 秒，本地模型 45 秒） | 切换 | 30 秒 |
| 5xx、空响应、网络错误 | 切换 | 15–30 秒 |
| 模型名错误（400 / 404） | 切换 | 5 分钟 |

- 冷却中的服务在后续翻译里排到最后，所以已知被限流的服务不会再让你干等。
- **译文一旦开始流式输出就不再切换**，避免拼出两个服务混合的译文；此时出错会保留已收到的部分并显示错误。
- 全部失败时，错误信息会逐个列出每个服务的原因。
- 首字超时可在 设置 → 高级 调整。

## 安装

从 [Releases](https://github.com/mohist-club/Qevigo/releases) 下载 `Qevigo.dmg`，把 `Qevigo.app` 拖进「应用程序」。
这是 ad-hoc 签名版本，首次打开会被系统拦截：到 系统设置 → 隐私与安全性 里点「仍要打开」即可。

## 构建与运行

需要 macOS 14+ 和 Xcode（Swift 5.10+）。

```bash
swift test                          # 单元测试（39 个）
./scripts/build-app.sh              # 生成 dist/Qevigo.app（release，ad-hoc 签名）
CONFIG=debug ./scripts/build-app.sh # 调试构建，更快
./scripts/make-dmg.sh               # 生成 dist/Qevigo.dmg 与 dist/Qevigo.zip
open dist/Qevigo.app
```

首次运行需要在 系统设置 → 隐私与安全性 → 辅助功能 中授权。
授权与 App 路径绑定：日常使用请把 `Qevigo.app` 放到 `/Applications` 后再授权，避免反复授权。
ad-hoc 签名的 App 首次打开会被 Gatekeeper 拦截，到 隐私与安全性 里点「仍要打开」。

默认翻译快捷键是 `⌃⌥T`（避免占用各 App 通用的 `⌘G` 查找下一个），可在 设置 → 通用 修改。

## 结构

```
Sources/QevigoCore/       无 UI 的核心库（可单测）
  Models/                 设置、语言目录、快捷键绑定
  Providers/              服务商目录 + 4 种协议后端（OpenAI 兼容 / Gemini / DeepL / Ollama）
  Routing/                健康状态与冷却、路由规划、首字超时、故障转移路由器
  Support/                存储、API Key 加密、语言识别、<think> 过滤、原版配置导入
Sources/Qevigo/           App
  App/                    入口、AppDelegate、SettingsStore（唯一设置来源）
  Settings/               原生设置窗口与五个标签页
  Panel/                  翻译浮窗与协调器
  Services/               取词、权限、热键、动作执行、开机启动、更新检查
Tests/QevigoCoreTests/
```

**相对原版的结构调整**

- 服务后端统一为 `AsyncThrowingStream`，基于 `URLSession.bytes`。原版的 `TranslationService` / `OllamaService` 是持有可变回调的单例，并发请求会互相覆盖。
- 设置只有一个来源 `SettingsStore`。原版「通用」和「服务」页各持一份 `TranslationSettings` 副本并整体保存，会互相覆盖。
- 新增服务商只需在 `ProviderCatalog` 加一项数据；OpenAI 兼容的服务不需要新代码。
- 新请求会取消旧请求，过期结果不会写进界面。
- 过滤 Qwen3 / DeepSeek 等模型输出的 `<think>…</think>`，不会混进译文。
- Gemini 的 API Key 放在请求头，不再出现在 URL 里。

## 数据

数据在 `~/Library/Application Support/Qevigo/`，与原版 Poptro 的目录互不影响，两者可并存。
API Key 用 AES-GCM 加密后保存（密钥由本机硬件 UUID 派生），文件权限 0600。这样可避免明文落盘，
也避免 ad-hoc 签名的 App 反复弹钥匙串授权；但它不等同于钥匙串或硬件安全模块。

环境变量 `QEVIGO_DATA_DIR` 可改数据目录（测试用）。

## 开发辅助

```bash
# 把每个设置标签页渲染成 PNG（进程内渲染，不需要屏幕录制权限）
dist/Qevigo.app/Contents/MacOS/Qevigo --snapshot /tmp/shots [--english] [--dark]
# 用固定文本打开翻译浮窗并截图
QEVIGO_DATA_DIR=/tmp/data dist/Qevigo.app/Contents/MacOS/Qevigo --demo-panel "Hello" /tmp/panel.png
```

## 尚需真机手测

以下依赖系统权限或真实第三方 App，自动化测试覆盖不到：辅助功能取词与剪贴板兜底（原生 App、浏览器、
Electron）、全局快捷键、开机启动、多屏幕下浮窗位置、各服务商的真实接口。

## 更新检查

应用会读取本仓库的 GitHub Releases，有新版本时提示下载 DMG，需要手动替换（ad-hoc 签名无法自动替换自身）。
仓库地址在 `AppInfo.updateRepository`，设为 `nil` 会隐藏所有更新相关界面。

## 许可

MIT，见 [LICENSE](LICENSE)。基于 Poptro（MIT）。
