import Foundation
import struct TSCUtility.Version
import TuistCore
import TuistSupport
import XcodeGraph

public protocol GraphLinting: AnyObject {
    func lint(graphTraverser: GraphTraversing, config: Config) -> [LintingIssue]
}

// swiftlint:disable type_body_length
public class GraphLinter: GraphLinting {
    // MARK: - Attributes

    private let projectLinter: ProjectLinting
    private let staticProductsLinter: StaticProductsGraphLinting

    // MARK: - Init

    public convenience init() {
        let projectLinter = ProjectLinter()
        let staticProductsLinter = StaticProductsGraphLinter()
        self.init(
            projectLinter: projectLinter,
            staticProductsLinter: staticProductsLinter
        )
    }

    init(
        projectLinter: ProjectLinting,
        staticProductsLinter: StaticProductsGraphLinting
    ) {
        self.projectLinter = projectLinter
        self.staticProductsLinter = staticProductsLinter
    }

    // MARK: - GraphLinting

    public func lint(graphTraverser: GraphTraversing, config: Config) -> [LintingIssue] {
        var issues: [LintingIssue] = []
        issues.append(contentsOf: graphTraverser.projects.flatMap { project -> [LintingIssue] in
            projectLinter.lint(project.value)
        })
        issues.append(contentsOf: lintDependencies(graphTraverser: graphTraverser, config: config))
        issues.append(contentsOf: lintMismatchingConfigurations(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintWatchBundleIndentifiers(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintCodeCoverageMode(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintWorkspaceUnuesedTargetsInWorkspace(graphTraverser: graphTraverser))
        return issues
    }

    // MARK: - Fileprivate

    private func lintWorkspaceUnuesedTargetsInWorkspace(graphTraverser: GraphTraversing) -> [LintingIssue] {
        graphTraverser.workspace.schemes.map { scheme in
            let arr = scheme
                .targetDependencies()
                .filter { targetReference in
                    if let target = graphTraverser
                        .targets()[targetReference.projectPath],
                        target.keys.contains(targetReference.name)
                    {
                        return false
                    }
                    return true
                }
                .map(\.name)
            return LintingIssue(
                reason: "Cannot find targets \(arr.joined(separator: ", ")) defined in \(scheme.name)",
                severity: .warning
            )
        }
    }

    private func lintCodeCoverageMode(graphTraverser: GraphTraversing) -> [LintingIssue] {
        switch graphTraverser.workspace.generationOptions.autogeneratedWorkspaceSchemes.codeCoverageMode {
        case .disabled, .all: return []
        case .relevant:
            let targets = graphTraverser.workspace.codeCoverageTargets(projects: Array(graphTraverser.projects.values))

            if targets.isEmpty {
                return [
                    LintingIssue(
                        reason: "Cannot find any any targets configured for code coverage, perhaps you wanted to use `CodeCoverageMode.all`?",
                        severity: .warning
                    ),
                ]
            }

            return []
        case let .targets(targets):
            if targets.isEmpty {
                return [LintingIssue(reason: "List of targets for code coverage is empty", severity: .warning)]
            }

            let nonExistingTargets = targets
                .filter { target in
                    graphTraverser.target(
                        path: target.projectPath,
                        name: target.name
                    ) == nil
                }

            guard !nonExistingTargets.isEmpty else { return [] }

            return nonExistingTargets.map {
                LintingIssue(reason: "Target '\($0.name)' at '\($0.projectPath)' doesn't exist", severity: .error)
            }
        }
    }

    private func lintDependencies(graphTraverser: GraphTraversing, config: Config) -> [LintingIssue] {
        var issues: [LintingIssue] = []

        issues.append(contentsOf: lintDependencyRelationships(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintLinkableDependencies(graphTraverser: graphTraverser))
        issues.append(contentsOf: staticProductsLinter.lint(graphTraverser: graphTraverser, config: config))
        issues.append(contentsOf: lintPrecompiledFrameworkDependencies(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintPackageDependencies(graphTraverser: graphTraverser))
        issues.append(contentsOf: lintAppClip(graphTraverser: graphTraverser))

        return issues
    }

    private func lintLinkableDependencies(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let linkableProducts: Set<Product> = [
            .framework,
            .staticFramework,
            .staticLibrary,
            .dynamicLibrary,
        ]

        let dependencyIssues = graphTraverser.dependencies.flatMap { fromDependency, _ -> [LintingIssue] in
            guard case let GraphDependency.target(fromTargetName, fromTargetPath) = fromDependency,
                  let fromTarget = graphTraverser.target(path: fromTargetPath, name: fromTargetName) else { return [] }

            let fromPlatforms = fromTarget.target.supportedPlatforms

            let dependencies: [LintingIssue] = graphTraverser.directTargetDependencies(path: fromTargetPath, name: fromTargetName)
                .flatMap { dependentTarget in
                    guard linkableProducts.contains(dependentTarget.target.product) else { return [LintingIssue]() }

                    var requiredPlatforms = fromPlatforms

                    if let condition = dependentTarget.condition {
                        requiredPlatforms.formIntersection(Set(condition.platformFilters.compactMap(\.platform)))
                    }

                    let platformsSupportedByDependency = dependentTarget.target.supportedPlatforms
                    let unaccountedPlatforms = requiredPlatforms.subtracting(platformsSupportedByDependency)

                    if !unaccountedPlatforms.isEmpty {
                        let missingPlatforms = unaccountedPlatforms.map(\.rawValue).joined(separator: ", ")
                        return [LintingIssue(
                            reason: "Target \(fromTargetName) which depends on \(dependentTarget.target.name) does not support the required platforms: \(missingPlatforms). The dependency on \(dependentTarget.target.name) must have a dependency condition constraining to at most: \(platformsSupportedByDependency.map(\.rawValue).joined(separator: ", ")).",
                            severity: .error
                        )]
                    } else {
                        return [LintingIssue]()
                    }
                }

            return dependencies
        }

        return dependencyIssues
    }

    private func lintDependencyRelationships(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let dependencyIssues = graphTraverser.dependencies.flatMap { fromDependency, toDependencies -> [LintingIssue] in
            toDependencies.flatMap { toDependency -> [LintingIssue] in
                guard case let GraphDependency.target(fromTargetName, fromTargetPath) = fromDependency else { return [] }
                guard case let GraphDependency.target(toTargetName, toTargetPath) = toDependency else { return [] }
                guard let fromTarget = graphTraverser.target(path: fromTargetPath, name: fromTargetName) else { return [] }
                guard let toTarget = graphTraverser.target(path: toTargetPath, name: toTargetName) else { return [] }
                return lintDependency(from: fromTarget, to: toTarget)
            }
        }
        return dependencyIssues
    }

    private func lintDependency(from: GraphTarget, to: GraphTarget) -> [LintingIssue] {
        let fromPlatforms = from.target.supportedPlatforms
        let toPlatforms = to.target.supportedPlatforms

        var validLinksCount = 0
        for fromPlatform in fromPlatforms {
            let fromTarget = LintableTarget(
                platform: fromPlatform,
                product: from.target.product
            )

            guard let supportedTargets = GraphLinter.validLinks[fromTarget] else {
                let reason =
                    "Target \(from.target.name) has platform '\(fromPlatform)' and product '\(from.target.product)' which is an invalid or not yet supported combination."
                return [LintingIssue(reason: reason, severity: .error)]
            }

            let toLintTargets = toPlatforms.map {
                LintableTarget(platform: $0, product: to.target.product)
            }

            let validLinks = Set(toLintTargets).intersection(supportedTargets)
            validLinksCount += validLinks.count
        }

        // Need to have at least one valid link based on common platforms
        guard validLinksCount > 0 else {
            let reason =
                "Target \(from.target.name) has platforms '\(fromPlatforms.map(\.caseValue).listed())' and product '\(from.target.product)' and depends on target \(to.target.name) of type '\(to.target.product)' and platforms '\(toPlatforms.map(\.caseValue).listed())' which is an invalid or not yet supported combination."
            return [LintingIssue(reason: reason, severity: .error)]
        }

        return []
    }

    private func lintMismatchingConfigurations(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let rootProjects = graphTraverser.rootProjects()

        let knownConfigurations = rootProjects.reduce(into: Set()) {
            $0.formUnion(Set($1.settings.configurations.keys))
        }

        let projectBuildConfigurations = graphTraverser.projects.compactMap { project in
            (name: project.value.name, buildConfigurations: Set(project.value.settings.configurations.keys))
        }

        let mismatchingBuildConfigurations = projectBuildConfigurations.filter {
            !knownConfigurations.isSubset(of: $0.buildConfigurations)
        }

        return mismatchingBuildConfigurations.map {
            let expectedConfigurations = knownConfigurations.sorted()
            let configurations = $0.buildConfigurations.sorted()
            let reason =
                "The project '\($0.name)' has missing or mismatching configurations. It has \(configurations), other projects have \(expectedConfigurations)"
            return LintingIssue(
                reason: reason,
                severity: .warning
            )
        }
    }

    /// It verifies setup for packages
    ///
    /// - Parameter graphTraverser: Project graph.
    /// - Returns: Linting issues.
    private func lintPackageDependencies(graphTraverser: GraphTraversing) -> [LintingIssue] {
        guard graphTraverser.hasPackages else { return [] }

        let version: Version
        do {
            version = try XcodeController.shared.selectedVersion()
        } catch {
            return [LintingIssue(reason: "Could not determine Xcode version", severity: .error)]
        }

        if version.major < 11 {
            let reason =
                "The project contains package dependencies but the selected version of Xcode is not compatible. Need at least 11 but got \(version)"
            return [LintingIssue(reason: reason, severity: .error)]
        }

        return []
    }

    private func lintAppClip(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let apps = graphTraverser.apps()

        let issues = apps.flatMap { app -> [LintingIssue] in
            let appClips = graphTraverser.directLocalTargetDependencies(path: app.path, name: app.target.name)
                .filter { $0.target.product == .appClip }

            if appClips.count > 1 {
                return [
                    LintingIssue(
                        reason: "\(app) cannot depend on more than one app clip: \(appClips.map(\.target.name).sorted().listed())",
                        severity: .error
                    ),
                ]
            }

            return appClips.flatMap { appClip -> [LintingIssue] in
                lint(appClip: appClip.graphTarget, parentApp: app)
            }
        }

        return issues
    }

    private func lintPrecompiledFrameworkDependencies(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let frameworks = graphTraverser.precompiledFrameworksPaths()

        return frameworks
            .filter { !FileHandler.shared.exists($0) }
            .map { LintingIssue(reason: "Framework not found at path \($0.pathString)", severity: .error) }
    }

    private func lintWatchBundleIndentifiers(graphTraverser: GraphTraversing) -> [LintingIssue] {
        let apps = graphTraverser.apps()

        let issues = apps.flatMap { app -> [LintingIssue] in
            let watchApps = graphTraverser.directLocalTargetDependencies(path: app.path, name: app.target.name)
                .filter { $0.target.product == .watch2App }

            return watchApps.flatMap { watchApp -> [LintingIssue] in
                let watchAppTarget = watchApp.graphTarget
                let watchAppIssues = lint(watchApp: watchAppTarget, parentApp: app)
                let watchExtensions = graphTraverser.directLocalTargetDependencies(
                    path: watchAppTarget.path,
                    name: watchAppTarget.target.name
                )
                .filter { $0.target.product == .watch2Extension }

                let watchExtensionIssues = watchExtensions.flatMap { watchExtension in
                    lint(watchExtension: watchExtension.graphTarget, parentWatchApp: watchAppTarget)
                }
                return watchAppIssues + watchExtensionIssues
            }
        }

        return issues
    }

    private func lint(watchApp: GraphTarget, parentApp: GraphTarget) -> [LintingIssue] {
        guard watchApp.target.bundleId.hasPrefix(parentApp.target.bundleId) else {
            return [
                LintingIssue(reason: """
                Watch app '\(watchApp.target.name)' bundleId: \(
                    watchApp.target
                        .bundleId
                ) isn't prefixed with its parent's app '\(parentApp.target.bundleId)' bundleId '\(
                    parentApp.target
                        .bundleId
                )'
                """, severity: .error),
            ]
        }
        return []
    }

    private func lint(watchExtension: GraphTarget, parentWatchApp: GraphTarget) -> [LintingIssue] {
        guard watchExtension.target.bundleId.hasPrefix(parentWatchApp.target.bundleId) else {
            return [
                LintingIssue(reason: """
                Watch extension '\(watchExtension.target.name)' bundleId: \(
                    watchExtension.target
                        .bundleId
                ) isn't prefixed with its parent's watch app '\(
                    parentWatchApp.target
                        .bundleId
                )' bundleId '\(parentWatchApp.target.bundleId)'
                """, severity: .error),
            ]
        }
        return []
    }

    private func lint(appClip: GraphTarget, parentApp: GraphTarget) -> [LintingIssue] {
        var foundIssues = [LintingIssue]()

        if !appClip.target.bundleId.hasPrefix(parentApp.target.bundleId) {
            foundIssues.append(
                LintingIssue(reason: """
                AppClip '\(appClip.target.name)' bundleId: \(
                    appClip.target
                        .bundleId
                ) isn't prefixed with its parent's app '\(parentApp.target.name)' bundleId '\(
                    parentApp.target
                        .bundleId
                )'
                """, severity: .error)
            )
        }

        if let entitlements = appClip.target.entitlements {
            if case let .file(path: path) = entitlements, !FileHandler.shared.exists(path) {
                foundIssues
                    .append(LintingIssue(
                        reason: "The entitlements at path '\(path.pathString)' referenced by target does not exist",
                        severity: .error
                    ))
            }
        } else {
            foundIssues.append(LintingIssue(
                reason: "An AppClip '\(appClip.target.name)' requires its Parent Application Identifiers Entitlement to be set",
                severity: .error
            ))
        }

        return foundIssues
    }

    struct LintableTarget: Equatable, Hashable {
        let platform: XcodeGraph.Platform
        let product: Product
    }

    static let validLinks: [LintableTarget: [LintableTarget]] = [
        // iOS products
        LintableTarget(platform: .iOS, product: .app): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .iOS, product: .appExtension),
            LintableTarget(platform: .iOS, product: .messagesExtension),
            LintableTarget(platform: .iOS, product: .stickerPackExtension),
            LintableTarget(platform: .watchOS, product: .watch2App),
            LintableTarget(platform: .watchOS, product: .app),
            LintableTarget(platform: .iOS, product: .appClip),
//            LintableTarget(platform: .watchOS, product: .watchApp),
            LintableTarget(platform: .iOS, product: .extensionKitExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .staticLibrary): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .staticFramework): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .dynamicLibrary): [
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .framework): [
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .unitTests): [
            LintableTarget(platform: .iOS, product: .app),
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .iOS, product: .appClip),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .uiTests): [
            LintableTarget(platform: .iOS, product: .app),
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .iOS, product: .appClip),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .appExtension): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .appClip): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .appExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .extensionKitExtension): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .messagesExtension): [
            LintableTarget(platform: .iOS, product: .staticFramework),
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .iOS, product: .stickerPackExtension): [
            LintableTarget(platform: .iOS, product: .staticLibrary),
            LintableTarget(platform: .iOS, product: .dynamicLibrary),
            LintableTarget(platform: .iOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        // macOS
        LintableTarget(platform: .macOS, product: .app): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .appExtension),
            LintableTarget(platform: .macOS, product: .app),
            LintableTarget(platform: .macOS, product: .commandLineTool),
            LintableTarget(platform: .macOS, product: .xpc),
            LintableTarget(platform: .macOS, product: .systemExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .staticLibrary): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .staticFramework): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .dynamicLibrary): [
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .framework): [
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .unitTests): [
            LintableTarget(platform: .macOS, product: .app),
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .uiTests): [
            LintableTarget(platform: .macOS, product: .app),
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .appExtension): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .commandLineTool): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .xpc): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .app): [
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .dynamicLibrary),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .tvOS, product: .bundle),
            LintableTarget(platform: .tvOS, product: .tvTopShelfExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .uiTests): [
            LintableTarget(platform: .tvOS, product: .app),
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .dynamicLibrary),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .staticLibrary): [
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .staticFramework): [
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .dynamicLibrary): [
            LintableTarget(platform: .tvOS, product: .dynamicLibrary),
            LintableTarget(platform: .tvOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .framework): [
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .tvOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .unitTests): [
            LintableTarget(platform: .tvOS, product: .app),
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .dynamicLibrary),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .tvOS, product: .tvTopShelfExtension): [
            LintableTarget(platform: .tvOS, product: .staticLibrary),
            LintableTarget(platform: .tvOS, product: .dynamicLibrary),
            LintableTarget(platform: .tvOS, product: .framework),
            LintableTarget(platform: .tvOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .app): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .dynamicLibrary),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .appExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .watch2App): [
            LintableTarget(platform: .watchOS, product: .watch2Extension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .staticLibrary): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .staticFramework): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .dynamicLibrary): [
            LintableTarget(platform: .watchOS, product: .dynamicLibrary),
            LintableTarget(platform: .watchOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .framework): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .unitTests): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .watch2Extension),
            LintableTarget(platform: .watchOS, product: .app),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .uiTests): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .watch2App),
            LintableTarget(platform: .watchOS, product: .app),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .watchOS, product: .watch2Extension): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .dynamicLibrary),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .appExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],

        LintableTarget(platform: .watchOS, product: .appExtension): [
            LintableTarget(platform: .watchOS, product: .staticLibrary),
            LintableTarget(platform: .watchOS, product: .dynamicLibrary),
            LintableTarget(platform: .watchOS, product: .staticFramework),
            LintableTarget(platform: .watchOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .macOS, product: .systemExtension): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .dynamicLibrary),
            LintableTarget(platform: .macOS, product: .framework),
            LintableTarget(platform: .macOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],

        // visionOS products
        LintableTarget(platform: .visionOS, product: .app): [
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .dynamicLibrary),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .visionOS, product: .appExtension),
            LintableTarget(platform: .visionOS, product: .extensionKitExtension),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .staticLibrary): [
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .staticFramework): [
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .dynamicLibrary): [
            LintableTarget(platform: .visionOS, product: .dynamicLibrary),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .framework): [
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .unitTests): [
            LintableTarget(platform: .visionOS, product: .app),
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .dynamicLibrary),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .bundle),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .appExtension): [
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .dynamicLibrary),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        LintableTarget(platform: .visionOS, product: .extensionKitExtension): [
            LintableTarget(platform: .visionOS, product: .staticLibrary),
            LintableTarget(platform: .visionOS, product: .dynamicLibrary),
            LintableTarget(platform: .visionOS, product: .framework),
            LintableTarget(platform: .visionOS, product: .staticFramework),
            LintableTarget(platform: .macOS, product: .macro),
        ],
        // Swift Macro
        LintableTarget(platform: .macOS, product: .macro): [
            LintableTarget(platform: .macOS, product: .staticLibrary),
            LintableTarget(platform: .macOS, product: .staticFramework),
        ],
    ]
} // swiftlint:enable type_body_length
