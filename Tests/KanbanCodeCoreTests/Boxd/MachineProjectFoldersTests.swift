import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Project folders of an ssh machine")
struct MachineProjectFoldersTests {

    @Test("Folders are stored absolute, with ~ as the home of the ssh user")
    func absoluteFolders() {
        let machine = SshMachine(
            name: "datatruss-hl", target: "dev@datatruss-hl",
            projectFolders: ["~/datatruss", "~", "srv/app", "/opt/tool/", " ", "/home/dev/datatruss"])
        #expect(machine.absoluteFolder("~/datatruss") == "/home/dev/datatruss")
        #expect(machine.absoluteFolder("~") == "/home/dev")
        #expect(machine.absoluteFolder("srv/app") == "/home/dev/srv/app")
        #expect(machine.absoluteFolder("/opt/tool/") == "/opt/tool")
        // Blanks and repeats are dropped.
        #expect(machine.absoluteProjectFolders == ["/home/dev/datatruss", "/home/dev", "/home/dev/srv/app", "/opt/tool"])
    }

    @Test("Settings without folders read and write as before")
    func codable() throws {
        let old = #"{"name":"box","target":"dev@h","repoRoot":"~/code"}"#
        let decoded = try JSONDecoder().decode(SshMachine.self, from: Data(old.utf8))
        #expect(decoded.projectFolders.isEmpty)
        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!written.contains("projectFolders"))

        let machine = SshMachine(name: "box", target: "dev@h", projectFolders: ["~/a", "/srv/b"])
        let again = try JSONDecoder().decode(SshMachine.self, from: JSONEncoder().encode(machine))
        #expect(again == machine)
        #expect(again.projectFolders == ["~/a", "/srv/b"])
        #expect(again != decoded)
    }

    @Test("Only a folder listed for the machine runs as written")
    func machineFolderRule() {
        let machine = SshMachine(name: "m", target: "lime@m", projectFolders: ["~/datatruss", "/Users/lime/code/app"])
        #expect(BoxdLaunchPlanner.isMachineFolder("/home/lime/datatruss", of: machine))
        #expect(BoxdLaunchPlanner.isMachineFolder("/home/lime/datatruss/", of: machine))
        // A machine with the same paths as this Mac: listed, so used as written.
        #expect(BoxdLaunchPlanner.isMachineFolder("/Users/lime/code/app", of: machine))
        // Not listed: a checkout of this Mac, cloned under the repositories folder.
        #expect(!BoxdLaunchPlanner.isMachineFolder("/home/lime/other", of: machine))
        #expect(!BoxdLaunchPlanner.isMachineFolder("/Users/lime/code/kanban-code", of: machine))
        #expect(!BoxdLaunchPlanner.isMachineFolder("/home/lime/datatruss", of: nil))
    }

    @Test("A typed folder is added to the machine once")
    func addTypedFolder() async throws {
        let dir = NSTemporaryDirectory() + "folders-\(UUID().uuidString)"
        let store = SettingsStore(basePath: dir)
        var settings = Settings()
        settings.boxd = BoxdSettings(sshMachines: [SshMachine(name: "m", target: "dev@m", projectFolders: ["~/a"])])
        try await store.write(settings)

        #expect(try await store.addProjectFolder("~/b", toSshMachine: "m"))
        #expect(try await !store.addProjectFolder("/home/dev/b", toSshMachine: "m"))
        #expect(try await !store.addProjectFolder("~/c", toSshMachine: "nope"))
        #expect(try await store.read().boxd?.sshMachines.first?.projectFolders == ["~/a", "~/b"])
    }

    @Test("A folder written for the assumed home moves to the home the machine reports")
    func rebaseOnTheRealHome() {
        #expect(BoxdLaunchPlanner.machineFolderPath("/home/dev/x", assumedHome: "/home/dev", remoteHome: "/srv/dev")
                == "/srv/dev/x")
        #expect(BoxdLaunchPlanner.machineFolderPath("/home/dev", assumedHome: "/home/dev", remoteHome: "/srv/dev/")
                == "/srv/dev")
        #expect(BoxdLaunchPlanner.machineFolderPath("/opt/x/", assumedHome: "/home/dev", remoteHome: "/srv/dev")
                == "/opt/x")
        #expect(BoxdLaunchPlanner.machineFolderPath("/home/devops/x", assumedHome: "/home/dev", remoteHome: "/srv/dev")
                == "/home/devops/x")
        #expect(BoxdLaunchPlanner.machineFolderPath("/home/dev/x", assumedHome: nil, remoteHome: "/srv/dev")
                == "/home/dev/x")
    }
}
