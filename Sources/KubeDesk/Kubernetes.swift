import Foundation

struct Resource: Identifiable, Hashable {
    var name: String
    var namespace = ""
    var node = ""
    var status = ""
    var group = ""
    var replicas = 0
    var ready = 0
    var cpu: Double?
    var memory: Double?
    var capacityCPU: Double?
    var capacityMemory: Double?
    var id: String { namespace + "/" + name }
}

enum Quantity {
    static func parse(_ value: String) -> Double? {
        let units: [(String, Double)] = [("Ki", 1024), ("Mi", pow(1024, 2)), ("Gi", pow(1024, 3)), ("Ti", pow(1024, 4)), ("Pi", pow(1024, 5)), ("Ei", pow(1024, 6)), ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("K", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18)]
        for (suffix, scale) in units where value.hasSuffix(suffix) {
            return Double(value.dropLast(suffix.count)).map { $0 * scale }
        }
        return Double(value)
    }
    static func cpu(_ value: Double?) -> String { value.map { String(format: "%.0f mCPU", $0 * 1000) } ?? "—" }
    static func memory(_ value: Double?) -> String { value.map { String(format: "%.1f MiB", $0 / 1048576) } ?? "—" }
}

struct CLIError: LocalizedError { let message: String; var errorDescription: String? { message } }

struct Kubectl {
    var executable: String
    var timeout: TimeInterval = 15
    func run(_ args: [String]) async throws -> Data {
        let path = executable
        let timeout = self.timeout
        let worker = Task.detached {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw CLIError(message: "kubectl was not found at \(path). Set its absolute path in Settings.") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let out = directory.appendingPathComponent("stdout"), err = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            FileManager.default.createFile(atPath: err.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
            defer { try? stdout.close(); try? stderr.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args + ["--request-timeout=15s"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline {
                    throw CLIError(message: "kubectl timed out after \(Int(timeout))s. Check VPN, cluster connectivity and authentication, or select another context.")
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw CLIError(message: String(data: try Data(contentsOf: err), encoding: .utf8) ?? "kubectl failed")
            }
            return try Data(contentsOf: out)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func json(_ args: [String]) async throws -> [String: Any] {
        let data = try await run(args)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError(message: "Unexpected Kubernetes response") }
        return value
    }
}

func items(_ json: [String: Any]) -> [[String: Any]] { json["items"] as? [[String: Any]] ?? [] }
func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func string(_ value: Any?) -> String { value as? String ?? "" }
func resource(_ object: [String: Any], kind: String, groupLabel: String = "") -> Resource {
    let meta = dict(object["metadata"]), spec = dict(object["spec"]), status = dict(object["status"])
    var r = Resource(name: string(meta["name"]), namespace: string(meta["namespace"]), node: string(spec["nodeName"]), status: string(status["phase"]))
    if kind == "deployment" {
        r.replicas = spec["replicas"] as? Int ?? 1
        r.ready = status["readyReplicas"] as? Int ?? 0
    }
    if kind == "node" {
        let labels = dict(meta["labels"])
        let keys = [groupLabel, "eks.amazonaws.com/nodegroup", "cloud.google.com/gke-nodepool", "kubernetes.azure.com/agentpool", "karpenter.sh/nodepool", "agentpool"]
        r.group = keys.compactMap { labels[$0] as? String }.first ?? "Ungrouped"
        let conditions = status["conditions"] as? [[String: Any]] ?? []
        r.status = conditions.contains { string($0["type"]) == "Ready" && string($0["status"]) == "True" } ? "Ready" : "Not ready"
        let capacity = dict(status["allocatable"])
        r.capacityCPU = Quantity.parse(string(capacity["cpu"]))
        r.capacityMemory = Quantity.parse(string(capacity["memory"]))
    }
    if meta["deletionTimestamp"] != nil { r.status = "Terminating" }
    return r
}

func metrics(_ json: [String: Any], pods: Bool) -> [String: (Double?, Double?)] {
    var result: [String: (Double?, Double?)] = [:]
    for item in items(json) {
        let meta = dict(item["metadata"])
        let usages = pods ? (item["containers"] as? [[String: Any]] ?? []).map { dict($0["usage"]) } : [dict(item["usage"])]
        let cpus = usages.compactMap { Quantity.parse(string($0["cpu"])) }
        let memories = usages.compactMap { Quantity.parse(string($0["memory"])) }
        result[string(meta["namespace"]) + "/" + string(meta["name"])] = (cpus.count == usages.count && !cpus.isEmpty ? cpus.reduce(0,+) : nil, memories.count == usages.count && !memories.isEmpty ? memories.reduce(0,+) : nil)
    }
    return result
}

struct ScaledObject: Identifiable {
    let name: String
    let namespace: String
    let resourceVersion: String
    let targetName: String
    let targetKind: String
    let minReplicas: Int?
    let maxReplicas: Int?
    let idleReplicas: Int?
    let ready: String
    var id: String { namespace + "/" + name }
    var effectiveMin: Int { minReplicas ?? 0 }
    var effectiveMax: Int { maxReplicas ?? 100 }

    init(_ object: [String: Any]) {
        let meta = dict(object["metadata"]), spec = dict(object["spec"])
        let target = dict(spec["scaleTargetRef"])
        name = string(meta["name"]); namespace = string(meta["namespace"])
        resourceVersion = string(meta["resourceVersion"])
        targetName = string(target["name"])
        targetKind = target["kind"] as? String ?? "Deployment"
        minReplicas = spec["minReplicaCount"] as? Int
        maxReplicas = spec["maxReplicaCount"] as? Int
        idleReplicas = spec["idleReplicaCount"] as? Int
        let conditions = dict(object["status"])["conditions"] as? [[String: Any]] ?? []
        let condition = conditions.first { string($0["type"]) == "Ready" }
        ready = condition.map { string($0["status"]) == "True" ? "Ready" : "Not ready" } ?? "Unknown"
    }

    func validationError(min: Int?, max: Int?) -> String? {
        guard let min, let max else { return "Enter whole numbers for both replica limits." }
        guard min >= 0, max >= 1, min <= Int32.max, max <= Int32.max else {
            return "Minimum must be 0 or greater; maximum must be at least 1. Both must fit a 32-bit integer."
        }
        guard min <= max else { return "Minimum replicas cannot exceed maximum replicas." }
        if let idleReplicas, idleReplicas >= min {
            return "Minimum must be greater than the configured idle replica count (\(idleReplicas))."
        }
        return nil
    }

    func patch(min: Int, max: Int) throws -> String {
        if let error = validationError(min: min, max: max) { throw CLIError(message: error) }
        guard !resourceVersion.isEmpty else { throw CLIError(message: "Resource version is missing. Refresh before editing this ScaledObject.") }
        // A merge patch leaves triggers and other settings intact. The version rejects stale edits.
        let patch: [String: Any] = ["metadata": ["resourceVersion": resourceVersion], "spec": ["minReplicaCount": min, "maxReplicaCount": max]]
        return String(decoding: try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys]), as: UTF8.self)
    }
}
