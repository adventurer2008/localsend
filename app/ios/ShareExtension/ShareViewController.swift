import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let done = UIButton(type: .system)
    private let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.textAlignment = .center
        message.numberOfLines = 0
        message.text = chinese ? "正在导入到 LocalSend…" : "Importing into LocalSend…"
        spinner.startAnimating()
        done.setTitle(chinese ? "完成" : "Done", for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isHidden = true
        let stack = UIStackView(arrangedSubviews: [spinner, message, done])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])

        Task {
            defer {
                spinner.stopAnimating()
                done.isHidden = false
            }
            do {
                let failed = try await saveShare()
                if failed > 0 {
                    message.text = chinese ? "已导入可读取的内容。打开 LocalSend 后可发送。" : "Readable items imported. Open LocalSend to send them."
                } else {
                    message.text = chinese ? "已导入。打开 LocalSend 后可发送。" : "Imported. Open LocalSend to send."
                }
            } catch {
                message.text = chinese ? "无法导入共享内容。" : "Could not import the shared items."
            }
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func saveShare() async throws -> Int {
        let files = FileManager.default
        guard let group = files.containerURL(forSecurityApplicationGroupIdentifier: "group.org.localsend.localsendApp") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = group.appendingPathComponent("IncomingShares", isDirectory: true)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent("." + id, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let providers = (extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []).flatMap { $0.attachments ?? [] }
        var paths: [String] = []
        var texts: [String] = []
        var failed = 0
        for (index, provider) in providers.enumerated() {
            do {
                if let path = try await saveAttachment(provider, to: staging.appendingPathComponent(String(index), isDirectory: true)) {
                    paths.append("\(index)/\(path)")
                } else if let text = try await readText(provider), !text.isEmpty {
                    texts.append(text)
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        guard !paths.isEmpty || !texts.isEmpty else { throw CocoaError(.fileReadUnknown) }
        let manifest: [String: Any] = ["paths": paths, "text": texts.joined(separator: "\n"), "failed": failed]
        try JSONSerialization.data(withJSONObject: manifest).write(to: staging.appendingPathComponent("manifest.json"))
        try files.moveItem(at: staging, to: root.appendingPathComponent(id, isDirectory: true))
        return failed
    }

    private func saveAttachment(_ provider: NSItemProvider, to directory: URL) async throws -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let source = (try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)) as? URL,
           source.isFileURL {
            return try await Task.detached {
                try Self.copy(source, suggested: nil, fileType: nil, to: directory)
            }.value
        }
        let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first {
            $0.conforms(to: .data) && (!$0.conforms(to: .text) || provider.suggestedName != nil)
        }
        guard let type else { return nil }
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                do {
                    guard let source else { throw error ?? CocoaError(.fileReadUnknown) }
                    // The provider's temporary URL is valid only inside this callback.
                    continuation.resume(returning: try Self.copy(source, suggested: suggested, fileType: type, to: directory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func copy(_ source: URL, suggested: String?, fileType: UTType?, to directory: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown)
        }
        let baseName = (suggested ?? source.lastPathComponent)
            .components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        var name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Shared file" }
        if (name as NSString).pathExtension.isEmpty, let suffix = fileType?.preferredFilenameExtension {
            name += "." + suffix
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }

    private func readText(_ provider: NSItemProvider) async throws -> String? {
        for type in [UTType.url, UTType.text] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let value = try await provider.loadItem(forTypeIdentifier: type.identifier)
            if let url = value as? URL, !url.isFileURL { return url.absoluteString }
            if let text = value as? String { return text }
        }
        return nil
    }
}
