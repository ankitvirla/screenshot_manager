import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let screenshotFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/screenshot", isDirectory: true)
    private let reminderIntervalDefaultsKey = "cleanupReminderInterval"
    private var statusItem: NSStatusItem!
    private var screenshotCountItem: NSMenuItem!
    private var recordingItem: NSMenuItem!
    private var reminderMenuItems: [Int: NSMenuItem] = [:]
    private var activeCapture: Process?
    private var recordingProcess: Process?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var lastScreenshotCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        } catch {
            showError("Couldn't create the screenshot folder", detail: error.localizedDescription)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Screenshot Manager"
        )

        let menu = NSMenu()
        screenshotCountItem = NSMenuItem(title: "Screenshots: 0", action: nil, keyEquivalent: "")
        screenshotCountItem.isEnabled = false
        menu.addItem(screenshotCountItem)
        let cleanupMenuItem = NSMenuItem(title: "Cleanup Reminder", action: nil, keyEquivalent: "")
        let cleanupMenu = NSMenu()
        for (title, interval) in [("Every 10 Screenshots", 10), ("Every 20 Screenshots", 20), ("Off", 0)] {
            let item = NSMenuItem(title: title, action: #selector(setReminderInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            cleanupMenu.addItem(item)
            reminderMenuItems[interval] = item
        }
        cleanupMenuItem.submenu = cleanupMenu
        menu.addItem(cleanupMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Capture Full Screen", action: #selector(captureFullScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Selected Area", action: #selector(captureArea), keyEquivalent: ""))
        recordingItem = NSMenuItem(title: "Start Screen Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(recordingItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Screenshot Folder", action: #selector(openScreenshotFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Screenshot Manager", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        statusItem.menu = menu

        lastScreenshotCount = screenshotCount()
        watchScreenshotFolder()
        checkStorageThreshold()
    }

    func menuWillOpen(_ menu: NSMenu) {
        screenshotCountItem.title = "Screenshots: \(screenshotCount())"
        updateReminderMenuSelection()
    }

    @objc private func captureFullScreen() {
        captureScreenshot(arguments: ["-m", "-x"])
    }

    @objc private func captureArea() {
        captureScreenshot(arguments: ["-i", "-s", "-x"])
    }

    private func captureScreenshot(arguments: [String]) {
        guard activeCapture == nil else { return }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotManager-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [temporaryURL.path]
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.finishScreenshot(process: process, temporaryURL: temporaryURL)
            }
        }

        do {
            try process.run()
            activeCapture = process
        } catch {
            showError("Couldn't start screenshot capture", detail: error.localizedDescription)
        }
    }

    private func finishScreenshot(process: Process, temporaryURL: URL) {
        activeCapture = nil
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return }

        do {
            let imageData = try Data(contentsOf: temporaryURL)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(imageData, forType: .png)

            let timestamp = Self.timestamp()
            let savedURL = uniqueURL(in: screenshotFolder, name: "screenshot_\(timestamp)", extension: "png")
            try FileManager.default.moveItem(at: temporaryURL, to: savedURL)
            checkStorageThreshold()

            FilenameGenerator.suggest(from: imageData) { [weak self] suggestion in
                guard let self else { return }
                guard let suggestion else { return }
                let namedURL = self.uniqueURL(
                    in: self.screenshotFolder,
                    name: "\(suggestion)_\(timestamp)",
                    extension: "png"
                )
                do {
                    try FileManager.default.moveItem(at: savedURL, to: namedURL)
                } catch {
                    self.showError("Screenshot saved, but couldn't apply its name", detail: error.localizedDescription)
                }
            }
        } catch {
            showError("Couldn't save the screenshot", detail: error.localizedDescription)
        }
    }

    @objc private func toggleRecording() {
        if let recordingProcess {
            recordingProcess.interrupt()
            recordingItem.title = "Finishing Screen Recording…"
            recordingItem.isEnabled = false
            return
        }

        let folder = screenshotFolder.appendingPathComponent("recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showError("Couldn't create the recordings folder", detail: error.localizedDescription)
            return
        }

        let outputURL = uniqueURL(in: folder, name: Self.timestamp(), extension: "mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-J", "video", "-x", outputURL.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishRecording(at: outputURL)
            }
        }

        do {
            try process.run()
            recordingProcess = process
            recordingItem.title = "Stop Screen Recording"
            recordingItem.isEnabled = true
        } catch {
            showError("Couldn't start screen recording", detail: error.localizedDescription)
        }
    }

    private func finishRecording(at outputURL: URL) {
        recordingProcess = nil
        recordingItem.title = "Start Screen Recording"
        recordingItem.isEnabled = true
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Screen recording saved"
        alert.informativeText = outputURL.lastPathComponent
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    @objc private func openScreenshotFolder() {
        NSWorkspace.shared.open(screenshotFolder)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func watchScreenshotFolder() {
        let descriptor = open(screenshotFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.checkStorageThreshold()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        folderWatcher = source
    }

    private func screenshotCount() -> Int {
        screenshotSummary().count
    }

    private func screenshotSummary() -> (count: Int, bytes: Int64) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: screenshotFolder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        let totalBytes = images.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (images.count, totalBytes)
    }

    private func checkStorageThreshold() {
        let count = screenshotCount()
        screenshotCountItem?.title = "Screenshots: \(count)"
        let interval = reminderInterval
        guard interval > 0 else {
            lastScreenshotCount = count
            return
        }
        let previousCountWithinInterval = max(0, lastScreenshotCount - 1)
        let nextReminderCount = (previousCountWithinInterval / interval + 1) * interval + 1
        let crossedReminderCount = count > lastScreenshotCount && count >= nextReminderCount
        lastScreenshotCount = count
        guard crossedReminderCount else { return }

        let summary = screenshotSummary()
        let storageSize = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Review your screenshot storage"
        alert.informativeText = "\(summary.count) screenshots are using \(storageSize) in ~/Pictures/screenshot. Consider removing the ones you no longer need."
        alert.addButton(withTitle: "Open Folder")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(screenshotFolder)
        }
    }

    private var reminderInterval: Int {
        guard let storedInterval = UserDefaults.standard.object(forKey: reminderIntervalDefaultsKey) as? Int,
              [0, 10, 20].contains(storedInterval) else { return 10 }
        return storedInterval
    }

    @objc private func setReminderInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(interval, forKey: reminderIntervalDefaultsKey)
        updateReminderMenuSelection()
    }

    private func updateReminderMenuSelection() {
        let selectedInterval = reminderInterval
        for (interval, item) in reminderMenuItems {
            item.state = interval == selectedInterval ? .on : .off
        }
    }

    private func uniqueURL(in folder: URL, name: String, extension fileExtension: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}