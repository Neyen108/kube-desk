import SwiftUI

@main struct KubeDeskApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            Dashboard().environmentObject(store).frame(minWidth: 1120, minHeight: 720)
                .task { await store.start() }
        }
        Settings {
            Form {
                TextField("kubectl executable", text: $store.executable)
                TextField("Custom node-group label", text: $store.groupLabel)
                Text("Leave the label blank to detect EKS, GKE, AKS and Karpenter node groups. Refresh after changing settings.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 520)
        }
    }
}

struct Dashboard: View {
    @EnvironmentObject var store: Store
    @State private var page = "Pods"
    @State private var search = ""
    @State private var manualNamespace = ""
    @State private var editingScaledObject: ScaledObjectSelection?
    @State private var scaling: Resource?
    @State private var targetReplicas = 0
    @State private var autoRefresh = false
    @State private var excludedNodeNamespaces: [String: Set<String>] = [:]
    @State private var showingNamespaceFilter = false
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var filteredPods: [Resource] { store.pods.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.node.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                Label("KubeDesk", systemImage: "square.stack.3d.up.fill").font(.title2.bold()).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACTIVE CONTEXT").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("Context", selection: Binding(get: { store.context }, set: { value in Task { await store.switchContext(value) } })) {
                        if store.context.isEmpty { Text("Choose context").tag("") }
                        ForEach(store.contexts, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().disabled(store.mutating)
                    Text(store.context.isEmpty ? "Not connected" : store.context).font(.caption).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("NAMESPACE").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("Namespace", selection: Binding(get: { store.namespace }, set: { value in Task { await store.changeNamespace(value) } })) {
                        ForEach(Array(Set(store.namespaces + [store.namespace])).sorted(), id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().disabled(store.mutating)
                    HStack {
                        TextField("Enter namespace", text: $manualNamespace)
                        Button { let value = manualNamespace.trimmingCharacters(in: .whitespacesAndNewlines); Task { await store.changeNamespace(value) } } label: { Image(systemName: "arrow.right") }.disabled(manualNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.mutating || store.context.isEmpty)
                    }
                }
                ForEach(["Pods", "Deployments", "ScaledObjects", "Nodes"], id: \.self) { item in
                    Button { page = item; search = "" } label: {
                        HStack { Image(systemName: item == "Pods" ? "shippingbox" : item == "Nodes" ? "server.rack" : item == "ScaledObjects" ? "arrow.up.and.down" : "square.stack"); Text(item); Spacer() }
                            .padding(10).background(page == item ? Color.teal.opacity(0.16) : .clear).cornerRadius(8)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Toggle("Refresh every 30s", isOn: $autoRefresh).font(.caption)
                Text("Uses your local kubeconfig").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationSplitViewColumnWidth(240)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page).font(.largeTitle.bold())
                        Text(page == "Nodes" ? "Cluster capacity & pod placement" : "\(store.namespace) namespace").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.busy {
                        ProgressView().controlSize(.small)
                        Text(store.loadingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 220)
                        if !store.mutating { Button("Cancel") { store.cancel() } }
                    }
                    Button { Task { await store.start() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.busy).keyboardShortcut("r")
                }
                HStack(spacing: 12) {
                    stat("PODS", "\(store.pods.count)", "shippingbox")
                    stat("DEPLOYMENTS", "\(store.deployments.count)", "square.stack")
                    stat("NODES", "\(store.nodes.count)", "server.rack")
                }
                if !store.messages.isEmpty {
                    DisclosureGroup("\(store.messages.count) connection or metrics issue(s)", isExpanded: .constant(true)) {
                        ScrollView { Text(store.messages.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                    }.padding(10).background(Color.orange.opacity(0.1)).cornerRadius(8)
                }
                if !store.notice.isEmpty { Text(store.notice).foregroundStyle(.teal).font(.callout) }
                TextField("Search \(page.lowercased())…", text: $search).textFieldStyle(.roundedBorder)
                HSplitView {
                    Group {
                        if page == "Pods" { podList }
                        else if page == "Deployments" { deploymentList }
                        else if page == "ScaledObjects" { scaledObjectList }
                        else { nodeList }
                    }.frame(minWidth: 450)
                    if !store.selectedNode.isEmpty && (page == "Pods" || page == "Nodes") { inspector.frame(minWidth: 250, idealWidth: 300, maxWidth: 370) }
                }
                HStack {
                    if let updated = store.updated { Text("Last refreshed \(updated.formatted(date: .omitted, time: .standard))") }
                    Spacer()
                    Text("CPU in millicores · memory in MiB · — unavailable")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onReceive(timer) { _ in if autoRefresh && scaling == nil && editingScaledObject == nil && !store.busy { Task { await store.refresh() } } }
        .sheet(item: $editingScaledObject) { selection in
            ScaledObjectEditor(selection: selection).environmentObject(store)
        }
        .sheet(item: $scaling) { deployment in
            VStack(alignment: .leading, spacing: 20) {
                Text("Scale deployment").font(.title2.bold())
                Text(deployment.name).font(.headline)
                Text("Context: \(store.context)\nNamespace: \(deployment.namespace)\nCurrent desired replicas: \(deployment.replicas)").foregroundStyle(.secondary)
                TextField("Desired replicas", value: $targetReplicas, format: .number).textFieldStyle(.roundedBorder)
                if targetReplicas == 0 { Text("Zero replicas stops all pods in this deployment.").foregroundStyle(.orange) }
                Text("An autoscaler may adjust this value again. Scaling fails if the current replica count has changed.").font(.caption)
                HStack {
                    Button("Cancel") { scaling = nil }
                    Spacer()
                    Button("Apply to cluster") { let count = targetReplicas; scaling = nil; Task { await store.scale(deployment, to: count) } }.disabled(targetReplicas < 0 || targetReplicas == deployment.replicas).buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 430)
        }
    }
    func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack { Image(systemName: icon).font(.title2).foregroundStyle(.teal); VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title.bold()) }; Spacer() }.padding(16).frame(maxWidth: .infinity).background(Color.primary.opacity(0.04)).cornerRadius(12)
    }
    var podList: some View {
        List {
            if filteredPods.isEmpty { Text(store.busy ? "Loading pods…" : "No pods to display").foregroundStyle(.secondary) }
            ForEach(filteredPods) { pod in
                Button { Task { await store.inspectNode(pod.node) } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(pod.name).fontWeight(.medium); Spacer(); Text(pod.status).foregroundStyle(pod.status == "Running" ? .teal : .orange) }
                        HStack { Label(pod.node.isEmpty ? "Not scheduled" : pod.node, systemImage: "server.rack"); Spacer(); Text(Quantity.cpu(pod.cpu)); Text(Quantity.memory(pod.memory)) }
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.listStyle(.inset)
    }
    var deploymentList: some View {
        List {
            if store.deployments.isEmpty { Text(store.busy ? "Loading deployments…" : "No deployments to display").foregroundStyle(.secondary) }
            ForEach(store.deployments.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { deployment in
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(deployment.name).fontWeight(.medium); Text("\(deployment.ready) ready / \(deployment.replicas) desired replicas").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Scale…") { targetReplicas = deployment.replicas; scaling = deployment }.disabled(store.busy)
                }.padding(.vertical, 10)
            }
        }.listStyle(.inset)
    }
    var scaledObjectList: some View {
        List {
            if !store.scaledObjectsError.isEmpty {
                Text(store.scaledObjectsError).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            } else if store.scaledObjects.isEmpty {
                Text(store.busy ? "Loading ScaledObjects…" : "No ScaledObjects in this namespace").foregroundStyle(.secondary)
            }
            ForEach(store.scaledObjects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.targetName.localizedCaseInsensitiveContains(search) }) { object in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(object.name).fontWeight(.medium)
                        Text("\(object.targetKind)/\(object.targetName) · \(object.ready)").font(.caption).foregroundStyle(.secondary)
                        Text("Min \(object.effectiveMin)\(object.minReplicas == nil ? " (default)" : "") · Max \(object.effectiveMax)\(object.maxReplicas == nil ? " (default)" : "") replicas").font(.callout)
                    }
                    Spacer()
                    Button("Edit limits…") { editingScaledObject = ScaledObjectSelection(object: object, context: store.context) }.disabled(store.busy || store.mutating)
                }.padding(.vertical, 10)
            }
        }.listStyle(.inset)
    }
    var nodeList: some View {
        List {
            if store.nodes.isEmpty { Text(store.busy ? "Loading nodes…" : "No nodes to display").foregroundStyle(.secondary) }
            ForEach(Array(Set(store.nodes.map(\.group))).sorted(), id: \.self) { group in
                let members = store.nodes.filter { $0.group == group }
                Section {
                    ForEach(members.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || group.localizedCaseInsensitiveContains(search) }) { node in
                        Button { Task { await store.inspectNode(node.name) } } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(node.name).fontWeight(.medium); Spacer(); Text(node.status).foregroundStyle(node.status == "Ready" ? .teal : .orange) }
                                Text("CPU \(Quantity.cpu(node.cpu)) / \(Quantity.cpu(node.capacityCPU)) · Memory \(Quantity.memory(node.memory)) / \(Quantity.memory(node.capacityMemory))").font(.caption).foregroundStyle(.secondary)
                                if let cpu = node.cpu, let capacity = node.capacityCPU, capacity > 0 { ProgressView(value: min(cpu / capacity, 1)).tint(.teal) }
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group) · \(members.count) nodes").font(.headline)
                        Text("Usage: \(Quantity.cpu(total(members.map(\.cpu)))) · \(Quantity.memory(total(members.map(\.memory))))").font(.caption)
                    }
                }
            }
        }.listStyle(.inset)
    }
    func total(_ values: [Double?]) -> Double? { values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0,+) : nil }
    // Keep exclusions per context, across node selections and refreshes in this window.
    var hiddenNodeNamespaces: Set<String> { excludedNodeNamespaces[store.context] ?? [] }
    var visibleNeighbors: [Resource] { store.neighbors.filter { !hiddenNodeNamespaces.contains($0.namespace) } }
    var nodeNamespaceOptions: [String] {
        Set(store.neighbors.map(\.namespace)).union(hiddenNodeNamespaces).sorted()
    }
    func resetNodeNamespaceFilter() { excludedNodeNamespaces[store.context] = [] }
    var nodeNamespaceFilter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hide namespaces").font(.headline)
            Text("Checked namespaces are hidden from this node's pod list.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(nodeNamespaceOptions, id: \.self) { namespace in
                        Toggle(namespace, isOn: Binding(
                            get: { hiddenNodeNamespaces.contains(namespace) },
                            set: { hidden in
                                var exclusions = hiddenNodeNamespaces
                                if hidden { exclusions.insert(namespace) }
                                else { exclusions.remove(namespace) }
                                excludedNodeNamespaces[store.context] = exclusions
                            }
                        )).toggleStyle(.checkbox)
                    }
                    if nodeNamespaceOptions.isEmpty { Text("No namespaces on this node yet.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            Divider()
            HStack {
                Button("Show all") { resetNodeNamespaceFilter() }.disabled(hiddenNodeNamespaces.isEmpty)
                Spacer()
                Button("Done") { showingNamespaceFilter = false }
            }
        }.padding(16).frame(width: 280)
    }
    var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("NODE INSPECTOR").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button { showingNamespaceFilter = false; Task { await store.inspectNode("") } } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Label(store.selectedNode, systemImage: "server.rack").font(.headline).textSelection(.enabled)
            Text("Pods sharing this node").font(.title3.bold())
            HStack {
                Text(hiddenNodeNamespaces.isEmpty ? "All namespaces" : "\(hiddenNodeNamespaces.count) namespace(s) excluded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showingNamespaceFilter.toggle() } label: {
                    Label("Filter", systemImage: hiddenNodeNamespaces.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }.popover(isPresented: $showingNamespaceFilter) { nodeNamespaceFilter }
            }
            if !store.loadingPlacement && store.placementError.isEmpty {
                Text("Showing \(visibleNeighbors.count) of \(store.neighbors.count) pods").font(.caption).foregroundStyle(.secondary)
            }
            if store.loadingPlacement { ProgressView() }
            if !store.placementError.isEmpty { Text(store.placementError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleNeighbors) { pod in
                        VStack(alignment: .leading, spacing: 5) { Text(pod.name).font(.callout).textSelection(.enabled); Text("\(pod.namespace) · \(pod.status)").font(.caption).foregroundStyle(.secondary) }
                        Divider()
                    }
                    if !store.loadingPlacement && store.placementError.isEmpty && visibleNeighbors.isEmpty {
                        if store.neighbors.isEmpty {
                            Text("No pods on this node").foregroundStyle(.secondary)
                        } else {
                            Text("All pods are hidden by your namespace filter.").foregroundStyle(.secondary)
                            Button("Show all namespaces") { resetNodeNamespaceFilter() }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }

}


struct ScaledObjectSelection: Identifiable {
    let object: ScaledObject
    let context: String
    var id: String { context + "/" + object.id }
}

struct ScaledObjectEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let selection: ScaledObjectSelection
    @State private var minimum: String
    @State private var maximum: String
    @State private var saving = false
    @State private var error = ""

    init(selection: ScaledObjectSelection) {
        self.selection = selection
        _minimum = State(initialValue: String(selection.object.effectiveMin))
        _maximum = State(initialValue: String(selection.object.effectiveMax))
    }
    var minValue: Int? { Int(minimum.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var maxValue: Int? { Int(maximum.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var validation: String? { selection.object.validationError(min: minValue, max: maxValue) }
    var unchanged: Bool { minValue == selection.object.effectiveMin && maxValue == selection.object.effectiveMax }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit replica limits").font(.title2.bold())
            Text(selection.object.name).font(.headline)
            Text("Context: \(selection.context)\nNamespace: \(selection.object.namespace)\nTarget: \(selection.object.targetKind)/\(selection.object.targetName)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                VStack(alignment: .leading) { Text("Minimum replicas"); TextField("Minimum", text: $minimum).textFieldStyle(.roundedBorder) }
                VStack(alignment: .leading) { Text("Maximum replicas"); TextField("Maximum", text: $maximum).textFieldStyle(.roundedBorder) }
            }.disabled(saving)
            Text("Current limits: \(selection.object.effectiveMin)–\(selection.object.effectiveMax). KEDA applies the new limits through its autoscaler.").font(.caption).foregroundStyle(.secondary)
            if minValue == 0 { Text("A minimum of 0 allows scaling to zero when triggers are inactive.").font(.caption) }
            if let validation { Text(validation).font(.callout).foregroundStyle(.orange) }
            if !error.isEmpty { ScrollView { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 120) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Apply to cluster") {
                    guard let min = minValue, let max = maxValue else { return }
                    saving = true; error = ""
                    Task {
                        let success = await store.updateScaledObject(selection.object, context: selection.context, min: min, max: max)
                        saving = false
                        if success { dismiss() }
                        else { error = store.messages.isEmpty ? "Another operation is in progress. Try again when it finishes." : store.messages.joined(separator: "\n") }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || validation != nil || unchanged || store.busy || store.mutating)
            }
        }.padding(28).frame(width: 500).interactiveDismissDisabled(saving)
    }
}
