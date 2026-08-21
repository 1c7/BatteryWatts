# 常见问题

## 「App 已损坏，无法打开」/「未识别的开发者」

Gatekeeper 对浏览器下载的 ad-hoc 签名 App 的反应。修复：

```sh
xattr -dr com.apple.quarantine ~/Applications/BatteryWatts.app
```

一键安装脚本已经自动做这步了，只有手动从浏览器下载才会遇到。

## 充电瓦数看起来比充电器额定低

正常。详细解释见 [工作原理 → 充电瓦数为什么看起来偏低](how-it-works.md#充电瓦数为什么看起来比充电器额定值低)。

## 菜单栏没显示

确认进程在跑：

```sh
pgrep -x BatteryWatts
```

如果是空的，启动它：

```sh
open ~/Applications/BatteryWatts.app
```

或重跑安装脚本。没有电池的 Mac 不会显示有意义的数字。

## 时间显示 `--:--`

刚插上电源时 macOS 还没算出预估时间，等一两分钟就会填上。

## 会不会耗电？

几乎不耗。每 5 秒醒来读一次硬件值、改一行文字。

## 如何彻底卸载

```sh
curl -fsSL https://raw.githubusercontent.com/1c7/BatteryWatts/main/uninstall.sh | bash
```

只退出当前会话：点菜单栏图标 → 「退出充电速度」。
