import SwiftUI
import KanbanCodeCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    var globalRemoteSettings: RemoteSettings?
    /// Remote backend of this launch. When set it decides the remote row, and
    /// `globalRemoteSettings` is ignored.
    var remoteOptions: RemoteLaunchOptions?
    var enabledAssistants: [CodingAssistant] = CodingAssistant.allCases
    /// (prompt, projectPath, title, startImmediately, images) — creates task without an assistant set
    var onCreate: (String, String?, String?, Bool, [ImageAttachment]) -> Void = { _, _, _, _, _ in }
    /// (prompt, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride, images, assistant, apiServiceId) — creates and launches directly (skips LaunchConfirmation)
    var onCreateAndLaunch: (String, String?, String?, Bool, Bool, Bool, String?, [ImageAttachment], CodingAssistant, String?) -> Void = { _, _, _, _, _, _, _, _, _, _ in }
    /// Boxd machine the user picked. Called just before `onCreateAndLaunch`
    /// when the launch runs on boxd.
    var onMachineChoice: (BoxdMachineChoice) -> Void = { _ in }

    private let settingsStore = SettingsStore()
    @State private var settings = Settings()
    @State private var apiServices: [APIService] = []
    @State private var defaultAPIServiceIds: [String: String] = [:]
    @State private var selectedServiceId: String? = nil
    @AppStorage("selectedAssistant") private var selectedAssistantRaw: String = CodingAssistant.claude.rawValue
    private var selectedAssistant: CodingAssistant {
        get { CodingAssistant(rawValue: selectedAssistantRaw) ?? .claude }
        nonmutating set { selectedAssistantRaw = newValue.rawValue }
    }
    @State private var prompt = ""
    @FocusState private var titleFocused: Bool
    @State private var images: [ImageAttachment] = []
    @State private var title = ""
    @State private var selectedProjectPath: String = ""
    @State private var customPath = ""
    @State private var command = ""
    @State private var commandEdited = false
    @State private var worktreeBranch = ""
    @AppStorage("startTaskImmediately") private var startImmediately = true
    @State private var createWorktree = true
    @State private var runRemotely = true
    @State private var machineChoice: BoxdMachineChoice = .newMachine
    @AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true
    @AppStorage("lastSelectedProjectPath") private var lastSelectedProjectPath = ""
    /// The last project of this Mac, to go back to from a machine's folders.
    @AppStorage("lastLocalProjectPath") private var lastLocalProjectPath = ""

    private static let customPathSentinel = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.app(.title3))
                .fontWeight(.semibold)

            // Title (optional)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.app(.callout))
                .focused($titleFocused)

            // Prompt
            PromptSection(
                text: $prompt,
                images: $images,
                placeholder: "Describe what you want \(selectedAssistant.displayName) to do...",
                maxHeight: 180,
                onSubmit: submitForm,
                onEscape: { isPresented = false }
            )

            // Where the card runs comes first: a machine offers its own
            // project folders.
            if picksMachineFirst, let remoteOptions {
                RunTargetPicker(remote: remoteOptions, runRemotely: $runRemotely, machineChoice: $machineChoice)
            }

            // Project picker
            if projects.isEmpty && machineFolders.isEmpty {
                TextField(customPathPrompt + " (optional)", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.caption))
            } else {
                Picker("Project", selection: $selectedProjectPath) {
                    if let machine = selectedSshMachine {
                        if !machineFolders.isEmpty {
                            Section("Already on \(machine.name)") {
                                ForEach(machineFolders, id: \.self) { folder in
                                    Text(Self.folderLabel(folder, machine: machine)).tag(folder)
                                }
                            }
                        }
                        if !projects.isEmpty {
                            Section("From this Mac (cloned to \(machine.name))") {
                                ForEach(projects) { project in
                                    Text(project.name).tag(project.path)
                                }
                            }
                        }
                    } else {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.path)
                        }
                    }
                    Divider()
                    Text("Custom path...").tag(Self.customPathSentinel)
                }

                if selectedProjectPath == Self.customPathSentinel {
                    TextField(customPathPrompt, text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.caption))
                }
            }

            // Assistant picker (when multiple enabled)
            if startImmediately && enabledAssistants.count > 1 {
                Picker("Assistant", selection: $selectedAssistantRaw) {
                    ForEach(enabledAssistants, id: \.self) { assistant in
                        Text(assistant.displayName).tag(assistant.rawValue)
                    }
                }
                .onChange(of: selectedAssistantRaw) {
                    selectedServiceId = defaultAPIServiceIds[selectedAssistant.rawValue]
                }
            }

            // API Service picker (when services exist for this assistant)
            let servicesForAssistant = apiServices.filter { $0.assistant == selectedAssistant }
            if startImmediately && !servicesForAssistant.isEmpty {
                Picker("API Service", selection: $selectedServiceId) {
                    Text("Default").tag(String?.none)
                    ForEach(servicesForAssistant) { service in
                        Text(service.name).tag(String?.some(service.id))
                    }
                }
                .onChange(of: selectedServiceId) {
                    if !commandEdited { command = commandPreview }
                }
            }

            // Start immediately toggle
            Toggle("Start immediately", isOn: $startImmediately)
                .font(.app(.callout))

            // Launch options (shown when "Start immediately" is checked)
            if startImmediately {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create worktree", isOn: (isGitRepo && selectedAssistant.supportsWorktree) ? $createWorktree : .constant(false))
                        .font(.app(.callout))
                        .disabled(!isGitRepo || !selectedAssistant.supportsWorktree)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    } else if !selectedAssistant.supportsWorktree {
                        Label("\(selectedAssistant.displayName) doesn't support worktrees", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    if createWorktree && isGitRepo {
                        HStack {
                            Text("Branch name")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                            TextField("", text: $worktreeBranch, prompt: Text("Leave empty for a random name"))
                                .textFieldStyle(.roundedBorder)
                                .font(.app(.callout))
                        }
                        .padding(.leading, 20)
                    }

                    remoteSection

                    Toggle("Dangerously skip permissions", isOn: $dangerouslySkipPermissions)
                        .font(.app(.callout))
                }

                // Editable command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    if runsOnBoxd {
                        Text("on machine \(selectedMachineLabel)")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                        if createWorktree && isGitRepo && selectedAssistant.supportsWorktree {
                            Text("The worktree is created on the machine and on this Mac, so the command has no --worktree flag.")
                                .font(.app(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                    CommandTextEditor(text: $command, onSubmit: submitForm, onEscape: { isPresented = false })
                        .font(.app(.caption).monospaced())
                        .frame(minHeight: 36, maxHeight: 80)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: command) {
                            if command != commandPreview {
                                commandEdited = true
                            }
                        }
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(startImmediately ? "Create & Start" : "Create", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            if let defaultPath = defaultProjectPath,
               projects.contains(where: { $0.path == defaultPath }) {
                selectedProjectPath = defaultPath
            } else if !lastSelectedProjectPath.isEmpty,
               projects.contains(where: { $0.path == lastSelectedProjectPath }) {
                selectedProjectPath = lastSelectedProjectPath
            } else if let first = projects.first {
                selectedProjectPath = first.path
            }
            // Ensure selected assistant is enabled; fall back to first enabled
            if !enabledAssistants.contains(selectedAssistant),
               let first = enabledAssistants.first {
                selectedAssistant = first
            }
            applyProjectDefaults()
            // The last project was a folder on a machine: that machine again,
            // unless the board has a project of this Mac selected.
            if !projects.contains(where: { $0.path == defaultProjectPath }),
               let machine = remoteOptions?.sshMachines.first(where: {
                   $0.absoluteProjectFolders.contains(lastSelectedProjectPath)
               }) {
                machineChoice = .existing(machine.name)
                runRemotely = true
                selectedProjectPath = lastSelectedProjectPath
            }
            command = commandPreview
            titleFocused = true
        }
        .task { await reloadServices() }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged)) { _ in
            Task { await reloadServices() }
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: createWorktree) {
            if let path = resolvedProjectPath {
                UserDefaults.standard.set(createWorktree, forKey: "createWorktree_\(path)")
            }
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: worktreeBranch) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: runRemotely) {
            rememberRunRemotely()
            followRunTarget()
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: machineChoice) {
            followRunTarget()
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: selectedProjectPath) {
            applyProjectDefaults(includingRunTarget: !picksMachineFirst)
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: customPath) {
            applyProjectDefaults(includingRunTarget: !picksMachineFirst)
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: dangerouslySkipPermissions) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: selectedAssistantRaw) {
            if !commandEdited { command = commandPreview }
            // Reset to default service for the newly selected assistant
            selectedServiceId = defaultAPIServiceIds[selectedAssistant.rawValue]
        }
    }

    // MARK: - Remote row

    @ViewBuilder
    private var remoteSection: some View {
        if picksMachineFirst {
            // Shown above the project picker.
        } else {
            Toggle(remoteToggleLabel, isOn: canRunRemotely ? $runRemotely : .constant(false))
                .font(.app(.callout))
                .disabled(!canRunRemotely)
        }

        if let hint = remoteHint {
            Label(hint, systemImage: "info.circle")
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }

    }

    private var selectedMachineLabel: String {
        machineChoice.machineName ?? "new machine"
    }

    private var remoteToggleLabel: String {
        switch remoteMode {
        case .ssh: "Run on an ssh machine"
        case .boxd: "Run on boxd"
        case .mutagen: "Run remotely"
        }
    }

    private var remoteHint: String? {
        guard !canRunRemotely else { return nil }
        switch remoteMode {
        case .ssh:
            return "Add an ssh machine in Settings > Remote"
        case .boxd:
            if remoteOptions?.boxd == nil { return "Configure boxd in Settings > Remote" }
            return "Install the boxd CLI to run on boxd"
        case .mutagen:
            if remoteOptions?.mutagen != nil || globalRemoteSettings != nil {
                return "Project not under remote sync path"
            }
            return "Configure remote execution in Settings > Remote"
        }
    }

    /// The run target was picked first, so the project follows it: a machine
    /// with project folders selects one of them (the last one used there),
    /// and leaving it drops a folder that is on another machine.
    private func followRunTarget() {
        guard picksMachineFirst, selectedProjectPath != Self.customPathSentinel else { return }
        let folders = machineFolders
        if let machine = selectedSshMachine, !folders.isEmpty {
            guard !folders.contains(selectedProjectPath) else { return }
            let last = UserDefaults.standard.string(forKey: Self.lastFolderKey(machine.name))
            selectedProjectPath = last.flatMap { folders.contains($0) ? $0 : nil } ?? folders[0]
        } else if !projects.contains(where: { $0.path == selectedProjectPath }) {
            selectedProjectPath = projects.first(where: { $0.path == lastLocalProjectPath })?.path
                ?? projects.first?.path ?? ""
        }
    }

    /// Reads the toggle defaults of the selected project. Once the run target
    /// is picked first, a project change leaves it alone.
    private func applyProjectDefaults(includingRunTarget: Bool = true) {
        if !includingRunTarget {
            if let path = resolvedProjectPath {
                createWorktree = UserDefaults.standard.object(forKey: "createWorktree_\(path)") as? Bool ?? true
            }
            return
        }
        let fallbackMachine: BoxdMachineChoice = remoteMode == .ssh
            ? (remoteOptions?.allMachines.first.map { BoxdMachineChoice.existing($0.name) } ?? .newMachine)
            : .newMachine
        machineChoice = remoteOptions?.cardMachine.map { BoxdMachineChoice.existing($0) } ?? fallbackMachine
        guard let path = resolvedProjectPath else { return }
        if let remoteOptions { machineChoice = remoteOptions.initialMachineChoice(projectPath: path) }
        runRemotely = remoteOptions?.cardMachine != nil
            ? true
            : RemoteLaunchOptions.defaultRunRemotely(mode: remoteMode, projectPath: path)
        createWorktree = UserDefaults.standard.object(forKey: "createWorktree_\(path)") as? Bool ?? true
    }

    private func rememberRunRemotely() {
        // A card that already has a machine keeps the toggle on by itself, so
        // its value is not the project default.
        guard remoteOptions?.cardMachine == nil, let path = resolvedProjectPath else { return }
        RemoteLaunchOptions.rememberRunRemotely(runRemotely, mode: remoteMode, projectPath: path)
    }

    // MARK: - Actions

    private func reloadServices() async {
        let loaded = (try? await settingsStore.read()) ?? Settings()
        settings = loaded
        apiServices = loaded.apiServices
        defaultAPIServiceIds = loaded.defaultAPIServiceIds
        // Keep current selection if it still exists; otherwise fall back to the new default.
        let currentStillValid = selectedServiceId.flatMap { id in
            apiServices.first { $0.id == id }
        } != nil
        if !currentStillValid {
            selectedServiceId = loaded.defaultAPIServiceIds[selectedAssistant.rawValue]
        }
        if !commandEdited { command = commandPreview }
    }

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A path typed for a machine joins its project folders: that is what
        // makes the launch run in it as written, and it is offered next time.
        // It is saved before the launch reads the settings.
        let typed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let machine = selectedSshMachine, resolvedProjectPath == typedProjectPath, !typed.isEmpty,
           !machineFolders.contains(machine.absoluteFolder(typed)) {
            Task {
                if (try? await settingsStore.addProjectFolder(typed, toSshMachine: machine.name)) == true {
                    NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
                }
                deliver()
            }
            return
        }
        deliver()
    }

    private func deliver() {
        let proj = resolvedProjectPath
        let titleOrNil = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let proj { lastSelectedProjectPath = proj }
        if let proj, projects.contains(where: { $0.path == proj }) { lastLocalProjectPath = proj }
        if runsOnBoxd {
            onMachineChoice(machineChoice)
            if remoteOptions?.cardMachine == nil, let proj {
                RemoteLaunchOptions.rememberMachineChoice(machineChoice, projectPath: proj)
            }
            if let machine = selectedSshMachine, let proj, machineFolders.contains(proj) {
                // A folder of the machine only runs there: a later launch of
                // the card offers the machine.
                RemoteLaunchOptions.rememberRunRemotely(true, mode: remoteMode, projectPath: proj)
                UserDefaults.standard.set(proj, forKey: Self.lastFolderKey(machine.name))
            }
        }
        if startImmediately {
            onCreateAndLaunch(
                prompt,
                proj,
                titleOrNil,
                createWorktree && isGitRepo && selectedAssistant.supportsWorktree,
                effectiveRunRemotely,
                dangerouslySkipPermissions,
                commandEdited ? command : nil,
                images,
                selectedAssistant,
                selectedServiceId
            )
        } else {
            onCreate(prompt, proj, titleOrNil, false, images)
        }
        isPresented = false
    }

    // MARK: - Computed

    private var resolvedProjectPath: String? {
        if (projects.isEmpty && machineFolders.isEmpty) || selectedProjectPath == Self.customPathSentinel {
            return typedProjectPath
        }
        return selectedProjectPath.isEmpty ? nil : selectedProjectPath
    }

    /// The typed path as the launch uses it: the launch quotes the path for
    /// the shell, so a `~` there is never expanded. On a machine, `~` is the
    /// home there.
    private var typedProjectPath: String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let machine = selectedSshMachine { return machine.absoluteFolder(trimmed) }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// The run target is offered before the project: the card runs on ssh
    /// machines or boxd.
    private var picksMachineFirst: Bool {
        remoteMode.runsOnMachines && canRunRemotely && remoteOptions != nil
    }

    /// The ssh machine the card runs on, when it runs on one.
    private var selectedSshMachine: SshMachine? {
        guard runsOnBoxd, let name = machineChoice.machineName else { return nil }
        return remoteOptions?.sshMachines.first(where: { $0.name == name })
    }

    /// Project folders of the selected machine, as the cards store them.
    private var machineFolders: [String] {
        selectedSshMachine?.absoluteProjectFolders ?? []
    }

    private var customPathPrompt: String {
        selectedSshMachine.map { "Folder already on \($0.name), e.g. ~/my-project" } ?? "Project path"
    }

    /// `datatruss  ~/datatruss`: the folder name, then where it is.
    private static func folderLabel(_ folder: String, machine: SshMachine) -> String {
        let name = (folder as NSString).lastPathComponent
        var shown = folder
        if folder == machine.assumedHome {
            shown = "~"
        } else if folder.hasPrefix(machine.assumedHome + "/") {
            shown = "~" + folder.dropFirst(machine.assumedHome.count)
        }
        return "\(name)  \(shown)"
    }

    private static func lastFolderKey(_ machine: String) -> String { "lastProjectFolder_\(machine)" }

    private var selectedProject: Project? {
        projects.first(where: { $0.path == resolvedProjectPath })
    }

    private var isGitRepo: Bool {
        guard let path = resolvedProjectPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private var hasRemoteConfig: Bool {
        guard let remote = globalRemoteSettings else { return false }
        guard let path = resolvedProjectPath else { return false }
        return path.hasPrefix(remote.localPath)
    }

    private var remoteHost: String? {
        globalRemoteSettings?.host
    }

    private var remoteMode: RemoteMode {
        remoteOptions?.mode ?? .mutagen
    }

    private var canRunRemotely: Bool {
        remoteOptions?.canRunRemotely(projectPath: resolvedProjectPath) ?? hasRemoteConfig
    }

    private var effectiveRunRemotely: Bool {
        runRemotely && canRunRemotely
    }

    /// True when the session runs on a machine: an ssh machine or boxd.
    private var runsOnBoxd: Bool {
        remoteMode.runsOnMachines && effectiveRunRemotely
    }

    private var commandPreview: String {
        var parts: [String] = []

        if effectiveRunRemotely && remoteMode == .mutagen {
            parts.append("SHELL=~/.kanban-code/remote/zsh")
            if selectedAssistant.requiresRemotePathWrapper {
                parts.append("PATH=~/.kanban-code/remote:$PATH")
            }
        }

        let worktreeName: String?
        // On boxd the app creates the worktree, so the command carries no
        // worktree flag.
        if createWorktree && isGitRepo && selectedAssistant.supportsWorktree && !runsOnBoxd {
            let branch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            worktreeName = branch
        } else {
            worktreeName = nil
        }

        let service = selectedServiceId.flatMap { id in apiServices.first { $0.id == id } }
        let launchCmd = selectedAssistant.launchCommand(
            skipPermissions: dangerouslySkipPermissions,
            worktreeName: worktreeName,
            service: service
        )
        let template = settings.commandTemplate(for: selectedAssistant, remote: effectiveRunRemotely)
        parts.append(CodingAssistant.applyCommandTemplate(launchCmd, template: template))

        return parts.joined(separator: " \\\n  ")
    }
}
