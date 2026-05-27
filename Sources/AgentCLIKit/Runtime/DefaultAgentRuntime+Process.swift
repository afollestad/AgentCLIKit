import Foundation

extension DefaultAgentRuntime {
    func makeProcess(launch: AgentLaunchConfiguration, config: AgentSpawnConfig) -> PreparedProcess {
        processFactory(launch, config)
    }

    static func defaultProcessFactory(launch: AgentLaunchConfiguration, config: AgentSpawnConfig) -> PreparedProcess {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(config.environment) { _, new in new }
        environment.merge(launch.environment) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.includesSpawnArguments ? launch.arguments : launch.arguments + config.arguments
        process.currentDirectoryURL = launch.workingDirectory ?? config.workingDirectory
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        return PreparedProcess(process: process, stdout: stdout, stderr: stderr, stdin: stdin)
    }

    static func defaultSleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
