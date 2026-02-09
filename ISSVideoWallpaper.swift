import AppKit
import AVFoundation
import QuartzCore

let loopDir  = NSHomeDirectory() + "/.local/share/iss-wallpaper/loops"
let pathA    = loopDir + "/loop_a.mp4"
let pathB    = loopDir + "/loop_b.mp4"
let fadeSecs: CFTimeInterval = 2.0

class Wallpaper: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var root: CALayer!

    // Dual players for crossfade
    var pA = AVQueuePlayer(), pB = AVQueuePlayer()
    var lA: AVPlayerLayer!, lB: AVPlayerLayer!
    var looperA: AVPlayerLooper?, looperB: AVPlayerLooper?

    var active = ""
    var modA = Date.distantPast, modB = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        buildWindow()
        buildPlayers()
        loadExisting()

        // Poll for new loops
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.poll()
        }

        // Resize on display change
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: – Window

    func buildWindow() {
        guard let scr = NSScreen.main else { exit(1) }
        window = NSWindow(
            contentRect: scr.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.ignoresMouseEvents = true

        let v = window.contentView!
        v.wantsLayer = true
        root = v.layer!
        window.orderBack(nil)
    }

    // MARK: – Players

    func buildPlayers() {
        pA.isMuted = true; pB.isMuted = true

        lA = AVPlayerLayer(player: pA)
        lA.videoGravity = .resizeAspectFill
        lA.frame = root.bounds; lA.opacity = 0
        lA.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(lA)

        lB = AVPlayerLayer(player: pB)
        lB.videoGravity = .resizeAspectFill
        lB.frame = root.bounds; lB.opacity = 0
        lB.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(lB)
    }

    // MARK: – Loop management

    func loadExisting() {
        modA = mtime(pathA); modB = mtime(pathB)
        if modA > modB, modA > .distantPast {
            startPlaying(pathA, isA: true, fade: false)
        } else if modB > .distantPast {
            startPlaying(pathB, isA: false, fade: false)
        }
    }

    func poll() {
        let mA = mtime(pathA), mB = mtime(pathB)
        if mA > modA      { modA = mA; startPlaying(pathA, isA: true,  fade: true) }
        else if mB > modB { modB = mB; startPlaying(pathB, isA: false, fade: true) }
    }

    func startPlaying(_ path: String, isA: Bool, fade: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)

        let (np, nl, op, ol): (AVQueuePlayer, AVPlayerLayer, AVQueuePlayer, AVPlayerLayer)
        if isA {
            (np, nl, op, ol) = (pA, lA, pB, lB)
            looperA?.disableLooping(); looperA = nil; np.removeAllItems()
            looperA = AVPlayerLooper(player: np, templateItem: AVPlayerItem(url: url))
            active = "a"
        } else {
            (np, nl, op, ol) = (pB, lB, pA, lA)
            looperB?.disableLooping(); looperB = nil; np.removeAllItems()
            looperB = AVPlayerLooper(player: np, templateItem: AVPlayerItem(url: url))
            active = "b"
        }

        np.play()

        if fade {
            CATransaction.begin()
            CATransaction.setAnimationDuration(fadeSecs)
            CATransaction.setAnimationTimingFunction(.init(name: .easeInEaseOut))
            nl.opacity = 1; ol.opacity = 0
            CATransaction.commit()

            DispatchQueue.main.asyncAfter(deadline: .now() + fadeSecs + 0.5) {
                op.pause(); op.removeAllItems()
            }
        } else {
            nl.opacity = 1; ol.opacity = 0
        }
    }

    // MARK: – Helpers

    @objc func screenChanged() {
        guard let f = NSScreen.main?.frame else { return }
        window.setFrame(f, display: true)
        lA.frame = root.bounds; lB.frame = root.bounds
    }

    func mtime(_ p: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
    }
}

// --- Entry point ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // No dock icon, no menu bar
let delegate = Wallpaper()
app.delegate = delegate
app.run()
