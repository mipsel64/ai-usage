import Foundation
import Testing
@testable import QuotaCore

struct RemoteUsageTests {
    private static let zaiQuotaBody = Data(#"""
        {"code":200,"success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20}
        ]}}
    """#.utf8)

    private let observedAt = Date(timeIntervalSince1970: 1_800_000_100)

    @Test func zaiMapsDistinctWindowsAndConvertsUsedToRemaining() async throws {
        let snapshot = try await fetch(
            .zai,
            body: #"""
                {
                "data": { "level": "pro", "limits": [
                    {
                        "type": "TIME_LIMIT", "unit": 5, "number": 1,
                        "percentage": 10
                    },
                    {
                        "type": "TOKENS_LIMIT", "unit": 3,
                        "percentage": 12.5, "nextResetTime": 1800000000123
                    },
                    {
                        "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
                        "percentage": 60, "nextResetTime": 1800060000000
                    }
                ] }
                }
            """#
        )

        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows == [
            QuotaWindow(
                id: "zai-5h",
                title: "5-hour",
                remainingPercent: 87.5,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000.123)
            ),
            QuotaWindow(
                id: "zai-weekly",
                title: "Weekly",
                remainingPercent: 40,
                resetAt: Date(timeIntervalSince1970: 1_800_060_000)
            ),
            QuotaWindow(
                id: "zai-monthly-tools",
                title: "Monthly tools",
                remainingPercent: 90,
                resetAt: nil
            ),
        ])
    }

    @Test func zaiSupportsCreditLimitsAndOmittedResets() async throws {
        let snapshot = try await fetch(
            .zai,
            body: #"""
                {
                "code": 200,
                "success": true,
                "data": { "limits": [
                    { "type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 0 }
                ] }
                }
            """#
        )

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].remainingPercent == 100)
        #expect(snapshot.windows[0].resetAt == nil)
    }

    @Test func zaiKeepsLegacyWeeklyNumberPairs() async throws {
        for number in ["7", "null"] {
            let snapshot = try await fetch(
                .zai,
                body: """
                {"code":200,"success":true,"data":{"limits":[
                    {"type":"CREDIT_LIMIT","unit":6,"number":\(number),"percentage":40}
                ]}}
                """
            )
            #expect(snapshot.windows.map(\.id) == ["zai-weekly"])
            #expect(snapshot.windows[0].remainingPercent == 60)
        }
    }

    @Test func zaiSkipsUnknownUnitNumberPairs() async throws {
        let snapshot = try await fetch(
            .zai,
            body: #"""
                {"code":200,"success":true,"data":{"limits":[
                    {"type":"TOKENS_LIMIT","unit":6,"number":2,"percentage":90},
                    {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}
                ]}}
            """#
        )
        #expect(snapshot.windows.map(\.id) == ["zai-5h"])
    }

    @Test func zaiRejectsDuplicateWeeklyWindows() async {
        await assertError(
            .invalidResponse,
            provider: .zai,
            body: Data(#"""
                {"code":200,"success":true,"data":{"limits":[
                    {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":10},
                    {"type":"CREDIT_LIMIT","unit":6,"number":7,"percentage":20}
                ]}}
            """#.utf8)
        )
    }

    @Test func defaultObservationTimeFollowsQuotaResponse() async throws {
        let transport = MockRemoteUsageTransport(body: Self.zaiQuotaBody)
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport
        )

        let quotaReturnedAt = try #require(await transport.quotaReturnedAt)
        #expect(snapshot.observedAt >= quotaReturnedAt)
    }

    @Test func zaiExcludesCardThatExpiresBeforeQuotaResponse() async throws {
        let expiry = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: expiry)
        let transport = MockRemoteUsageTransport(
            body: Self.zaiQuotaBody,
            resetBody: Data(#"""
                {"code":200,"success":true,"data":{"fiveHourResets":[
                    {"available":true,"expireTime":"\#(timestamp)"}
                ],"weekResets":[]}}
            """#.utf8),
            quotaRespondAfter: expiry
        )
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport
        )

        #expect(snapshot.resetCredits == ResetCredits(availableCount: 0))
    }

    @Test func zaiReadsAvailableResetCountAndNearestExpiry() async throws {
        let transport = MockRemoteUsageTransport(
            body: Self.zaiQuotaBody,
            resetBody: Data(#"""
                {"code":200,"success":true,"data":{
                    "fiveHourResets":[
                        {"available":false,"expireTime":"2026-11-01 23:59:59"}
                    ],
                    "weekResets":[
                        {"available":true,"expireTime":"2027-12-22 23:59:59","recordId":11,"grantType":"gift"},
                        {"available":true,"expireTime":"2027-12-23 23:59:59","recordId":12,"grantType":"gift"},
                        {"available":true,"expireTime":"2027-12-22 23:59:59","recordId":13,"grantType":"gift"}
                    ]
                }}
            """#.utf8)
        )
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport,
            observedAt: observedAt
        )

        #expect(snapshot.windows.map(\.id) == ["zai-5h"])
        #expect(snapshot.resetCredits == ResetCredits(
            availableCount: 3,
            options: [ResetOption(
                id: "11",
                title: "Weekly reset card",
                detail: "Refills your weekly limit.",
                count: 3,
                expiry: Date(timeIntervalSince1970: 1_829_491_199)
            )]
        ))
        let requests = await transport.requests
        #expect(requests.count == 2)
        let resetRequest = try #require(requests.first {
            $0.url?.path == "/api/biz/customer-package-reset/list"
        })
        #expect(resetRequest.url?.absoluteString ==
            "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")
        #expect(resetRequest.httpMethod == "GET")
        #expect(resetRequest.httpBody == nil)
    }

    @Test func zaiValidEmptyResetInventoryReportsZero() async throws {
        let transport = MockRemoteUsageTransport(
            body: Self.zaiQuotaBody,
            resetBody: Data(#"""
                {"code":200,"success":true,"data":{"fiveHourResets":[],"weekResets":[]}}
            """#.utf8)
        )
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport,
            observedAt: observedAt
        )

        #expect(snapshot.windows.map(\.id) == ["zai-5h"])
        #expect(snapshot.resetCredits == ResetCredits(availableCount: 0))
    }

    @Test func zaiExcludesExpiredResetsAndCountsMissingExpiry() async throws {
        let transport = MockRemoteUsageTransport(
            body: Self.zaiQuotaBody,
            resetBody: Data(#"""
                {"code":200,"success":true,"data":{
                    "fiveHourResets":[
                        {"available":true,"expireTime":"2027-01-01 00:00:00"},
                        {"available":true}
                    ],
                    "weekResets":[
                        {"available":true,"expireTime":"2027-02-01 23:59:59"},
                        {"available":false,"expireTime":"2027-03-01 23:59:59"}
                    ]
                }}
            """#.utf8)
        )
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport,
            observedAt: observedAt
        )

        #expect(snapshot.resetCredits == ResetCredits(availableCount: 2))
    }

    @Test func zaiCountsCardsWithoutRedeemableFieldsButOmitsTheirOptions() async throws {
        let transport = MockRemoteUsageTransport(
            body: Self.zaiQuotaBody,
            resetBody: Data(#"""
                {"code":200,"success":true,"data":{
                    "fiveHourResets":[
                        {"available":true,"expireTime":"2027-02-01 00:00:00"},
                        {"available":true,"expireTime":"2027-02-01 00:00:00","recordId":7,"grantType":""},
                        {"available":true,"expireTime":"2027-02-01 00:00:00","recordId":"9","grantType":"gift"},
                        {"available":true,"expireTime":"2027-02-01 00:00:00","recordId":10,"grantType":4},
                        {"available":true,"expireTime":"2027-02-01 00:00:00","recordId":8,"grantType":"gift"}
                    ],
                    "weekResets":[]
                }}
            """#.utf8)
        )
        let snapshot = try await RemoteUsage.fetch(
            provider: .zai,
            credential: "test-key",
            transport: transport,
            observedAt: observedAt
        )

        #expect(snapshot.resetCredits?.availableCount == 5)
        #expect(snapshot.resetCredits?.options == [ResetOption(
            id: "8",
            title: "5-hour reset card",
            detail: "Refills your 5-hour limit.",
            count: 1,
            expiry: Date(timeIntervalSince1970: 1_801_411_200)
        )])
    }

    @Test func zaiRedeemReadsListThenPostsExactRequest() async throws {
        let transport = QueuedRemoteUsageTransport(responses: [
            .success(.init(statusCode: 200, body: Data(#"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2027-01-16 00:00:00","recordId":42,"grantType":"gift"}],"weekResets":[]}}"#.utf8))),
            .success(.init(statusCode: 200, body: Data(#"{"success":true}"#.utf8))),
        ])

        let outcome = try await RemoteUsage.redeemZaiReset(
            credential: "test-key",
            recordID: "42",
            requestID: "request-1",
            transport: transport,
            observedAt: observedAt
        )

        #expect(redemptionName(outcome) == "reset")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].url?.absoluteString == "https://api.z.ai/api/biz/customer-package-reset/use")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(!requests[1].httpShouldHandleCookies)
        #expect(requests[1].httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"grantType":"gift","recordId":42,"requestId":"request-1","resetType":"FIVE_HOUR","targetType":"PERSONAL"}"#)
    }

    @Test(arguments: [
        #"{"available":true,"expireTime":"2027-01-16 00:00:00","recordId":43,"grantType":"gift"}"#,
        #"{"available":true,"expireTime":"2027-01-14 00:00:00","recordId":42,"grantType":"gift"}"#,
        #"{"available":false,"recordId":42,"grantType":"gift"}"#,
    ])
    func zaiRedeemRefusesUnavailableCardWithoutPost(card: String) async throws {
        let body = #"{"code":200,"success":true,"data":{"fiveHourResets":["# + card + #"],"weekResets":[]}}"#
        let transport = QueuedRemoteUsageTransport(responses: [
            .success(.init(statusCode: 200, body: Data(body.utf8))),
        ])

        let outcome = try await RemoteUsage.redeemZaiReset(
            credential: "test-key",
            recordID: "42",
            requestID: "request-1",
            transport: transport,
            observedAt: observedAt
        )

        #expect(redemptionName(outcome) == "noCredit")
        #expect(await transport.requests.count == 1)
    }

    @Test func zaiRedeemRejectsUnconfirmedResponse() async {
        let transport = QueuedRemoteUsageTransport(responses: [
            .success(.init(statusCode: 200, body: Data(#"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"recordId":42,"grantType":"gift"}],"weekResets":[]}}"#.utf8))),
            .success(.init(statusCode: 200, body: Data(#"{"success":false}"#.utf8))),
        ])

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await RemoteUsage.redeemZaiReset(
                credential: "test-key",
                recordID: "42",
                requestID: "request-1",
                transport: transport,
                observedAt: observedAt
            )
        }
    }

    @Test(arguments: ["", "abc", "-1", "0", "1.0", "１２"])
    func zaiRedeemRejectsInvalidRecordIDBeforeRequests(recordID: String) async {
        let transport = QueuedRemoteUsageTransport(responses: [])

        await #expect(throws: QuotaError.notConfigured) {
            _ = try await RemoteUsage.redeemZaiReset(
                credential: "test-key",
                recordID: recordID,
                requestID: "request-1",
                transport: transport
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func zaiResetReadIsBestEffort() async throws {
        let malformed = Data(#"""
            {"code":200,"success":true,"data":{"fiveHourResets":[],"weekResets":[
                {"available":true,"expireTime":"not-a-date"}
            ]}}
        """#.utf8)
        let transports = [
            MockRemoteUsageTransport(body: Self.zaiQuotaBody, resetBody: malformed),
            MockRemoteUsageTransport(body: Self.zaiQuotaBody, resetErrorCode: .networkConnectionLost),
        ]

        for transport in transports {
            let snapshot = try await RemoteUsage.fetch(
                provider: .zai,
                credential: "test-key",
                transport: transport,
                observedAt: observedAt
            )
            #expect(snapshot.windows.map(\.id) == ["zai-5h"])
            #expect(snapshot.resetCredits == nil)
        }
    }

    @Test func zaiIgnoresUnknownFutureWindowTypes() async throws {
        let snapshot = try await fetch(
            .zai,
            body: #"""
                {
                "code": 200,
                "success": true,
                "data": { "limits": [
                    { "type": "FUTURE_LIMIT", "unit": 99, "number": 1 },
                    { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25 }
                ] }
                }
            """#
        )

        #expect(snapshot.windows.map(\.id) == ["zai-5h"])
    }

    @Test func kimiMapsAllWindowsAndParsesRFC3339Resets() async throws {
        let snapshot = try await fetch(
            .kimi,
            body: #"""
                {
                "usages": {
                    "limit_5h": {
                        "used_ratio": 0.25,
                        "reset_time": "2027-01-15T08:00:00.123Z"
                    },
                    "limit_7d": {
                        "used_ratio": "0.5",
                        "reset_time": "2027-01-15T08:00:00Z"
                    },
                    "limit_month_total": {
                        "used_ratio": 0.75,
                        "reset_time": "2027-01-15T16:00:00+08:00"
                    },
                    "limit_month_code": { "used_ratio": 1 }
                },
                "boosterWallet": null
                }
            """#
        )

        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows == [
            QuotaWindow(
                id: "kimi-5h",
                title: "5-hour",
                remainingPercent: 75,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000.123)
            ),
            QuotaWindow(
                id: "kimi-weekly",
                title: "Weekly",
                remainingPercent: 50,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            QuotaWindow(
                id: "kimi-monthly-total",
                title: "Monthly",
                remainingPercent: 25,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ])
    }

    @Test func kimiAllowsPlanDependentMissingAndNullWindows() async throws {
        let snapshot = try await fetch(
            .kimi,
            body: #"""
                {
                "usages": {
                    "limit_5h": { "used_ratio": "0.1", "reset_time": null },
                    "limit_7d": null
                }
                }
            """#
        )

        #expect(snapshot.windows.map(\.id) == ["kimi-5h"])
        #expect(abs(snapshot.windows[0].remainingPercent - 90) <= 0.000_001)
        #expect(snapshot.windows[0].resetAt == nil)
    }

    @Test func kimiTreatsEmptyResetAsUnreported() async throws {
        let snapshot = try await fetch(
            .kimi,
            body: #"""
                {
                "usages": { "limit_5h": { "used_ratio": 0, "reset_time": "" } }
                }
            """#
        )

        #expect(snapshot.windows[0].resetAt == nil)
        #expect(snapshot.windows[0].remainingPercent == 100)
    }

    @Test func requestsUseFixedEndpointsBearerAuthAndNoCookies() async throws {
        let cases: [(ProviderID, String, String)] = [
            (
                .zai,
                "https://api.z.ai/api/monitor/usage/quota/limit",
                #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":0}]}}"#
            ),
            (
                .kimi,
                "https://api.kimi.com/coding/v1/usages",
                #"{"usages":{"limit_5h":{"used_ratio":0}}}"#
            ),
        ]

        for (provider, expectedURL, body) in cases {
            let transport = MockRemoteUsageTransport(body: Data(body.utf8))
            _ = try await RemoteUsage.fetch(
                provider: provider,
                credential: "  test-key  ",
                transport: transport,
                observedAt: observedAt
            )
            let requests = await transport.requests
            let request = try #require(requests.first { $0.url?.absoluteString == expectedURL })
            #expect(requests.count == (provider == .zai ? 2 : 1))
            #expect(request.url?.absoluteString == expectedURL)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(!request.httpShouldHandleCookies)
            if provider == .zai {
                let resetRequest = try #require(requests.first {
                    $0.url?.path == "/api/biz/customer-package-reset/list"
                })
                #expect(resetRequest.url?.absoluteString ==
                    "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")
                #expect(resetRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
                #expect(resetRequest.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(resetRequest.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                #expect(!resetRequest.httpShouldHandleCookies)
            }
        }
    }

    @Test func sessionConfigurationIsEphemeralAndBounded() {
        let configuration = RemoteUsage.makeConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test func scopedReadRejectsNonHTTPSBeforeNetworking() async throws {
        let transport = MockRemoteUsageTransport()
        let endpoint = try #require(URL(string: "http://api.z.ai/api/monitor/usage/quota/limit"))

        await #expect(throws: QuotaError.unavailable) {
            _ = try await RemoteUsage.fetch(
                endpoint: endpoint,
                credential: "test-key",
                transport: transport
            )
        }
        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test func redirectDelegateDoesNotForwardRequest() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try #require(URL(string: "https://api.z.ai/api/monitor/usage/quota/limit"))
        let task = session.dataTask(with: originalURL)
        let response = try #require(HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/steal-credential"]
        ))
        let redirectedURL = try #require(URL(string: "https://example.com/steal-credential"))
        let redirectedRequest = URLRequest(url: redirectedURL)

        await confirmation("Redirect decision") { completed in
            RedirectDenier().urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: redirectedRequest
            ) { request in
                #expect(request == nil)
                completed()
            }
        }
    }

    @Test func httpStatusErrorsAreSafeAndSpecific() async {
        let cases: [(Int, QuotaError)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (429, .rateLimited),
            (404, .unavailable),
            (500, .unavailable),
        ]
        let body = Data(#"{"usages":{"limit_5h":{"used_ratio":0}}}"#.utf8)

        for (status, expected) in cases {
            await assertError(expected, provider: .kimi, body: body, status: status)
        }
    }

    @Test func zaiBusinessErrorsDoNotRequireHTTPFailure() async {
        await assertError(
            .unauthorized,
            provider: .zai,
            body: Data(#"""
                {"code":401,"success":false,"msg":"private upstream detail"}
            """#.utf8)
        )
        await assertError(
            .rateLimited,
            provider: .zai,
            body: Data(#"""
                {"code":429,"success":false}
            """#.utf8)
        )
        await assertError(
            .unavailable,
            provider: .zai,
            body: Data(#"""
                {"code":500,"success":false}
            """#.utf8)
        )
    }

    @Test func transportAndNonHTTPErrorsMapToUnavailable() async {
        await assertError(
            .unavailable,
            provider: .kimi,
            body: Data(),
            transport: MockRemoteUsageTransport(errorCode: .networkConnectionLost)
        )
        await assertError(.unavailable, provider: .kimi, body: Data(), status: nil)
    }

    @Test func missingAndMalformedCredentialsFailBeforeNetworking() async {
        for (provider, credential, expected) in [
            (ProviderID.zai, "", QuotaError.notConfigured),
            (.zai, "  \n  ", .notConfigured),
            (.kimi, "bad\r\nkey", .unauthorized),
        ] {
            let transport = MockRemoteUsageTransport()
            await assertError(
                expected,
                provider: provider,
                body: Data(),
                credential: credential,
                transport: transport
            )
            let requests = await transport.requests
            #expect(requests.isEmpty)
        }
    }

    @Test func unsupportedProvidersAreNotConfiguredWithoutNetworking() async {
        for provider in [ProviderID.claude, .codex, ProviderID(rawValue: "future")] {
            let transport = MockRemoteUsageTransport()
            await assertError(.notConfigured, provider: provider, body: Data(), transport: transport)
            let requests = await transport.requests
            #expect(requests.isEmpty)
        }
    }

    @Test func zaiRejectsInvalidPercentages() async {
        for percentage in [-1, 101] {
            let body = Data("""
            {"code":200,"success":true,"data":{"limits":[
                {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":\(percentage)}
            ]}}
            """.utf8)
            await assertError(.invalidResponse, provider: .zai, body: body)
        }
    }

    @Test func zaiRejectsDuplicateWindows() async {
        await assertError(
            .invalidResponse,
            provider: .zai,
            body: Data(#"""
                {
                "code":200,"success":true,"data":{"limits":[
                    {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10},
                    {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":20}
                ]}
                }
            """#.utf8)
        )
    }

    @Test func zaiRejectsMissingRecognizedPercentageAndEmptyLimits() async {
        await assertError(
            .invalidResponse,
            provider: .zai,
            body: Data(#"""
                {
                "code":200,"success":true,"data":{"limits":[
                    {"type":"TOKENS_LIMIT","unit":3,"number":5}
                ]}
                }
            """#.utf8)
        )
        await assertError(
            .invalidResponse,
            provider: .zai,
            body: Data(#"""
                {"code":200,"success":true,"data":{"limits":[]}}
            """#.utf8)
        )
    }

    @Test func zaiRejectsInvalidResetTimestamp() async {
        await assertError(
            .invalidResponse,
            provider: .zai,
            body: Data(#"""
                {
                "code":200,"success":true,"data":{"limits":[
                    {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":0,"nextResetTime":0}
                ]}
                }
            """#.utf8)
        )
    }

    @Test func kimiRejectsInvalidOrNonfiniteRatios() async {
        for ratio in ["-0.01", "1.01", "\"NaN\"", "\"Infinity\"", "\"not-a-number\""] {
            let body = Data(#"{"usages":{"limit_5h":{"used_ratio":\#(ratio)}}}"#.utf8)
            await assertError(.invalidResponse, provider: .kimi, body: body)
        }
    }

    @Test func kimiRejectsInvalidResetTimestamp() async {
        await assertError(
            .invalidResponse,
            provider: .kimi,
            body: Data(#"""
                {
                "usages":{"limit_5h":{"used_ratio":0.2,"reset_time":"tomorrow"}}
                }
            """#.utf8)
        )
    }

    @Test func kimiRejectsMissingRatioAndAmbiguousEmptySchema() async {
        await assertError(
            .invalidResponse,
            provider: .kimi,
            body: Data(#"""
                {"usages":{"limit_5h":{"reset_time":null}}}
            """#.utf8)
        )
        await assertError(.invalidResponse, provider: .kimi, body: Data(#"{"usages":{}}"#.utf8))
    }

    @Test func malformedJSONIsInvalidResponse() async {
        await assertError(.invalidResponse, provider: .zai, body: Data("not JSON".utf8))
        await assertError(.invalidResponse, provider: .kimi, body: Data("[]".utf8))
    }

    @Test func responseBodyIsBoundedEvenWhenContentLengthIsAbsent() async {
        await assertError(
            .invalidResponse,
            provider: .kimi,
            body: Data(repeating: 0x20, count: 64 * 1024 + 1)
        )
    }

    private func redemptionName(_ redemption: Redemption) -> String {
        switch redemption {
        case .reset: "reset"
        case .alreadyRedeemed: "alreadyRedeemed"
        case .nothingToReset: "nothingToReset"
        case .noCredit: "noCredit"
        case .tryLater: "tryLater"
        }
    }

    private func fetch(
        _ provider: ProviderID,
        body: String,
        credential: String = "test-key"
    ) async throws -> QuotaSnapshot {
        try await fetch(provider, body: Data(body.utf8), credential: credential)
    }

    private func fetch(
        _ provider: ProviderID,
        body: Data,
        credential: String = "test-key"
    ) async throws -> QuotaSnapshot {
        let transport = MockRemoteUsageTransport(body: body)
        return try await RemoteUsage.fetch(
            provider: provider,
            credential: credential,
            transport: transport,
            observedAt: observedAt
        )
    }

    private func assertError(
        _ expected: QuotaError,
        provider: ProviderID,
        body: Data,
        status: Int? = 200,
        credential: String = "test-key",
        transport: MockRemoteUsageTransport? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let transport = transport ?? MockRemoteUsageTransport(body: body, status: status)
        await #expect(throws: expected, sourceLocation: sourceLocation) {
            _ = try await RemoteUsage.fetch(
                provider: provider,
                credential: credential,
                transport: transport,
                observedAt: observedAt
            )
        }
    }
}

private actor MockRemoteUsageTransport: RemoteUsageTransport {
    private let result: Result<RemoteUsageTransportResponse, URLError>
    private let resetResult: Result<RemoteUsageTransportResponse, URLError>?
    private let quotaRespondAfter: Date?
    private(set) var quotaReturnedAt: Date?
    private(set) var requests: [URLRequest] = []

    init(
        body: Data = Data(),
        status: Int? = 200,
        resetBody: Data? = nil,
        resetStatus: Int? = 200,
        resetErrorCode: URLError.Code? = nil,
        quotaRespondAfter: Date? = nil
    ) {
        self.quotaRespondAfter = quotaRespondAfter
        result = .success(RemoteUsageTransportResponse(statusCode: status, body: body))
        if let resetErrorCode {
            resetResult = .failure(URLError(resetErrorCode))
        } else if let resetBody {
            resetResult = .success(RemoteUsageTransportResponse(statusCode: resetStatus, body: resetBody))
        } else {
            resetResult = nil
        }
    }

    init(errorCode: URLError.Code) {
        result = .failure(URLError(errorCode))
        resetResult = nil
        quotaRespondAfter = nil
    }

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        if request.url?.path == "/api/biz/customer-package-reset/list" {
            return try (resetResult ?? result).get()
        }
        if let quotaRespondAfter {
            try await Task.sleep(for: .seconds(max(0, quotaRespondAfter.timeIntervalSinceNow)))
        }
        quotaReturnedAt = Date()
        return try result.get()
    }
}

private actor QueuedRemoteUsageTransport: RemoteUsageTransport {
    typealias Result = Swift.Result<RemoteUsageTransportResponse, Error>
    private var responses: [Result]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result]) {
        self.responses = responses
    }

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw QuotaError.unavailable }
        return try responses.removeFirst().get()
    }
}

