import Cocoa
import IOKit
import IOKit.ps

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        peakAdapterWatts = defaults.integer(forKey: "peakAdapterWatts")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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

        // Status-bar title: charging watts · charger watts · time to full · battery % · temp
        let title: String
        let chargeW = String(format: "%.0f", b.chargeWatts)
        let chargerW = peakAdapterWatts > 0 ? "\(peakAdapterWatts)" : "—"
        let hot = b.temperatureC >= 35            // charging tends to throttle/pause above ~35°C
        // Temperature suffix, shown while plugged in (when charging heat is the concern).
        let tempSuffix = b.temperatureC > 0
            ? " · \(hot ? "🌡️" : "")\(String(format: "%.0f°C", b.temperatureC))"
            : ""
        if !b.pluggedIn {
            if b.minutesToEmpty >= 0 {
                title = "🔋 \(b.percent)% · \(formatTime(b.minutesToEmpty)) left"
            } else {
                title = "🔋 \(b.percent)%"
            }
        } else if b.fullyCharged || (b.percent >= 100) {
            title = "⚡ Full · \(b.percent)%\(tempSuffix)"
        } else if !b.charging {
            // Plugged in but not charging — charging is paused (thermal hold, optimized
            // charging, etc.). Surface it so a heat-related stall is immediately visible.
            title = "⏸ \(b.percent)% paused\(tempSuffix)"
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
            } else if b.chargeWatts >= 0.5 {
                menu.addItem(makeInfo(String(format: "Charging battery at: %.1f W", b.chargeWatts)))
            } else {
                let warm = b.temperatureC >= 35 ? " (battery warm — likely thermal)" : ""
                menu.addItem(makeInfo("Charging paused\(warm)"))
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
            let f = b.temperatureC * 9 / 5 + 32
            let note = b.temperatureC >= 35 ? "  ⚠️ warm — charging may pause" : ""
            menu.addItem(makeInfo(String(format: "Battery temp: %.0f°C (%.0f°F)", b.temperatureC, f) + note))
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
