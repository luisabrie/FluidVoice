@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Amazon Bedrock: SigV4, AWS profile credentials, and the Converse translation.
@MainActor
final class AmazonBedrockTests: XCTestCase {
    private let baseURL = "https://bedrock-runtime.us-east-1.amazonaws.com"
    private let exampleSecret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    // MARK: - SigV4

    /// AWS SigV4 test suite "get-vanilla".
    func testSigV4MatchesAWSGetVanillaVector() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://example.amazonaws.com/")))
        request.httpMethod = "GET"
        AWSSigV4.sign(
            &request,
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: self.exampleSecret, sessionToken: nil, expiration: nil),
            region: "us-east-1",
            service: "service",
            date: Date(timeIntervalSince1970: 1_440_938_160)
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Date"), "20150830T123600Z")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    /// Expected signatures in the tests below come from an independent Python implementation of SigV4.
    func testSigV4SignsBodyAndSessionToken() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://bedrock-runtime.us-west-2.amazonaws.com/anthropic/v1/messages")))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"m","max_tokens":1}"#.utf8)
        AWSSigV4.sign(
            &request,
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: self.exampleSecret, sessionToken: "SESSIONTOKEN/EXAMPLE+=", expiration: nil),
            region: "us-west-2",
            service: "bedrock",
            date: Date(timeIntervalSince1970: 1_794_139_200)
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"), "SESSIONTOKEN/EXAMPLE+=")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261108/us-west-2/bedrock/aws4_request, SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=4eb9e164a12794febe39086eacd4b1f4ca61fc87d95554aaeacbf19063871a1f"
        )
    }

    /// Model IDs with `:` are percent-encoded in the path and encoded again in the canonical request.
    func testSigV4DoubleEncodesModelIDsInThePath() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "\(self.baseURL)/model/us.meta.llama3-3-70b-instruct-v1%3A0/converse")))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"messages":[]}"#.utf8)
        AWSSigV4.sign(
            &request,
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: self.exampleSecret, sessionToken: nil, expiration: nil),
            region: "us-east-1",
            service: "bedrock",
            date: Date(timeIntervalSince1970: 1_794_139_200)
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261108/us-east-1/bedrock/aws4_request, SignedHeaders=host;x-amz-date, Signature=4055b506ec8a53a103df1ffea547516382035f5161301bfe7fa95f077cb61c75"
        )
    }

    func testSigV4CanonicalizesEncodedQuery() throws {
        var components = URLComponents(string: "https://bedrock.us-east-1.amazonaws.com/inference-profiles")
        components?.percentEncodedQuery = "type=SYSTEM_DEFINED&nextToken=abc%2Bdef%2F%3D&maxResults=1000"
        var request = try URLRequest(url: XCTUnwrap(components?.url))
        AWSSigV4.sign(
            &request,
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: self.exampleSecret, sessionToken: nil, expiration: nil),
            region: "us-east-1",
            service: "bedrock",
            date: Date(timeIntervalSince1970: 1_794_139_200)
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261108/us-east-1/bedrock/aws4_request, SignedHeaders=host;x-amz-date, Signature=4931e4d83686d775aa7cd8aa54e58db21f7f603b367a011bbd8ccd9f650e33f0"
        )
    }

    // MARK: - Endpoints and Credentials

    func testRecognizesTheRuntimeRootOnly() {
        XCTAssertTrue(AmazonBedrock.isConverseEndpoint(baseURL: self.baseURL))
        XCTAssertTrue(AmazonBedrock.isConverseEndpoint(baseURL: self.baseURL + "/"))
        XCTAssertTrue(AmazonBedrock.isConverseEndpoint(baseURL: "https://vpce-0abc.bedrock-runtime.us-east-1.vpce.amazonaws.com"))
        // Bedrock's OpenAI-compatible route and other providers keep Chat Completions.
        XCTAssertFalse(AmazonBedrock.isConverseEndpoint(baseURL: self.baseURL + "/openai/v1"))
        XCTAssertFalse(AmazonBedrock.isConverseEndpoint(baseURL: "https://bedrock-mantle.us-east-1.api.aws/v1"))
        XCTAssertFalse(AmazonBedrock.isConverseEndpoint(baseURL: "https://api.anthropic.com/v1"))
        XCTAssertFalse(AmazonBedrock.isConverseEndpoint(baseURL: "http://localhost:11434/v1"))
        XCTAssertEqual(AmazonBedrock.region(fromBaseURL: "https://vpce-0abc.bedrock-runtime.eu-central-1.vpce.amazonaws.com"), "eu-central-1")
    }

    func testRegionCannotChangeTheHost() {
        XCTAssertEqual(AmazonBedrock.normalizedRegion(" EU-West-1 "), "eu-west-1")
        XCTAssertNil(AmazonBedrock.normalizedRegion("us-east-1.evil.com/x"))
        XCTAssertNil(AmazonBedrock.normalizedRegion("evil.com#"))
        XCTAssertEqual(ModelRepository.bedrockBaseURL(region: "evil.com/"), self.baseURL)
    }

    func testDefaultModelsUseTheRegionsInferenceProfiles() {
        XCTAssertEqual(ModelRepository.bedrockModels(region: "us-west-2").first, "us.anthropic.claude-opus-5-5")
        XCTAssertEqual(ModelRepository.bedrockModels(region: "eu-west-3").first, "eu.anthropic.claude-opus-5-5")
        XCTAssertEqual(ModelRepository.bedrockModels(region: "ap-southeast-2").first, "au.anthropic.claude-opus-5-5")
        XCTAssertEqual(ModelRepository.bedrockModels(region: "ap-northeast-1").first, "global.anthropic.claude-opus-5-5", "Claude 5.5 has no jp. profile")
        XCTAssertEqual(ModelRepository.bedrockModels(region: "sa-east-1").first, "global.anthropic.claude-opus-5-5")
        XCTAssertEqual(
            ModelRepository.shared.defaultModels(for: AmazonBedrock.providerID, baseURL: ModelRepository.bedrockBaseURL(region: "eu-west-1")).first,
            "eu.anthropic.claude-opus-5-5"
        )
    }

    func testSetupLinkFollowsTheSignInMethod() {
        let repository = ModelRepository.shared
        XCTAssertEqual(repository.providerWebsiteURL(for: AmazonBedrock.providerID, apiKey: "aws-profile:dev-sso")?.label, "Setup Guide")
        XCTAssertEqual(repository.providerWebsiteURL(for: AmazonBedrock.providerID, apiKey: "ABSKexample")?.label, "Get API Key")
        XCTAssertEqual(repository.providerWebsiteURL(for: "openai", apiKey: "aws-profile:dev-sso")?.label, "Get API Key")
    }

    func testSelectedModelMovesToAProfileTheNewRegionOffers() {
        let euWest1 = ["eu.anthropic.claude-sonnet-5-5", "global.anthropic.claude-sonnet-5-5", "global.openai.gpt-5.6-luna", "openai.gpt-oss-20b-1:0"]
        XCTAssertEqual(ModelRepository.bedrockModelID("us.anthropic.claude-sonnet-5-5", among: euWest1), "eu.anthropic.claude-sonnet-5-5", "Stays in a geography")
        XCTAssertEqual(ModelRepository.bedrockModelID("us.openai.gpt-5.6-luna", among: euWest1), "global.openai.gpt-5.6-luna")
        XCTAssertEqual(ModelRepository.bedrockModelID("openai.gpt-oss-20b-1:0", among: euWest1), "openai.gpt-oss-20b-1:0")
        XCTAssertNil(ModelRepository.bedrockModelID("us.meta.llama3-3-70b-instruct-v1:0", among: euWest1))

        XCTAssertEqual(AmazonBedrock.foundationModelID("global.openai.gpt-5.6-luna"), "openai.gpt-5.6-luna")
        XCTAssertEqual(AmazonBedrock.foundationModelID("openai.gpt-5.4"), "openai.gpt-5.4", "A provider name isn't a profile prefix")
    }

    func testOnlyRejectedCredentialsAreExportedAgain() {
        XCTAssertTrue(AmazonBedrock.rejectsCredentials(status: 403, body: #"{"message":"The security token included in the request is expired"}"#))
        XCTAssertTrue(AmazonBedrock.rejectsCredentials(status: 401, body: ""))
        XCTAssertFalse(AmazonBedrock.rejectsCredentials(
            status: 403,
            body: #"{"message":"User: arn:aws:sts::123456789012:assumed-role/Dev/me is not authorized to perform: bedrock:InvokeModel"}"#
        ))
    }

    func testCredentialReferenceRoundTrips() {
        XCTAssertEqual(BedrockCredential(storedValue: "aws-profile:dev-sso"), .profile("dev-sso"))
        XCTAssertEqual(BedrockCredential.profile("dev-sso").storedValue, "aws-profile:dev-sso")
        XCTAssertEqual(BedrockCredential(storedValue: " ABSKexample "), .apiKey("ABSKexample"))
        XCTAssertNil(BedrockCredential(storedValue: "aws-profile:").profileName)
    }

    // MARK: - Requests

    func testAPIKeyRequestUsesBearerAndTheConversePath() throws {
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Hi"]],
            model: "us.meta.llama3-3-70b-instruct-v1:0",
            baseURL: self.baseURL,
            apiKey: "ABSKexample",
            streaming: true
        )
        let request = try LLMClient.shared.buildRequest(config)
        XCTAssertEqual(request.url?.absoluteString, self.baseURL + "/model/us.meta.llama3-3-70b-instruct-v1%3A0/converse-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ABSKexample")
    }

    func testProfileRequestIsSignedAndNeverSendsTheReference() async throws {
        let cli = FakeAWSCLI(result: Self.exportResult(expiration: "2099-01-01T00:00:00+00:00"))
        let client = LLMClient(session: .shared, awsCredentials: AWSCLICredentialProvider(runner: cli))

        let request = try await client.prepareRequest(self.config(apiKey: "aws-profile:dev-sso"))

        XCTAssertEqual(request.url?.path, "/model/us.anthropic.claude-opus-5-5/converse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"), "TOKEN")
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDTEST/"))
        XCTAssertTrue(authorization.contains("/us-east-1/bedrock/aws4_request"))
        XCTAssertEqual(cli.calls, [["configure", "export-credentials", "--profile", "dev-sso", "--format", "process"]])
    }

    func testBodyTranslatesSystemToolsAndSettings() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Clean up dictation."],
            ["role": "user", "content": "hello world"],
        ]
        let config = LLMClient.Config(
            messages: messages,
            model: "us.anthropic.claude-opus-5-5",
            baseURL: self.baseURL,
            apiKey: "key",
            streaming: false,
            tools: [TerminalService.toolDefinition],
            temperature: 0.2,
            extraParameters: ["output_config": ["effort": "low"]]
        )
        let body = LLMClient.shared.buildConverseBody(config)

        XCTAssertEqual((body["system"] as? [[String: Any]])?.first?["text"] as? String, "Clean up dictation.")
        let inference = try XCTUnwrap(body["inferenceConfig"] as? [String: Any])
        XCTAssertEqual(inference["temperature"] as? Double, 0.2)
        XCTAssertNil(inference["maxTokens"], "Without a limit each model uses its own default")
        let tools = try XCTUnwrap((body["toolConfig"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first?["toolSpec"] as? [String: Any])
        XCTAssertEqual(tool["name"] as? String, "execute_terminal_command")
        XCTAssertNotNil((tool["inputSchema"] as? [String: Any])?["json"] as? [String: Any])
        let additional = try XCTUnwrap(body["additionalModelRequestFields"] as? [String: Any])
        XCTAssertEqual((additional["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let converted = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(converted.count, 1)
        XCTAssertEqual((converted.first?["content"] as? [[String: Any]])?.first?["text"] as? String, "hello world")
    }

    // MARK: - Reasoning effort

    /// Schemas as ListFoundationModels publishes them.
    func testEffortFieldsComeFromPublishedSchemas() throws {
        let gpt = try XCTUnwrap(BedrockModelCatalog.EffortField(schemaJSON: #"{"reasoning_config":{"type":"enum","default":"medium","enum":["none","low","medium","high","xhigh","max"]}}"#))
        XCTAssertEqual(gpt.path, ["reasoning_config"])
        let claude = try XCTUnwrap(BedrockModelCatalog.EffortField(schemaJSON: #"{"output_config":{"effort":{"type":"enum","default":"medium","enum":["low","medium","high","xhigh","max"]}},"hideSamplingParameter":true}"#))
        XCTAssertEqual(claude.path, ["output_config", "effort"])
        XCTAssertNil(BedrockModelCatalog.EffortField(schemaJSON: #"{"top_k":{"type":"number"},"reasoningConfig":{"enabled":{"type":"boolean","default":false},"budgetTokens":{"type":"integer"}}}"#), "Claude 4.5 rejects the toggle it lists")
        XCTAssertNil(BedrockModelCatalog.EffortField(schemaJSON: "null"))

        XCTAssertEqual(claude.level(for: "minimal"), "low", "Rounds up to a level the model takes")
        XCTAssertEqual(claude.level(for: "none"), "low")
        XCTAssertEqual(gpt.level(for: "none"), "none")
        let kimi = BedrockModelCatalog.EffortField(path: ["reasoning_config"], levels: ["none", "low", "high", "max"])
        XCTAssertEqual(kimi.level(for: "medium"), "high")
    }

    func testReasoningEffortMovesIntoTheModelsField() async throws {
        let region = "eu-south-2"
        await BedrockModelCatalog.cacheEffortFields([
            "openai.gpt-5.6-luna": .init(path: ["reasoning_config"], levels: ["none", "low", "medium", "high"]),
            "anthropic.claude-sonnet-5-5": .init(path: ["output_config", "effort"], levels: ["low", "medium", "high"]),
        ], region: region)
        func parameters(_ model: String, _ extra: [String: Any]) async -> [String: Any] {
            await LLMClient.converseExtraParameters(for: LLMClient.Config(
                messages: [], model: model, baseURL: "https://bedrock-runtime.\(region).amazonaws.com", apiKey: "key", extraParameters: extra
            ))
        }

        let gpt = await parameters("us.openai.gpt-5.6-luna", ["reasoning_effort": "low", "custom": 1])
        XCTAssertEqual(gpt["reasoning_config"] as? String, "low")
        XCTAssertNil(gpt["reasoning_effort"])
        XCTAssertEqual(gpt["custom"] as? Int, 1, "Custom settings go to the model unchanged")

        let claude = await parameters("global.anthropic.claude-sonnet-5-5", ["reasoning_effort": "minimal"])
        XCTAssertEqual((claude["output_config"] as? [String: Any])?["effort"] as? String, "low")

        let gptOSS = await parameters("openai.gpt-oss-20b-1:0", ["reasoning_effort": "low"])
        XCTAssertEqual(gptOSS["reasoning_effort"] as? String, "low", "Models without an effort field get it as-is")
    }

    func testToolCallsBecomeToolUseAndToolResultBlocks() throws {
        let messages = LLMClient.converseMessages(from: [
            ["role": "user", "content": "list files"],
            ["role": "assistant", "content": "", "tool_calls": [[
                "id": "tooluse_1", "type": "function",
                "function": ["name": "execute_terminal_command", "arguments": #"{"command":"ls"}"#],
            ]]],
            ["role": "tool", "content": #"{"success":true}"#, "tool_call_id": "tooluse_1"],
            ["role": "user", "content": "thanks"],
        ]).messages
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])

        let toolUse = try XCTUnwrap((messages[1]["content"] as? [[String: Any]])?.first?["toolUse"] as? [String: Any])
        XCTAssertEqual(toolUse["toolUseId"] as? String, "tooluse_1")
        XCTAssertEqual((toolUse["input"] as? [String: Any])?["command"] as? String, "ls")

        let reply = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual((reply.first?["toolResult"] as? [String: Any])?["toolUseId"] as? String, "tooluse_1")
        XCTAssertEqual(reply.last?["text"] as? String, "thanks")
    }

    /// Command Mode records a cancelled command as an assistant message with no tool result.
    func testCancelledToolCallGetsAnErrorResult() throws {
        let messages = LLMClient.converseMessages(from: [
            ["role": "user", "content": "delete the build folder"],
            ["role": "assistant", "content": "Removing it.", "tool_calls": [[
                "id": "tooluse_9", "type": "function",
                "function": ["name": "execute_terminal_command", "arguments": #"{"command":"rm -rf build"}"#],
            ]]],
            ["role": "assistant", "content": "Command cancelled."],
            ["role": "user", "content": "never mind"],
        ]).messages

        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first?["toolResult"] as? [String: Any])
        XCTAssertEqual(result["toolUseId"] as? String, "tooluse_9")
        XCTAssertEqual(result["status"] as? String, "error")
    }

    // MARK: - Responses

    func testNonStreamingResponseParsesTextReasoningAndTools() throws {
        let response = try LLMClient.shared.parseConverseResponse([
            "output": ["message": ["role": "assistant", "content": [
                ["reasoningContent": ["reasoningText": ["text": "Check first."]]],
                ["text": "Listing files."],
                ["toolUse": ["toolUseId": "tooluse_2", "name": "execute_terminal_command", "input": ["command": "ls"]]],
            ]]],
            "stopReason": "tool_use",
        ])
        XCTAssertEqual(response.content, "Listing files.")
        XCTAssertEqual(response.thinking, "Check first.")
        XCTAssertEqual(response.toolCalls.first?.id, "tooluse_2")
        XCTAssertEqual(response.toolCalls.first?.getString("command"), "ls")
        XCTAssertFalse(response.isIncomplete)

        let truncated = try LLMClient.shared.parseConverseResponse([
            "output": ["message": ["role": "assistant", "content": [["text": "Partial"]]]],
            "stopReason": "max_tokens",
        ])
        XCTAssertTrue(truncated.isIncomplete)
    }

    func testEventStreamDecoderSplitsFramesAndReadsHeaders() throws {
        let stream = Self.event("contentBlockDelta", #"{"delta":{"text":"Hi"}}"#) + Self.event("messageStop", #"{"stopReason":"end_turn"}"#)
        var decoder = AWSEventStreamDecoder()
        var messages: [AWSEventStreamDecoder.Message] = []
        for byte in stream {
            if let message = try decoder.append(byte) { messages.append(message) }
        }
        XCTAssertEqual(messages.map { $0.headers[":event-type"] }, ["contentBlockDelta", "messageStop"])
        XCTAssertEqual(messages.first.flatMap { String(bytes: $0.payload, encoding: .utf8) }, #"{"delta":{"text":"Hi"}}"#)
    }

    func testStreamingParsesTextReasoningAndToolInput() async throws {
        let events = [
            Self.event("messageStart", #"{"role":"assistant"}"#),
            Self.event("contentBlockDelta", #"{"contentBlockIndex":0,"delta":{"reasoningContent":{"text":"Plan."}}}"#),
            Self.event("contentBlockStop", #"{"contentBlockIndex":0}"#),
            Self.event("contentBlockDelta", #"{"contentBlockIndex":1,"delta":{"text":"Checking"}}"#),
            Self.event("contentBlockDelta", #"{"contentBlockIndex":1,"delta":{"text":" files."}}"#),
            Self.event("contentBlockStart", #"{"contentBlockIndex":2,"start":{"toolUse":{"toolUseId":"tooluse_3","name":"execute_terminal_command"}}}"#),
            Self.event("contentBlockDelta", #"{"contentBlockIndex":2,"delta":{"toolUse":{"input":"{\"command\": \"ls"}}}"#),
            Self.event("contentBlockDelta", #"{"contentBlockIndex":2,"delta":{"toolUse":{"input":"\"}"}}}"#),
            Self.event("messageStop", #"{"stopReason":"tool_use"}"#),
            Self.event("metadata", #"{"usage":{"inputTokens":5,"outputTokens":9}}"#),
        ]
        BedrockStubProtocol.respond(contentType: "application/vnd.amazon.eventstream", body: events.reduce(Data(), +))
        let chunks = ChunkRecorder()
        var config = self.config(apiKey: "ABSKexample", streaming: true)
        config.onContentChunk = { chunks.append($0) }
        config.onToolCallStart = { chunks.append("tool:\($0)") }

        let response = try await self.stubbedClient().call(config)

        XCTAssertEqual(response.content, "Checking files.")
        XCTAssertEqual(response.thinking, "Plan.")
        XCTAssertEqual(response.toolCalls.first?.id, "tooluse_3")
        XCTAssertEqual(response.toolCalls.first?.getString("command"), "ls")
        XCTAssertEqual(chunks.values, ["Checking", " files.", "tool:execute_terminal_command"])
        XCTAssertEqual(BedrockStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer ABSKexample")
    }

    func testStreamingExceptionEventThrows() async {
        BedrockStubProtocol.respond(
            contentType: "application/vnd.amazon.eventstream",
            body: Self.frame([":message-type": "exception", ":exception-type": "throttlingException"], #"{"message":"Too many requests"}"#)
        )
        do {
            _ = try await self.stubbedClient().call(self.config(apiKey: "ABSKexample", streaming: true))
            XCTFail("Expected the exception event to throw")
        } catch let LLMError.httpError(status, body) {
            XCTAssertEqual(status, 429)
            XCTAssertTrue(body.contains("Too many requests"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingErrorFrameThrows() async {
        BedrockStubProtocol.respond(
            contentType: "application/vnd.amazon.eventstream",
            body: Self.event("contentBlockDelta", #"{"delta":{"text":"Hi"}}"#)
                + Self.frame([":message-type": "error", ":error-code": "InternalFailure", ":error-message": "Stream failed"], "")
        )
        do {
            _ = try await self.stubbedClient().call(self.config(apiKey: "ABSKexample", streaming: true))
            XCTFail("Expected the error frame to throw")
        } catch let LLMError.httpError(_, body) {
            XCTAssertEqual(body, "InternalFailure: Stream failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamEndingBeforeMessageStopIsIncomplete() async throws {
        BedrockStubProtocol.respond(
            contentType: "application/vnd.amazon.eventstream",
            body: Self.event("contentBlockDelta", #"{"delta":{"text":"The meeting covered"}}"#)
        )
        let response = try await self.stubbedClient().call(self.config(apiKey: "ABSKexample", streaming: true))
        XCTAssertEqual(response.content, "The meeting covered")
        XCTAssertTrue(response.isIncomplete)
    }

    // MARK: - AWS CLI Credentials

    func testCredentialsAreCachedAndRefreshWithoutWaiting() async throws {
        let cli = FakeAWSCLI(result: Self.exportResult(expiration: "2026-11-08T13:00:00Z"))
        let provider = AWSCLICredentialProvider(runner: cli)
        let issued = Date(timeIntervalSince1970: 1_794_139_200) // 12:00 UTC

        _ = try await provider.credentials(profile: "dev", now: issued)
        _ = try await provider.credentials(profile: "dev", now: issued.addingTimeInterval(50 * 60))
        XCTAssertEqual(cli.calls.count, 1)

        // Inside the refresh margin the still-valid credentials come back while a refresh runs.
        let current = try await provider.credentials(profile: "dev", now: issued.addingTimeInterval(56 * 60))
        XCTAssertEqual(current.accessKeyID, "AKIDTEST")

        await provider.invalidate(profile: "dev")
        _ = try await provider.credentials(profile: "dev", now: issued)
        XCTAssertGreaterThanOrEqual(cli.calls.count, 2)
    }

    func testExpiredSSOSessionAsksToSignIn() async {
        let cli = FakeAWSCLI(result: AWSCLIResult(
            exitCode: 255,
            stdout: "",
            stderr: "Error when retrieving token from sso: Token has expired and refresh failed"
        ))
        do {
            _ = try await AWSCLICredentialProvider(runner: cli).credentials(profile: "dev-sso")
            XCTFail("Expected an SSO error")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .signInRequired(profile: "dev-sso"))
            XCTAssertTrue(error.localizedDescription.contains("aws sso login --profile dev-sso"))
        }
    }

    func testSSOLoginFailureIsReported() async {
        let cli = FakeAWSCLI(result: AWSCLIResult(exitCode: 255, stdout: "", stderr: "The config profile (missing) could not be found"))
        do {
            try await AWSCLICredentialProvider(runner: cli).signIn(profile: "missing")
            XCTFail("Expected a missing profile error")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .profileNotFound(profile: "missing"))
        }
        XCTAssertEqual(cli.calls, [["sso", "login", "--profile", "missing"]])
    }

    func testParsesProfilesFromConfigAndCredentials() {
        let profiles = AWSConfigProfiles.parse(
            config: """
            [default]
            region = us-west-2

            [profile dev-sso]
            sso_session = corp

            [profile legacy-sso]
            sso_start_url = https://example.awsapps.com/start

            [sso-session corp]
            sso_start_url = https://example.awsapps.com/start
            """,
            credentials: """
            [default]
            aws_access_key_id = AKIDEXAMPLE

            [ci]
            aws_access_key_id = AKIDEXAMPLE
            """
        )
        XCTAssertEqual(profiles.map(\.name), ["default", "dev-sso", "legacy-sso", "ci"])
        XCTAssertEqual(profiles.filter(\.usesSSO).map(\.name), ["dev-sso", "legacy-sso"])
    }

    func testModelCatalogListsConverseChatModels() {
        func model(_ id: String, types: [String], converse: Bool = true, status: String = "ACTIVE") -> [String: Any] {
            [
                "modelId": id,
                "inferenceTypesSupported": types,
                "inputModalities": ["TEXT"],
                "modelLifecycle": ["status": status],
                "inferenceAPIsSupported": ["converse": ["sync": converse, "streaming": converse]],
            ]
        }
        func profile(_ id: String, model: String) -> [String: Any] {
            ["inferenceProfileId": id, "status": "ACTIVE", "models": [["modelArn": "arn:aws:bedrock:us-east-1::foundation-model/\(model)"]]]
        }
        let ids = BedrockModelCatalog.chatModelIDs(
            foundationModels: ["modelSummaries": [
                model("openai.gpt-oss-20b-1:0", types: ["ON_DEMAND"]),
                model("meta.llama3-3-70b-instruct-v1:0", types: ["INFERENCE_PROFILE"]),
                model("cohere.rerank-v3-5:0", types: ["ON_DEMAND"], converse: false),
                model("amazon.retired-model", types: ["ON_DEMAND"], status: "LEGACY"),
            ]],
            inferenceProfiles: ["inferenceProfileSummaries": [
                profile("us.meta.llama3-3-70b-instruct-v1:0", model: "meta.llama3-3-70b-instruct-v1:0"),
                profile("us.cohere.embed-v4:0", model: "cohere.embed-v4:0"),
            ]]
        )
        XCTAssertEqual(ids, ["openai.gpt-oss-20b-1:0", "us.meta.llama3-3-70b-instruct-v1:0"])
    }

    // MARK: - Helpers

    private func config(apiKey: String, streaming: Bool = false) -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Hi"]],
            model: "us.anthropic.claude-opus-5-5",
            baseURL: self.baseURL,
            apiKey: apiKey,
            streaming: streaming
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return config
    }

    private func stubbedClient() -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedrockStubProtocol.self]
        return LLMClient(session: URLSession(configuration: configuration))
    }

    private static func exportResult(expiration: String) -> AWSCLIResult {
        AWSCLIResult(
            exitCode: 0,
            stdout: #"{"Version":1,"AccessKeyId":"AKIDTEST","SecretAccessKey":"SECRET","SessionToken":"TOKEN","Expiration":"\#(expiration)"}"#,
            stderr: ""
        )
    }

    private static func event(_ type: String, _ payload: String) -> Data {
        self.frame([":event-type": type, ":message-type": "event", ":content-type": "application/json"], payload)
    }

    /// An AWS event stream frame with string headers. The decoder doesn't check CRCs, so they are zero.
    private static func frame(_ headers: [String: String], _ payload: String) -> Data {
        var headerBytes: [UInt8] = []
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let valueBytes = Array(value.utf8)
            headerBytes += [UInt8(name.utf8.count)] + Array(name.utf8)
            headerBytes += [7, UInt8(valueBytes.count >> 8), UInt8(valueBytes.count & 0xff)] + valueBytes
        }
        let payloadBytes = Array(payload.utf8)
        func bigEndian(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        let total = 12 + headerBytes.count + payloadBytes.count + 4
        return Data(bigEndian(total) + bigEndian(headerBytes.count) + [0, 0, 0, 0] + headerBytes + payloadBytes + [0, 0, 0, 0])
    }
}

private final class FakeAWSCLI: AWSCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let result: AWSCLIResult

    init(result: AWSCLIResult) {
        self.result = result
    }

    var calls: [[String]] {
        self.lock.withLock { self.recorded }
    }

    func run(arguments: [String], timeout _: TimeInterval) async throws -> AWSCLIResult {
        self.lock.withLock { self.recorded.append(arguments) }
        return self.result
    }
}

private final class ChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        self.lock.withLock { self.recorded }
    }

    func append(_ value: String) {
        self.lock.withLock { self.recorded.append(value) }
    }
}

private final class BedrockStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var response = (contentType: "application/json", body: Data())
    private nonisolated(unsafe) static var request: URLRequest?

    static var lastRequest: URLRequest? {
        self.lock.withLock { self.request }
    }

    static func respond(contentType: String, body: Data) {
        self.lock.withLock {
            self.response = (contentType, body)
            self.request = nil
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (contentType, body) = Self.lock.withLock {
            Self.request = self.request
            return Self.response
        }
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])
        else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
