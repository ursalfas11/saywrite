import AppKit
import SaywriteLlama

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--selftest") {
    let testArguments = Array(arguments[(index + 1)...])
    Task {
        let code = await SelfTest.run(arguments: testArguments)
        LlamaEngine.shared.shutdown() // ggml asserts at exit when the Metal model is still loaded
        exit(code)
    }
    dispatchMain()
}

if let index = arguments.firstIndex(of: "--render-overlay"), index + 1 < arguments.count {
    let code = MainActor.assumeIsolated { OverlaySnapshot.run(directory: arguments[index + 1]) }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
