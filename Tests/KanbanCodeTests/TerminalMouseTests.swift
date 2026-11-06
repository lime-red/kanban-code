import Testing
import Foundation
import AppKit
import SwiftTerm
@testable import KanbanCode

private final class SentRecorder: TerminalViewDelegate {
    var sent: [UInt8] = []
    var text: String { String(decoding: sent, as: UTF8.self) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@Suite("Terminal mouse wheel")
@MainActor
struct TerminalMouseWheelTests {
    /// What rush and agtop ask for on start: the alternate screen, every
    /// mouse motion (1003) in SGR encoding (1006) and focus reports.
    private static let rushStart = "\u{1b}[?1049h\u{1b}[?1004h\u{1b}[?1003h\u{1b}[?1006h"

    private func wheel(lines: Int32) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: event)!
    }

    private func view(feeding start: String) -> (TerminalView, SentRecorder) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let recorder = SentRecorder()
        view.terminalDelegate = recorder
        view.feed(text: start)
        recorder.sent = []
        return (view, recorder)
    }

    /// rush scrolls its conversation on wheel reports; the view used to
    /// spend the wheel on its own scrollback, which the alternate screen
    /// does not have, so nothing reached the program.
    @Test("The wheel reaches a program that asked for the mouse as buttons 4 and 5")
    func wheelIsReported() {
        let (view, recorder) = view(feeding: Self.rushStart)
        view.scrollWheel(with: wheel(lines: 3))
        #expect(recorder.text.components(separatedBy: "\u{1b}[<64;").count - 1 == 3)
        recorder.sent = []
        view.scrollWheel(with: wheel(lines: -2))
        #expect(recorder.text.components(separatedBy: "\u{1b}[<65;").count - 1 == 2)
    }

    @Test("Without mouse reporting the wheel stays with the view")
    func wheelStaysWhenNotAllowed() {
        let (view, recorder) = view(feeding: Self.rushStart)
        view.allowMouseReporting = false
        view.scrollWheel(with: wheel(lines: 3))
        #expect(recorder.sent.isEmpty)
    }

    @Test("A program that did not ask for the mouse gets no wheel reports")
    func wheelStaysWithoutMouseMode() {
        let (view, recorder) = view(feeding: "\u{1b}[?1049h")
        view.scrollWheel(with: wheel(lines: 3))
        #expect(recorder.sent.isEmpty)
    }

    @Test("sendWheel forwards wheel reports to a mouse-tracking tmux TUI while keeping allowMouseReporting false for selection")
    func sendWheelForwardsWhenClickReportingDisabled() {
        let (view, recorder) = view(feeding: Self.rushStart)
        view.allowMouseReporting = false
        #expect(view.getTerminal().mouseMode != .off)
        view.sendWheel(with: wheel(lines: 3))
        #expect(recorder.text.components(separatedBy: "\u{1b}[<64;").count - 1 == 3)
        recorder.sent = []
        view.sendWheel(with: wheel(lines: -2))
        #expect(recorder.text.components(separatedBy: "\u{1b}[<65;").count - 1 == 2)
    }
}

@Suite("Terminal mouse motion")
struct TerminalMouseMotionTests {
    private final class Recorder: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
    }

    /// With no button held, SGR motion is button 35 on a press ('M'), as
    /// xterm sends it. It went out as 32 on a release ('m'), which bubbletea
    /// reads as the left button dragging, so rush never saw the pointer
    /// hover and treated every move as a drag.
    @Test("Motion with no button is 35 with M, a release stays m")
    func hoverEncoding() {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        recorder.sent = []
        let hover = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
        terminal.sendMotion(buttonFlags: hover, x: 4, y: 2, pixelX: 0, pixelY: 0)
        #expect(String(decoding: recorder.sent, as: UTF8.self) == "\u{1b}[<35;5;3M")
        recorder.sent = []
        terminal.sendEvent(buttonFlags: hover, x: 4, y: 2)
        #expect(String(decoding: recorder.sent, as: UTF8.self) == "\u{1b}[<0;5;3m")
    }
}

@Suite("BatchedTerminalView interactive TUI")
@MainActor
struct BatchedTerminalViewInteractiveTests {
    private static let altScreenStart = "\u{1b}[?1049h"
    private static let mouseTrackingStart = "\u{1b}[?1000h"

    @Test("Normal terminal view drops frames when not lossless or in passthrough")
    func normalTerminalDropsFrames() {
        let view = BatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(!view.isInteractiveTUI)
        #expect(view.dropsFrames)
    }

    @Test("Alternate screen terminal does not drop frames")
    func alternateScreenTerminalDoesNotDropFrames() {
        let view = BatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(text: Self.altScreenStart)
        #expect(view.isInteractiveTUI)
        #expect(!view.dropsFrames)
    }

    @Test("Mouse tracking terminal does not drop frames")
    func mouseTrackingTerminalDoesNotDropFrames() {
        let view = BatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(text: Self.mouseTrackingStart)
        #expect(view.isInteractiveTUI)
        #expect(!view.dropsFrames)
    }

    @Test("Interactive TUI terminal processes large payload without dropping bytes")
    func interactiveTUIProcessesWithoutDropping() async {
        let view = BatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(text: Self.altScreenStart)

        // Generate 48KB of data (exceeding 32KB keepBytes threshold)
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("line \(i): test terminal data stream\n")
        }
        let payload = lines.joined()
        let data = Array(payload.utf8)

        view.dataReceived(slice: data[...])

        // Allow batch delay / async processing to complete
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!view.dropsFrames)
    }
}
