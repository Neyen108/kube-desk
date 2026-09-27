import XCTest
@testable import KubeDesk

final class KubernetesTests: XCTestCase {
    func testQuantities() {
        XCTAssertEqual(Quantity.parse("250m"), 0.25)
        XCTAssertEqual(Quantity.parse("120000000n")!, 0.12, accuracy: 0.0000001)
        XCTAssertEqual(Quantity.parse("2Gi"), 2147483648)
        XCTAssertEqual(Quantity.parse("400M"), 400000000)
        XCTAssertEqual(Quantity.parse("1e3"), 1000)
        XCTAssertNil(Quantity.parse("unavailable"))
    }
    func testNodeGroupPriorityAndCapacity() {
        let object: [String: Any] = ["metadata": ["name": "node-a", "labels": ["team/pool": "custom", "eks.amazonaws.com/nodegroup": "workers"]], "status": ["allocatable": ["cpu": "3900m", "memory": "8Gi"], "conditions": [["type": "Ready", "status": "True"]]]]
        XCTAssertEqual(resource(object, kind: "node").group, "workers")
        let custom = resource(object, kind: "node", groupLabel: "team/pool")
        XCTAssertEqual(custom.group, "custom")
        XCTAssertEqual(custom.capacityCPU, 3.9)
        XCTAssertEqual(custom.status, "Ready")
    }
    func testMetricsSumContainersAndPreserveMissing() {
        let data: [String: Any] = ["items": [["metadata": ["name": "web", "namespace": "prod"], "containers": [["usage": ["cpu": "100m", "memory": "1Mi"]], ["usage": ["cpu": "200m", "memory": "2Mi"]]]]]]
        let value = metrics(data, pods: true)["prod/web"]!
        XCTAssertEqual(value.0!, 0.3, accuracy: 0.0001)
        XCTAssertEqual(value.1, 3145728)
        let missing = metrics(["items": [["metadata": ["name": "node"], "usage": ["memory": "1Mi"]]]], pods: false)
        XCTAssertNil(missing["/node"]!.0)
    }
    func testPlacementAndReplicas() {
        XCTAssertEqual(resource(["metadata": ["name": "web", "namespace": "a"], "spec": ["nodeName": "worker"]], kind: "pod").node, "worker")
        XCTAssertEqual(resource(["spec": ["replicas": 0]], kind: "deployment").replicas, 0)
    }
    func testRunnerCapturesError() async throws {
        do { _ = try await Kubectl(executable: "/usr/bin/false").run([]); XCTFail("Should fail") } catch { XCTAssertTrue(error is CLIError) }
    }
    func testRunnerMissingExecutable() async {
        do { _ = try await Kubectl(executable: "/missing/kubectl").run([]); XCTFail("Should fail") } catch { XCTAssertTrue(error.localizedDescription.contains("not found")) }
    }
    func testArgumentsAreNotEvaluatedByShell() async throws {
        let literal = "$(touch /tmp/kubedesk-must-not-exist); `whoami`"
        let data = try await Kubectl(executable: "/bin/echo").run([literal])
        XCTAssertEqual(String(data: data, encoding: .utf8), literal + " --request-timeout=15s\n")
    }
}
