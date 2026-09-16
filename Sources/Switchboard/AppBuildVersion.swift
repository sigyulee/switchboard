import Foundation

struct AppBuildVersion {
    let release: String?
    let beta: Bool

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        beta = info["SwitchboardReleaseChannel"] as? String == "beta"
        release = info["CFBundleShortVersionString"] as? String
    }

    var display: String {
        guard let release, !release.isEmpty else { return "—" }
        return beta ? "\(release) beta" : release
    }
}
