import Foundation

extension AIEnhancementSettingsViewModel {
    enum AWSSignInState: Equatable {
        case idle
        case signingIn(profile: String)
        case signedIn(profile: String)
        case failed(profile: String, message: String)
    }

    /// Chosen without asking only when it is unambiguous; empty asks the user to choose.
    var defaultAWSProfileName: String {
        if self.awsProfiles.contains(where: { $0.name == "default" }) {
            return "default"
        }
        return self.awsProfiles.count == 1 ? self.awsProfiles[0].name : ""
    }

    /// Reads ~/.aws/config off the main actor.
    func refreshAWSProfiles() {
        self.awsProfilesTask?.cancel()
        self.awsProfilesTask = Task {
            let profiles = await Task.detached(priority: .utility) { AWSConfigProfiles.load() }.value
            guard !Task.isCancelled, profiles != self.awsProfiles else { return }
            self.awsProfiles = profiles
        }
    }

    func signInToAWS(profile: String) {
        self.awsSignInTask?.cancel()
        self.awsSignIn = .signingIn(profile: profile)
        self.awsSignInTask = Task {
            do {
                try await AWSCLICredentialProvider.shared.signIn(profile: profile)
                guard !Task.isCancelled else { return }
                self.awsSignIn = .signedIn(profile: profile)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.awsSignIn = .failed(profile: profile, message: error.localizedDescription)
            }
        }
    }

    /// The sign-in failure for the profile in a stored credential, shown in each surface's error style.
    func awsSignInError(for credential: String) -> String? {
        guard case let .failed(profile, message) = self.awsSignIn,
              profile == BedrockCredential(storedValue: credential).profileName
        else { return nil }
        return message
    }

    func cancelAWSSignIn() {
        self.awsSignInTask?.cancel()
        self.awsSignInTask = nil
        if case .signingIn = self.awsSignIn {
            self.awsSignIn = .idle
        }
    }
}
