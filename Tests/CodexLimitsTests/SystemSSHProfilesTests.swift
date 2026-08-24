import XCTest
@testable import CodexLimits

final class SystemSSHProfilesTests: XCTestCase {
    func testRemoteSSHPolicyTimeoutsAndRetryDelay() {
        XCTAssertEqual(RemoteSSHPolicy.connectTimeoutSeconds, 15)
        XCTAssertEqual(RemoteSSHPolicy.operationTimeout, 300)
        XCTAssertEqual(RemoteSSHPolicy.retryDelay, 300)
    }

    func testLoadsConcreteHostsAndIncludedConfigs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLimitsSSHProfiles-\(UUID().uuidString)", isDirectory: true)
        let includes = root.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = root.appendingPathComponent("config")
        try """
        Host production staging *.internal !excluded
          User codex
        Include config.d/*
        Host *
          ServerAliveInterval 30
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        Host gpu-box # shown in settings
          HostName 192.0.2.10
        """.write(
            to: includes.appendingPathComponent("servers"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            SystemSSHProfiles.load(from: config),
            ["gpu-box", "production", "staging"]
        )
    }

    func testMissingConfigReturnsNoProfiles() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertEqual(SystemSSHProfiles.load(from: missing), [])
    }
}
