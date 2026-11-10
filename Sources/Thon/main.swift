import Foundation

let cliArgs = CommandLine.arguments
if cliArgs.contains("--dump") {
    runDump(cliArgs)
} else if cliArgs.contains("--selftest") {
    let gpu = runSelfTest()
    let cpu = runPickTests(cliArgs)      // CPU-only logic tests (MRC, picks, auto-picker, IO)
    exit(gpu != 0 || cpu != 0 ? 1 : 0)
} else if cliArgs.contains("--autopick") {
    exit(runAutoPickCLI(cliArgs))
} else if cliArgs.contains("--export-picks") {
    exit(runExportCLI(cliArgs))
} else if cliArgs.contains("--picktest") {
    exit(runPickTests(cliArgs))
} else if cliArgs.contains("--render") {
    exit(runRender(cliArgs))
} else {
    ThonApp.main()
}
