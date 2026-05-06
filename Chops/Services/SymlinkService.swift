import SwiftData
import Foundation

enum SymlinkError: LocalizedError {
    case destinationExists(String)
    case notOurFile(String)
    case sourceNotFound(String)
    case noTargetDirectory(ToolSource, ItemKind)
    case renameDestinationExists(String)

    var errorDescription: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        switch self {
        case .destinationExists(let p):
            return "\(tilde(p)) already exists and is not our hard link."
        case .notOurFile(let p):
            return "\(tilde(p)) is not our hard link — refusing to remove."
        case .sourceNotFound(let p):
            return "Source file not found at \(tilde(p))."
        case .noTargetDirectory(let tool, let kind):
            return "\(tool.displayName) has no global directory for \(kind.displayName.lowercased())."
        case .renameDestinationExists(let p):
            return "A file named \"\(URL(fileURLWithPath: p).lastPathComponent)\" already exists."
        }
    }
}

@MainActor
final class SymlinkService {
    static let shared = SymlinkService()
    private let fm = FileManager.default

    private init() {}

    // MARK: - Link

    /// Creates a hard link in the vendor's global directory pointing at the same inode as `skill.resolvedPath`.
    func link(_ skill: Skill, to tool: ToolSource, context: ModelContext) throws {
        let source = skill.resolvedPath
        guard fm.fileExists(atPath: source) else {
            throw SymlinkError.sourceNotFound(source)
        }

        let targetDir = try vendorDirectory(for: tool, kind: skill.itemKind)
        let relativePath: String
        if tool.flattensLinks(for: skill.itemKind) {
            relativePath = URL(fileURLWithPath: source).lastPathComponent
        } else {
            relativePath = relativePathFromScanBase(source: source, kind: skill.itemKind, toolSources: skill.toolSources, installedPaths: skill.installedPaths)
        }
        let destination = useMarkdownExtension(
            tool, skill,
            URL(fileURLWithPath: targetDir).appendingPathComponent(relativePath)
        ).path
        let destinationParent = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destinationParent, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination) {
            // Idempotent if destination is already our link to source.
            guard isOurLink(at: destination, source: source, tool: tool, kind: skill.itemKind) else {
                throw SymlinkError.destinationExists(destination)
            }
        } else {
            if tool.usesHardLink(for: skill.itemKind) {
                try fm.linkItem(atPath: source, toPath: destination)
            } else {
                try fm.createSymbolicLink(atPath: destination, withDestinationPath: source)
            }
        }

        let targetID = "\(source)\n\(tool.rawValue)"
        let existingDescriptor = FetchDescriptor<SymlinkTarget>(predicate: #Predicate { $0.id == targetID })
        if let existingRecord = try context.fetch(existingDescriptor).first {
            if existingRecord.linkedPath == destination && existingRecord.kind == skill.itemKind.rawValue {
                // Hard link was recreated on disk after being marked broken — keep consistency.
                if existingRecord.isBroken {
                    existingRecord.isBroken = false
                    try context.save()
                    NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
                }
                return
            }
            // Stale record (e.g. kind changed after a bug fix) — remove only if it is our link.
            if fm.fileExists(atPath: existingRecord.linkedPath) {
                if isOurLink(at: existingRecord.linkedPath, source: source, tool: tool, kind: existingRecord.itemKind) {
                    do {
                        try fm.removeItem(atPath: existingRecord.linkedPath)
                    } catch {
                        AppLogger.fileIO.error("SymlinkService: failed to remove stale link at \(existingRecord.linkedPath): \(error.localizedDescription)")
                    }
                } else {
                    AppLogger.fileIO.warning("SymlinkService: stale record path \(existingRecord.linkedPath) is not our link — leaving file intact")
                }
            }
            context.delete(existingRecord)
        }

        context.insert(SymlinkTarget(
            skillResolvedPath: source,
            toolSource: tool,
            linkedPath: destination,
            kind: skill.itemKind
        ))
        try context.save()
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }

    // MARK: - Unlink

    /// Removes the hard link from the vendor directory and deletes the `SymlinkTarget` record.
    func unlink(_ skill: Skill, from tool: ToolSource, context: ModelContext) throws {
        let targetID = "\(skill.resolvedPath)\n\(tool.rawValue)"
        let descriptor = FetchDescriptor<SymlinkTarget>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try context.fetch(descriptor).first else { return }

        let path = record.linkedPath
        guard fm.fileExists(atPath: path) else {
            // File already gone — just clean up the record.
            context.delete(record)
            try context.save()
            return
        }

        if tool.usesHardLink(for: skill.itemKind) {
            // Hard link: require positive inode match. If source is gone and we can't confirm,
            // skip removal — the destination may be the last copy of the data.
            let srcInode = (try? fm.attributesOfItem(atPath: skill.resolvedPath))?[.systemFileNumber] as? UInt64
            let dstInode = (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
            guard let s = srcInode, let d = dstInode else {
                AppLogger.fileIO.warning("SymlinkService.unlink: cannot verify inode for \(path) — skipping removal, cleaning record only")
                context.delete(record)
                try context.save()
                return
            }
            guard s == d else {
                throw SymlinkError.notOurFile(path)
            }
        } else {
            // Soft link: verify the symlink points to our source before removing.
            let target = try? fm.destinationOfSymbolicLink(atPath: path)
            guard target == skill.resolvedPath else {
                throw SymlinkError.notOurFile(path)
            }
        }
        try fm.removeItem(atPath: path)

        context.delete(record)
        try context.save()
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }

    // MARK: - Reconcile

    /// Validates every `SymlinkTarget` record and syncs hard-link tool associations into
    /// `Skill.toolSources`. The scanner skips hard-link target directories, so those
    /// associations must be maintained here from the record state.
    func reconcile(context: ModelContext) {
        guard let records = try? context.fetch(FetchDescriptor<SymlinkTarget>()) else { return }
        let allSkills = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        let skillsByPath = Dictionary(uniqueKeysWithValues: allSkills.map { ($0.resolvedPath, $0) })

        var dirty = false
        // skillResolvedPath -> set of hard-link tools that have active (non-broken) records.
        var activeHardLinks: [String: Set<ToolSource>] = [:]

        for record in records {
            // Orphaned record — source skill no longer exists. Clean up the link and the record.
            guard skillsByPath[record.skillResolvedPath] != nil else {
                if fm.fileExists(atPath: record.linkedPath),
                   let tool = record.toolSourceEnum,
                   !tool.usesHardLink(for: record.itemKind),
                   (try? fm.destinationOfSymbolicLink(atPath: record.linkedPath)) == record.skillResolvedPath {
                    try? fm.removeItem(atPath: record.linkedPath)
                }
                context.delete(record)
                dirty = true
                continue
            }

            if let skill = skillsByPath[record.skillResolvedPath], skill.kind != record.kind {
                // Stale record — kind changed. Remove only if we can confirm it is our link.
                if fm.fileExists(atPath: record.linkedPath),
                   let tool = record.toolSourceEnum,
                   isOurLink(at: record.linkedPath, source: record.skillResolvedPath, tool: tool, kind: record.itemKind) {
                    do {
                        try fm.removeItem(atPath: record.linkedPath)
                    } catch {
                        AppLogger.fileIO.error("SymlinkService: failed to remove stale link at \(record.linkedPath): \(error.localizedDescription)")
                    }
                }
                context.delete(record)
                dirty = true
                continue
            }

            let broken = !fm.fileExists(atPath: record.linkedPath)
            if broken != record.isBroken {
                record.isBroken = broken
                dirty = true
            }
            if broken, let tool = record.toolSourceEnum, !tool.usesHardLink(for: record.itemKind),
               (try? fm.destinationOfSymbolicLink(atPath: record.linkedPath)) != nil {
                // Dangling soft link — remove the dead entry from the vendor directory.
                do {
                    try fm.removeItem(atPath: record.linkedPath)
                } catch {
                    AppLogger.fileIO.warning("SymlinkService.reconcile: failed to remove dangling link at \(record.linkedPath): \(error.localizedDescription)")
                }
                context.delete(record)
                dirty = true
            }

            // Collect active hard-link associations for toolSources sync below.
            if !record.isBroken,
               let tool = record.toolSourceEnum,
               tool.usesHardLink(for: record.itemKind) {
                activeHardLinks[record.skillResolvedPath, default: []].insert(tool)
            }
        }

        // Sync toolSources for hard-link tools, scoped to the skill's own kind.
        // A tool may use hard links for .agent but soft links for .rule — only manage the
        // toolSources slot for the combination that actually uses hard links. Scanner-discovered
        // entries for soft-linked kinds must be left untouched.
        for skill in allSkills {
            let hardLinkToolsForKind: Set<ToolSource> = Set(
                ToolSource.allCases.filter { $0.usesHardLink(for: skill.itemKind) }
            )
            guard !hardLinkToolsForKind.isEmpty else { continue }

            let activeLinked = activeHardLinks[skill.resolvedPath] ?? []
            let scannerOnly = skill.toolSources.filter { !hardLinkToolsForKind.contains($0) }
            let expectedSet = Set(scannerOnly).union(activeLinked)
            if expectedSet != Set(skill.toolSources) {
                skill.toolSources = ToolSource.allCases.filter { expectedSet.contains($0) }
                dirty = true
            }
        }

        if dirty {
            do {
                try context.save()
            } catch {
                AppLogger.fileIO.error("SymlinkService.reconcile save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Rename

    /// Renames the source file on disk and re-creates all vendor links under the new filename.
    /// Hard links are rebuilt from the new path; soft links are re-pointed to the new path.
    func rename(_ skill: Skill, to newBaseName: String, context: ModelContext) throws {
        guard !skill.isDirectory else { return }

        let oldPath = skill.resolvedPath
        let oldURL = URL(fileURLWithPath: oldPath)
        let ext = oldURL.pathExtension
        let newFilename = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newFilename)
        let newPath = newURL.path

        guard newPath != oldPath else { return }
        guard !fm.fileExists(atPath: newPath) else {
            throw SymlinkError.renameDestinationExists(newPath)
        }
        guard fm.fileExists(atPath: oldPath) else {
            throw SymlinkError.sourceNotFound(oldPath)
        }

        try fm.moveItem(atPath: oldPath, toPath: newPath)

        let descriptor = FetchDescriptor<SymlinkTarget>(
            predicate: #Predicate { $0.skillResolvedPath == oldPath }
        )
        let targets = (try? context.fetch(descriptor)) ?? []

        for target in targets {
            guard let tool = target.toolSourceEnum else { continue }
            let kind = target.itemKind
            let oldLinkedURL = URL(fileURLWithPath: target.linkedPath)
            let newLinkedURL = oldLinkedURL
                .deletingLastPathComponent()
                .appendingPathComponent(newBaseName)
                .appendingPathExtension(oldLinkedURL.pathExtension)
            let newLinkedPath = newLinkedURL.path

            // Remove old link (or dangling symlink entry)
            if fm.fileExists(atPath: target.linkedPath)
                || (try? fm.destinationOfSymbolicLink(atPath: target.linkedPath)) != nil {
                do {
                    try fm.removeItem(atPath: target.linkedPath)
                } catch {
                    AppLogger.fileIO.warning("SymlinkService.rename: failed to remove old link at \(target.linkedPath): \(error.localizedDescription)")
                }
            }

            // Re-create at new path; hard links rebuild from the renamed source
            do {
                if tool.usesHardLink(for: kind) {
                    try fm.linkItem(atPath: newPath, toPath: newLinkedPath)
                } else {
                    try fm.createSymbolicLink(atPath: newLinkedPath, withDestinationPath: newPath)
                }
                target.id = "\(newPath)\n\(tool.rawValue)"
                target.skillResolvedPath = newPath
                target.linkedPath = newLinkedPath
            } catch {
                AppLogger.fileIO.error("SymlinkService.rename: failed to re-link \(tool.rawValue) → \(newLinkedPath): \(error.localizedDescription)")
            }
        }

        skill.resolvedPath = newPath
        skill.filePath = newPath
        skill.installedPaths = skill.installedPaths.map { $0 == oldPath ? newPath : $0 }

        try context.save()
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }

    // MARK: - Query

    func targets(for skill: Skill, context: ModelContext) -> [SymlinkTarget] {
        let path = skill.resolvedPath
        let descriptor = FetchDescriptor<SymlinkTarget>(
            predicate: #Predicate { $0.skillResolvedPath == path && !$0.isBroken }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.fileIO.error("SymlinkService.targets fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private

    /// Swaps `.md` → `.mdc` on the last path component when the tool and kind require it.
    /// Cursor requires `.mdc` for both agents and rules.
    private func useMarkdownExtension(_ tool: ToolSource, _ skill: Skill, _ url: URL) -> URL {
        guard tool == .cursor,
              skill.itemKind == .agent || skill.itemKind == .rule,
              url.pathExtension == "md" else { return url }
        return url.deletingPathExtension().appendingPathExtension("mdc")
    }

    /// Returns true if the file at `path` is the link we created to `source`.
    /// For hard-link tools: confirms both paths share the same inode.
    /// For soft-link tools: confirms the symlink at `path` resolves to `source`.
    private func isOurLink(at path: String, source: String, tool: ToolSource, kind: ItemKind) -> Bool {
        if tool.usesHardLink(for: kind) {
            guard let srcInode = (try? fm.attributesOfItem(atPath: source))?[.systemFileNumber] as? UInt64,
                  let dstInode = (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64 else {
                return false
            }
            return srcInode == dstInode
        } else {
            let target = try? fm.destinationOfSymbolicLink(atPath: path)
            return target == source
        }
    }

    /// Returns `source` relative to its scan base, preserving subdirectory structure.
    private func relativePathFromScanBase(source: String, kind: ItemKind, toolSources: [ToolSource], installedPaths: [String]) -> String {
        // 1. Resolved path against own tool sources (fast path for non-symlinked skills).
        for toolSource in toolSources {
            for base in toolSource.globalDirs(for: kind) {
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if source.hasPrefix(prefix) {
                    return String(source.dropFirst(prefix.count))
                }
            }
        }
        // 2. Installed paths against own tool sources — resolvedPath may live outside all
        //    scan bases (e.g. ~/.aidevtools/rules/python/file) but an installed path like
        //    ~/.augment/rules/python/file still carries the correct relative structure.
        for toolSource in toolSources {
            for base in toolSource.globalDirs(for: kind) {
                let prefix = base.hasSuffix("/") ? base : base + "/"
                for path in installedPaths where path.hasPrefix(prefix) {
                    return String(path.dropFirst(prefix.count))
                }
            }
        }
        // 3. Search all tool sources (catches shared-library sources not in toolSources).
        for toolSource in ToolSource.allCases {
            for base in toolSource.globalDirs(for: kind) {
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if source.hasPrefix(prefix) {
                    return String(source.dropFirst(prefix.count))
                }
            }
        }
        let fallback = URL(fileURLWithPath: source).lastPathComponent
        AppLogger.fileIO.warning("SymlinkService: no scan base found for \(source), falling back to filename '\(fallback)' — collision possible if other skills share this name")
        return fallback
    }

    private func vendorDirectory(for tool: ToolSource, kind: ItemKind) throws -> String {
        guard let dir = tool.globalDirs(for: kind).first else {
            throw SymlinkError.noTargetDirectory(tool, kind)
        }
        return dir
    }
}
