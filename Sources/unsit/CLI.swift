import Foundation

struct Options {
    var archivePath: String
    var outputDir: String?
    var list = false
    var quiet = false
    var noVerify = false
    var limits = Limits()
}

enum CLIAction { case help, selfTest, archive(Options) }

let helpText = """
unsit — extract classic StuffIt (SIT!) archives

Usage: unsit [options] <archive.sit> [output-directory]

  -l, --list        List contents (also with --quiet)
  -o, --output DIR  Extract into DIR
  -q, --quiet       Only warnings/errors during extraction
      --no-verify   Skip fork CRC checks, retain structural checks
      --self-test   Run built-in table/CRC checks
  -h, --help        Show help successfully
      --           End options; remaining tokens are paths

  --max-input-bytes N     Input limit (default 268435456)
  --max-fork-bytes N      Decoded fork limit (default 67108864)
  --max-total-bytes N     Aggregate decoded limit (default 536870912)
  --max-members N         Member-record limit (default 100000)
  --max-depth N           Folder nesting limit (default 128)
  --max-recovery-bytes N  Recovery scan limit (default 1048576)

Limits are nonnegative integers. Conflicting output forms or self-test and
archive actions are usage errors. Existing output is preserved.
"""

func parseArguments(_ args: [String]) throws -> CLIAction {
    var opts = Options(archivePath: "")
    var positional: [String] = []
    var index = 0, optionsEnded = false, selfTest = false, help = false
    var extractionOption = false
    func invalid(_ message: String) -> MacFileWriter.WriteError { .init(description: message) }
    func value(for option: String) throws -> String {
        guard index < args.count else { throw invalid("missing value for \(option)") }
        let value = args[index]; index += 1
        return value
    }
    while index < args.count {
        let a = args[index]; index += 1
        if optionsEnded { positional.append(a); continue }
        switch a {
        case "--": optionsEnded = true
        case "-h", "--help": help = true
        case "--self-test": selfTest = true
        case "-l", "--list": opts.list = true; extractionOption = true
        case "-q", "--quiet": opts.quiet = true; extractionOption = true
        case "--no-verify": opts.noVerify = true; extractionOption = true
        case "-o", "--output":
            guard opts.outputDir == nil else { throw invalid("conflicting output destinations") }
            opts.outputDir = try value(for: a); extractionOption = true
        case "--max-input-bytes", "--max-fork-bytes", "--max-total-bytes", "--max-members", "--max-depth", "--max-recovery-bytes":
            let raw = try value(for: a)
            guard let n = Int(raw), n >= 0 else { throw invalid("invalid nonnegative limit for \(a): \(raw)") }
            extractionOption = true
            switch a {
            case "--max-input-bytes": opts.limits.inputBytes = n
            case "--max-fork-bytes": opts.limits.forkBytes = n
            case "--max-total-bytes": opts.limits.totalBytes = n
            case "--max-members": opts.limits.members = n
            case "--max-depth": opts.limits.depth = n
            default: opts.limits.recoveryBytes = n
            }
        default:
            guard !a.hasPrefix("-") || a == "-" else { throw invalid("unknown option \(a)") }
            positional.append(a)
        }
    }
    if help { return .help }
    if selfTest {
        guard positional.isEmpty, !extractionOption else { throw invalid("--self-test conflicts with archive/extraction arguments") }
        return .selfTest
    }
    guard (1...2).contains(positional.count), !positional[0].isEmpty else { throw invalid("expected archive and optional output directory") }
    opts.archivePath = positional[0]
    if positional.count == 2 {
        guard opts.outputDir == nil else { throw invalid("conflicting --output and positional output destinations") }
        opts.outputDir = positional[1]
    }
    guard opts.outputDir != "" else { throw invalid("output directory must not be empty") }
    return .archive(opts)
}
