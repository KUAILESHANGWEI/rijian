import AppKit
import WebKit
import UserNotifications
import AVFoundation
import UniformTypeIdentifiers

struct Reminder: Codable { let key: String; let title: String; let time: Double }
@main final class RijianMac: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var server: LocalAppServer!
    let musicUpload = MusicUpload()
    var player: AVAudioPlayer?
    var previewing = false
    var requests: [Reminder] = []
    var fired = Set<String>()
    var tick: Timer?
    var activity: NSObjectProtocol?
    let defaults = UserDefaults.standard
    var reminderStatus = "App 运行时可播放提醒；通知权限尚未开启"
    var backupStatus = "尚未选择 iCloud 备份目录"
    var notificationEnabled = false
    var store: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("日缄", isDirectory: true) }
    var musicURL: URL { store.appendingPathComponent("reminder-audio") }
    static func main() {
        let app = NSApplication.shared
        let delegate = RijianMac()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "显示日缄", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "停止音乐", action: #selector(stopMusic), keyEquivalent: ".").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出日缄", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "编辑"; menu.addItem(edit)
        let edits = NSMenu(title: "编辑"); edit.submenu = edits
        for (title, action, key) in [("撤销", "undo:", "z"),("剪切", "cut:", "x"),("复制", "copy:", "c"),("粘贴", "paste:", "v"),("全选", "selectAll:", "a")] { edits.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = menu
        let config = WKWebViewConfiguration()
        let content = WKUserContentController(); content.add(self, name: "rijian")
        content.addUserScript(WKUserScript(source: "window.rijianMac=true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1180,height:800), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "日缄"; window.minSize = NSSize(width:760,height:600)
        window.isReleasedWhenClosed = false
        window.contentView = web; window.center(); showWindow()
        UNUserNotificationCenter.current().delegate = self
        if let data = defaults.data(forKey: "requests"), let saved = try? JSONDecoder().decode([Reminder].self,from:data) { requests = saved }
        fired = Set(defaults.stringArray(forKey:"fired") ?? [])
        do {
            server = try LocalAppServer(root: Bundle.main.resourceURL!.appendingPathComponent("Web"))
            server.onReady = { [weak self] in self?.web.load(URLRequest(url:URL(string:"http://127.0.0.1:24716/index.html")!)) }
            server.onFailure = { [weak self] error in self?.alert("打开失败：\(error)") }
            server.start()
        } catch { alert("打开失败：\(error.localizedDescription)") }
        tick = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.checkReminders() }
        refreshPermission(); backup(force:false)
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in DispatchQueue.main.async {
            self.notificationEnabled = settings.authorizationStatus == .authorized
            self.reminderStatus = self.notificationEnabled ? "通知已开启；App 运行时支持提醒音乐" : "App 运行时可播放提醒；通知权限尚未开启"
            self.status()
        } }
    }
    func status() {
        let value:[String:Any] = ["reminderStatus":reminderStatus,"remindersEnabled":true,"playing":player?.isPlaying == true,"previewing":previewing,"backupStatus":backupStatus,"backupDays":max(1,defaults.integer(forKey:"backupDays")),"backupEnabled":defaults.bool(forKey:"backupEnabled")]
        if let data=try? JSONSerialization.data(withJSONObject:value),let json=String(data:data,encoding:.utf8) { web.evaluateJavaScript("window.rijianNativeStatus?.(\(json))",completionHandler:nil) }
    }
    func checkReminders() {
        let now=Date().timeIntervalSince1970*1000
        for request in requests where request.time <= now && request.time > now-86400000 && !fired.contains(request.key) {
            play(title:request.title,key:request.key)
            let content=UNMutableNotificationContent(); content.title="日缄"; content.body=request.title
            if player?.isPlaying != true { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:request.key,content:content,trigger:nil))
        }
        backup(force:false)
    }
    func play(title:String,key:String,preview:Bool=false) {
        if !preview && fired.contains(key) { return }
        if !preview { fired.insert(key); defaults.set(Array(fired.suffix(1000)),forKey:"fired") }
        stopMusic()
        do {
            guard FileManager.default.fileExists(atPath:musicURL.path) else {
                if preview { alert("请先上传音乐") } else { NSSound.beep() }
                return
            }
            let audio=try AVAudioPlayer(contentsOf:musicURL); audio.numberOfLoops = -1
            guard audio.prepareToPlay(),audio.play() else { throw CocoaError(.fileReadCorruptFile) }
            player=audio; previewing=preview; status()
        } catch { alert("音乐播放失败：\(error.localizedDescription)") }
    }
    @objc func stopMusic() { player?.stop(); player=nil; previewing=false; if web != nil { status() } }
    func backup(force:Bool) {
        guard defaults.bool(forKey:"backupEnabled"),let path=defaults.string(forKey:"backupFolder") else { return }
        let days=max(1,defaults.integer(forKey:"backupDays"))
        let last=defaults.object(forKey:"lastBackup") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last)>Double(days)*86400 else { return }
        let source=store.appendingPathComponent("latest-backup.json")
        guard let data=try? Data(contentsOf:source) else { if force { alert("暂无可备份数据") }; return }
        do {
            let folder=URL(fileURLWithPath:path).appendingPathComponent("日缄备份",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let formatter=DateFormatter(); formatter.dateFormat="yyyy-MM-dd-HHmmss"
            try data.write(to:folder.appendingPathComponent("日缄-\(formatter.string(from:Date()))-\(UUID().uuidString.prefix(6)).json"),options:.atomic)
            defaults.set(Date(),forKey:"lastBackup"); backupStatus="已保存到 iCloud 目录，系统将同步"; status()
        } catch { backupStatus="备份失败：\(error.localizedDescription)"; status() }
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,message.frameInfo.securityOrigin.host=="127.0.0.1",let data=message.body as? [String:Any],let action=data["action"] as? String else { return }
        switch action {
        case "status":refreshPermission();status()
        case "requestReminders":UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in DispatchQueue.main.async { self.refreshPermission() } }
        case "sync":
            if let text=data["snapshot"] as? String { try? Data(text.utf8).write(to:store.appendingPathComponent("latest-backup.json"),options:.atomic);backup(force:false) }
            if let raw=data["requests"],let bytes=try? JSONSerialization.data(withJSONObject:raw),let values=try? JSONDecoder().decode([Reminder].self,from:bytes) { for value in values where self.requests.first(where: { $0.key == value.key })?.time != value.time { fired.remove(value.key) }
                requests=values;defaults.set(bytes,forKey:"requests")
                if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity=nil }
                if values.contains(where: { $0.time > Date().timeIntervalSince1970*1000 }) { activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"日缄正在等待提醒或倒计时") } }
        case "musicChunk":
            var failure: String? = nil
            do {
                if let url=try musicUpload.receive(data) {
                    defer { try? FileManager.default.removeItem(at:url) }
                    let bytes=try Data(contentsOf:url)
                    let audio=try AVAudioPlayer(contentsOf:url)
                    guard audio.duration>0 else { throw CocoaError(.fileReadCorruptFile) }
                    try bytes.write(to:musicURL,options:.atomic)
                }
            } catch { failure=error.localizedDescription }
            if let callback=data["callback"] as? String,let json=try? JSONSerialization.data(withJSONObject:[callback,failure as Any? ?? NSNull()]),let args=String(data:json,encoding:.utf8) {
                web.evaluateJavaScript("window.rijianNativeMusicResult?.(...\(args))",completionHandler:nil)
            }
        case "music":
            if let text=data["data"] as? String,let bytes=Data(base64Encoded:text),bytes.count<=200*1024*1024 {
                do { let audio=try AVAudioPlayer(data:bytes);guard audio.duration>0 else { throw CocoaError(.fileReadCorruptFile) };try bytes.write(to:musicURL,options:.atomic) }
                catch { alert("音乐保存失败：\(error.localizedDescription)") }
            }
        case "previewMusic":play(title:"提醒音乐试听",key:"preview",preview:true)
        case "playAlarm":play(title:data["title"] as? String ?? "提醒",key:data["key"] as? String ?? UUID().uuidString)
        case "stopAlarm":stopMusic()
        case "removeMusic":stopMusic();try? FileManager.default.removeItem(at:musicURL)
        case "export":
            guard let text=data["content"] as? String else { return }
            let panel=NSSavePanel();panel.nameFieldStringValue=data["filename"] as? String ?? "日缄备份.json";panel.allowedContentTypes=[.json]
            panel.beginSheetModal(for:window) { response in if response == .OK,let url=panel.url { do { try Data(text.utf8).write(to:url,options:.atomic) } catch { self.alert("导出失败：\(error.localizedDescription)") } } }
        case "chooseBackupFolder":
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.message="选择 iCloud 云盘中的备份目录"
            panel.directoryURL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            panel.beginSheetModal(for:window) { response in
                guard response == .OK,let url=panel.url else { return }
                guard url.path.contains("com~apple~CloudDocs") || (try? url.resourceValues(forKeys:[.isUbiquitousItemKey]).isUbiquitousItem)==true else { self.alert("请选择 iCloud 云盘中的目录");return }
                self.defaults.set(url.path,forKey:"backupFolder");self.defaults.set(true,forKey:"backupEnabled");self.backupStatus="备份目录已连接";self.backup(force:true);self.status()
            }
        case "configureBackup":defaults.set(data["enabled"] as? Bool ?? false,forKey:"backupEnabled");defaults.set(data["days"] as? Int ?? 1,forKey:"backupDays");backup(force:false);status()
        case "backupNow":backup(force:true)
        default:break
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { status(); if ProcessInfo.processInfo.arguments.contains("--smoke-test") { smokeTest() } }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let url=navigationAction.request.url else { decisionHandler(.cancel);return }
        if url.host=="127.0.0.1" && url.port==24716 || url.scheme=="blob" || url.scheme=="about" { decisionHandler(.allow) } else { decisionHandler(.cancel);if ["http","https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } }
    }
    func webView(_ webView:WKWebView,runOpenPanelWith parameters:WKOpenPanelParameters,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping([URL]?)->Void) {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=parameters.allowsMultipleSelection;panel.canChooseDirectories=false
        panel.beginSheetModal(for:window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
    func alert(_ text:String) { let alert=NSAlert();alert.messageText="日缄";alert.informativeText=text;alert.addButton(withTitle:"好");alert.runModal() }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void) { alert(message);completionHandler() }
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void) { let a=NSAlert();a.messageText=message;a.addButton(withTitle:"确定");a.addButton(withTitle:"取消");completionHandler(a.runModal() == .alertFirstButtonReturn) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.sound]) }
    func smokeTest() {
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            self.web.evaluateJavaScript("JSON.stringify({title:document.title,heading:document.querySelector('h1').textContent,width:innerWidth,scroll:document.documentElement.scrollWidth,crypto:!!crypto.subtle,bridge:!!window.rijianNativePreviewMusic})") { value,error in
                var result="\(value ?? "") error=\(String(describing:error))"
                self.web.evaluateJavaScript("document.querySelector('#countdown').click();document.querySelector('#timer-dialog').open") { open,error in
                    result += " timerOpen=\(open ?? "nil") error=\(String(describing:error))"
                    try? result.write(toFile:"/private/tmp/rijian-mac-smoke.txt",atomically:true,encoding:.utf8)
                    self.web.takeSnapshot(with:nil) { image,_ in
                        if let bytes=image?.tiffRepresentation,let rep=NSBitmapImageRep(data:bytes),let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:"/private/tmp/rijian-mac-smoke.png")) }
                        self.web.evaluateJavaScript("document.querySelector('#timer-dialog').close()",completionHandler:nil)
                    }
                }
            }
        }
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
