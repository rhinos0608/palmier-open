import Foundation
import Observation

/// Manages the local Python server process for on-device AI inference.
@MainActor
final class PythonServerManager: ObservableObject {
    static let defaultPort: Int = 19790

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: Int = defaultPort

    nonisolated(unsafe) var isRunningValue: Bool = Bool()
    nonisolated(unsafe) var portValue: Int = Int()
    nonisolated var baseURL: String? {
        isRunningValue ? "http://127.0.0.1:\(portValue)" : nil
    }

    private var process: Process?

    /// Locate a Python interpreter on the system.
    static func findPython() -> String? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
                          "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Returns true when the resolved interpreter is `uv` (needs `run` subcommand).
    static func isUV(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "uv"
    }

    func start() async {
        guard !isRunning else { return }
        guard let python = Self.findPython() else {
            Log.app.warning("python not found; local ai unavailable")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        
        // Locate bundled server.py
        let serverScript: URL
        if let resourcePath = Bundle.main.resourcePath {
            serverScript = URL(fileURLWithPath: resourcePath).appendingPathComponent("mlx_server/server.py")
        } else {
            serverScript = URL(fileURLWithPath: "/tmp/mlx_server/server.py")
        }
        
        if Self.isUV(python) {
            process.arguments = ["run", serverScript.path, "--port", "\(port)"]
        } else {
            process.arguments = [serverScript.path, "--port", "\(port)"]
        }
        var env = ProcessInfo.processInfo.environment
        env["PALMIER_MODELS_DIR"] = PythonServerManager.modelsDirectory().path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.isRunningValue = false
                ProviderConfig.setLocalServerURL(nil)
            }
        }

        do {
            try process.run()
            self.process = process
            portValue = port

            // Wait for server health check (up to ~5s)
            let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
            var healthy = false
            for _ in 0..<50 {
                if (try? await URLSession.shared.data(from: healthURL)) != nil { healthy = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            if healthy {
                isRunning = true
                isRunningValue = true
                ProviderConfig.setLocalServerURL(baseURL)
                Log.app.notice("local python server started port=\(port)")
            } else {
                process.terminate()
                self.process = nil
                Log.app.error("local python server failed health check")
            }
        } catch {
            Log.app.error("failed to start python server: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
        isRunningValue = false
        portValue = 0
        ProviderConfig.setLocalServerURL(nil)
        Log.app.notice("local python server stopped")
    }

    static func modelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PalmierPro/Models", isDirectory: true)
    }
}
