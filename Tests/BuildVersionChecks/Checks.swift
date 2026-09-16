import Foundation

@main struct BuildVersionChecks {
    static func main() {
        let version = AppBuildVersion(info: [
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "45",
            "SourceCommit": "private-commit", "GitBranch": "private-branch",
        ])
        precondition(version.display == "1.1.0", "Internal build numbers must stay out of the app UI")
        precondition(
            AppBuildVersion(info: [:]).display == "—", "Missing metadata must not invent an identity")
        precondition(
            AppBuildVersion(info: ["CFBundleShortVersionString": "1.1.0"]).display == "1.1.0",
            "Legacy metadata must remain readable")
        precondition(
            AppBuildVersion(info: [
                "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "5",
                "SwitchboardReleaseChannel": "beta",
            ]).display == "1.1.0 beta")
        print("4 semantic-version display checks passed; build and Git metadata are not displayed.")
    }
}
