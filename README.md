# 充电功率

> macOS 菜单栏小工具，把充电功率、充满时间、电池温度直接显示在电池图标旁边。

## 它能告诉你什么

macOS 自带只显示电池百分比，不会告诉你这些：

- 充电功率（瓦）是多少
- 充电器实际能力是多少瓦
- 还要多久充满
- 电池温度多少
- 是不是已经接电但 Mac 其实还在掉电

「充电功率」把这些数字放在菜单栏，1 秒刷新一次：

```
⚡ 29/100W · 3:07 · 14% · 32°C
```

- **充电瓦** — 真正流进电池的功率（电压 × 电流）
- **充电器瓦** — 本次插电以来充电器输出的最高值
- **剩余时间** — 距离充满或用完的预估
- **电量百分比**
- **电池温度** — 过热时用 🌡️ 高亮，并发系统通知

拔电后自动切换到「🔋 82% · 剩余 3:29」，依然能看到电池能撑多久。

## 截图

![screenshot](doc/screenshot.png)

## 安装

需要 macOS 12 及以上。系统设置里会请求一次通知权限。

### 一行命令（推荐）

打开终端，粘贴：

```sh
curl -fsSL https://raw.githubusercontent.com/1c7/BatteryWatts/main/install.sh | bash
```

几秒后菜单栏右上角就会出现图标，并设置开机自启。

### 手动下载

1. 前往 [Releases](https://github.com/1c7/BatteryWatts/releases/latest) 下载 `BatteryWatts.zip`
2. 解压后把 `充电功率.app` 移到 `/Applications`
3. 清除隔离属性后打开：

   ```sh
   xattr -dr com.apple.quarantine /Applications/充电功率.app
   open /Applications/充电功率.app
   ```

### 从源码编译

需要 Xcode Command Line Tools（`xcode-select --install`）：

```sh
git clone https://github.com/1c7/BatteryWatts.git
cd BatteryWatts
./build.sh     # 编译出 充电功率.app
./install.sh   # 安装到 /Applications 并设置自启（需要 sudo）
```

## 退出

点菜单栏图标 → 「退出充电功率」（仅本次退出）。

彻底卸载：

```sh
curl -fsSL https://raw.githubusercontent.com/1c7/BatteryWatts/main/uninstall.sh | bash
```

---

详细文档：

- [工作原理](doc/how-it-works.md)
- [配置温度阈值](doc/configuration.md)
- [兼容性与隐私](doc/compatibility.md)
- [常见问题](doc/troubleshooting.md)

## 许可

[MIT](LICENSE)
