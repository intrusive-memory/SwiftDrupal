import CryptoKit
import Foundation

// The two things Containerization needs before it can boot any container:
//
//   kernel   an uncompressed arm64 Linux kernel. Nobody ships one with macOS
//            (not even macOS 27), so `start` fetches it once into
//            ~/Library/Application Support/drupal/runtime/kernels/. It is the
//            Kata Containers kernel apple/containerization's own
//            `make fetch-default-kernel` uses, pinned by SHA-256. A copy the
//            `container` CLI already installed is reused instead of
//            downloading.
//   vminit   the guest init image. Only a reference: `ContainerManager` pulls
//            and caches it itself. Its tag must equal the Containerization
//            library version (vminitd is the guest half of a gRPC contract
//            with the host library), so it is derived from `Containerization.version`.
//
// See docs/spikes/01-containerization-runtime-spike.md, "Kernel".

/// Everything `ContainerManager(kernel:initfsReference:…)` needs.
public struct RuntimeAssets: Sendable, Equatable {
    public var kernel: URL
    public var initfsReference: String

    public init(kernel: URL, initfsReference: String) {
        self.kernel = kernel
        self.initfsReference = initfsReference
    }
}

/// The Containerization package version, pinned `exact:` in Package.swift.
/// `RuntimeAssetsTests` fails if the two drift apart.
public enum Containerization {
    public static let version = "0.45.0"
    public static let vminitReference = "ghcr.io/apple/containerization/vminit:\(version)"
}

/// A kernel pinned by content: where to get it and what it must hash to.
public struct KernelSpec: Sendable, Equatable {
    /// Human-readable origin, for progress and error messages.
    public var name: String
    /// A `.tar.xz` release archive containing the kernel.
    public var archiveURL: URL
    /// Directory inside the archive to extract (as `tar` names it).
    public var archiveDirectory: String
    /// File (usually a symlink) inside `archiveDirectory` that is the kernel.
    public var archiveMember: String
    public var approximateDownloadMB: Int
    /// Lowercase hex SHA-256 of the kernel file itself.
    public var sha256: String
    public var size: Int

    public init(
        name: String, archiveURL: URL, archiveDirectory: String, archiveMember: String,
        approximateDownloadMB: Int, sha256: String, size: Int
    ) {
        self.name = name
        self.archiveURL = archiveURL
        self.archiveDirectory = archiveDirectory
        self.archiveMember = archiveMember
        self.approximateDownloadMB = approximateDownloadMB
        self.sha256 = sha256
        self.size = size
    }

    /// Kata Containers 3.17.0 `vmlinux.container` (Linux 6.12.28).
    public static let kata = KernelSpec(
        name: "Kata Containers 3.17.0 kernel",
        archiveURL: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz")!,
        archiveDirectory: "./opt/kata/share/kata-containers/",
        archiveMember: "vmlinux.container",
        approximateDownloadMB: 290,
        sha256: "67bac9f416af4cdc9b151e4ba4962d6515e0ad7acc53816761cf964aa6af6ea0",
        size: 14_750_208
    )

    /// Where the kernel is kept once verified.
    var fileName: String { "vmlinux-\(sha256.prefix(12))" }
}

public protocol RuntimeAssetProviding: Sendable {
    /// Returns the kernel and vminit reference, fetching the kernel on first
    /// use. Idempotent and cheap once the kernel is in place. `progress`
    /// receives one-line human-readable status messages.
    func ensureRuntimeAssets(progress: @Sendable (String) -> Void) async throws(DrupalError) -> RuntimeAssets
}

/// Gets a `KernelSpec`'s archive onto disk and extracts the kernel from it.
public protocol KernelFetching: Sendable {
    /// Writes the kernel described by `spec` to `destination`. Need not
    /// verify it; the caller does.
    func fetch(_ spec: KernelSpec, to destination: URL, workDirectory: URL) async throws(DrupalError)
}

public struct RuntimeAssetStore: RuntimeAssetProviding {
    public var spec: KernelSpec
    /// drupal's own runtime directory; the kernel goes in `kernels/` under it.
    public var directory: URL
    /// Directories searched (not recursively) for a kernel matching `spec`
    /// before downloading, e.g. the `container` CLI's kernels directory.
    public var reuseDirectories: [URL]
    public var fetcher: any KernelFetching
    public var initfsReference: String

    public init(
        spec: KernelSpec = .kata,
        directory: URL,
        reuseDirectories: [URL] = [],
        fetcher: any KernelFetching = ArchiveKernelFetcher(),
        initfsReference: String = Containerization.vminitReference
    ) {
        self.spec = spec
        self.directory = directory
        self.reuseDirectories = reuseDirectories
        self.fetcher = fetcher
        self.initfsReference = initfsReference
    }

    public static func live() -> RuntimeAssetStore {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return RuntimeAssetStore(
            directory: support.appending(path: "drupal/runtime", directoryHint: .isDirectory),
            reuseDirectories: [support.appending(path: "com.apple.container/kernels", directoryHint: .isDirectory)]
        )
    }

    public var kernelFile: URL {
        directory.appending(path: "kernels").appending(path: spec.fileName)
    }

    public func ensureRuntimeAssets(progress: @Sendable (String) -> Void) async throws(DrupalError) -> RuntimeAssets {
        let assets = RuntimeAssets(kernel: kernelFile, initfsReference: initfsReference)
        let fm = FileManager.default

        if fm.fileExists(atPath: kernelFile.path) {
            if matches(kernelFile) { return assets }
            // Truncated or tampered: replace it rather than boot it.
            progress("Kernel at \(kernelFile.filePath) failed its checksum; fetching it again")
            try? fm.removeItem(at: kernelFile)
        }

        // Stage everything in the destination volume so the final move is atomic
        // and a concurrent `start` never sees a partial kernel.
        let kernels = kernelFile.deletingLastPathComponent()
        let work = directory.appending(path: "tmp-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: kernels, withIntermediateDirectories: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw DrupalError(.ioError, "could not create \(work.deletingLastPathComponent().filePath): \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: work) }
        let staged = work.appending(path: spec.fileName)

        if let existing = reusableKernel() {
            progress("Using the kernel already installed at \(existing.filePath)")
            do {
                try fm.copyItem(at: existing, to: staged)
            } catch {
                throw DrupalError(.ioError, "could not copy \(existing.filePath): \(error.localizedDescription)")
            }
        } else {
            progress("Downloading the \(spec.name) (one-time, about \(spec.approximateDownloadMB) MB) from \(spec.archiveURL.absoluteString)")
            try await fetcher.fetch(spec, to: staged, workDirectory: work)
            guard matches(staged) else {
                throw DrupalError(
                    .runtimeAssetsUnavailable,
                    "the downloaded kernel does not match its pinned SHA-256 (\(spec.sha256))",
                    hint: "Rerun `drupal start`; if it keeps failing, the release archive at \(spec.archiveURL.absoluteString) has changed."
                )
            }
        }

        // Another `start` may have finished first; its identical file is fine.
        if fm.fileExists(atPath: kernelFile.path), matches(kernelFile) { return assets }
        do {
            _ = try fm.replaceItemAt(kernelFile, withItemAt: staged)
        } catch {
            throw DrupalError(.ioError, "could not install the kernel at \(kernelFile.filePath): \(error.localizedDescription)")
        }
        progress("Kernel installed at \(kernelFile.filePath)")
        return assets
    }

    private func reusableKernel() -> URL? {
        let fm = FileManager.default
        for dir in reuseDirectories {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = entry.resolvingSymlinksInPath()
                if matches(file) { return file }
            }
        }
        return nil
    }

    /// Size check first so unrelated files are never read in full.
    func matches(_ file: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue == spec.size,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == spec.sha256
    }
}

/// Downloads the release archive and extracts the kernel with `/usr/bin/tar`
/// (bsdtar reads `.tar.xz` natively).
public struct ArchiveKernelFetcher: KernelFetching {
    public init() {}

    public func fetch(_ spec: KernelSpec, to destination: URL, workDirectory: URL) async throws(DrupalError) {
        let archive = workDirectory.appending(path: "kernel.tar.xz")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: spec.archiveURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: downloaded)
                throw DrupalError(
                    .runtimeAssetsUnavailable,
                    "downloading the kernel failed: HTTP \(http.statusCode) from \(spec.archiveURL.absoluteString)"
                )
            }
            try FileManager.default.moveItem(at: downloaded, to: archive)
        } catch let error as DrupalError {
            throw error
        } catch {
            throw DrupalError(
                .runtimeAssetsUnavailable,
                "downloading the kernel failed: \(error.localizedDescription)",
                hint: "Check the network connection and rerun `drupal start`; nothing was left half-installed."
            )
        }

        let extracted = workDirectory.appending(path: "extracted", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", extracted.path, spec.archiveDirectory]
        let stderr = Pipe()
        tar.standardError = stderr
        tar.standardOutput = FileHandle.nullDevice
        do {
            try tar.run()
        } catch {
            throw DrupalError(.runtimeAssetsUnavailable, "could not run /usr/bin/tar: \(error.localizedDescription)")
        }
        let tarErrors = stderr.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let message = String(decoding: tarErrors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DrupalError(.runtimeAssetsUnavailable, "extracting the kernel from the archive failed: \(message)")
        }

        let member = extracted.appending(path: spec.archiveDirectory).appending(path: spec.archiveMember)
            .resolvingSymlinksInPath()
        do {
            try FileManager.default.moveItem(at: member, to: destination)
        } catch {
            throw DrupalError(
                .runtimeAssetsUnavailable,
                "the archive has no \(spec.archiveMember) under \(spec.archiveDirectory)"
            )
        }
    }
}
