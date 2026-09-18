import AppKit
import Foundation

/// The `alarm` subcommand: wait out the lead, make noise, and hold a window up
/// until someone dismisses it. One process now — the sound loop and the window
/// used to be two more.
final class AlarmRunner: NSObject, NSApplicationDelegate {
    private let cfg: Config
    private let title: String
    private let start: Date
    private let url: String

    private var window: AlarmWindow?
    private let loop = SoundLoop()
    private var savedVolume: VolumeSetting?
    private var lockHandle: FileHandle?
    private var primary = false
    private var finished = false
    private var signalSources: [DispatchSourceSignal] = []

    init(cfg: Config, title: String, start: Date, url: String) {
        self.cfg = cfg
        self.title = title
        self.start = start
        self.url = url
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        log("spawned title=\(title) start=\(Int(start.timeIntervalSince1970))", name: "alarm")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.prepare() }
    }

    private func prepare() {
        // The poll spawns up to a minute early; sound exactly lead_seconds before start.
        let wait = start.timeIntervalSinceNow - cfg.leadSeconds
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }

        acquireLock()
        log("ringing primary=\(primary)", name: "alarm")
        wakeDisplay()

        if primary {
            let output = Volume.current()
            if let output, output.muted, !cfg.breakMute {
                // A deliberate mute stands. Raising the level under it would only
                // be heard later, so the output is left untouched and there is
                // nothing to put back.
                log("output is muted and break_mute is off; leaving the volume alone", name: "alarm")
            } else if output != nil {
                savedVolume = output
                Volume.set(level: cfg.volume, muted: false)
            }
            if cfg.speak { speak(cfg.message) }
            if let sound = cfg.resolvedSound {
                if !loop.start(path: sound) {
                    log("could not play \(sound)", name: "alarm")
                }
            } else {
                log("no sound file found", name: "alarm")
            }
        }
        DispatchQueue.main.async { [weak self] in self?.showWindow() }
    }

    private func showWindow() {
        let window = AlarmWindow(meetingURL: url) { [weak self] outcome in
            self?.finish(outcome.rawValue)
        }
        window.show(headline: cfg.message, detail: title)
        self.window = window

        guard cfg.maxAlarmSeconds > 0 else { return }
        let remaining = start.addingTimeInterval(cfg.maxAlarmSeconds).timeIntervalSinceNow
        if remaining <= 0 {
            finish("stopped at max_alarm_seconds")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.finish("stopped at max_alarm_seconds")
            }
        }
    }

    /// Meetings a minute apart put two alarms on screen at once. Only the lock
    /// holder raises the volume and loops the sound.
    private func acquireLock() {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let fd = open(Paths.alarmLock.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            primary = true
            lockHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } else {
            close(fd)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.finish("terminated by signal \(sig)")
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func finish(_ reason: String) {
        if finished { return }
        finished = true
        window?.close()
        window = nil
        loop.stop()
        if let saved = savedVolume,
           let target = volumeRestore(saved: saved, current: Volume.current(),
                                      alarmLevel: cfg.volume) {
            Volume.set(level: target.level, muted: target.muted)
        }
        try? lockHandle?.close()
        lockHandle = nil
        log(reason, name: "alarm")
        exit(0)
    }
}
