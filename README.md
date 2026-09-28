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

## 浏览与备份

- 浏览：查看当前 App 有权访问的目录、文件大小和修改时间；文本、JSON、plist 可以直接预览。
- 备份：生成 `.sandboxark`，通过系统分享面板或「文件」App 保存到你选的位置。
