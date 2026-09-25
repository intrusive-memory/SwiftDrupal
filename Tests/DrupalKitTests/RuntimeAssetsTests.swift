import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import DrupalKit

// Kernel provisioning against temp dirs and a fake fetcher; nothing here
// touches the network or ~/Library.

private func sandbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "drupalkit-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let kernelBytes = Data("not really a kernel\n".utf8)

private func spec(for data: Data = kernelBytes) -> KernelSpec {
    KernelSpec(
        name: "test kernel",
        archiveURL: URL(string: "https://example.invalid/kernel.tar.xz")!,
        archiveDirectory: "./k/", archiveMember: "vmlinux",
        approximateDownloadMB: 1,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        size: data.count
    )
}

/// Writes `bytes` as the "downloaded" kernel and counts calls.
final class FakeFetcher: KernelFetching {
    let bytes: Data
    let error: DrupalError?
    private let calls = Mutex(0)

    init(bytes: Data = kernelBytes, error: DrupalError? = nil) {
        self.bytes = bytes
        self.error = error
    }

    var callCount: Int { calls.withLock { $0 } }

    func fetch(_ spec: KernelSpec, to destination: URL, workDirectory: URL) async throws(DrupalError) {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        do { try bytes.write(to: destination) } catch { throw DrupalError(.ioError, "\(error)") }
    }
}

private final class Messages: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ s: String) { lines.withLock { $0.append(s) } }
    var all: [String] { lines.withLock { $0 } }
}

@Suite struct RuntimeAssetStoreTests {
    @Test func firstUseFetchesThenReusesTheInstalledKernel() async throws {
        let dir = try sandbox()
        let fetcher = FakeFetcher()
        let store = RuntimeAssetStore(spec: spec(), directory: dir, fetcher: fetcher)
        let messages = Messages()

        let assets = try await store.ensureRuntimeAssets { messages.append($0) }
        #expect(assets.kernel == store.kernelFile)
        #expect(assets.initfsReference == Containerization.vminitReference)
        #expect(try Data(contentsOf: assets.kernel) == kernelBytes)
        #expect(fetcher.callCount == 1)
        #expect(messages.all.first?.hasPrefix("Downloading the test kernel") == true)

        _ = try await store.ensureRuntimeAssets { messages.append($0) }
        #expect(fetcher.callCount == 1)
        // Staging directories are cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func corruptInstalledKernelIsReplaced() async throws {
        let dir = try sandbox()
        let fetcher = FakeFetcher()
        let store = RuntimeAssetStore(spec: spec(), directory: dir, fetcher: fetcher)
        try FileManager.default.createDirectory(at: store.kernelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: store.kernelFile)

        _ = try await store.ensureRuntimeAssets { _ in }
        #expect(fetcher.callCount == 1)
        #expect(try Data(contentsOf: store.kernelFile) == kernelBytes)
    }

    @Test func matchingKernelFromTheContainerCLIIsReusedWithoutDownloading() async throws {
        let dir = try sandbox()
        let appleKernels = dir.appending(path: "com.apple.container/kernels", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appleKernels, withIntermediateDirectories: true)
        try Data("some other kernel".utf8).write(to: appleKernels.appending(path: "a-other"))
        try kernelBytes.write(to: appleKernels.appending(path: "vmlinux-6.12.28-153"))
        // The `container` CLI points a symlink at its default kernel.
        try FileManager.default.createSymbolicLink(
            at: appleKernels.appending(path: "default.kernel-arm64"),
            withDestinationURL: appleKernels.appending(path: "vmlinux-6.12.28-153")
        )

        let fetcher = FakeFetcher()
        let store = RuntimeAssetStore(spec: spec(), directory: dir.appending(path: "drupal"), reuseDirectories: [appleKernels], fetcher: fetcher)
        let messages = Messages()
        let assets = try await store.ensureRuntimeAssets { messages.append($0) }

        #expect(fetcher.callCount == 0)
        #expect(try Data(contentsOf: assets.kernel) == kernelBytes)
        #expect(messages.all.first?.hasPrefix("Using the kernel already installed") == true)
        // A copy, not a link: removing the container CLI's kernels must not break drupal.
        let type = try FileManager.default.attributesOfItem(atPath: assets.kernel.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func checksumMismatchFailsWithoutInstalling() async throws {
        let dir = try sandbox()
        let store = RuntimeAssetStore(spec: spec(), directory: dir, fetcher: FakeFetcher(bytes: Data("tampered kernel!!!!\n".utf8)))
        do {
            _ = try await store.ensureRuntimeAssets { _ in }
            Issue.record("expected a checksum failure")
        } catch {
            #expect(error.status == .runtimeAssetsUnavailable)
            #expect(error.message.contains("SHA-256"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.kernelFile.path))
    }

    @Test func downloadFailureIsReportedAsIs() async throws {
        let dir = try sandbox()
        let failure = DrupalError(.runtimeAssetsUnavailable, "downloading the kernel failed: offline")
        let store = RuntimeAssetStore(spec: spec(), directory: dir, fetcher: FakeFetcher(error: failure))
        do {
            _ = try await store.ensureRuntimeAssets { _ in }
            Issue.record("expected the fetch error")
        } catch {
            #expect(error == failure)
        }
        #expect(!FileManager.default.fileExists(atPath: store.kernelFile.path))
    }

    /// vminitd must be the same version as the host library, and Package.swift
    /// pins that library `exact:` — so the constant must follow Package.resolved.
    @Test func vminitTagMatchesTheResolvedContainerizationVersion() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Package.resolved"))) as? [String: Any]
        let pins = resolved?["pins"] as? [[String: Any]] ?? []
        let pin = pins.first { $0["identity"] as? String == "containerization" }
        let version = (pin?["state"] as? [String: Any])?["version"] as? String
        #expect(version == Containerization.version)
        #expect(Containerization.vminitReference.hasSuffix(":\(Containerization.version)"))
    }
}

@Suite struct StartFetchesRuntimeAssetsTests {
    @Test func startEnsuresAssetsBeforeTheRuntime() async throws {
        let assets = FakeAssets()
        let runtime = FakeRuntime()
        let r = await drupal("start", in: try tempProject(config: ""), runtime: runtime, assets: assets)
        #expect(r.code == 0)
        #expect(assets.callCount == 1)
        #expect(runtime.recorded == ["start"])
    }

    @Test func assetFailureStopsStartWithExit15() async throws {
        let assets = FakeAssets(error: DrupalError(.runtimeAssetsUnavailable, "downloading the kernel failed: offline"))
        let runtime = FakeRuntime()
        let r = await drupal("start", in: try tempProject(config: ""), runtime: runtime, assets: assets)
        #expect(r.code == 15)
        #expect(r.error["code"] as? String == "runtime_assets_unavailable")
        #expect(runtime.recorded.isEmpty)
    }

    @Test func progressGoesToStderrInTextModeOnly() async throws {
        let dir = try tempProject(config: "")
        let assets = FakeAssets(progressMessage: "Downloading the kernel")

        let text = await drupal("start", in: dir, tty: true, runtime: FakeRuntime(), assets: assets)
        #expect(text.stderr.contains("Downloading the kernel\n"))
        #expect(!text.stdout.contains("Downloading"))

        let json = await drupal("start", in: dir, runtime: FakeRuntime(), assets: assets)
        #expect(!json.stderr.contains("Downloading"))
        #expect(json.stdout.split(separator: "\n").count == 1)
    }
}
