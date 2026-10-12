//  The code in the corner of a sync clip.
//
//  While one of the Settings → Audio sync clips plays, a QR code sits in the
//  top-right corner saying which rate's delay this is and the delay the
//  clip is playing with (`SyncCode`). The iPhone app's Measure Apple TV sync
//  screen reads it off the television through its camera along with the
//  flash and the beep, so the phone knows what to add its reading to and
//  which rate to name — and the two apps never need to find each other on
//  the network. Redrawn as the Sync tab moves the delay, so what the phone
//  reads is always what is in force.

#if os(tvOS)

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SyncCodeOverlay: View {
    @Environment(PlayerModel.self) private var player
    @State private var image: UIImage?

    /// Clear of the overscan margin and of the clip's title; the clip's
    /// own layout leaves this corner empty.
    private nonisolated static let size: CGFloat = 300

    private var payload: String? {
        guard let test = player.syncTest else { return nil }
        return SyncCode(fps: test.fps, delayMilliseconds: player.audioDelayMilliseconds).payload
    }

    var body: some View {
        VStack {
            HStack {
                Spacer()
                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: Self.size, height: Self.size)
                        .padding(14)
                        .background(Color.white)
                }
            }
            Spacer()
        }
        .padding(.top, 60)
        .padding(.trailing, 60)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: payload) {
            image = payload.flatMap(Self.render)
        }
    }

    /// The QR code for `payload`, drawn at a whole number of pixels per
    /// module so its edges stay sharp when the camera finds them.
    private nonisolated static func render(_ payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let small = filter.outputImage else { return nil }
        let scale = (size / small.extent.width).rounded(.down)
        let scaled = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

#endif
