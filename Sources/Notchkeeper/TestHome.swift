import Foundation
import Darwin

/// 自检和演示在临时 HOME 里跑：日志、配置、偏好、guard-state 的路径全跟着走，绝不写真实的 ~/Library。
/// 做法是带上 CFFIXED_USER_HOME 重新 exec 自己：CoreFoundation 在进程启动时读它，
/// homeDirectoryForCurrentUser 和 applicationSupportDirectory（含 GuardCore 的 GuardPaths）都跟着变；
/// 进程中途再 setenv 已经来不及，只改 HOME 也不行（实测 Application Support 仍指向真实主目录）。
/// 自检第一项会核对确实没落在真实主目录下（SelfTest.isolationTest）。临时目录不删，留给系统清理临时目录。
/// @see https://developer.apple.com/documentation/foundation/filemanager/homedirectoryforcurrentuser
/// @see https://developer.apple.com/documentation/foundation/filemanager/temporarydirectory
enum TestHome {
    private static let marker = "NOTCHKEEPER_TEST_HOME"

    /// 已在临时 HOME 里就直接返回；否则建临时目录、换 HOME 后 exec 自己（不返回）
    static func enter(arguments: [String]) {
        let env = ProcessInfo.processInfo.environment
        if let home = env[marker], env["CFFIXED_USER_HOME"] == home, !isUnderRealHome(URL(fileURLWithPath: home)) { return }
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("nk-test-XXXXXX").path
        var buf = Array(template.utf8CString)
        guard let exe = Bundle.main.executablePath, mkdtemp(&buf) != nil else {
            print("FAIL  无法建立临时 HOME")
            exit(1)
        }
        let home = String(cString: buf)
        setenv("CFFIXED_USER_HOME", home, 1)
        setenv("HOME", home, 1)
        setenv(marker, home, 1)
        let argv = arguments.map { strdup($0) } + [nil]
        execv(exe, argv)
        print("FAIL  无法在临时 HOME 里重启自检：\(String(cString: strerror(errno)))")
        exit(1)
    }

    /// 按账户数据库求的真实主目录，不受 HOME / CFFIXED_USER_HOME 影响
    static let realHome: URL? = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }

    static func isUnderRealHome(_ url: URL) -> Bool {
        guard let real = realHome?.standardizedFileURL.path else { return true }
        let p = url.standardizedFileURL.path
        return p == real || p.hasPrefix(real + "/")
    }
}
