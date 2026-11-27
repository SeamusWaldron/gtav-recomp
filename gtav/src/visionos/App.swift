// gtav - visionOS app shell (docs/VISIONOS_PLAN.md, phase 2): a SwiftUI app with a small launch
// window and a full immersive space whose Compositor Services layer shows the game.
//
// The game itself is unchanged: rex_ios_run_app() runs the SDK's app (SDL, the runtime, the native
// renderer) exactly as SDL's own UIKit app delegate would, from a run-loop callout on the main
// thread. Its main loop is SDL's nested run loop, which keeps UIKit and SwiftUI running.
import CompositorServices
import SwiftUI

// One texture per eye (no vertex amplification needed) and no foveation: a flat screen in the room
// gains nothing from either yet.
struct GameLayerConfiguration: CompositorLayerConfiguration {
  func makeConfiguration(
    capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration
  ) {
    configuration.layout = .dedicated
    configuration.isFoveationEnabled = false
    configuration.colorFormat = .bgra8Unorm_srgb
    configuration.depthFormat = .depth32Float
  }
}

final class GameStarter: NSObject {
  static let shared = GameStarter()
  private var started = false

  // Starts the game once. A run-loop callout, not a main-queue block: the game's main loop never
  // returns, and the main queue has to stay free for SwiftUI (SDL starts the same way).
  func startOnce() {
    guard !started else { return }
    started = true
    perform(#selector(run), with: nil, afterDelay: 0)
  }

  @objc private func run() {
    let rc = rex_ios_run_app(CommandLine.argc, CommandLine.unsafeArgv)
    exit(rc)
  }
}

@main
struct GTAVApp: App {
  var body: some Scene {
    // The launch window also gives SDL's (hidden) game window a scene to live in.
    WindowGroup(id: "launcher") {
      LauncherView()
    }
    .windowStyle(.plain)
    .defaultSize(width: 560, height: 280)

    ImmersiveSpace(id: "game") {
      CompositorLayer(configuration: GameLayerConfiguration()) { layer in
        // The compositor loop runs on its own thread for as long as the space is open.
        let thread = Thread { gtav_immersive_run(layer) }
        thread.name = "compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
      }
    }
    .immersionStyle(selection: .constant(.full), in: .full)
  }
}

struct LauncherView: View {
  @Environment(\.openImmersiveSpace) private var openImmersiveSpace
  @State private var status = "Opening the immersive space..."
  @State private var open = false

  // The window cannot close while the game runs (SDL's hidden game window lives in its scene), so
  // once the space is open it turns invisible and lets input through.
  var body: some View {
    VStack(spacing: 14) {
      Text("GTA V").font(.largeTitle).bold()
      Text(status).foregroundStyle(.secondary)
      Button("Enter") { Task { await enter() } }
    }
    .padding(36)
    .glassBackgroundEffect()
    .opacity(open ? 0 : 1)
    .allowsHitTesting(!open)
    .onAppear {
      GameStarter.shared.startOnce()
      Task { await enter() }
    }
  }

  private func enter() async {
    switch await openImmersiveSpace(id: "game") {
    case .opened:
      open = true
      status = "Playing in the immersive space."
    case .userCancelled:
      status = "The immersive space was declined."
    default:
      status = "The immersive space could not be opened."
    }
  }
}
