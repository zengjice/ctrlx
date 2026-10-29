#if os(iOS)
    import Testing
    import UIKit
    @testable import CtrlxCommon

    @Suite("Local preview zoom") @MainActor
    struct LocalImagePreviewTests {
        private func image(_ size: CGSize = CGSize(width: 800, height: 400)) throws -> CGImage {
            try #require(UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }.cgImage)
        }

        private func preview() throws -> LocalImageScrollView {
            let view = LocalImageScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            try view.update(image: image(), identity: "page-a")
            view.layoutIfNeeded()
            return view
        }

        @Test
        func newFramesKeepZoomAndPositionIncludingResolutionChanges() throws {
            let view = try preview()
            view.setZoomScale(3, animated: false)
            view.contentOffset = CGPoint(x: 100, y: 0)
            let offset = view.contentOffset
            try view.update(image: image(CGSize(width: 1_600, height: 800)), identity: "page-a")
            view.layoutIfNeeded()
            try #require(view.zoomScale == 3)
            try #require(view.contentOffset == offset)
            try view.update(image: image(CGSize(width: 1_600, height: 801)), identity: "page-a")
            view.layoutIfNeeded()
            try #require(view.zoomScale == 3)
            try #require(view.contentOffset == offset)
        }

        @Test
        func gradualAspectRatioChangesRestoreFit() throws {
            let view = try preview()
            view.setZoomScale(3, animated: false)
            for height in 401...405 {
                try view.update(image: image(CGSize(width: 800, height: height)), identity: "page-a")
                view.layoutIfNeeded()
                if height == 401 {
                    try #require(view.zoomScale == 3)
                }
            }
            try #require(view.zoomScale == 1)
            try #require(abs(view.picture.frame.height - 202.5) < 0.001)

            // Explicit fit must also use the latest frame below the reset threshold.
            try view.update(image: image(CGSize(width: 800, height: 406)), identity: "page-a")
            view.resetZoom()
            try #require(abs(view.picture.frame.height - 203) < 0.001)
        }

        @Test
        func controlledFramesStayAlignedWithInputDuringGradualResizing() throws {
            let canvas = BrowserCanvasUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            canvas.acceptsInput = true
            try canvas.preview.update(image: image(), identity: "page")
            canvas.layoutIfNeeded()

            for height in 401...410 {
                let size = CGSize(width: 800, height: height)
                canvas.pageSize = size
                try canvas.preview.update(image: image(size), identity: "page")
                canvas.layoutIfNeeded()
                let displayed = canvas.preview.picture.convert(canvas.preview.picture.bounds, to: canvas)
                let expected = RemoteBrowserGeometry.imageRect(viewSize: canvas.bounds.size, pageSize: size)
                // UIScrollView aligns its offset to display pixels.
                let pixel = 1 / canvas.preview.contentScaleFactor
                try #require(abs(displayed.minY - expected.minY) < pixel)
                try #require(abs(displayed.height - expected.height) < 0.001)
                let point = CGPoint(x: displayed.minX + displayed.width / 4, y: displayed.minY + displayed.height * 0.75)
                let mapped = try #require(RemoteBrowserGeometry.pagePoint(point, viewSize: canvas.bounds.size, pageSize: size))
                try #require(abs(mapped.x - size.width / 4) < 0.001)
                try #require(abs(mapped.y - size.height * 0.75) < pixel * size.height / expected.height)
            }
        }

        @Test
        func newContentAndOrientationRestoreFit() throws {
            let view = try preview()
            view.setZoomScale(3, animated: false)
            try view.update(image: image(), identity: "page-b")
            try #require(view.zoomScale == 1)
            view.setZoomScale(3, animated: false)
            try view.update(image: image(CGSize(width: 400, height: 800)), identity: "page-b")
            try #require(view.zoomScale == 1)
            view.setZoomScale(3, animated: false)
            view.frame.size = CGSize(width: 600, height: 400)
            view.layoutIfNeeded()
            try #require(view.zoomScale == 1)
        }

        @Test
        func zoomIsBoundedAndFitCentersTheImage() throws {
            let view = try preview()
            view.setZoomScale(10, animated: false)
            try #require(view.zoomScale == 4)
            view.resetZoom()
            try #require(view.zoomScale == 1)
            try #require(view.picture.frame.size == CGSize(width: 400, height: 200))
            try #require(view.contentOffset.y == -200)
        }

        @Test
        func controlTakeoverResetsZoomAndOnlyEnablesRemoteGestures() throws {
            let canvas = BrowserCanvasUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            try canvas.preview.update(image: image(), identity: "page")
            canvas.allowsLocalZoom = true
            canvas.layoutIfNeeded()
            canvas.preview.setZoomScale(3, animated: false)
            try #require(canvas.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
            canvas.acceptsInput = true
            try #require(canvas.preview.zoomScale == 1)
            try #require(!canvas.preview.zoomEnabled)
            try #require(canvas.preview.pinchGestureRecognizer?.isEnabled == false)
            try #require(canvas.gestureRecognizers?.allSatisfy(\.isEnabled) == true)
            canvas.acceptsInput = false
            try #require(canvas.preview.zoomEnabled)
            try #require(canvas.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
        }

        @Test
        func disablingInputForAddressEditingDoesNotEnableReadOnlyZoom() throws {
            let canvas = BrowserCanvasUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            canvas.acceptsInput = true
            canvas.acceptsInput = false
            try #require(!canvas.preview.zoomEnabled)
            try #require(canvas.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
        }
    }
#endif
