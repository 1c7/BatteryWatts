import Cocoa
import IOKit
import IOKit.ps
import UserNotifications

// MARK: - Battery reading

struct BatteryInfo {
    var pluggedIn: Bool = false
    var charging: Bool = false
    var fullyCharged: Bool = false
    var percent: Int = 0
    var chargeWatts: Double = 0      // power flowing into the battery (V * I), clamped >= 0
    var netPowerW: Double = 0        // signed battery power; negative = discharging
    var adapterWatts: Int = 0
    var minutesToFull: Int = -1      // -1 = unknown / not charging
    var minutesToEmpty: Int = -1     // -1 = unknown / on AC power
    var temperatureC: Double = 0     // battery temperature in °C (0 = unknown)
    var notChargingReason: Int = 0   // ChargerData.NotChargingReason (0 = none)
    // PowerTelemetryData (Apple Silicon, unit mW -> W)
    var systemLoadW: Double = 0
    var systemPowerInW: Double = 0
}

// Caches the IOService handle so we don't reopen AppleSmartBattery every tick.
final class BatteryReader {
    private var service: io_service_t = 0

    init() {
        let matching = IOServiceMatching("AppleSmartBattery")
        service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    var isAvailable: Bool { service != 0 }

    func read() -> BatteryInfo {
        var info = BatteryInfo()
        guard service != 0 else { return info }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return info
        }

        info.pluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        info.charging = (props["IsCharging"] as? Bool) ?? false
        info.fullyCharged = (props["FullyCharged"] as? Bool) ?? false

        if let raw = props["AppleRawCurrentCapacity"] as? Int,
           let rawMax = props["AppleRawMaxCapacity"] as? Int, rawMax > 0 {
            info.percent = Int((Double(raw) / Double(rawMax) * 100).rounded())
        } else if let cur = props["CurrentCapacity"] as? Int {
            info.percent = cur
        }

        if let mV = props["Voltage"] as? Int, let mA = props["Amperage"] as? Int {
            info.netPowerW = (Double(mV) / 1000.0) * (Double(mA) / 1000.0)
            info.chargeWatts = max(0, info.netPowerW)
        }

        if let adapter = props["AdapterDetails"] as? [String: Any],
           let watts = adapter["Watts"] as? Int {
            info.adapterWatts = watts
        }

        if let t = props["AvgTimeToFull"] as? Int, t >= 0, t < 65535 {
            info.minutesToFull = t
        }
        if let t = props["AvgTimeToEmpty"] as? Int, t >= 0, t < 65535 {
            info.minutesToEmpty = t
        }

        if let t = props["Temperature"] as? Int, t > 0 {
            info.temperatureC = Double(t) / 100.0
        }

        if let charger = props["ChargerData"] as? [String: Any],
           let reason = charger["NotChargingReason"] as? Int {
            info.notChargingReason = reason
        }

        if let ptd = props["PowerTelemetryData"] as? [String: Any] {
            if let v = ptd["SystemLoad"] as? Int    { info.systemLoadW    = Double(v) / 1000.0 }
            if let v = ptd["SystemPowerIn"] as? Int { info.systemPowerInW = Double(v) / 1000.0 }
        }

        return info
    }
}

func formatTime(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    return String(format: "%d:%02d", h, m)
}

func notChargingReasonText(_ reason: Int) -> String {
    switch reason {
    case 1: return "优化充电 hold"
    case 2: return "电池热保护"
    case 3: return "系统请求暂停"
    case 4: return "充电上限已达"
    case 5: return "电池保养模式"
    default: return ""
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let reader = BatteryReader()
    var statusItem: NSStatusItem!
    var timer: Timer?

    let defaults = UserDefaults.standard
    var peakAdapterWatts = 0
    var hotThresholdC = 35.0
    var wasHot = false

    // Charging pulse debounce: macOS flips between charging and brief idle/discharge
    // many times a minute, so a single "not charging" sample is not a real stall.
    var notChargingStreak = 0
    let pauseAfterSeconds = 120
    let refreshInterval = 1.0     // 1 Hz, was 5s — captures pulse peaks reliably

    // EMA smoothing for the menu-bar charge wattage so the number doesn't jitter.
    var smoothedChargeW: Double = 0
    var emaInit = false
    let emaAlpha = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        peakAdapterWatts = defaults.integer(forKey: "peakAdapterWatts")
        if defaults.object(forKey: "hotThresholdC") != nil {
            let t = defaults.double(forKey: "hotThresholdC")
            if t > 0 { hotThresholdC = t }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: refresh pipeline

    func refresh() {
        let raw = reader.read()
        let b = smooth(raw)
        updatePeakAdapter(b)
        updatePauseStreak(b)
        maybeNotifyHot(b)

        statusItem.button?.title = buildTitle(b)
        statusItem.menu = buildMenu(b)
    }

    func smooth(_ info: BatteryInfo) -> BatteryInfo {
        var b = info
        if !emaInit {
            smoothedChargeW = b.chargeWatts
            emaInit = true
        } else {
            smoothedChargeW = emaAlpha * b.chargeWatts + (1 - emaAlpha) * smoothedChargeW
        }
        b.chargeWatts = smoothedChargeW
        return b
    }

    func updatePeakAdapter(_ b: BatteryInfo) {
        if b.pluggedIn {
            if b.adapterWatts > peakAdapterWatts {
                peakAdapterWatts = b.adapterWatts
                defaults.set(peakAdapterWatts, forKey: "peakAdapterWatts")
            }
        } else if peakAdapterWatts != 0 {
            peakAdapterWatts = 0
            defaults.removeObject(forKey: "peakAdapterWatts")
        }
    }

    func updatePauseStreak(_ b: BatteryInfo) {
        if b.pluggedIn && !b.charging && !b.fullyCharged {
            notChargingStreak += 1
        } else {
            notChargingStreak = 0
        }
    }

    var sustainedPause: Bool {
        Double(notChargingStreak) * refreshInterval >= Double(pauseAfterSeconds)
    }

    func maybeNotifyHot(_ b: BatteryInfo) {
        guard b.temperatureC > 0 else { return }
        if b.temperatureC >= hotThresholdC && !wasHot {
            wasHot = true
            notifyHot(b.temperatureC)
        } else if wasHot && b.temperatureC < hotThresholdC - 2 {
            wasHot = false
        }
    }

    func notifyHot(_ tempC: Double) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "充电功率 — 电池过热"
        content.body = "电池温度达到 \(Int(tempC.rounded()))°C，macOS 可能会暂停充电直至温度下降。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "batterywatts-hot", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: rendering

    func buildTitle(_ b: BatteryInfo) -> String {
        let tempStr = b.temperatureC > 0
            ? "\(b.temperatureC >= hotThresholdC ? "🌡️" : "")\(Int(b.temperatureC.rounded()))°C"
            : ""

        if !b.pluggedIn {
            var parts = ["🔋 \(b.percent)%"]
            if b.minutesToEmpty >= 0 { parts.append("剩余 \(formatTime(b.minutesToEmpty))") }
            if !tempStr.isEmpty { parts.append(tempStr) }
            return parts.joined(separator: " · ")
        }

        let draining = b.netPowerW < -0.5
        let warn = draining ? "⚠️" : ""
        let glyph: String
        let eta: String
        if b.fullyCharged || b.percent >= 100 {
            glyph = "⚡"; eta = "0:00"
        } else if b.charging {
            glyph = "⚡"; eta = b.minutesToFull >= 0 ? formatTime(b.minutesToFull) : "--:--"
        } else if sustainedPause {
            glyph = "⏸"; eta = "--:--"
        } else {
            glyph = "🔌"; eta = "--:--"
        }

        let chargeW = String(format: "%.0f", b.chargeWatts)
        let chargerW = peakAdapterWatts > 0 ? "\(peakAdapterWatts)" : "—"

        var parts = ["\(warn)\(glyph) \(chargeW)/\(chargerW)W", eta, "\(b.percent)%"]
        if !tempStr.isEmpty { parts.append(tempStr) }
        return parts.joined(separator: " · ")
    }

    func buildMenu(_ b: BatteryInfo) -> NSMenu {
        let menu = NSMenu()
        if b.pluggedIn {
            let draining = b.netPowerW < -0.5
            if b.fullyCharged {
                menu.addItem(makeInfo("状态：已充满"))
            } else if draining {
                menu.addItem(makeInfo(String(format: "⚠️ 已接入电源仍在掉电：%.1f W", b.netPowerW)))
                menu.addItem(makeInfo("系统负载超过充电器输出功率"))
            } else if b.charging || b.chargeWatts >= 0.5 {
                menu.addItem(makeInfo(String(format: "正在充电：%.1f W", b.chargeWatts)))
            } else if sustainedPause {
                let warm = b.temperatureC >= hotThresholdC
                let detail = warm ? "电池过热" : notChargingReasonText(b.notChargingReason)
                let suffix = detail.isEmpty ? "" : "（\(detail)）"
                menu.addItem(makeInfo("充电已暂停\(suffix)"))
            } else {
                menu.addItem(makeInfo("已接入电源（待机）"))
            }

            if hasPowerFlow(b) {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(makeInfo("—— 功率流向 ——"))
                if b.systemPowerInW > 0 {
                    menu.addItem(makeInfo(String(format: "墙插输入：%.1f W", b.systemPowerInW)))
                }
                if b.systemLoadW > 0 {
                    menu.addItem(makeInfo(String(format: "系统消耗：%.1f W", b.systemLoadW)))
                }
                menu.addItem(makeInfo(String(format: "电池充电：%.1f W", b.chargeWatts)))
                if b.systemPowerInW > 0 && b.systemLoadW > 0 {
                    let residual = b.systemPowerInW - b.systemLoadW - b.chargeWatts
                    menu.addItem(makeInfo(String(format: "守恒校验：%.2f W（≈0 即数据自洽）", residual)))
                }
            }

            if peakAdapterWatts > 0 {
                menu.addItem(makeInfo("充电器：本次最高 \(peakAdapterWatts) W"))
            }
            if b.adapterWatts > 0 {
                menu.addItem(makeInfo("充电器当前输出：\(b.adapterWatts) W"))
            }
            if b.minutesToFull >= 0 && !b.fullyCharged {
                menu.addItem(makeInfo("距离充满还需：\(formatTime(b.minutesToFull))"))
            }
        } else {
            menu.addItem(makeInfo("正在使用电池"))
            if b.minutesToEmpty >= 0 {
                menu.addItem(makeInfo("剩余使用时间：\(formatTime(b.minutesToEmpty))"))
            } else {
                menu.addItem(makeInfo("剩余使用时间：计算中…"))
            }
            if b.systemLoadW > 0 {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(makeInfo("系统消耗：\(String(format: "%.1f", b.systemLoadW)) W"))
            }
        }
        menu.addItem(makeInfo("电池电量：\(b.percent)%"))
        if b.temperatureC > 0 {
            let note = b.temperatureC >= hotThresholdC ? "  ⚠️ 过热 — 充电可能暂停" : ""
            menu.addItem(makeInfo("电池温度：\(Int(b.temperatureC.rounded()))°C" + note))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出充电功率", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    func hasPowerFlow(_ b: BatteryInfo) -> Bool {
        b.systemPowerInW > 0 || b.systemLoadW > 0
    }

    func makeInfo(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
