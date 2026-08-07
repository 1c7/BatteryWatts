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
    var chargeWatts: Double = 0      // power flowing into the battery (V * I)
    var adapterWatts: Int = 0        // adapter's max rating
    var minutesToFull: Int = -1      // -1 = unknown / not charging
    var minutesToEmpty: Int = -1     // -1 = unknown / on AC power
    var temperatureC: Double = 0     // battery temperature in °C (0 = unknown)
    var notChargingReason: Int = 0   // ChargerData.NotChargingReason (0 = none)
}

func readBattery() -> BatteryInfo {
    var info = BatteryInfo()

    let matching = IOServiceMatching("AppleSmartBattery")
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return info }
    defer { IOObjectRelease(service) }

    var propsRef: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let props = propsRef?.takeRetainedValue() as? [String: Any] else {
        return info
    }

    info.pluggedIn = (props["ExternalConnected"] as? Bool) ?? false
    info.charging = (props["IsCharging"] as? Bool) ?? false
    info.fullyCharged = (props["FullyCharged"] as? Bool) ?? false

    // State of charge
    if let raw = props["AppleRawCurrentCapacity"] as? Int,
       let rawMax = props["AppleRawMaxCapacity"] as? Int, rawMax > 0 {
        info.percent = Int((Double(raw) / Double(rawMax) * 100).rounded())
    } else if let cur = props["CurrentCapacity"] as? Int {
        info.percent = cur
    }

    // Charge power into the battery: Voltage(mV) * Amperage(mA)
    if let mV = props["Voltage"] as? Int, let mA = props["Amperage"] as? Int {
        let watts = (Double(mV) / 1000.0) * (Double(mA) / 1000.0)
        info.chargeWatts = max(0, watts)   // negative = discharging
    }

    // Adapter max rating
    if let adapter = props["AdapterDetails"] as? [String: Any],
       let watts = adapter["Watts"] as? Int {
        info.adapterWatts = watts
    }

    // Time to full (minutes). 65535 means "still calculating".
    if let t = props["AvgTimeToFull"] as? Int, t >= 0, t < 65535 {
        info.minutesToFull = t
    }

    // Time to empty on battery (minutes). 65535 means "still calculating".
    if let t = props["AvgTimeToEmpty"] as? Int, t >= 0, t < 65535 {
        info.minutesToEmpty = t
    }

    // Battery temperature. IOKit reports it in hundredths of a degree Celsius.
    if let t = props["Temperature"] as? Int, t > 0 {
        info.temperatureC = Double(t) / 100.0
    }

    // Why charging is inhibited, if it is (0 = no inhibit).
    if let charger = props["ChargerData"] as? [String: Any],
       let reason = charger["NotChargingReason"] as? Int {
        info.notChargingReason = reason
    }

    return info
}

func formatTime(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    return String(format: "%d:%02d", h, m)
}

// Battery temperature is read in Celsius; we display it in Fahrenheit.
func fahrenheit(_ celsius: Double) -> Int {
    return Int((celsius * 9 / 5 + 32).rounded())
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer!

    // macOS reports the *currently negotiated* USB-C Power Delivery wattage, which
    // tapers as the battery fills (e.g. a 100 W charger negotiates 20 V × 5 A = 100 W
    // when the battery is low, but drops to 20 V × 1.5 A = 30 W near full). There is no
    // static "nameplate" the OS exposes. So we peak-hold the highest wattage seen this
    // plug-in session to represent the charger's actual capability, persist it so an
    // app restart while still plugged doesn't lose it, and reset on unplug.
    let defaults = UserDefaults.standard
    var peakAdapterWatts = 0

    // Temperature alerting. Fires a system notification once each time the battery
    // crosses `hotThresholdC` (default 35°C; override with
    // `defaults write com.jpert.batterywatts hotThresholdC 40`). A hysteresis band
    // re-arms the alert only after it cools a couple of degrees, so it never spams.
    var hotThresholdC = 35.0
    var wasHot = false

    // Managed charging pulses: a plugged-in battery normally flips between charging and
    // brief idle/discharge (macOS charges in bursts), so a single "not charging" sample
    // is not a real stall. Count consecutive not-charging refreshes and only surface the
    // "⏸ paused" state once it has genuinely stopped for a sustained stretch.
    var notChargingStreak = 0
    let pauseAfterSeconds = 120       // ~2 min continuously not charging = a real pause
    let refreshInterval = 5.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        peakAdapterWatts = defaults.integer(forKey: "peakAdapterWatts")
        if defaults.object(forKey: "hotThresholdC") != nil {
            let t = defaults.double(forKey: "hotThresholdC")
            if t > 0 { hotThresholdC = t }
        }
        // Ask once for permission to post notifications (no-op if run as a bare binary).
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

    func notifyHot(_ tempC: Double) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "BatteryWatts — battery is hot"
        content.body = "Battery reached \(fahrenheit(tempC))°F. macOS may pause charging until it cools down."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "batterywatts-hot", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func refresh() {
        let b = readBattery()

        // Track the charger's peak capability for this plug-in session.
        if b.pluggedIn {
            if b.adapterWatts > peakAdapterWatts {
                peakAdapterWatts = b.adapterWatts
                defaults.set(peakAdapterWatts, forKey: "peakAdapterWatts")
            }
        } else if peakAdapterWatts != 0 {
            peakAdapterWatts = 0
            defaults.removeObject(forKey: "peakAdapterWatts")
        }

        // Debounce charging pulses so brief not-charging troughs don't read as a stall.
        if b.pluggedIn && !b.charging && !b.fullyCharged {
            notChargingStreak += 1
        } else {
            notChargingStreak = 0
        }
        let sustainedPause = Double(notChargingStreak) * refreshInterval >= Double(pauseAfterSeconds)

        // Edge-triggered hot alert: notify once on crossing the threshold, re-arm only
        // after cooling ~2°C below it (hysteresis) so it fires once per heat episode.
        if b.temperatureC > 0 {
            if b.temperatureC >= hotThresholdC && !wasHot {
                wasHot = true
                notifyHot(b.temperatureC)
            } else if wasHot && b.temperatureC < hotThresholdC - 2 {
                wasHot = false
            }
        }

        // Status-bar title: charging watts · charger watts · time to full · battery % · temp
        let title: String
        let chargeW = String(format: "%.0f", b.chargeWatts)
        let chargerW = peakAdapterWatts > 0 ? "\(peakAdapterWatts)" : "—"
        let hot = b.temperatureC >= hotThresholdC // charging tends to throttle/pause when hot
        // Temperature suffix, shown while plugged in (when charging heat is the concern).
        let tempSuffix = b.temperatureC > 0
            ? " · \(hot ? "🌡️" : "")\(fahrenheit(b.temperatureC))°F"
            : ""
        if !b.pluggedIn {
            if b.minutesToEmpty >= 0 {
                title = "🔋 \(b.percent)% · \(formatTime(b.minutesToEmpty)) left"
            } else {
                title = "🔋 \(b.percent)%"
            }
        } else if b.fullyCharged || (b.percent >= 100) {
            title = "⚡ Full · \(b.percent)%\(tempSuffix)"
        } else if !b.charging && sustainedPause {
            // Charging has genuinely stopped for a sustained stretch (thermal hold,
            // optimized charging, etc.) — surface it so a real stall is visible.
            title = "⏸ \(b.percent)% paused\(tempSuffix)"
        } else if !b.charging {
            // Brief not-charging trough within normal pulsed charging — stay calm.
            title = "🔌 \(b.percent)%\(tempSuffix)"
        } else {
            let eta = b.minutesToFull >= 0 ? formatTime(b.minutesToFull) : "--:--"
            title = "⚡ \(chargeW)/\(chargerW)W · \(eta) · \(b.percent)%\(tempSuffix)"
        }
        statusItem.button?.title = title

        // Dropdown detail menu
        let menu = NSMenu()
        if b.pluggedIn {
            if b.fullyCharged {
                menu.addItem(makeInfo("Status: Fully charged"))
            } else if b.charging || b.chargeWatts >= 0.5 {
                menu.addItem(makeInfo(String(format: "Charging battery at: %.1f W", b.chargeWatts)))
            } else if sustainedPause {
                let warm = b.temperatureC >= hotThresholdC ? " (battery warm — likely thermal)" : ""
                menu.addItem(makeInfo("Charging paused\(warm)"))
            } else {
                menu.addItem(makeInfo("Plugged in (holding)"))
            }
            if peakAdapterWatts > 0 {
                menu.addItem(makeInfo("Charger: \(peakAdapterWatts) W"))
            }
            // The live negotiated draw differs from the charger's peak once charging
            // tapers near full — show it so the numbers are transparent.
            if b.adapterWatts > 0 && b.adapterWatts < peakAdapterWatts {
                menu.addItem(makeInfo("Drawing now: \(b.adapterWatts) W (tapers as battery fills)"))
            }
            if b.minutesToFull >= 0 && !b.fullyCharged {
                menu.addItem(makeInfo("Time until full: \(formatTime(b.minutesToFull))"))
            }
        } else {
            menu.addItem(makeInfo("On battery power"))
            if b.minutesToEmpty >= 0 {
                menu.addItem(makeInfo("Time remaining: \(formatTime(b.minutesToEmpty))"))
            } else {
                menu.addItem(makeInfo("Time remaining: calculating…"))
            }
        }
        menu.addItem(makeInfo("Battery: \(b.percent)%"))
        if b.temperatureC > 0 {
            let note = b.temperatureC >= hotThresholdC ? "  ⚠️ warm — charging may pause" : ""
            menu.addItem(makeInfo("Battery temp: \(fahrenheit(b.temperatureC))°F" + note))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit BatteryWatts", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
