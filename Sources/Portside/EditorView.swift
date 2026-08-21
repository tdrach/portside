import AppKit
import SwiftUI

/// The add/edit server dialog — the same NSAlert container as "New project",
/// with the field stack embedded as a SwiftUI accessory. Alert buttons give
/// us Return-to-submit and Esc-to-cancel for free.
@MainActor
enum EditorPresenter {

    static func present(model: AppModel) {
        // The MenuBarExtra panel floats at status-bar window level and would
        // cover the dialog — dismiss it first.
        MenuGlassBackground.currentPanel?.close()
        NSApp.activate(ignoringOtherApps: true)

        guard let draft = model.editorDraft else { return }
        let box = EditorDraftBox(draft: draft, projects: model.projects)
        let isNew = draft.serverID == nil

        let alert = NSAlert()
        alert.messageText = isNew ? "New server" : "Edit server"
        alert.informativeText = "Runs the command from its folder, with your login shell's environment."
        let fields = EditorFields(box: box, onCreateProject: { [weak model] in
            guard let model, let name = askProjectName() else { return nil }
            let project = model.createProject(named: name)
            box.projects = model.projects
            return project.id
        })
        let hosting = NSHostingView(rootView: fields)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        alert.accessoryView = hosting
        alert.addButton(withTitle: isNew ? "Add server" : "Save")
        alert.addButton(withTitle: "Cancel")

        // Validation loop: commit errors re-present with the message shown
        // and every field preserved.
        while true {
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            guard alert.runModal() == .alertFirstButtonReturn else {
                model.editorDraft = nil
                return
            }
            if let message = model.commit(box.draft) {
                box.error = message
            } else {
                return // commit cleared editorDraft
            }
        }
    }
}

/// Nested name prompt — the same container, stacked over the editor.
@MainActor
private func askProjectName() -> String? {
    let alert = NSAlert()
    alert.messageText = "New project"
    alert.informativeText = "Group servers to start and stop them together."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "my-stack"
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmed
    return name.isEmpty ? nil : name
}

@MainActor
final class EditorDraftBox: ObservableObject {
    @Published var draft: ServerDraft
    @Published var error: String?
    @Published var projects: [Project]

    init(draft: ServerDraft, projects: [Project]) {
        self.draft = draft
        self.projects = projects
    }
}

struct EditorFields: View {
    @ObservedObject var box: EditorDraftBox
    let onCreateProject: () -> UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name") {
                TextField("my-app", text: $box.draft.name)
            }
            field("Directory") {
                HStack(spacing: 6) {
                    TextField("~/Code/my-app", text: $box.draft.directory)
                    Button("Choose…") { chooseDirectory() }
                }
            }
            field("Command") {
                TextField("npm run dev", text: $box.draft.command)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack(alignment: .top, spacing: 10) {
                field("Port") {
                    TextField("3000", text: $box.draft.portText)
                        .frame(width: 70)
                }
                field("URL") {
                    TextField("optional — defaults to the port", text: $box.draft.urlOverride)
                }
            }
            field("Project") {
                // A real NSPopUpButton: SwiftUI Picker menus can't open
                // inside an NSAlert modal session.
                ProjectPopUp(box: box, onCreateProject: onCreateProject)
                    .frame(width: 160, alignment: .leading)
            }
            if let error = box.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .textFieldStyle(.roundedBorder)
        // Standard alert content width — wider stretches the panel past the
        // system button grid and the paired pills stop lining up.
        .frame(width: 260)
        .padding(.top, 2)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let current = (box.draft.directory.trimmed as NSString).expandingTildeInPath
        panel.directoryURL = URL(
            fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current
        )
        if panel.runModal() == .OK, let url = panel.url {
            box.draft.directory = url.path.abbreviatingHome
            if box.draft.name.trimmed.isEmpty {
                box.draft.name = url.lastPathComponent
            }
            if box.draft.command.trimmed.isEmpty,
               let guessed = CommandGuess.guess(directory: url.path) {
                box.draft.command = guessed
            }
        }
    }
}


/// AppKit popup for project membership: None, each project, New project….
private struct ProjectPopUp: NSViewRepresentable {
    @ObservedObject var box: EditorDraftBox
    let onCreateProject: () -> UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        rebuild(popup)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuild(popup)
    }

    private func rebuild(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: "None")
        for project in box.projects {
            popup.addItem(withTitle: project.name)
            popup.lastItem?.representedObject = project.id
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "New project…")
        popup.lastItem?.representedObject = "new"

        if let projectID = box.draft.projectID,
           let index = box.projects.firstIndex(where: { $0.id == projectID }) {
            popup.selectItem(at: index + 1)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ProjectPopUp

        init(_ parent: ProjectPopUp) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let marker = sender.selectedItem?.representedObject as? String,
               marker == "new" {
                if let newID = parent.onCreateProject() {
                    parent.box.draft.projectID = newID
                } else {
                    // Cancelled — snap the popup back to the current value.
                    parent.rebuild(sender)
                }
                return
            }
            parent.box.draft.projectID = sender.selectedItem?.representedObject as? UUID
        }
    }
}
