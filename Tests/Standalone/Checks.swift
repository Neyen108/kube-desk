import Foundation

@main struct Checks {
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            passed += 1
            print("PASS: \(message)")
        }
        check(Quantity.parse("250m") == 0.25, "CPU millicores")
        check(abs(Quantity.parse("120000000n")! - 0.12) < 0.0000001, "CPU nanocores")
        check(Quantity.parse("2Gi") == 2147483648, "Binary memory")
        check(Quantity.parse("400M") == 400000000, "Decimal memory")
        check(Quantity.parse("1e3") == 1000, "Scientific quantity")
        check(Quantity.parse("invalid") == nil, "Missing metrics remain unavailable")
        let node: [String: Any] = ["metadata": ["name": "node-a", "labels": ["team/pool": "custom", "eks.amazonaws.com/nodegroup": "workers"]], "status": ["allocatable": ["cpu": "3900m", "memory": "8Gi"], "conditions": [["type": "Ready", "status": "True"]]]]
        check(resource(node, kind: "node").group == "workers", "Cloud node group detection")
        check(resource(node, kind: "node", groupLabel: "team/pool").group == "custom", "Custom node group overrides detection")
        check(resource(node, kind: "node").status == "Ready", "Node readiness")
        check(resource(node, kind: "node").capacityMemory == 8589934592, "Allocatable capacity")
        check(resource(["spec": ["replicas": 0]], kind: "deployment").replicas == 0, "Zero replicas preserved")
        check(resource(["spec": ["nodeName": "worker"]], kind: "pod").node == "worker", "Pod placement")
        let data: [String: Any] = ["items": [["metadata": ["name": "web", "namespace": "prod"], "containers": [["usage": ["cpu": "100m", "memory": "1Mi"]], ["usage": ["cpu": "200m", "memory": "2Mi"]]]]]]
        let value = metrics(data, pods: true)["prod/web"]!
        check(abs(value.0! - 0.3) < 0.00001 && value.1 == 3145728, "Multi-container metrics aggregation")
        let missing = metrics(["items": [["metadata": ["name": "node"], "usage": ["memory": "1Mi"]]]], pods: false)
        check(missing["/node"]!.0 == nil, "Missing CPU is not reported as zero")
        let literal = "$(echo unsafe); `whoami`"
        let output = try await Kubectl(executable: "/bin/echo").run([literal])
        check(String(data: output, encoding: .utf8) == literal + " --request-timeout=15s\n", "Arguments are never shell evaluated")
        do { _ = try await Kubectl(executable: "/usr/bin/false").run([]); fatalError("Expected failure") } catch { check(error is CLIError, "Nonzero exit is surfaced") }
        do { _ = try await Kubectl(executable: "/missing/kubectl").run([]); fatalError("Expected failure") } catch { check(error.localizedDescription.contains("not found"), "Missing kubectl has actionable error") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = directory.appendingPathComponent("hanging-kubectl")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleeper.path)
        let start = Date()
        do {
            _ = try await Kubectl(executable: sleeper.path, timeout: 0.2).run([])
            fatalError("Expected timeout")
        } catch {
            check(error.localizedDescription.contains("timed out") && Date().timeIntervalSince(start) < 2, "Hung subprocess has a hard deadline")
        }
        let task = Task { try await Kubectl(executable: sleeper.path).run([]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = Date()
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") }
        catch { check(error is CancellationError && Date().timeIntervalSince(cancelled) < 1, "Cancellation interrupts a running subprocess") }
        let scaled = ScaledObject(["metadata": ["name": "queue", "namespace": "default", "resourceVersion": "42"], "spec": ["scaleTargetRef": ["name": "worker"]]])
        check(scaled.effectiveMin == 0 && scaled.effectiveMax == 100 && scaled.targetKind == "Deployment", "KEDA defaults and target parsing")
        check(scaled.validationError(min: 0, max: 1) == nil, "Scale-to-zero minimum is allowed")
        check(scaled.validationError(min: -1, max: 10) != nil && scaled.validationError(min: 0, max: 0) != nil && scaled.validationError(min: 11, max: 10) != nil, "Invalid replica bounds rejected")
        check(scaled.validationError(min: nil, max: 10) != nil && scaled.validationError(min: 0, max: Int.max) != nil, "Non-integer and overflowing replica limits rejected")
        let idle = ScaledObject(["spec": ["idleReplicaCount": 0]])
        check(idle.validationError(min: 0, max: 10) != nil && idle.validationError(min: 1, max: 10) == nil, "Configured idle replicas remain below minimum")
        let patch = try JSONSerialization.jsonObject(with: Data(scaled.patch(min: 2, max: 8).utf8)) as! [String: Any]
        let patchSpec = dict(patch["spec"])
        check(dict(patch["metadata"])["resourceVersion"] as? String == "42" && patchSpec["minReplicaCount"] as? Int == 2 && patchSpec["maxReplicaCount"] as? Int == 8 && patchSpec.count == 2 && patch.count == 2, "Patch changes only replica limits and checks resource version")
        do { _ = try ScaledObject([:]).patch(min: 0, max: 10); fatalError("Expected missing version error") }
        catch { check(error.localizedDescription.contains("version"), "Missing resource version cannot be patched") }
        print("\(passed) checks passed")
    }
}
