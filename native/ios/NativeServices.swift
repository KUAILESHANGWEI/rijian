import Foundation
import UIKit
import UserNotifications
import BackgroundTasks
import UniformTypeIdentifiers
import AVFoundation
import AlarmKit
import ActivityKit
import SwiftUI
import CryptoKit
import AudioToolbox

struct ReminderRequest: Codable, Equatable {
    let key: String
    let title: String
    let time: Double
    let hour: Int?
    let minute: Int?
    let weekdays: [Int]?
    var date: Date { Date(timeIntervalSince1970: time / 1000) }
    var id: UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

@available(iOS 26.0, *)
struct RijianAlarmMetadata: AlarmMetadata { let key: String }

@MainActor
final class NativeReminders: NSObject, UNUserNotificationCenterDelegate {
    private var requests: [ReminderRequest] = []
    private var generation = 0
    private var scheduling = false
    private var player: AVAudioPlayer?
    private var defaultTone: Timer?
    private var playingKey: String?
    var isPreviewing: Bool { playingKey == "music-preview" && player?.isPlaying == true }
    private var alarmMusicURL: URL { soundURL.deletingLastPathComponent().appendingPathComponent("rijian-full-alarm.caf") }
    private var previewURL: URL { soundURL.deletingLastPathComponent().appendingPathComponent("rijian-preview.caf") }
    private var observer: Task<Void, Never>?
    var onChange: (() -> Void)?
    private(set) var status = "尚未开启后台提醒"
    private(set) var enabled = false
    var isPlaying: Bool {
        if player?.isPlaying == true || defaultTone != nil { return true }
        if #available(iOS 26.0, *), let alarms = try? AlarmManager.shared.alarms { return alarms.contains { $0.state == .alerting } }
        return false
    }
    private var soundURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds/rijian-reminder.caf")
    }
    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "native-reminders"), let saved = try? JSONDecoder().decode([ReminderRequest].self, from: data) { requests = saved }
        UNUserNotificationCenter.current().delegate = self
        if #available(iOS 26.0, *) {
            observer = Task { [weak self] in
                for await alarms in AlarmManager.shared.alarmUpdates {
                    guard let self else { return }
                    for alarm in alarms where alarm.state == .alerting {
                        if let item = self.requests.first(where: { $0.id == alarm.id }) {
                            if UIApplication.shared.applicationState == .active && self.playingKey != item.key {
                                try? AlarmManager.shared.stop(id:alarm.id)
                                self.play(title:item.title,key:item.key,force:true)
                            } else { self.markFired(item.key) }
                        }
                    }
                    self.onChange?()
                }
            }
        }
        refresh()
    }
    func refresh() {
        Task {
            if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized {
                enabled = true
                status = "系统闹钟已开启，支持后台与锁屏提醒"
            } else {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                status = enabled ? "系统通知提醒已开启" : "后台提醒权限尚未开启"
            }
            onChange?()
        }
    }
    func authorize() {
        Task {
            do {
                if #available(iOS 26.0, *) { _ = try await AlarmManager.shared.requestAuthorization() }
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge])
                refresh()
                reschedule()
            } catch { status = "提醒授权失败：\(error.localizedDescription)"; onChange?() }
        }
    }
    func update(_ incoming: [ReminderRequest]) {
        let valid = incoming.filter { $0.time.isFinite && !$0.key.isEmpty && !$0.title.isEmpty }.sorted { $0.time < $1.time }
        guard valid != requests else { return }
        requests = Array(valid.prefix(61))
        UserDefaults.standard.set(try? JSONEncoder().encode(requests), forKey: "native-reminders")
        reschedule()
    }
    private func reschedule() {
        generation += 1
        guard !scheduling else { return }
        scheduling = true
        let revision = generation
        let desired = requests.filter { $0.date > Date() }
        Task {
            defer { scheduling = false; if revision != generation { reschedule() } }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("rijian-") }.map(\.identifier))
            if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized {
                let alarms = (try? AlarmManager.shared.alarms) ?? []
                let desiredIDs = Set(desired.map(\.id))
                for alarm in alarms where alarm.state != .alerting && !desiredIDs.contains(alarm.id) { try? AlarmManager.shared.cancel(id: alarm.id) }
                for item in desired {
                    guard revision == generation else { return }
                    if alarms.contains(where: { $0.id == item.id && $0.state == .alerting }) { continue }
                    if alarms.contains(where: { $0.id == item.id }) { try? AlarmManager.shared.cancel(id: item.id) }
                    let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: item.title), stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill"))
                    let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: RijianAlarmMetadata(key: item.key), tintColor: Color(red: 0.27,green: 0.39,blue: 0.33))
                    let sound: AlertConfiguration.AlertSound = FileManager.default.fileExists(atPath: alarmMusicURL.path) ? .named(alarmMusicURL.lastPathComponent) : (FileManager.default.fileExists(atPath: soundURL.path) ? .named(soundURL.lastPathComponent) : .default)
                    do {
                        let schedule: Alarm.Schedule
                        if let days=item.weekdays,!days.isEmpty,let hour=item.hour,let minute=item.minute {
                            let weekdays: [Locale.Weekday] = [.sunday,.monday,.tuesday,.wednesday,.thursday,.friday,.saturday]
                            schedule = .relative(.init(time:.init(hour:hour,minute:minute),repeats:.weekly(days.filter { (0...6).contains($0) }.map { weekdays[$0] })))
                        } else { schedule = .fixed(item.date) }
                        _ = try await AlarmManager.shared.schedule(id:item.id,configuration:.alarm(schedule:schedule,attributes:attributes,sound:sound))
                        if revision != generation { try? AlarmManager.shared.cancel(id: item.id); return }
                    } catch {
                        status = "部分提醒改用系统通知：\(error.localizedDescription)"
                        try? await addNotification(item, generation: revision)
                    }
                }
            } else {
                for item in desired {
                    guard revision == generation else { return }
                    do { try await addNotification(item, generation: revision) }
                    catch { status = "提醒安排失败：\(error.localizedDescription)" }
                }
            }
            onChange?()
        }
    }
    private func addNotification(_ item: ReminderRequest, generation: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = "日缄"
        content.body = item.title
        content.userInfo = ["key":item.key]
        content.sound = FileManager.default.fileExists(atPath: soundURL.path) ? UNNotificationSound(named: UNNotificationSoundName(soundURL.lastPathComponent)) : .default
        if let days=item.weekdays,!days.isEmpty,let hour=item.hour,let minute=item.minute {
            for day in days {
                var date=DateComponents();date.weekday=day+1;date.hour=hour;date.minute=minute
                let request=UNNotificationRequest(identifier:"rijian-\(item.id)-\(day)",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:date,repeats:true))
                try await UNUserNotificationCenter.current().add(request)
            }
        } else {
            let request=UNNotificationRequest(identifier:"rijian-\(item.id)",content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:max(1,item.date.timeIntervalSinceNow),repeats:false))
            try await UNUserNotificationCenter.current().add(request)
        }
    }

    func installMusic(_ data: Data, name: String) throws {
        guard data.count <= 200 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((name as NSString).pathExtension)
        try data.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let input = try AVAudioFile(forReading: inputURL)
        guard input.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: soundURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = soundURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        let shortTemporary = soundURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at:temporary);try? FileManager.default.removeItem(at:shortTemporary) }
        do {
            let settings: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:input.processingFormat.sampleRate,AVNumberOfChannelsKey:input.processingFormat.channelCount,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
            let output = try AVAudioFile(forWriting:temporary,settings:settings)
            let shortOutput = try AVAudioFile(forWriting:shortTemporary,settings:settings)
            guard let samples=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:65536) else { throw CocoaError(.fileReadCorruptFile) }
            let shortFrames=AVAudioFramePosition(input.processingFormat.sampleRate*29)
            while input.framePosition<input.length {
                let offset=input.framePosition
                try input.read(into:samples,frameCount:AVAudioFrameCount(min(65536,input.length-offset)))
                guard samples.frameLength>0 else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(from:samples)
                if offset<shortFrames {
                    samples.frameLength=AVAudioFrameCount(min(Int64(samples.frameLength),shortFrames-offset))
                    try shortOutput.write(from:samples)
                }
            }
        }
        // AlarmKit receives the complete track; only legacy notifications use 29 seconds.
        for (source,destination) in [(temporary,alarmMusicURL),(shortTemporary,soundURL)] {
            if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:source) }
            else { try FileManager.default.moveItem(at:source,to:destination) }
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.none],ofItemAtPath:destination.path)
        }
        // Keep the complete selected track for preview; notification sound remains short.
        let preview = try AVAudioPlayer(data: data)
        guard preview.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try data.write(to: previewURL, options: .atomic)
        reschedule()
    }
    func previewMusic() throws {
        stop()
        let url = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : soundURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Rijian", code: 2, userInfo: [NSLocalizedDescriptionKey:"音乐尚未准备好，请重新上传后试听。"])
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.numberOfLoops = -1
        guard audio.prepareToPlay(), audio.play() else { throw CocoaError(.fileReadCorruptFile) }
        player = audio
        playingKey = "music-preview"
        onChange?()
    }
    func removeMusic() { stop(); try? FileManager.default.removeItem(at: alarmMusicURL); try? FileManager.default.removeItem(at: previewURL); try? FileManager.default.removeItem(at: soundURL); reschedule() }
    func play(title: String, key: String, force: Bool = false) {
        if playingKey == key && isPlaying { return }
        if !force && wasFired(key) { onChange?(); return }
        markFired(key)
        playingKey = key
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let fullTrack = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : soundURL
            if FileManager.default.fileExists(atPath: fullTrack.path) {
                player = try AVAudioPlayer(contentsOf: fullTrack)
                player?.numberOfLoops = -1
                player?.play()
            } else {
                AudioServicesPlayAlertSound(1005)
                defaultTone = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in AudioServicesPlayAlertSound(1005) }
            }
        } catch { status = "音乐播放失败：\(error.localizedDescription)" }
        onChange?()
    }
    func stop() {
        player?.stop(); player = nil
        defaultTone?.invalidate(); defaultTone = nil
        if #available(iOS 26.0, *), let alarms = try? AlarmManager.shared.alarms {
            for alarm in alarms where alarm.state == .alerting { try? AlarmManager.shared.stop(id: alarm.id) }
        }
        playingKey = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }
    private func occurrenceKey(_ key:String)->String {
        guard key.hasPrefix("alarm-") else { return key }
        let date=Calendar.current.startOfDay(for:Date()).timeIntervalSince1970
        let item=requests.first { $0.key == key }
        return "\(key)-\(Int(date))-\(item?.hour ?? -1)-\(item?.minute ?? -1)"
    }
    private func wasFired(_ key: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "fired-reminders") ?? []).contains(occurrenceKey(key)) }
    private func markFired(_ original: String) {
        let key=occurrenceKey(original)
        var keys = UserDefaults.standard.stringArray(forKey: "fired-reminders") ?? []
        if !keys.contains(key) { keys.append(key) }
        UserDefaults.standard.set(Array(keys.suffix(1000)), forKey: "fired-reminders")
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in if let key = response.notification.request.content.userInfo["key"] as? String { self.markFired(key) }; completionHandler() }
    }
}

@MainActor
final class CloudBackupStore {
    static let shared = CloudBackupStore()
    static let taskID = "com.shangweiqiu.rijian.backup"
    var onChange: (() -> Void)?
    private var writing = false
    private var message: String?
    private let defaults = UserDefaults.standard
    var enabled: Bool { defaults.bool(forKey: "backup-enabled") }
    var days: Int { max(1, defaults.integer(forKey: "backup-days")) }
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("latest-backup.json")
    }
    var status: String {
        if let message { return message }
        if let date = defaults.object(forKey: "backup-last") as? Date { return "上次保存：\(date.formatted(date: .numeric,time: .shortened))" }
        return defaults.data(forKey: "backup-folder") == nil ? "尚未选择 iCloud 备份目录" : "备份目录已连接"
    }
    func receiveSnapshot(_ text: String) {
        do {
            let data = Data(text.utf8)
            let value = try JSONSerialization.jsonObject(with: data) as? [String:Any]
            guard value?["events"] is [Any], value?["labels"] is [Any] else { return }
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            backup(force: false)
        } catch { message = "本机备份快照保存失败：\(error.localizedDescription)"; onChange?() }
    }
    func choose(_ folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let ubiquitous = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        guard ubiquitous || folder.path.contains("com~apple~CloudDocs") else {
            throw NSError(domain: "Rijian", code: 1, userInfo: [NSLocalizedDescriptionKey:"请选择 iCloud 云盘中的文件夹"])
        }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "backup-folder")
        defaults.set(true, forKey: "backup-enabled")
        message = nil
        backup(force: true)
        scheduleBackground()
        onChange?()
    }
    func configure(enabled: Bool, days: Int) {
        guard !enabled || defaults.data(forKey: "backup-folder") != nil else { message = "请先选择 iCloud 备份目录"; onChange?(); return }
        defaults.set(enabled, forKey: "backup-enabled")
        defaults.set([1,7,30].contains(days) ? days : 1, forKey: "backup-days")
        message = nil
        scheduleBackground()
        backup(force: false)
        onChange?()
    }
    func backup(force: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !writing else { completion?(false); return }
        guard enabled, let bookmark = defaults.data(forKey: "backup-folder") else { if force { message = "请先选择并启用 iCloud 备份目录"; onChange?() }; completion?(false); return }
        let last = defaults.object(forKey: "backup-last") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Double(days) * 86400 else { completion?(true); return }
        guard let data = try? Data(contentsOf: cacheURL) else { message = "尚无可备份的日子数据"; onChange?(); completion?(false); return }
        writing = true
        message = "正在保存 iCloud 备份…"
        onChange?()
        Task.detached {
            var access = false
            var folder: URL?
            let result: Result<Void, Error>
            do {
                var stale = false
                let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                folder = resolved
                access = resolved.startAccessingSecurityScopedResource()
                let directory = resolved.appendingPathComponent("日缄备份", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let file = directory.appendingPathComponent("日缄-自动备份-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).json")
                var coordinationError: NSError?
                var writeError: Error?
                NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
                    do { try data.write(to: url, options: .atomic) } catch { writeError = error }
                }
                if let error = coordinationError ?? writeError as NSError? { throw error }
                result = .success(())
            } catch { result = .failure(error) }
            if access { folder?.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                self.writing = false
                switch result {
                case .success: self.defaults.set(Date(), forKey: "backup-last"); self.message = "已保存至 iCloud 备份目录，系统将同步文件"
                case .failure(let error): self.message = "备份未完成：\(error.localizedDescription)"
                }
                self.scheduleBackground()
                self.onChange?()
                completion?((try? result.get()) != nil)
            }
        }
    }
    func scheduleBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        guard enabled else { return }
        let last = defaults.object(forKey: "backup-last") as? Date ?? Date()
        let due = last.addingTimeInterval(Double(days) * 86400)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = max(due,Date().addingTimeInterval(900))
        try? BGTaskScheduler.shared.submit(request)
    }
    func runBackground(_ task: BGAppRefreshTask) {
        var finished = false
        task.expirationHandler = { if !finished { finished = true; task.setTaskCompleted(success: false) } }
        backup(force: false) { success in if !finished { finished = true; task.setTaskCompleted(success: success) } }
    }
}
