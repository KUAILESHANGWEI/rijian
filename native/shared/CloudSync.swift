import Foundation
import CoreData
import CloudKit
import CryptoKit
import WebKit

struct RijianSnapshot {
    var events: [[String:Any]] = []
    var labels: [String] = []
    var alarms: [[String:Any]] = []
    var music: [String:Any]?
    var deletedRecords:Set<String> = []
    init() {}
    init(_ object:[String:Any]) throws {
        guard let events=object["events"] as? [[String:Any]],let labels=object["labels"] as? [String],events.count<=10000,labels.count<=10000 else { throw CocoaError(.fileReadCorruptFile) }
        self.events=events;self.labels=labels;self.alarms=object["alarms"] as? [[String:Any]] ?? [];self.deletedRecords=Set(object["deletedRecords"] as? [String] ?? [])
    }
    var object:[String:Any] { ["events":events,"labels":labels,"alarms":alarms,"deletedRecords":deletedRecords.sorted()] }
    func records() throws -> [String:Data] {
        var result:[String:Data]=[:]
        for (kind,items) in [("event",events),("alarm",alarms)] {
            for item in items { guard let id=item["id"] as? String,!id.isEmpty else { throw CocoaError(.fileReadCorruptFile) };result[kind+":"+id]=try JSONSerialization.data(withJSONObject:item,options:.sortedKeys) }
        }
        for (index,name) in labels.enumerated() { result["label:"+name]=try JSONSerialization.data(withJSONObject:["name":name,"order":index],options:.sortedKeys) }
        if let music { result["music:current"]=try JSONSerialization.data(withJSONObject:music,options:.sortedKeys) }
        return result
    }
    static func decode(_ records:[String:Data]) throws -> RijianSnapshot {
        var snapshot=RijianSnapshot();var labels:[(String,Int)]=[]
        for (key,data) in records {
            guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { continue }
            if key.hasPrefix("event:") { snapshot.events.append(value) }
            else if key.hasPrefix("alarm:") { snapshot.alarms.append(value) }
            else if key.hasPrefix("label:"),let name=value["name"] as? String { labels.append((name,value["order"] as? Int ?? 0)) }
            else if key=="music:current" { snapshot.music=value }
        }
        snapshot.events.sort { ($0["id"] as? String ?? "")<($1["id"] as? String ?? "") }
        snapshot.alarms.sort { ($0["id"] as? String ?? "")<($1["id"] as? String ?? "") }
        snapshot.labels=labels.sorted { $0.1 == $1.1 ? $0.0<$1.0 : $0.1<$1.1 }.map { $0.0 }
        return snapshot
    }
}
@MainActor final class RijianCloudStore {
    static let containerID = "iCloud.com.shangweiqiu.rijian"
    let container: NSPersistentCloudKitContainer
    private let directory: URL
    private var observers: [NSObjectProtocol] = []
    private var cachedRecords: [String: Data] = [:]
    private var cachedDeleted:Set<String> = []
    private var cachedSnapshot: RijianSnapshot?
    private var publishTask: Task<Void, Never>?
    var onChange: ((RijianSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var status = "iCloud 正在连接"
    private(set) var initialImportCompleted=false
    private(set) var accountFingerprint=""

    init(directory: URL, cloudEnabled: Bool) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entity = NSEntityDescription()
        entity.name = "RijianEntry"
        entity.managedObjectClassName = "NSManagedObject"
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
        let payload = attribute("payload", .binaryDataAttributeType)
        payload.allowsExternalBinaryDataStorage = true
        let deleted = attribute("isTombstone", .booleanAttributeType)
        deleted.defaultValue = false
        entity.properties = [attribute("logicalID", .stringAttributeType), payload, attribute("modifiedAt", .dateAttributeType), deleted]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        container = NSPersistentCloudKitContainer(name: "RijianLibrary", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("RijianCloud.sqlite"))
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloudEnabled { description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerID) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.transactionAuthor = "Rijian"
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                guard let self else { return }
                if event.endDate == nil { self.setStatus("iCloud 正在同步") }
                else if event.succeeded { if event.type == .import { self.initialImportCompleted=true };self.setStatus("iCloud 已同步"); self.schedulePublish() }
                else { self.setStatus("iCloud 同步暂不可用，已保存在本机");if let error=event.error as NSError? { print("Rijian CloudKit error",event.type.rawValue,error.domain,error.code) } }
            }
        })
        if cloudEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cloud=CKContainer(identifier:Self.containerID)
                do {
                    let account=try await cloud.accountStatus()
                    if account == .available {
                        if self.status != "iCloud 已同步" { self.setStatus("iCloud 正在同步") }
                        if let record=try? await cloud.userRecordID() {
                            self.accountFingerprint=SHA256.hash(data:Data(record.recordName.utf8)).map { String(format:"%02x",$0) }.joined()
                            self.onStatus?(self.status)
                        }
                    } else { self.setStatus("请在系统设置中登录 iCloud") }
                } catch { self.setStatus("iCloud 暂不可用，数据已保存在本机") }
            }
        } else { setStatus("本机保存") }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func setStatus(_ value: String) { status = value; onStatus?(value) }

    private func rows() throws -> [String: NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "RijianEntry")
        request.shouldRefreshRefetchedObjects=true
        request.predicate = NSPredicate(format: "NOT (logicalID BEGINSWITH %@)", "blob:")
        let fetched = try container.viewContext.fetch(request)
        var result: [String: NSManagedObject] = [:]
        for row in fetched {
            guard let id = row.value(forKey: "logicalID") as? String else { continue }
            if let previous = result[id] {
                let oldDate = previous.value(forKey: "modifiedAt") as? Date ?? .distantPast
                let newDate = row.value(forKey: "modifiedAt") as? Date ?? .distantPast
                let oldHash = SHA256.hash(data: previous.value(forKey: "payload") as? Data ?? Data()).description
                let newHash = SHA256.hash(data: row.value(forKey: "payload") as? Data ?? Data()).description
                if newDate < oldDate || (newDate == oldDate && newHash <= oldHash) { continue }
            }
            result[id] = row
        }
        return result
    }

    func snapshot() throws -> RijianSnapshot {
        let current=try rows()
        let active = current.filter { !($0.value.value(forKey: "isTombstone") as? Bool ?? false) }
        let deleted=Set(current.filter { $0.value.value(forKey:"isTombstone") as? Bool == true }.keys)
        let records = active.compactMapValues { $0.value(forKey: "payload") as? Data }
        if let cachedSnapshot, records == cachedRecords,deleted == cachedDeleted { return cachedSnapshot }
        var result = try RijianSnapshot.decode(records);result.deletedRecords=deleted
        cachedRecords = records;cachedDeleted=deleted
        cachedSnapshot = result
        return result
    }

    /// Compare only edits made by this editor against its last displayed snapshot.
    /// Remote-only entries are retained even when a local editor has stale data.
    func commit(baseline: RijianSnapshot, next: RijianSnapshot) throws -> RijianSnapshot {
        let before = try baseline.records().filter { !$0.key.hasPrefix("music:") }, after = try next.records().filter { !$0.key.hasPrefix("music:") }
        let current = try rows()
        let maximumDate = current.values.compactMap { $0.value(forKey: "modifiedAt") as? Date }.max() ?? .distantPast
        let date = max(Date(), maximumDate.addingTimeInterval(0.001))
        do {
            for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
                let row = current[id] ?? NSEntityDescription.insertNewObject(forEntityName: "RijianEntry", into: container.viewContext)
                row.setValue(id, forKey: "logicalID")
                if let data = after[id] {
                    if row.value(forKey:"isTombstone") as? Bool == true && !baseline.deletedRecords.contains(id) { continue }
                    let merged = try mergeFields(base: before[id], local: data, remote: row.value(forKey: "payload") as? Data)
                    row.setValue(merged, forKey: "payload")
                    row.setValue(false, forKey: "isTombstone")
                } else { row.setValue(true, forKey: "isTombstone"); row.setValue(nil, forKey: "payload") }
                row.setValue(date, forKey: "modifiedAt")
            }
            if container.viewContext.hasChanges { try container.viewContext.save() }
        } catch { container.viewContext.rollback(); throw error }
        let result = try snapshot()
        onChange?(result)
        return result
    }

    func hasMusicDecision() throws -> Bool { try rows()["music:current"] != nil }
    func setMusic(_ metadata:[String:Any]?) throws {
        let current=try rows()
        let row=current["music:current"] ?? NSEntityDescription.insertNewObject(forEntityName:"RijianEntry",into:container.viewContext)
        row.setValue("music:current",forKey:"logicalID")
        row.setValue(try metadata.map { try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys) },forKey:"payload")
        row.setValue(metadata == nil,forKey:"isTombstone")
        let maximum=current.values.compactMap { $0.value(forKey:"modifiedAt") as? Date }.max() ?? .distantPast
        row.setValue(max(Date(),maximum.addingTimeInterval(0.001)),forKey:"modifiedAt")
        do { try container.viewContext.save() } catch { container.viewContext.rollback();throw error }
        onChange?(try snapshot())
    }
    private func mergeFields(base: Data?, local: Data, remote: Data?) throws -> Data {
        guard let base, let remote, remote != base,
              let old = try JSONSerialization.jsonObject(with: base) as? [String: Any],
              let edited = try JSONSerialization.jsonObject(with: local) as? [String: Any],
              var merged = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else { return local }
        func data(_ value: Any?) throws -> Data { try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed]) }
        var changed = try Set(old.keys).union(edited.keys).filter { try data(old[$0]) != data(edited[$0]) }
        if changed.contains("body") || changed.contains("content") { changed.formUnion(["body", "content"]) }
        for key in changed { merged[key] = edited[key] }
        return try JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        container.viewContext.refreshAllObjects()
        do { onChange?(try snapshot()) }
        catch { setStatus("无法读取本机资料库") }
    }
}

/// Immutable binary pieces keep attachments out of JSON snapshots and web messages.
final class BinaryAttachments: @unchecked Sendable {
    static let chunkSize = 8 * 1024 * 1024
    private let container: NSPersistentContainer
    let cacheDirectory: URL

    init(container: NSPersistentContainer, directory: URL) {
        self.container = container
        cacheDirectory = directory.appendingPathComponent("AttachmentCache", isDirectory: true)
    }

    private static func key(_ version: String, _ index: Int) -> String { "blob:\(version):\(index)" }

    func storeFile(at url: URL, metadata: [String: Any]) async throws -> [String: Any] {
        let context = container.newBackgroundContext()
        return try await context.perform {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let version = UUID().uuidString
            var digest = SHA256(), size = 0, count = 0
            do {
                while true {
                    let length = try autoreleasepool { () throws -> Int in
                        guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else { return 0 }
                        try Task.checkCancellation()
                        digest.update(data: data)
                        size += data.count
                        let row = NSEntityDescription.insertNewObject(forEntityName: "RijianEntry", into: context)
                        row.setValue(Self.key(version, count), forKey: "logicalID")
                        row.setValue(data, forKey: "payload")
                        row.setValue(false, forKey: "isTombstone")
                        row.setValue(Date(), forKey: "modifiedAt")
                        try context.save()
                        context.reset()
                        count += 1
                        return data.count
                    }
                    if length == 0 { break }
                }
                guard size == metadata["size"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
                var result = metadata
                result.removeValue(forKey: "data")
                result.removeValue(forKey: "native")
                result.removeValue(forKey: "thumbnail")
                result["storage"] = "chunks-v1"
                result["contentVersion"] = version
                result["chunkCount"] = count
                result["sha256"] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                return result
            } catch {
                context.rollback()
                try? Self.discard(version: version, context: context)
                throw error
            }
        }
    }

    func materialize(_ metadata: [String: Any]) async throws -> URL {
        guard let version = metadata["contentVersion"] as? String, UUID(uuidString: version) != nil,
              let count = metadata["chunkCount"] as? Int, count >= 0,
              let expectedSize = metadata["size"] as? Int, expectedSize >= 0,
              let expectedHash = metadata["sha256"] as? String,
              count == (expectedSize + Self.chunkSize - 1) / Self.chunkSize else { throw CocoaError(.fileReadCorruptFile) }
        let context = container.newBackgroundContext()
        let directory = cacheDirectory.appendingPathComponent(version, isDirectory: true)
        return try await context.perform {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = URL(fileURLWithPath: metadata["name"] as? String ?? "file").lastPathComponent
            guard name != ".", name != "..", !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                if values.fileSize == expectedSize { return destination }
            }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
            var hash = SHA256(), size = 0
            for index in 0..<count {
                try autoreleasepool {
                try Task.checkCancellation()
                let request = NSFetchRequest<NSManagedObject>(entityName: "RijianEntry")
                request.predicate = NSPredicate(format: "logicalID == %@", Self.key(version, index))
                request.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
                guard let row = try context.fetch(request).first,
                      !(row.value(forKey: "isTombstone") as? Bool ?? false),
                      let data = row.value(forKey: "payload") as? Data else {
                    throw NSError(domain: "ShiyeAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件正在从 iCloud 下载，请稍后重试。"])
                }
                let length = min(Self.chunkSize, expectedSize - size)
                guard data.count == length else { throw CocoaError(.fileReadCorruptFile) }
                hash.update(data: data)
                try output.write(contentsOf: data)
                size += data.count
                context.reset()
                }
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard size == expectedSize, actual == expectedHash else { throw CocoaError(.fileReadCorruptFile) }
            try output.synchronize()
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
    }

    func discard(_ metadata: [String: Any]) async throws {
        guard let version = metadata["contentVersion"] as? String, UUID(uuidString: version) != nil else { return }
        let context = container.newBackgroundContext()
        try await context.perform { try Self.discard(version: version, context: context) }
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(version, isDirectory: true))
    }

    private static func discard(version: String, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "RijianEntry")
        request.predicate = NSPredicate(format: "logicalID BEGINSWITH %@", "blob:\(version):")
        for row in try context.fetch(request) {
            row.setValue(nil, forKey: "payload")
            row.setValue(true, forKey: "isTombstone")
            row.setValue(Date(), forKey: "modifiedAt")
        }
        if context.hasChanges { try context.save() }
        context.reset()
    }
}

@MainActor final class RijianCloudSession {
    static let shared:Result<RijianCloudSession,Error> = Result {
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        #if os(macOS)
        let directory=support.appendingPathComponent("日缄/CloudKit",isDirectory:true)
        #else
        let directory=support.appendingPathComponent("RijianCloud",isDirectory:true)
        #endif
        return try RijianCloudSession(directory:directory)
    }
    var onSnapshot:((RijianSnapshot)->Void)?
    let store:RijianCloudStore
    let attachments:BinaryAttachments
    weak var web:WKWebView?
    var onMusic:((URL?,String?) throws -> Void)?
    private let diagnosticURL:URL
    private let seedURL:URL
    private var seeding=false
    private var pendingCommit:(snapshot:String,base:[String:Any]?)?
    private var ready=false
    private var appliedMusic:String?
    private var desiredMusic:String?
    private var musicTask:Task<Void,Never>?
    private var localMusicHash:String?
    private var refreshing=false
    private var uploadsInFlight=0
    private var musicRevision=0
    var status:String { store.status }
    init(directory:URL,cloudEnabled:Bool=true) throws {
        diagnosticURL=directory.appendingPathComponent("sync-status.json")
        seedURL=directory.appendingPathComponent("pending-music-seed")
        store=try RijianCloudStore(directory:directory,cloudEnabled:cloudEnabled)
        attachments=BinaryAttachments(container:store.container,directory:directory)
        localMusicHash=UserDefaults.standard.string(forKey:"rijian-cloud-uploaded-music-hash")
        appliedMusic=UserDefaults.standard.string(forKey:"rijian-cloud-applied-music")
        store.onChange={ [weak self] snapshot in self?.send(snapshot) }
        store.onStatus={ [weak self] _ in self?.sendStatus();self?.attemptMusicSeed();self?.flushPendingCommit() }
    }
    private func flushPendingCommit() {
        guard store.initialImportCompleted,let pending=pendingCommit else { return };pendingCommit=nil
        receive(snapshot:pending.snapshot,base:pending.base)
    }
    func receive(snapshot:String,base:[String:Any]?) {
        guard store.initialImportCompleted else { pendingCommit=(snapshot,base);sendStatus();return }
        do {
            guard let value=try JSONSerialization.jsonObject(with:Data(snapshot.utf8)) as? [String:Any] else { return }
            let next=try RijianSnapshot(value)
            let previous=try base.map { try RijianSnapshot($0) } ?? RijianSnapshot()
            ready=true
            _ = try store.commit(baseline:previous,next:next)
            sendStatus()
        } catch { sendError("同步写入失败，原本机数据保留：\(error.localizedDescription)") }
    }
    func refresh() { guard ready else { return };do { send(try store.snapshot());sendStatus() } catch { sendError("无法读取同步资料库") } }
    func hasMusicDecision()->Bool { (try? store.hasMusicDecision()) ?? false }
    func queueMigrationMusic(_ url:URL,name:String) throws {
        guard !hasMusicDecision() else { return }
        try Data(contentsOf:url).write(to:seedURL,options:.atomic)
        UserDefaults.standard.set(name,forKey:"rijian-pending-music-name")
        attemptMusicSeed()
    }
    private func attemptMusicSeed() {
        guard store.initialImportCompleted,!seeding,FileManager.default.fileExists(atPath:seedURL.path) else { return }
        if hasMusicDecision() { try? FileManager.default.removeItem(at:seedURL);return }
        seeding=true
        Task { [weak self] in
            guard let self else { return };defer { self.seeding=false }
            do { try await self.uploadMusic(self.seedURL,name:UserDefaults.standard.string(forKey:"rijian-pending-music-name") ?? "提醒音乐");try? FileManager.default.removeItem(at:self.seedURL) }
            catch { self.sendError("音乐已保存在本机，稍后继续同步") }
        }
    }
    func uploadMusic(_ url:URL,name:String) async throws {
        if url != seedURL { try? FileManager.default.removeItem(at:seedURL) }
        musicRevision += 1;let revision=musicRevision
        uploadsInFlight += 1;defer { uploadsInFlight -= 1;if uploadsInFlight==0 { refresh() } }
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
        var hash=SHA256();var size=0
        while let part=try handle.read(upToCount:1024*1024),!part.isEmpty { hash.update(data:part);size+=part.count }
        let digest=hash.finalize().map { String(format:"%02x",$0) }.joined()
        if let metadata=try store.snapshot().music,metadata["sha256"] as? String==digest { return }
        let metadata=try await attachments.storeFile(at:url,metadata:["name":name,"size":size])
        guard revision==musicRevision else { try? await attachments.discard(metadata);return }
        appliedMusic=metadata["contentVersion"] as? String
        UserDefaults.standard.set(appliedMusic,forKey:"rijian-cloud-applied-music")
        localMusicHash=digest;UserDefaults.standard.set(digest,forKey:"rijian-cloud-uploaded-music-hash")
        let previous=try store.snapshot().music
        try store.setMusic(metadata)
        if let previous,previous["contentVersion"] as? String != metadata["contentVersion"] as? String { try? await attachments.discard(previous) }
    }
    func removeMusic() {
        musicRevision += 1
        try? FileManager.default.removeItem(at:seedURL)
        do {
            let previous=try store.snapshot().music
            try store.setMusic(nil)
            if let previous { Task { try? await attachments.discard(previous) } }
        } catch { sendError("音乐删除同步失败") }
    }
    private func send(_ snapshot:RijianSnapshot) {
        onSnapshot?(snapshot)
        if ready { evaluate("window.rijianCloudReceive",snapshot.object) }
        guard uploadsInFlight==0 else { return }
        guard let metadata=snapshot.music,let version=metadata["contentVersion"] as? String else {
            desiredMusic=nil
            if hasMusicDecision() {
                if appliedMusic != "deleted" {
                    do { try onMusic?(nil,nil);appliedMusic="deleted";UserDefaults.standard.set("deleted",forKey:"rijian-cloud-applied-music") }
                    catch { sendError("本机音乐移除失败") }
                }
                evaluate("window.rijianCloudMusicChanged",NSNull())
            }
            return
        }
        desiredMusic=version
        if appliedMusic==version { evaluate("window.rijianCloudMusicChanged",["name":metadata["name"] as? String ?? "提醒音乐"]);return }
        guard musicTask==nil else { return }
        musicTask=Task { [weak self] in
            guard let self else { return }
            defer { self.musicTask=nil;if self.desiredMusic != version { self.refresh() } }
            do {
                let file=try await self.attachments.materialize(metadata)
                guard self.desiredMusic==version else { return }
                try self.onMusic?(file,metadata["name"] as? String)
                self.appliedMusic=version;UserDefaults.standard.set(version,forKey:"rijian-cloud-applied-music")
                self.evaluate("window.rijianCloudMusicChanged",["name":metadata["name"] as? String ?? "提醒音乐"]);self.sendStatus()
            } catch { self.sendError("提醒音乐正在下载，日子与闹钟仍可同步");DispatchQueue.main.asyncAfter(deadline:.now()+3){ [weak self] in self?.refresh() } }
        }
    }
    private func evaluate(_ function:String,_ value:Any) {
        guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys]),let json=String(data:data,encoding:.utf8) else { return }
        web?.evaluateJavaScript("\(function)?.(\(json))",completionHandler:nil)
    }
    func sendStatus() {
        evaluate("window.rijianCloudStatus",store.status)
        if let snapshot=try? store.snapshot() {
            let value:[String:Any] = ["status":store.status,"events":snapshot.events.count,"alarms":snapshot.alarms.count,"labels":snapshot.labels.count,"music":snapshot.music != nil,"musicReady":snapshot.music != nil && appliedMusic != nil,"updatedAt":Date().timeIntervalSince1970,"accountFingerprint":store.accountFingerprint,"qaRecords":snapshot.events.filter { ($0["title"] as? String ?? "").hasPrefix("日缄同步验证 ") }.map { ["id":$0["id"] ?? "","title":$0["title"] ?? "","notes":$0["notes"] ?? ""] },"musicVersion":snapshot.music?["contentVersion"] ?? ""]
            if let data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) { try? data.write(to:diagnosticURL,options:.atomic) }
        }
    }
    private func sendError(_ text:String) { evaluate("window.rijianCloudStatus",text) }
}
