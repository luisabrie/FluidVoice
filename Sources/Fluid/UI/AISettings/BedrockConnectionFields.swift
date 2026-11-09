import SwiftUI

/// Amazon Bedrock's Region, Sign in, and AWS SSO rows. Each settings surface lays them out with its own
/// `field`, and shows its usual API Key row when "Bedrock API key" is chosen in Sign in.
struct BedrockConnectionFields<Field: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    /// The provider's API key slot: `aws-profile:<name>` or a Bedrock API key.
    @Binding var credential: String
    @Binding var region: String
    /// Matches the surface's API Key field: nil fills the row.
    var controlWidth: CGFloat?
    /// Shown beside Sign in for an AWS profile, like the link beside an API Key field.
    var signInAccessory: AnyView?
    let field: (String, AnyView) -> Field

    private enum SignInChoice: Hashable {
        case profile(String)
        case apiKey
    }

    var body: some View {
        self.field("Region", AnyView(self.regionPicker))
            .onAppear {
                self.viewModel.refreshAWSProfiles()
                self.fillInDefaultProfile()
            }
            .onChange(of: self.viewModel.awsProfiles) { _, _ in self.fillInDefaultProfile() }
        self.field("Sign in", AnyView(HStack(spacing: 8) {
            self.signInPicker
            if let signInAccessory = self.signInAccessory, BedrockCredential(storedValue: self.credential).usesProfile {
                signInAccessory
            }
        }))
        if self.selectedProfileUsesSSO {
            self.field("AWS SSO", AnyView(self.ssoCard))
        }
    }

    private var regionPicker: some View {
        FluidDropdownPicker("Region", selectedTitle: self.region, selection: self.$region) {
            ForEach(ModelRepository.bedrockRegions, id: \.self) { Text($0).tag($0) }
        }
        .fluidDropdownStyle(fillsWidth: true)
        .frame(maxWidth: self.controlWidth ?? .infinity, alignment: .leading)
    }

    private var signInPicker: some View {
        FluidDropdownPicker("Sign in", selectedTitle: self.signInTitle, selection: self.signInChoice) {
            ForEach(self.profileOptions, id: \.self) { name in
                Text(name).tag(SignInChoice.profile(name))
            }
            Divider()
            Text("Bedrock API key").tag(SignInChoice.apiKey)
        }
        .fluidDropdownStyle(fillsWidth: true)
        .frame(maxWidth: self.controlWidth ?? .infinity, alignment: .leading)
    }

    /// Matches the Reasoning card: status on the left, action on the right.
    private var ssoCard: some View {
        HStack(spacing: 8) {
            if self.viewModel.awsSignIn == .signingIn(profile: self.selectedProfile) {
                ProgressView().controlSize(.small)
            }
            Text(self.ssoStatus)
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
            Spacer()
            Button("Sign in…", systemImage: "person.badge.key") {
                self.viewModel.signInToAWS(profile: self.selectedProfile)
            }
            .fluidButton(.compact, size: .small)
            .disabled(self.viewModel.awsSignIn == .signingIn(profile: self.selectedProfile))
        }
        .padding(10)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
        .overlay(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm).strokeBorder(self.theme.palette.cardBorder))
    }

    private var ssoStatus: String {
        switch self.viewModel.awsSignIn {
        case .signingIn(self.selectedProfile): return "Waiting for your browser…"
        case .signedIn(self.selectedProfile): return "Signed in"
        case .failed(self.selectedProfile, _): return "Sign-in didn’t finish"
        default: return "Uses your AWS CLI sign-in"
        }
    }

    // MARK: - Selection

    private var selectedProfile: String {
        BedrockCredential(storedValue: self.credential).profileName ?? ""
    }

    private var selectedProfileUsesSSO: Bool {
        self.viewModel.awsProfiles.first { $0.name == self.selectedProfile }?.usesSSO ?? false
    }

    private var signInTitle: String {
        guard BedrockCredential(storedValue: self.credential).usesProfile else { return "Bedrock API key" }
        if !self.selectedProfile.isEmpty {
            return self.selectedProfile
        }
        return self.viewModel.awsProfiles.isEmpty ? "No AWS profiles found" : "Choose a profile"
    }

    /// Keeps a saved profile selectable after it is removed from the config file.
    private var profileOptions: [String] {
        let names = self.viewModel.awsProfiles.map(\.name)
        guard !self.selectedProfile.isEmpty, !names.contains(self.selectedProfile) else { return names }
        return [self.selectedProfile] + names
    }

    /// A profile not yet chosen is filled in once profiles load, when the choice is unambiguous.
    private func fillInDefaultProfile() {
        let name = self.viewModel.defaultAWSProfileName
        guard BedrockCredential(storedValue: self.credential) == .profile(""), !name.isEmpty else { return }
        self.credential = BedrockCredential.profile(name).storedValue
    }

    private var signInChoice: Binding<SignInChoice> {
        Binding(
            get: { BedrockCredential(storedValue: self.credential).usesProfile ? .profile(self.selectedProfile) : .apiKey },
            set: { choice in
                switch choice {
                case let .profile(name):
                    self.credential = BedrockCredential.profile(name).storedValue
                case .apiKey:
                    guard BedrockCredential(storedValue: self.credential).usesProfile else { return }
                    self.credential = ""
                }
            }
        )
    }
}
