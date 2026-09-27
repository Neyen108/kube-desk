import Foundation

@main struct LoadingChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("kubectl")
        let script = #"""
        #!/bin/sh
        case "$*" in
          *"config view"*) echo '{"current-context":"slow","contexts":[{"name":"slow"},{"name":"fast"}]}' ;;
          *"config use-context"*) echo 'switched' ;;
          *"--raw"*) exec /bin/sleep 60 ;;
          *"patch scaledobjects.keda.sh"*)
            printf '%s\n' "$@" > "$(dirname "$0")/patch-args"
            if [ -f "$(dirname "$0")/fail-patch" ]; then echo 'Conflict: resourceVersion changed' >&2; exit 1; fi
            echo '{}' ;;
          *"get scaledobjects.keda.sh"*)
            if [ -f "$(dirname "$0")/missing-keda" ]; then echo 'the server does not have resource type scaledobjects' >&2; exit 1; fi
            echo '{"items":[{"metadata":{"name":"queue","namespace":"default","resourceVersion":"42"},"spec":{"scaleTargetRef":{"name":"worker"},"minReplicaCount":1,"maxReplicaCount":10}}]}' ;;
          *"get namespaces"*) echo '{"items":[{"metadata":{"name":"default"}}]}' ;;
          *"get pods"*)
            case "$*" in
              *"--context slow"*) /bin/sleep 0.2; echo '{"items":[{"metadata":{"name":"slow-pod","namespace":"default"}}]}' ;;
              *) echo '{"items":[{"metadata":{"name":"fast-pod","namespace":"default"}}]}' ;;
            esac ;;
          *) echo '{"items":[]}' ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let store = Store(client: Kubectl(executable: executable.path, timeout: 0.7))
        let start = Date()
        await store.start()
        precondition(!store.busy && Date().timeIntervalSince(start) < 1.6, "Requests must run concurrently and end on deadline")
        precondition(store.pods.first?.name == "slow-pod", "Metrics timeout must not hide pods")
        precondition(store.messages.count == 2, "Both metrics failures must be visible")
        print("PASS: Parallel loading finishes with pods despite two hung metrics requests")
        let refresh = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 100_000_000)
        store.cancel()
        await refresh.value
        precondition(!store.busy && store.loadingStatus.isEmpty, "Cancel must clear loading state")
        print("PASS: Cancel clears loading state")
        let old = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.switchContext("fast")
        await old.value
        precondition(store.context == "fast" && store.pods.first?.name == "fast-pod", "Old requests must not overwrite switched context")
        precondition(!store.busy && !store.mutating, "Context switch must unlock UI")
        print("PASS: Context switching cancels old loading and ignores stale results")
        let scaled = store.scaledObjects[0]
        precondition(scaled.name == "queue" && scaled.effectiveMin == 1 && scaled.effectiveMax == 10)
        let saved = await store.updateScaledObject(scaled, context: "fast", min: 0, max: 5)
        precondition(saved && !store.mutating && !store.busy)
        let argsURL = directory.appendingPathComponent("patch-args")
        let args = try String(contentsOf: argsURL).components(separatedBy: "\n")
        precondition(Array(args.prefix(8)) == ["--context", "fast", "--namespace", "default", "patch", "scaledobjects.keda.sh", "queue", "--type=merge"])
        let patchIndex = args.firstIndex(of: "--patch")!
        let patch = try JSONSerialization.jsonObject(with: Data(args[patchIndex + 1].utf8)) as! [String: Any]
        precondition(dict(patch["spec"])["maxReplicaCount"] as? Int == 5 && dict(patch["metadata"])["resourceVersion"] as? String == "42")
        print("PASS: ScaledObject list and update send namespace/context-scoped merge patch")
        try FileManager.default.removeItem(at: argsURL)
        let invalid = await store.updateScaledObject(scaled, context: "fast", min: 10, max: 5)
        let wrongContext = await store.updateScaledObject(scaled, context: "other", min: 0, max: 5)
        precondition(!invalid && !wrongContext && !FileManager.default.fileExists(atPath: argsURL.path))
        print("PASS: Invalid ranges and changed context never invoke a patch")
        try Data().write(to: directory.appendingPathComponent("fail-patch"))
        let conflict = await store.updateScaledObject(scaled, context: "fast", min: 2, max: 5)
        precondition(!conflict && !store.busy && !store.mutating && store.messages.joined().contains("Conflict"))
        print("PASS: Conflict errors are surfaced and unlock the editor")
        try Data().write(to: directory.appendingPathComponent("missing-keda"))
        await store.refresh()
        precondition(store.scaledObjects.isEmpty && !store.scaledObjectsError.isEmpty && !store.pods.isEmpty)
        print("PASS: Missing KEDA does not block other workloads")

    }
}
