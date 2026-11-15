import SwiftUI
import ModalTransport

/// Uses the original glasses-ui SVGs; only the lens content is rendered.
struct LensArtwork: View {
    let screen: LensScreen
    let nowNs: UInt64
    private var accent: Color {
        switch screen.style {
        case .checkingIn: Color(red: 1, green: 214/255, blue: 10/255)
        case .escalated: Color(red: 1, green: 59/255, blue: 48/255)
        case .alertSent, .cancelled: Color(red: 48/255, green: 209/255, blue: 88/255)
        }
    }
    private var icon: String {
        switch screen.style {
        case .checkingIn: "LensHourglass"
        case .escalated: "LensAlert"
        case .alertSent: "LensCheck"
        case .cancelled: "LensShieldCheck"
        }
    }
    var body: some View {
        VStack(spacing: 24) {
            if screen.isTest { Text("TEST").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
            ZStack {
                if screen.style == .checkingIn {
                    Circle().stroke(accent.opacity(0.25), lineWidth: 5).frame(width: 180, height: 180)
                }
                Image(icon).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(accent).frame(width: screen.style == .checkingIn ? 120 : 160, height: 160)
            }.frame(height: 190)
            Text(screen.title).font(.system(size: 54, weight: .regular))
                .multilineTextAlignment(.center).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if screen.style == .checkingIn {
                    Image("LensMicrophone").resizable().renderingMode(.template).scaledToFit().frame(width: 26, height: 26)
                }
                Text(screen.detail).font(.system(size: 26)).multilineTextAlignment(.center)
            }.foregroundStyle(.white.opacity(0.78))
            if let seconds = screen.remainingReplySeconds(nowNs: nowNs) {
                Text("\(seconds) s").font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(accent)
            }
        }
        .padding(52).frame(width: 600, height: 600)
        .background(.black).environment(\.colorScheme, .dark)
    }
}
