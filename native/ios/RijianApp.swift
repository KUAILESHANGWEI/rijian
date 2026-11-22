import UIKit
import WebKit
import Network
import BackgroundTasks
import UniformTypeIdentifiers

final class LocalAppServer {
    private let listener: NWListener
    private let root: URL
    private let queue = DispatchQueue(label: "rijian.local-assets")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(root: URL) throws {
        self.root = root
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 24716)
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            print("RIJIAN listener", state)
            switch state {
            case .ready: DispatchQueue.main.async { self?.onReady?() }
            case .failed(let error): DispatchQueue.main.async { self?.onFailure?(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.connections.removeValue(forKey: id) }
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: self.queue)
            self.receive(connection, collected: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = collected
            request.append(data ?? Data())
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if error != nil || complete || request.count > 16384 {
                connection.cancel()
            } else { self.receive(connection, collected: request) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        print("RIJIAN request received")
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { connection.cancel(); return }
        let path = String(parts[1]).components(separatedBy: "?").first?.removingPercentEncoding ?? "/"
        let file = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst())).standardizedFileURL
        let allowed = file.path.hasPrefix(root.standardizedFileURL.path + "/")
        let data = allowed ? try? Data(contentsOf: file) : nil
        let body = data ?? Data("Not Found".utf8)
        let mime = ["html":"text/html; charset=utf-8","js":"application/javascript; charset=utf-8","css":"text/css; charset=utf-8","json":"application/json","png":"image/png"][file.pathExtension] ?? "application/octet-stream"
        let header = "HTTP/1.1 \(data == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    deinit { listener.cancel(); connections.values.forEach { $0.cancel() } }
}

final class AppViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, UIDocumentPickerDelegate {
    private var cloudSession:RijianCloudSession?
    private let musicUpload = MusicUpload()
    private var server: LocalAppServer?
    private var webView: WKWebView!
    private let status = UILabel()
    private lazy var reminders: NativeReminders = {
        let engine = NativeReminders.shared
        engine.onChange = { [weak self] in self?.emitNativeStatus() }
        return engine
    }()
    private let backups = CloudBackupStore.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        backups.onChange = { [weak self] in self?.emitNativeStatus() }
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        view.backgroundColor = UIColor(red: 247/255, green: 245/255, blue: 239/255, alpha: 1)
        let controller = WKUserContentController()
        do {
            cloudSession=try RijianCloudSession.shared.get()
            let decision=cloudSession?.hasMusicDecision() == true
            controller.addUserScript(WKUserScript(source:"window.rijianCloudAvailable=true;window.rijianCloudMusicDecision=\(decision);",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        } catch { print("Rijian CloudKit unavailable",error) }

        controller.add(self, name: "rijian")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        cloudSession?.web=webView
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        status.numberOfLines = 0
        status.textAlignment = .center
        status.text = "正在打开日缄…"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85)
        ])
        do {
            guard let root = Bundle.main.url(forResource: "Web", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            server = try LocalAppServer(root: root)
            server?.onReady = { [weak self] in self?.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:24716/index.html")!)) }
            server?.onFailure = { [weak self] message in self?.status.text = "打开失败，请重新启动 App。\n\(message)" }
            server?.start()
        } catch { status.text = "打开失败，资源无法读取。" }
    }
    private var startedLockscreenTest = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.isHidden = true; emitNativeStatus()
        if CommandLine.arguments.contains("--lockscreen-test") && !startedLockscreenTest {
            startedLockscreenTest = true
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
                self?.webView.evaluateJavaScript("document.querySelector('#countdown').click();document.querySelector('#timer-hours').value=0;document.querySelector('#timer-minutes').value=1;document.querySelector('#timer-seconds').value=0;document.querySelector('#timer-form').dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#timer-form').requestSubmit();",completionHandler:nil)
            }
        }
    }
    @objc private func becameActive() {
        reminders.refresh()
        cloudSession?.refresh()
        backups.backup(force: false)
        backups.scheduleBackground()
        emitNativeStatus()
    }
    private func emitNativeStatus() {
        guard isViewLoaded else { return }
        let payload: [String:Any] = ["reminderStatus":reminders.status,"remindersEnabled":reminders.enabled,"playing":reminders.isPlaying,"previewing":reminders.isPreviewing,"backupStatus":backups.status,"backupDays":backups.days,"backupEnabled":backups.enabled]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.rijianNativeStatus?.(\(json));", completionHandler: nil)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let folder = urls.first else { return }
        do { try backups.choose(folder) }
        catch { showAlert(error.localizedDescription) }
        emitNativeStatus()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("RIJIAN navigation failed", error)
        status.text = "打开失败，请重新启动 App。"
        status.isHidden = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.host == "127.0.0.1" && url.port == 24716 || url.scheme == "blob" || url.scheme == "about" { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              let data = message.body as? [String: Any], let action = data["action"] as? String else { return }
        switch action {
        case "status": reminders.refresh(); emitNativeStatus(); return
        case "requestReminders": reminders.authorize(); return
        case "cloudRefresh":cloudSession?.refresh();return
        case "sync":
            if let snapshot=data["snapshot"] as? String { cloudSession?.receive(snapshot:snapshot,base:data["cloudBase"] as? [String:Any]) }
            if let snapshot = data["snapshot"] as? String { backups.receiveSnapshot(snapshot) }
            if let values = data["requests"], let encoded = try? JSONSerialization.data(withJSONObject: values), let requests = try? JSONDecoder().decode([ReminderRequest].self, from: encoded) { reminders.update(requests) }
            return
        case "chooseBackupFolder":
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.title = "选择 iCloud 云盘备份目录"
            present(picker, animated: true)
            return
        case "configureBackup": backups.configure(enabled: data["enabled"] as? Bool ?? false, days: data["days"] as? Int ?? 1); return
        case "backupNow": backups.backup(force: true); return
        case "musicChunk":
            var failure: String? = nil
            do {
                if let url=try musicUpload.receive(data) {
                    defer { try? FileManager.default.removeItem(at:url) }
                    let isMigration=data["migration"] as? Bool == true
                    if !isMigration || cloudSession?.hasMusicDecision() != true {
                        try reminders.installMusic(Data(contentsOf:url),name:data["name"] as? String ?? "music")
                        if let cloudSession {
                            let saved=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                            try FileManager.default.copyItem(at:url,to:saved)
                            Task { defer { try? FileManager.default.removeItem(at:saved) };do { if isMigration { try cloudSession.queueMigrationMusic(saved,name:data["name"] as? String ?? "music") } else { try await cloudSession.uploadMusic(saved,name:data["name"] as? String ?? "music") } } catch { print("Music sync failed",error) } }
                        }
                    }
                }
            } catch { failure=error.localizedDescription }
            if let callback=data["callback"] as? String,let json=try? JSONSerialization.data(withJSONObject:[callback,failure as Any? ?? NSNull()]),let args=String(data:json,encoding:.utf8) {
                webView.evaluateJavaScript("window.rijianNativeMusicResult?.(...\(args))",completionHandler:nil)
            }
        case "music":
            if let encoded = data["data"] as? String, let bytes = Data(base64Encoded: encoded) {
                do { try reminders.installMusic(bytes, name: data["name"] as? String ?? "music") }
                catch { showAlert("后台提示音准备失败：\(error.localizedDescription)") }
            }
            return
        case "previewMusic":
            do { try reminders.previewMusic() }
            catch { showAlert("试听失败：\(error.localizedDescription)") }
            return
        case "removeMusic": reminders.removeMusic();cloudSession?.removeMusic(); return
        case "playAlarm": reminders.play(title: data["title"] as? String ?? "日子提醒", key: data["key"] as? String ?? "reminder"); return
        case "stopAlarm": reminders.stop(); return
        case "export": break
        default: return
        }
        guard let content = data["content"] as? String, let name = data["filename"] as? String else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent((name as NSString).lastPathComponent)
            try Data(content.utf8).write(to: file, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = webView
            sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
            present(sheet, animated: true)
        } catch { showAlert("导出失败，请重试。") }
    }
    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: "日缄", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: "日缄", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "日缄", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: CloudBackupStore.taskID, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in CloudBackupStore.shared.runBackground(refresh) }
        }
        do {
            let session=try RijianCloudSession.shared.get()
            session.onSnapshot={ snapshot in NativeReminders.shared.updateCloudAlarms(snapshot.alarms) }
            session.onMusic={ file,name in
                if let file { try NativeReminders.shared.installMusic(Data(contentsOf:file),name:name ?? "music") }
                else { NativeReminders.shared.removeMusic() }
            }
        } catch { print("CloudKit startup failed",error) }
        application.registerForRemoteNotifications()
        CloudBackupStore.shared.scheduleBackground()
        return true
    }
    func application(_ application:UIApplication,didReceiveRemoteNotification userInfo:[AnyHashable:Any],fetchCompletionHandler completionHandler:@escaping(UIBackgroundFetchResult)->Void) {
        (try? RijianCloudSession.shared.get())?.refresh()
        completionHandler(.newData)
    }

}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = AppViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}


final class MusicUpload {
    private var active = ""
    private var received = 0
    private var file: URL?
    func receive(_ value: [String:Any]) throws -> URL? {
        guard let id=value["transfer"] as? String,let offset=value["offset"] as? Int,let total=value["total"] as? Int,total>0,total<=200*1024*1024,let text=value["data"] as? String,let bytes=Data(base64Encoded:text),bytes.count<=1024*1024 else { throw CocoaError(.fileReadCorruptFile) }
        if offset==0 {
            if let file { try? FileManager.default.removeItem(at:file) }
            active=id;received=0
            let ext=((value["name"] as? String ?? "audio") as NSString).pathExtension
            file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try Data().write(to:file!)
        }
        guard active==id,received==offset,offset+bytes.count<=total,let file else { throw CocoaError(.fileReadCorruptFile) }
        let handle=try FileHandle(forWritingTo:file);defer { try? handle.close() }
        try handle.seekToEnd();try handle.write(contentsOf:bytes);received+=bytes.count
        if value["final"] as? Bool == true { guard received==total else { throw CocoaError(.fileReadCorruptFile) };self.file=nil;active="";return file }
        return nil
    }
}
