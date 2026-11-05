import Cocoa
import FlutterMacOS
import KagiCore
import KagiGUIBridge

class MainFlutterWindow: NSWindow {
  private let coreQueue = DispatchQueue(label: "dev.kagi.gui.core", qos: .userInitiated)
  private let bridge: GUIBridge = {
    #if DEBUG
    if let home = ProcessInfo.processInfo.environment["KAGI_GUI_TEST_HOME"] {
      let decision: SoftwareBackend.Decision
      switch ProcessInfo.processInfo.environment["KAGI_GUI_TEST_DECISION"] ?? "approve" {
      case "approve": decision = .approve
      case "locked": decision = .locked
      default: decision = .deny
      }
      return GUIBridge(local: LocalStore(dir: URL(fileURLWithPath: home)),
        backend: SoftwareBackend(decision: decision), mode: "software")
    }
    #endif
    return GUIBridge()
  }()
  private var coreChannel: FlutterMethodChannel?
  @objc func kagiSearch(_ sender: Any?) {
    coreChannel?.invokeMethod("shortcut", arguments: "search")
  }

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1120, height: 720))
    minSize = NSSize(width: 360, height: 580)
    title = "Kagi"
    center()
    let channel = FlutterMethodChannel(name: "dev.kagi/core.v1", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "request", let text = call.arguments as? String,
        let bytes = text.data(using: .utf8), bytes.count <= 1024 * 1024, let self else {
        result(FlutterError(code: "INVALID_REQUEST", message: "无效的核心请求。", details: nil))
        return
      }
      self.coreQueue.async {
        let reply = self.bridge.handle(bytes)
        DispatchQueue.main.async { result(String(decoding: reply, as: UTF8.self)) }
      }
    }
    coreChannel = channel
    RegisterGeneratedPlugins(registry: controller)
    super.awakeFromNib()
  }
}
