# 配置

## 温度过热通知阈值

默认 **35°C**（约 95°F）。电池温度越线时，App 会在 macOS 通知中心发一次提醒，每次升温只发一次，等温度降回阈值以下 2°C 后才会重新触发（迟滞），不会刷屏。

第一次发通知时 macOS 会请求权限，点「允许」即可。之后可以在「系统设置 → 通知」里管理。

## 改阈值

配置项单位是 **摄氏度**。比如想改成 40°C：

```sh
defaults write com.jpert.batterywatts hotThresholdC -int 40
```

重启 App 生效。立即生效：

```sh
launchctl kickstart -k gui/$(id -u)/com.jpert.batterywatts
```

## 恢复默认

```sh
defaults delete com.jpert.batterywatts hotThresholdC
```
