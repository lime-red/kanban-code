import CoreGraphics
import Testing
@testable import KanbanCode

@Suite("Chat middle-click auto-scroll")
struct ChatMiddleClickAutoScrollTests {
    @Test("Click without drag toggles autoscroll on and stays active after release")
    func clickToggleMode() {
        var state = MiddleClickAutoScrollState()
        let origin = CGPoint(x: 200, y: 300)
        let viewport = CGPoint(x: 150, y: 250)

        #expect(state.handleMiddleDown(locationInWindow: origin, locationInViewport: viewport) == true)
        #expect(state.isActive)
        #expect(state.anchorInViewport == viewport)

        // Release without dragging keeps autoscroll active (toggle mode)
        state.handleMiddleUp(locationInWindow: origin)
        #expect(state.isActive)

        // Moving pointer in toggle mode updates scroll velocity
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 360), isDragged: false)
        #expect(state.stepYPerTick < 0)

        // Second middle-click toggles autoscroll off
        #expect(state.handleMiddleDown(locationInWindow: origin, locationInViewport: viewport) == false)
        #expect(!state.isActive)
        #expect(state.stepYPerTick == 0)
    }

    @Test("Holding and dragging middle mouse button stops autoscroll on release")
    func holdAndDragMode() {
        var state = MiddleClickAutoScrollState()
        let origin = CGPoint(x: 200, y: 300)

        state.handleMiddleDown(locationInWindow: origin, locationInViewport: origin)
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 240), isDragged: true)
        #expect(state.didDrag)
        #expect(state.stepYPerTick > 0)

        state.handleMiddleUp(locationInWindow: CGPoint(x: 200, y: 240))
        #expect(!state.isActive)
        #expect(state.stepYPerTick == 0)
    }

    @Test("Deadzone suppresses scroll within 12pt and velocity scales with distance")
    func deadzoneAndVelocityScaling() {
        var state = MiddleClickAutoScrollState()
        let origin = CGPoint(x: 200, y: 300)
        state.handleMiddleDown(locationInWindow: origin, locationInViewport: origin)

        // Inside deadzone
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 310), isDragged: false)
        #expect(state.stepYPerTick == 0)

        // Slightly above anchor -> slow upward scroll (negative in flipped coords)
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 330), isDragged: false)
        let slowUp = state.stepYPerTick
        #expect(slowUp < 0)

        // Further above anchor -> faster upward scroll
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 420), isDragged: false)
        let fastUp = state.stepYPerTick
        #expect(fastUp < slowUp)

        // Below anchor -> downward scroll (positive in flipped coords)
        state.handlePointerMove(locationInWindow: CGPoint(x: 200, y: 200), isDragged: false)
        let down = state.stepYPerTick
        #expect(down > 0)
    }
}
