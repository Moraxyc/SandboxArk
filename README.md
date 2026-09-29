# SandboxArk

SandboxArk 能够注入到 iOS App 里，访问当前App可以访问的私有数据，并打包成一个备份文件保存。

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
- `SandboxArkTestHost.ipa`：项目自带的测试 App
- `build-metadata.txt`：本次构建的 Xcode、iOS SDK、Swift、Clang 和目标配置

## 注入并安装

1. 在签名工具里导入目标 App 的 IPA。
2. 加入 `sandboxark.dylib`
3. 签名，安装到设备上。

## 打开界面

启动 App 后，在屏幕上三指长按约 1.5 秒即可打开 SandboxArk 的窗口
