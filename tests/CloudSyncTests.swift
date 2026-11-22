import Foundation
import CoreData
@main struct Run {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:"/private/tmp/rijian-cloud-native-"+UUID().uuidString)
  let store=try RijianCloudStore(directory:root,cloudEnabled:false)
  let initial=try RijianSnapshot(["events":[["id":"a","title":"原名","notes":"原备注"]],"labels":["工作"],"alarms":[]])
  let empty=RijianSnapshot();_ = try store.commit(baseline:empty,next:initial)
  var remote=initial;remote.events[0]["notes"]="远端备注";remote.events.append(["id":"remote-only","title":"手机日子"])
  _ = try store.commit(baseline:initial,next:remote)
  var local=initial;local.events[0]["title"]="本机标题"
  let merged=try store.commit(baseline:initial,next:local)
  assert(merged.events.count==2)
  let a=merged.events.first { $0["id"] as? String=="a" }!
  assert(a["title"] as? String=="本机标题" && a["notes"] as? String=="远端备注")
  var deleted=merged;deleted.events.removeAll { $0["id"] as? String=="a" }
  _ = try store.commit(baseline:merged,next:deleted)
  var stale=merged;stale.events[0]["title"]="离线修改"
  let after=try store.commit(baseline:merged,next:stale)
  assert(!after.events.contains { $0["id"] as? String=="a" })
  let attachments=BinaryAttachments(container:store.container,directory:root)
  let file=root.appendingPathComponent("music.bin");let bytes=Data(repeating:0x5a,count:10*1024*1024+31);try bytes.write(to:file)
  let metadata=try await attachments.storeFile(at:file,metadata:["size":bytes.count,"name":"music.bin"])
  assert(metadata["chunkCount"] as? Int==2)
  let restored=try await attachments.materialize(metadata);let read=try Data(contentsOf:restored);assert(read==bytes)
  try store.setMusic(metadata);let withMusic=try store.snapshot();assert(withMusic.music?["size"] as? Int==bytes.count)
  try store.setMusic(nil);let withoutMusic=try store.snapshot();assert(withoutMusic.music==nil);let decision=try store.hasMusicDecision();assert(decision)
  print("PASS Core Data first merge, stale-editor preservation, independent fields, tombstones, 10MB chunk roundtrip, music deletion")
 }
}
