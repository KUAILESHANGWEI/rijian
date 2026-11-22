# 日缄

每一天都是值得期待的日子。

日子提醒与倒计时工具，支持 iPhone、Android 和 Mac。可记录生日、纪念日及其他重要日子，选择公历或农历、自定义重复、管理分组，并上传提醒音乐。

[下载安装包](https://github.com/KUAILESHANGWEI/rijian/releases/latest) · [使用说明](使用说明.md)

## 安装

| 平台 | 安装包与要求 |
| --- | --- |
| Mac | Apple Silicon、macOS 13+；下载 DMG，将日缄拖到 Applications。当前为本地签名测试版，未经过 Apple 公证。 |
| iPhone | iOS 17+；IPA 需要使用自己的 Apple 开发者身份或 AltStore 重新签名。iOS 26+ 使用 AlarmKit 系统闹钟。不是 App Store 分发包。 |
| Android | Android 8.0+；下载 APK 安装。当前为开发测试签名，更新时覆盖安装，保留原有数据。 |

当前三端构建均为 2026112203，显示版本均为 1.0。iPhone 锁屏完整音乐播放及整首结束后循环已在用户 iPhone / iOS 27.3 上验证；其他系统版本需分别验证。

## 功能

- 日子记录、搜索、归档，分组添加、修改和删除。
- 公历与农历日期、自定义重复、提前提醒。
- 倒计时与系统提醒；上传最大 200MB 的音乐，完整播放后循环，手动停止。
- JSON 备份在三端导入、合并，清空所有日子前验证密码。
- iPhone 与 Mac 可选择 iCloud 云盘目录，按周期保存备份。

JSON 备份包含日子与分组，音乐文件需单独保存。iCloud 目录写入成功不代表云端已经同步完成。自动备份执行时间受系统及 App 运行状态影响，不是严格定时同步服务。Mac 关闭窗口继续运行，选择“退出日缄”才结束；电脑休眠或退出后的准时播放未保证。Android 需要通知及准时提醒权限；后台运行也受设备电池策略影响。旧版 iOS 的普通通知使用短提示音。

## 源码与构建

此仓库保存日缄 Web 与三端原生工程的现有开发历史，不依赖上游仓库自动同步。

- `dist/`：共享界面和业务逻辑。
- `native/ios/`：UIKit、WKWebView、AlarmKit、原生音乐与目录备份。
- `native/android/`：Java WebView、AlarmManager、音乐前台服务。
- `native/macos/`：AppKit、WKWebView、原生音乐、通知与目录备份。

Mac：安装 Xcode Command Line Tools，执行 `sh native/build-macos.sh`。

iPhone：安装支持 AlarmKit 的 Xcode，按自己的团队修改工程签名和 `ExportOptions.plist`，执行 `sh native/build-ios.sh`。自动签名需要对应 Apple Developer 身份和设备授权。

Android：安装 JDK 17、Android SDK 36.1、Build Tools 36.1.0 与 Gradle 9.3.1。设置 `JAVA_HOME`、`ANDROID_HOME` 和 `RIJIAN_GRADLE` 后执行 `sh native/build-android.sh`。离线缓存齐备时可追加 `--offline`。

构建结果保存在 `exports/`，不提交进源码仓库。不要提交签名私钥、凭据、个人音乐和备份文件。发布附件另附 `SHA256SUMS.txt`。

共享界面本机预览：`python3 -m http.server 8765 --directory dist`，打开 `http://127.0.0.1:8765`。各安装版本数据独立，跨设备通过 JSON 备份迁移。

农历组件使用 lunar-javascript，许可证保留在 `dist/vendor/LICENSE-lunar-javascript`。

## 独立闹钟（2026-11-22）

“闹钟功能”支持添加多个闹钟、编辑时间与名称、一次性/每天/工作日/自选星期、单独启停和删除。闹钟随 JSON 备份迁移，旧备份也可继续导入。到时沿用所选完整提醒音乐，整首播放结束后循环至手动停止。

iOS 26+ 使用 AlarmKit 系统星期重复，旧系统使用重复日历通知；Android 用原生准时提醒并在每次触发、重启或时区调整后安排下一次；Mac 在 App 运行时维护重复时间。首次使用需允许相应系统提醒权限。版本 1.0（2026112201）。
