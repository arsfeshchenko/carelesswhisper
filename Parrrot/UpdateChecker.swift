import AppKit
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "UpdateChecker")

final class UpdateChecker: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateChecker()

    private let repo = "arsfeshchenko/carelesswhisper"
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedAppURL: URL?

    // UI
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var actionButton: NSButton?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Public

    static func check(silent: Bool = false) {
        shared.checkForUpdate(silent: silent)
    }

    // MARK: - Check

    private func checkForUpdate(silent: Bool) {
        let urlStr = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    log.error("Update check failed: \(error.localizedDescription)")
                    if !silent { self.showError("Could not check for updates.\n\(error.localizedDescription)") }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent { self.showError("Could not parse update info.") }
                    return
                }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

                guard self.isNewer(remote: remote, local: local) else {
                    if !silent { self.showUpToDate() }
                    return
                }

                // Find .zip asset in release
                if let assets = json["assets"] as? [[String: Any]],
                   let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                   let downloadURL = zipAsset["browser_download_url"] as? String {
                    self.promptAndDownload(version: remote, url: downloadURL)
                } else if let htmlURL = json["html_url"] as? String {
                    self.showFallback(version: remote, url: htmlURL)
                }
            }
        }.resume()
    }

    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Download

    private func promptAndDownload(version: String, url: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        alert.informativeText = "Version \(version) is available (you have \(current)). Download and install?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let downloadURL = URL(string: url) else { return }
        showProgressWindow(version: version)
        downloadTask = session.downloadTask(with: downloadURL)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressBar?.doubleValue = pct * 100
        let mb = Double(totalBytesWritten) / 1_000_000
        statusLabel?.stringValue = String(format: "Downloading... %.1f MB (%d%%)", mb, Int(pct * 100))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        statusLabel?.stringValue = "Extracting..."
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)

        let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent("CarelessWhisper-update.zip")
        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("CarelessWhisper-update")

        try? FileManager.default.removeItem(at: tmpZip)
        try? FileManager.default.removeItem(at: extractDir)

        do {
            try FileManager.default.moveItem(at: location, to: tmpZip)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-xk", tmpZip.path, extractDir.path]
            try proc.run()
            proc.waitUntilExit()

            guard proc.terminationStatus == 0,
                  let appName = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
                    .first(where: { $0.hasSuffix(".app") }) else {
                throw NSError(domain: "UpdateChecker", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not extract update"])
            }

            downloadedAppURL = extractDir.appendingPathComponent(appName)

            progressBar?.isIndeterminate = false
            progressBar?.doubleValue = 100
            statusLabel?.stringValue = "Ready to install"
            actionButton?.title = "Relaunch to Install"
            actionButton?.action = #selector(relaunchToInstall)
            actionButton?.isEnabled = true
        } catch {
            log.error("Extract failed: \(error.localizedDescription)")
            statusLabel?.stringValue = "Error: \(error.localizedDescription)"
            actionButton?.title = "Close"
            actionButton?.action = #selector(closeWindow)
            actionButton?.isEnabled = true
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        log.error("Download failed: \(error.localizedDescription)")
        progressBar?.isIndeterminate = false
        statusLabel?.stringValue = "Download failed: \(error.localizedDescription)"
        actionButton?.title = "Close"
        actionButton?.action = #selector(closeWindow)
        actionButton?.isEnabled = true
    }

    // MARK: - Install & Relaunch

    @objc private func relaunchToInstall() {
        guard let newApp = downloadedAppURL else { return }
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // Shell script: wait for current app to quit, replace, relaunch
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(appPath)"
        mv "\(newApp.path)" "\(appPath)"
        open "\(appPath)"
        """

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("cw_update.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try? proc.run()

        NSApp.terminate(nil)
    }

    // MARK: - Progress Window

    private func showProgressWindow(version: String) {
        NSApp.activate(ignoringOtherApps: true)

        let w: CGFloat = 340
        let h: CGFloat = 120
        let frame = NSRect(x: 0, y: 0, width: w, height: h)

        let win = NSPanel(contentRect: frame,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        win.title = "Updating CarelessWhisper"
        win.center()
        win.isReleasedWhenClosed = false

        let content = win.contentView!

        let label = NSTextField(labelWithString: "Downloading...")
        label.frame = NSRect(x: 20, y: h - 40, width: w - 40, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        content.addSubview(label)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: h - 70, width: w - 40, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = false
        bar.startAnimation(nil)
        content.addSubview(bar)

        let btn = NSButton(frame: NSRect(x: w - 120, y: 10, width: 100, height: 32))
        btn.title = "Cancel"
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = #selector(cancelDownload)
        content.addSubview(btn)

        self.statusLabel = label
        self.progressBar = bar
        self.actionButton = btn
        self.window = win

        win.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        closeWindow()
    }

    @objc private func closeWindow() {
        window?.close()
        window = nil
    }

    // MARK: - Simple Alerts

    private func showFallback(version: String, url: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        alert.informativeText = "Version \(version) is available (you have \(current)).\nNo automatic download available — opening release page."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    private func showUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        alert.informativeText = "Version \(current) is the latest."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
