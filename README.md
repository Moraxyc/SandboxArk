# SandboxArk

SandboxArk 能够注入到 iOS App 里，访问当前App可以访问的私有数据，并打包成一个备份文件保存。

备份文件是 `.sandboxark`，本身就是普通 ZIP：里面是 JSON 清单和原来的文件树，用系统「文件」App 或任何解压工具都能打开。

适用环境：非越狱 iOS / iPadOS 16 及以上、arm64 设备，用 Feather 这类支持 dylib 注入的 sideload 签名工具安装。

## 准备

- 一台装了 Xcode 和 iOS SDK 的 macOS 电脑，用来编译
- 目标 App 的 IPA
- 签名证书与描述文件，以及一个支持 dylib 注入的 sideload 签名工具

## 构建

~~~sh
sh scripts/build.sh
~~~

产物在 `dist/SandboxArk/`：

- `sandboxark.dylib`：注入用的动态库
- `SandboxArkTestHost.ipa`：项目自带的测试宿主

宿主 app 包内会写入 `build-metadata.txt`，记录这次构建用的 Xcode、iOS SDK、Swift 和 Clang 版本。

## 注入并安装

1. 在签名工具里导入目标 App 的 IPA。
2. 加入 `sandboxark.dylib`，注入目标选主 App 的可执行文件。
3. 用自己的证书签名，安装到设备上。

dylib 文件名保持小写 `sandboxark.dylib`。

## 打开界面

启动 App 后，在屏幕上三指长按约 1.5 秒，SandboxArk 的窗口会在当前窗口打开。关掉窗口后，App 回到原来的焦点状态。

## 测试宿主

项目自带的 `SandboxArkTestHost.ipa` 用来验证注入、入口和浏览行为：

- **Create Test Fixture**：在这个宿主自己的容器里生成一棵合成目录树（普通文件、嵌套目录、符号链接、FIFO、Caches / tmp / Logs / WebKit / Cookies、SandboxArk 保留目录和一个凭据目录）。它只写宿主自己的 sandbox，dylib 仍然只读。
- **Copy Diagnostics**：把一份脱敏报告复制到剪贴板，内容包括宿主点击次数、注入的 dylib 相对加载路径、Scene 与窗口状态、最近一次浏览扫描的汇总，以及运行时的生命周期事件。报告不含 UDID、序列号、设备名、Team ID、凭据和绝对路径。

## 浏览沙盒

点 **Browse Sandbox** 打开只读浏览器：

- 只以当前 App 的 `NSHomeDirectory()` 为授权根；默认扫描 Documents、Library/Application Support、Library/Preferences。
- 目录和文件显示相对路径、类型、size 和 mtime；被排除项显示原因，读不到的文件显示错误码。
- 顶部显示扫描状态：complete / cancelled / 触顶截断，以及纳入文件数、总大小、unreadable 数和按原因汇总的 excluded 计数。
- 预览只支持文本、JSON、plist，且最多读 256 KiB；不可预览或截断都会明确说明。预览会重新经过同一套描述符访问层打开文件。
- Caches、tmp、Logs、SandboxArk 保留目录、Keychain / 凭据目录、符号链接和 special file（FIFO、socket、device）一律排除；WebKit 与 Cookies 需要单独 opt-in，默认关闭。
- 遇到符号链接一律不跟随，保留目录与子目录组件逐个用描述符打开并复核类型，`..`、空组件和超长路径直接拒绝。
- 扫描在后台线程执行，可以随时 Stop；扫描只读，不写、不删、不改宿主数据。

备份（生成 `.sandboxark`）属于后续阶段，尚未实现。

## 测试

仓库当前不带自动化测试；UI、注入和真机行为必须按下面的方式验证：

1. `sh scripts/build.sh` 产出 `dist/SandboxArk/sandboxark.dylib` 和 `SandboxArkTestHost.ipa`。
2. 用 Feather 把 dylib 注入 TestHost，签名并安装到 iPhone / iPad（iOS 16+、arm64）。
3. 启动后在 TestHost 上点 **Create Test Fixture**，再三指长按 1.5 秒进入 SandboxArk，点 **Browse Sandbox**，查看扫描状态、排除原因与文本预览。
4. 点 **Copy Diagnostics** 把报告贴回来，作为真机证据。

没有真机验证前，iOS 上的 `openat` / `O_NOFOLLOW` 行为一律标 unverified。
