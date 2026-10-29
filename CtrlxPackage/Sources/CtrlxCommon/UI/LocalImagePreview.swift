#if os(iOS)
    import SwiftUI
    import UIKit

    /// Local viewing only; this surface never sends input to a Host.
    struct LocalImagePreview: UIViewRepresentable {
        let image: CGImage

        func makeUIView(context: Context) -> LocalImageScrollView {
            LocalImageScrollView()
        }

        func updateUIView(_ view: LocalImageScrollView, context: Context) {
            view.update(image: image, identity: "file")
        }
    }

    final class LocalImageScrollView: UIScrollView, UIScrollViewDelegate {
        let picture = UIImageView()
        private var identity = ""
        private var aspectRatio: CGFloat = 0
        private var layoutAspectRatio: CGFloat = 0
        private var layoutSize = CGSize.zero
        private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        var zoomEnabled = true {
            didSet {
                guard zoomEnabled != oldValue else { return }
                resetZoom()
                isUserInteractionEnabled = zoomEnabled
                isAccessibilityElement = zoomEnabled
                pinchGestureRecognizer?.isEnabled = zoomEnabled
                panGestureRecognizer.isEnabled = zoomEnabled
                doubleTap.isEnabled = zoomEnabled
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            bounces = false
            picture.contentMode = .scaleAspectFit
            addSubview(picture)
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            isAccessibilityElement = true
            accessibilityLabel = "Image preview"
            accessibilityHint = "Pinch to zoom. Drag to move the enlarged preview. Double-tap to zoom or fit."
            accessibilityTraits = [.image, .adjustable]
            accessibilityIdentifier = "local-image-preview"
        }

        required init?(coder: NSCoder) {
            nil
        }

        func update(image: CGImage?, identity: String) {
            let ratio = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0
            // Tolerate thumbnail rounding against the actual layout, never the previous frame.
            // Controlled input must track every ratio change to preserve its coordinate mapping.
            let tolerance = zoomEnabled ? max(ratio, layoutAspectRatio) * 0.01 : 0
            let changed = self.identity != identity || abs(ratio - layoutAspectRatio) > tolerance
            self.identity = identity
            aspectRatio = ratio
            picture.image = image.map { UIImage(cgImage: $0) }
            // New frames (including higher-resolution ones) keep the viewing position.
            if changed {
                resetZoom()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != layoutSize {
                layoutSize = bounds.size
                resetZoom()
            }
        }

        func resetZoom() {
            setZoomScale(1, animated: false)
            layoutAspectRatio = aspectRatio
            let width = aspectRatio > 0 ? min(bounds.width, bounds.height * aspectRatio) : bounds.width
            let size = CGSize(width: width, height: aspectRatio > 0 ? width / aspectRatio : bounds.height)
            picture.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            centerPicture()
            setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
        }

        private func centerPicture() {
            contentInset = UIEdgeInsets(
                top: max(0, (bounds.height - picture.frame.height) / 2), left: max(0, (bounds.width - picture.frame.width) / 2),
                bottom: 0, right: 0
            )
            accessibilityValue = "\(Int(zoomScale * 100))%"
        }

        func viewForZooming(in _: UIScrollView) -> UIView? {
            zoomEnabled ? picture : nil
        }

        func scrollViewDidZoom(_: UIScrollView) {
            centerPicture()
        }

        @objc
        private func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard zoomEnabled else { return }
            if zoomScale > 1.01 {
                resetZoom()
            } else {
                let point = gesture.location(in: picture)
                let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        override func accessibilityIncrement() {
            guard zoomEnabled else { return }
            setZoomScale(min(maximumZoomScale, zoomScale + 1), animated: true)
        }

        override func accessibilityDecrement() {
            guard zoomEnabled else { return }
            setZoomScale(max(minimumZoomScale, zoomScale - 1), animated: true)
        }
    }
#endif
