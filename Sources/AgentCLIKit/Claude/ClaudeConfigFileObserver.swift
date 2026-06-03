import Foundation
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Darwin)
final class ClaudeConfigFileObserver: @unchecked Sendable {
    private let configURL: URL
    private let queue = DispatchQueue(label: "com.agentclikit.claude-config-observer")
    private let onChange: @Sendable () -> Void
    private var directoryDescriptor: CInt = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var fileSource: DispatchSourceFileSystemObject?

    init?(configURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.configURL = configURL
        self.onChange = onChange

        let directoryURL = configURL.deletingLastPathComponent()
        directoryDescriptor = open(directoryURL.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            return nil
        }

        let directorySource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )
        directorySource.setEventHandler { [weak self] in
            self?.refreshFileSource()
            onChange()
        }
        directorySource.setCancelHandler { [directoryDescriptor] in
            close(directoryDescriptor)
        }
        directorySource.resume()
        self.directorySource = directorySource

        refreshFileSource()
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private func refreshFileSource() {
        guard fileSource == nil,
              FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }

        fileDescriptor = open(configURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )
        fileSource.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            let event = self.fileSource?.data ?? []
            if event.contains(.delete) || event.contains(.rename) {
                self.fileSource?.cancel()
                self.fileSource = nil
                self.refreshFileSource()
            }
            onChange()
        }
        fileSource.setCancelHandler { [descriptor = fileDescriptor] in
            close(descriptor)
        }
        fileSource.resume()
        self.fileSource = fileSource
    }
}
#else
final class ClaudeConfigFileObserver: @unchecked Sendable {
    init?(configURL: URL, onChange: @escaping @Sendable () -> Void) {
        return nil
    }
}
#endif
