import Combine
import Foundation

extension SettingsStore {
    private static let bedrockRegionKey = "AmazonBedrockRegion"

    /// Bedrock is built in, so its endpoint follows this region rather than a saved base URL.
    var bedrockRegion: String {
        get { Self.savedBedrockRegion }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(AmazonBedrock.normalizedRegion(newValue) ?? AmazonBedrock.defaultRegion, forKey: Self.bedrockRegionKey)
        }
    }

    /// Static so `ModelRepository` can read it while `SettingsStore.shared` is still initializing:
    /// its migrations resolve default URLs and models, and touching `shared` there deadlocks.
    static var savedBedrockRegion: String {
        (UserDefaults.standard.object(forKey: self.bedrockRegionKey) as? String)
            .flatMap(AmazonBedrock.normalizedRegion) ?? AmazonBedrock.defaultRegion
    }
}
