import Foundation
@testable import TinybarCore
import Testing

@Test func datedOpenAISnapshotsUseBasePriceUnlessListedExactly() {
    let table = PriceTable(prices: [.codex: [
        "gpt-4.1": ModelPrice(input: 2, output: 8),
        "gpt-4.1-2025-04-15": ModelPrice(input: 3, output: 9),
    ]], fetchedAt: nil)
    #expect(table.price(provider: .codex, model: "openai/gpt-4.1-2025-04-14")?.input == 2)
    #expect(table.price(provider: .codex, model: "gpt-4.1-2025-04-15")?.input == 3)
    #expect(table.price(provider: .codex, model: "gpt-4.1-20250414")?.input == 2)
    #expect(table.price(provider: .codex, model: "gpt-4.1-5") == nil)
}

@Test func rejectsInvalidBaseAndTierPrices() throws {
    let costs = [
        #"{"input":-2,"output":10}"#,
        #"{"input":true,"output":10}"#,
        #"{"input":"2","output":10}"#,
        #"{"input":2,"output":-10}"#,
        #"{"input":2,"output":10,"cache_read":-1}"#,
        #"{"input":2,"output":10,"cache_write":false}"#,
        #"{"input":2,"output":10,"tiers":[{"input":-4,"output":20,"tier":{"type":"context","size":200000}}]}"#,
        #"{"input":2,"output":10,"context_over_200k":{"input":4,"output":false}}"#,
        #"{"input":2,"output":10,"tiers":[{"input":4,"tier":{"type":"context","size":200000}}]}"#,
        #"{"input":2,"output":10,"tiers":[{"output":20,"tier":{"type":"context","size":200000}}]}"#,
        #"{"input":2,"output":10,"context_over_200k":{"input":4}}"#,
        #"{"input":2,"output":10,"tiers":{}}"#,
        #"{"input":2,"output":10,"tiers":[{}]}"#,
    ]
    for cost in costs {
        let data = Data("{\"openai\":{\"models\":{\"m\":{\"cost\":\(cost)}}}}".utf8)
        #expect(throws: (any Error).self) { try PriceTable.parse(data, fetchedAt: nil) }
        let mixed = Data("{\"openai\":{\"models\":{\"bad\":{\"cost\":\(cost)},\"good\":{\"cost\":{\"input\":2,\"output\":10}}}}}".utf8)
        let table = try PriceTable.parse(mixed, fetchedAt: nil)
        #expect(table.price(provider: .codex, model: "bad") == nil)
        #expect(table.price(provider: .codex, model: "good")?.input == 2)
    }
    let free = try PriceTable.parse(Data(#"{"openai":{"models":{"m":{"cost":{"input":0,"output":0,"cache_read":0,"cache_write":0}}}}}"#.utf8), fetchedAt: nil)
    #expect(free.price(provider: .codex, model: "m")?.input == 0)
}

@Test func contextTierSizesMustBePositiveIntegers() throws {
    for size in ["true", "false", "-1", "0", "272000.5", "9223372036854775808", "1e100"] {
        let data = Data("{\"openai\":{\"models\":{\"m\":{\"cost\":{\"input\":2,\"output\":10,\"tiers\":[{\"input\":4,\"output\":20,\"tier\":{\"type\":\"context\",\"size\":\(size)}}]}}}}}".utf8)
        #expect(throws: (any Error).self) { try PriceTable.parse(data, fetchedAt: nil) }
    }
    for size in ["272000", "272000.0", "9223372036854775807"] {
        let data = Data("{\"openai\":{\"models\":{\"m\":{\"cost\":{\"input\":2,\"output\":10,\"tiers\":[{\"input\":4,\"output\":20,\"tier\":{\"type\":\"context\",\"size\":\(size)}}]}}}}}".utf8)
        #expect(try PriceTable.parse(data, fetchedAt: nil).price(provider: .codex, model: "m")?.tiers?.count == 1)
    }
}
