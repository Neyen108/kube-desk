import SwiftUI

@MainActor final class Store: ObservableObject {
    @Published var contexts: [String] = []
    @Published var context = ""
    @Published var namespaces: [String] = []
    @Published var namespace = "default"
    @Published var pods: [Resource] = []
    @Published var deployments: [Resource] = []
    @Published var nodes: [Resource] = []
    @Published var scaledObjects: [ScaledObject] = []
    @Published var scaledObjectsError = ""
    @Published var neighbors: [Resource] = []
    @Published var selectedNode = ""
    @Published var messages: [String] = []
    @Published var placementError = ""
    @Published var busy = false
    @Published var mutating = false
    @Published var loadingStatus = ""
    @Published var loadingPlacement = false
    @Published var updated: Date?
    @Published var notice = ""
    @AppStorage("kubectlPath") var executable = "/opt/homebrew/bin/kubectl"
    @AppStorage("groupLabel") var groupLabel = ""
    private let clientOverride: Kubectl?
    init(client: Kubectl? = nil) { clientOverride = client }
    var cli: Kubectl { clientOverride ?? Kubectl(executable: executable) }
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var placementGeneration = 0
    private var placementTask: Task<Void, Never>?

    func clear() {
        scaledObjects = []; scaledObjectsError = ""
        pods = []; deployments = []; nodes = []; neighbors = []; selectedNode = ""; updated = nil
        placementTask?.cancel(); placementGeneration += 1; loadingPlacement = false; placementError = ""
    }
    func cancel() {
        guard !mutating else { return }
        operation?.cancel(); generation += 1; busy = false; loadingStatus = ""
        placementTask?.cancel(); placementGeneration += 1; loadingPlacement = false
        notice = "Loading cancelled. Choose a context or refresh to retry."
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) async {
        operation?.cancel(); generation += 1
        let token = generation
        busy = true; messages = []; notice = ""
        let task = Task { @MainActor in
            do { try await work() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.messages.append(error.localizedDescription) } }
            if token == self.generation { self.busy = false; self.loadingStatus = "" }
        }
        operation = task
        await task.value
    }
    func start() async {
        guard !mutating else { return }
        await perform {
            self.loadingStatus = "Reading kubeconfig…"
            let config = try await self.cli.json(["config", "view", "-o", "json"])
            try Task.checkCancellation()
            self.contexts = (config["contexts"] as? [[String: Any]] ?? []).map { string($0["name"]) }.sorted()
            let active = string(config["current-context"])
            if self.context != active { self.clear(); self.namespace = "default" }
            self.context = active
            guard !active.isEmpty else { throw CLIError(message: "No active Kubernetes context. Choose a context above.") }
            await self.loadResources(includeNamespaces: true)
        }
    }
    func switchContext(_ value: String) async {
        guard !mutating, value != context else { return }
        // Only the short kubeconfig write is locked; network reads remain cancellable.
        mutating = true
        await perform {
            self.loadingStatus = "Switching context…"
            do {
                _ = try await self.cli.run(["config", "use-context", value])
                try Task.checkCancellation()
            } catch { self.mutating = false; throw error }
            self.mutating = false
            self.context = value; self.namespace = "default"; self.clear()
            await self.loadResources(includeNamespaces: true)
        }
    }
    func changeNamespace(_ value: String) async {
        guard !mutating else { return }
        guard value.range(of: "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", options: .regularExpression) != nil else {
            messages = ["Enter a valid namespace: 1–63 lowercase letters, digits or hyphens, starting and ending with a letter or digit."]
            return
        }
        namespace = value; clear(); await refresh()
    }
    func refresh() async {
        guard !mutating, !context.isEmpty else { return }
        await perform { await self.loadResources() }
    }
    func loadResources(includeNamespaces: Bool = false) async {
        let client = cli, ctx = context, ns = namespace
        var requests: [(String, [String])] = [
            ("pods", ["get", "pods", "--namespace", ns, "-o", "json"]),
            ("deployments", ["get", "deployments", "--namespace", ns, "-o", "json"]),
            ("nodes", ["get", "nodes", "-o", "json"]),
            ("ScaledObjects", ["get", "scaledobjects.keda.sh", "--namespace", ns, "-o", "json"]),
            ("Pod metrics", ["get", "--raw", "/apis/metrics.k8s.io/v1beta1/namespaces/\(ns)/pods"]),
            ("Node metrics", ["get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"])
        ]
        if includeNamespaces { requests.append(("namespaces", ["get", "namespaces", "-o", "json"])) }
        var pending = Set(requests.map { $0.0 })
        var podMetrics: [String: (Double?, Double?)] = [:]
        var nodeMetrics: [String: (Double?, Double?)] = [:]
        // Clear stale usage while retaining the last resource snapshot during refresh.
        pods = pods.map { var r = $0; r.cpu = nil; r.memory = nil; return r }
        nodes = nodes.map { var r = $0; r.cpu = nil; r.memory = nil; return r }
        updated = nil
        scaledObjectsError = ""
        loadingStatus = "Loading \(pending.count) resources…"
        await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            for (name, args) in requests {
                group.addTask {
                    do { return (name, .success(try await client.run(["--context", ctx] + args))) }
                    catch { return (name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); continue }
                do {
                    let data = try result.get()
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError(message: "Unexpected Kubernetes response") }
                    switch name {
                    case "pods": pods = items(json).map { resource($0, kind: "pod") }.sorted { $0.name < $1.name }
                    case "deployments": deployments = items(json).map { resource($0, kind: "deployment") }.sorted { $0.name < $1.name }
                    case "nodes": nodes = items(json).map { resource($0, kind: "node", groupLabel: groupLabel) }.sorted { $0.name < $1.name }
                    case "ScaledObjects": scaledObjects = items(json).map(ScaledObject.init).sorted { $0.name < $1.name }
                    case "namespaces": namespaces = items(json).map { string(dict($0["metadata"])["name"]) }.sorted()
                    case "Pod metrics": podMetrics = metrics(json, pods: true)
                    case "Node metrics": nodeMetrics = metrics(json, pods: false)
                    default: break
                    }
                } catch {
                    if name == "ScaledObjects" {
                        scaledObjects = []
                        scaledObjectsError = "Could not load KEDA ScaledObjects. Check that KEDA is installed and your account can list scaledobjects.keda.sh.\n\n\(error.localizedDescription)"
                    } else {
                        messages.append("\(name): \(error.localizedDescription)")
                    }
                    // A failed list must not look like fresh data from the server.
                    if name == "pods" { pods = [] }
                    if name == "deployments" { deployments = [] }
                    if name == "nodes" { nodes = [] }
                    if name == "namespaces" { namespaces = [ns] }
                }
                pods = pods.map { var r = $0; r.cpu = podMetrics[r.id]?.0; r.memory = podMetrics[r.id]?.1; return r }
                nodes = nodes.map { var r = $0; r.cpu = nodeMetrics[r.id]?.0; r.memory = nodeMetrics[r.id]?.1; return r }
                pending.remove(name)
                loadingStatus = pending.isEmpty ? "" : "Waiting for \(pending.sorted().joined(separator: ", "))…"
            }
        }
        guard !Task.isCancelled else { return }
        updated = Date()
        if !selectedNode.isEmpty { await inspectNode(selectedNode) }
    }
    func inspectNode(_ name: String) async {
        placementTask?.cancel(); placementGeneration += 1
        let token = placementGeneration
        selectedNode = name; neighbors = []; placementError = ""; loadingPlacement = !name.isEmpty
        guard !name.isEmpty else { return }
        let client = cli, ctx = context
        let task = Task { @MainActor in
            do {
                let data = try await client.json(["--context", ctx, "get", "pods", "--all-namespaces", "--field-selector", "spec.nodeName=\(name)", "-o", "json"])
                guard token == self.placementGeneration, !Task.isCancelled else { return }
                self.neighbors = items(data).map { resource($0, kind: "pod") }.sorted { $0.id < $1.id }
            } catch {
                guard token == self.placementGeneration, !Task.isCancelled else { return }
                self.placementError = "Could not list pods across namespaces: \(error.localizedDescription)"
            }
            if token == self.placementGeneration { self.loadingPlacement = false }
        }
        placementTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func scale(_ deployment: Resource, to count: Int) async {
        guard !busy, !mutating, count >= 0, deployment.namespace == namespace else { return }
        mutating = true
        await perform {
            self.loadingStatus = "Scaling \(deployment.name)…"
            do {
                _ = try await self.cli.run(["--context", self.context, "--namespace", deployment.namespace, "scale", "deployment", deployment.name, "--current-replicas=\(deployment.replicas)", "--replicas=\(count)"])
            } catch { self.mutating = false; throw error }
            self.mutating = false
            self.notice = "Scaled \(deployment.name) to \(count) replicas."
            await self.loadResources()
        }
    }
    func updateScaledObject(_ object: ScaledObject, context expectedContext: String, min: Int, max: Int) async -> Bool {
        guard !busy, !mutating else { return false }
        guard context == expectedContext, object.namespace == namespace else {
            messages = ["The selected context or namespace changed. Reopen the replica editor."]
            return false
        }
        let patch: String
        do { patch = try object.patch(min: min, max: max) }
        catch { messages = [error.localizedDescription]; return false }
        var saved = false
        mutating = true
        await perform {
            self.loadingStatus = "Updating \(object.name)…"
            do {
                _ = try await self.cli.run(["--context", expectedContext, "--namespace", object.namespace, "patch", "scaledobjects.keda.sh", object.name, "--type=merge", "--patch", patch])
            } catch {
                self.mutating = false
                throw CLIError(message: "Could not update ScaledObject: \(error.localizedDescription)\nRefresh and reopen the editor if the object changed. After a timeout, refresh to check whether the update was applied.")
            }
            saved = true
            self.mutating = false
            self.notice = "Updated \(object.name): minimum \(min), maximum \(max) replicas."
            await self.loadResources()
        }
        return saved
    }

}
