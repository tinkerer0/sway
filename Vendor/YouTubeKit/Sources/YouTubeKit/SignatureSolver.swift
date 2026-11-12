//
//  SignatureSolver.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.10.2025.
//

import Foundation
#if canImport(JavaScriptCore)
import CommonCrypto
import JavaScriptCore
import os.log

class SignatureSolver {

    private static let log = OSLog(SignatureSolver.self)

    // The preprocessed program depends only on the exact player JavaScript, not on
    // a video, its signatures, or its stream URLs. Keep immutable programs in memory;
    // each solve still has its own VM/context and uses the current request inputs.
    private static let preprocessedPlayers: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    // Sway: 전처리 결과를 캐시 폴더에도 남긴다. 메모리 캐시는 앱을 다시 켜면 비어서 첫 곡마다 player JS 전체를 다시 분석했다.
    // 실기기(iPhone 13 mini)에서 이 분석은 화면이 켜져 있으면 약 2.5초, 화면을 끈 뒤에는 약 21초 걸려
    // 곡을 누르고 바로 잠그면 iOS가 주는 실행 시간(약 30초)에 가까웠다. 원본 JS의 SHA-256을 파일 이름으로 쓴다.
    static var diskDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("YouTubeKit/preprocessed-players", isDirectory: true)
    private static let diskLimit = 4

    enum Source: String { case full, memory, disk }
    /// 마지막 해석이 전처리 결과를 어디서 얻었는지. 로그와 시험에서 본다.
    private(set) static var lastSource: Source?
    /// 전체 분석 횟수. 다시 켠 앱이 전체 분석을 건너뛰는지 시험에서 본다.
    private(set) static var fullSolves = 0

    private let vm = JSVirtualMachine()
    private let ctx: JSContext
    
    private let playerJS: String
    private var setupSeconds: TimeInterval = 0
    
    init(js: String) throws {
        self.playerJS = js
        let started = Date()
        
        guard let context = JSContext(virtualMachine: vm) else {
            throw SignatureSolverError.contextCreationFailed
        }
        ctx = context
        ctx.exceptionHandler = { _, exc in
            os_log("JSC error: %{public}@", log: Self.log, type: .error, exc?.toString() ?? "<unknown>")
        }
        
        // Minimal DOM/env shims (matches `setupNodes`)
        ctx.evaluateScript(#"""
            globalThis.XMLHttpRequest = { prototype: {} };
            globalThis.URL = class URL {
                constructor(url) {
                    this.href = url;
                    const match = url.match(/^(https?:)\/\/([^/:]+)(:(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
                    this.protocol = match ? match[1] : '';
                    this.hostname = match ? match[2] : '';
                    this.port = match && match[4] ? match[4] : '';
                    this.pathname = match && match[5] ? match[5] : '/';
                    this.search = match && match[6] ? match[6] : '';
                    this.hash = match && match[7] ? match[7] : '';
                }
            };
            globalThis.navigator = {
                userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
            };
            const window = Object.assign(Object.create(null), globalThis);
            window.location = new URL("https://www.youtube.com/watch?v=youtubekit-wins");
            const document = {};
            let self = globalThis;
        """#)
        
        // Load meriyah + astring UMD bundles from package resources
        func evalResource(_ name: String, _ ext: String) throws {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
                throw SignatureSolverError.resourceNotFound(name: name, extension: ext)
            }
            let src = try String(contentsOf: url, encoding: .utf8)
            ctx.evaluateScript(src)
        }
        try evalResource("meriyah", "umd.js")
        try evalResource("astring", "umd.js")
        
        // Load generated yt-ejs helper
        try evalResource("yt_ejs_helper", "js")
        setupSeconds = Date().timeIntervalSince(started)
    }
    
    private struct Request: Codable {
        let type: RequestType
        let challenges: [String]
        
        enum RequestType: String, Codable {
            case n, sig
        }
    }
    
    private struct Input: Codable {
        let type: PlayerType
        let player: String? // raw player JS if type == .player
        let preprocessed_player: String? // otherwise
        let requests: [Request]
        let output_preprocessed: Bool?
        
        enum PlayerType: String, Codable {
            case player
            case preprocessedPlayer = "preprocessed_player"
        }
    }
    
    private struct Response: Codable {
        struct Item: Codable {
            let type: ItemType
            let data: [String: String]?
            let error: String?
            
            enum ItemType: String, Codable {
                case result
                case error
            }
        }
        let type: String
        let responses: [Item]
        let preprocessed_player: String?
    }
    
    private func solve(with input: Input) throws -> Response {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let json = try String(data: encoder.encode(input), encoding: .utf8)!
        
        // Call the global `jsc` function defined by yt-ejs
        ctx.setObject(json, forKeyedSubscript: "swiftInput" as NSString)
        let js = "JSON.stringify(jsc(JSON.parse(swiftInput)))"
        guard let result = ctx.evaluateScript(js) else {
            throw SignatureSolverError.evaluationFailed
        }
        
        guard let out = result.toString() else {
            throw SignatureSolverError.resultConversionFailed
        }
        
        guard let data = out.data(using: .utf8) else {
            throw SignatureSolverError.encodingFailed
        }
        
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            os_log("JSC output was: %{public}@", log: Self.log, type: .error, out)
            throw SignatureSolverError.jsonDecodingFailed(error)
        }
    }
    
    // MARK: - Public
    
    struct SolveRequest {
        var nInputs: [String]
        var sigInputs: [String]
    }
    
    struct SolveResponse {
        let nMap: [String: String]
        let sigMap: [String: String]
    }
    
    func batchSolve(request: SolveRequest) throws -> SolveResponse {

        let requests = [
            Request(type: .n, challenges: request.nInputs),
            Request(type: .sig, challenges: request.sigInputs)
        ]

        let cacheKey = self.playerJS as NSString
        let diskKey = Self.diskKey(self.playerJS)
        let started = Date()

        func perform(cached: String?) throws -> SolveResponse {
            let input = Input(
                type: cached == nil ? .player : .preprocessedPlayer,
                player: cached == nil ? self.playerJS : nil,
                preprocessed_player: cached,
                requests: requests,
                output_preprocessed: cached == nil
            )
            let response = try solve(with: input)
            var nMap: [String: String] = [:]
            var sigMap: [String: String] = [:]

            // Responses come back in the same order as requests.
            for (request, item) in zip(requests, response.responses) {
                switch item.type {
                case .error:
                    if let error = item.error {
                        throw SignatureSolverError.solverError(requestType: request.type.rawValue, message: error)
                    }
                case .result:
                    if let data = item.data {
                        switch request.type {
                        case .n: nMap.merge(data) { _, new in new }
                        case .sig: sigMap.merge(data) { _, new in new }
                        }
                    }
                }
            }
            if let processed = response.preprocessed_player, !processed.isEmpty {
                Self.preprocessedPlayers.setObject(processed as NSString, forKey: cacheKey,
                    cost: self.playerJS.utf8.count + processed.utf8.count)
                Self.writeDisk(diskKey, processed)
            }
            return SolveResponse(nMap: nMap, sigMap: sigMap)
        }
        func finish(_ source: Source, _ response: SolveResponse) -> SolveResponse {
            Self.lastSource = source
            if source == .full { Self.fullSolves += 1 }
            os_log("Sway solve source=%{public}@ setup=%.0fms solve=%.0fms", log: Self.log, type: .default,
                   source.rawValue, setupSeconds * 1000, Date().timeIntervalSince(started) * 1000)
            return response
        }

        let memory = Self.preprocessedPlayers.object(forKey: cacheKey) as String?
        if let cached = memory ?? Self.readDisk(diskKey) {
            do {
                let response = try perform(cached: cached)
                if memory == nil {
                    Self.preprocessedPlayers.setObject(cached as NSString, forKey: cacheKey,
                        cost: self.playerJS.utf8.count + cached.utf8.count)
                }
                return finish(memory == nil ? .disk : .memory, response)
            } catch {
                // A failed cache hit retries the original full preprocessing path once.
                Self.preprocessedPlayers.removeObject(forKey: cacheKey)
                Self.removeDisk(diskKey)
            }
        }
        return finish(.full, try perform(cached: nil))
    }

    // MARK: - Sway disk cache

    static func diskKey(_ js: String) -> String {
        let data = Data(js.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private static func diskURL(_ key: String) -> URL? { diskDirectory?.appendingPathComponent("\(key).js") }
    private static func readDisk(_ key: String) -> String? {
        guard let url = diskURL(key), let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        // 최근에 쓴 버전이 정리 대상에서 밀리지 않게 한다.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return text
    }
    static func writeDisk(_ key: String, _ text: String) {
        guard let directory = diskDirectory, let url = diskURL(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        // YouTube는 여러 player 버전을 번갈아 주므로(2026-10-27 하루 4개) 최근 네 개를 남긴다.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(diskLimit) { try? FileManager.default.removeItem(at: old) }
    }
    private static func removeDisk(_ key: String) {
        if let url = diskURL(key) { try? FileManager.default.removeItem(at: url) }
    }
    static func removeMemoryCache() { preprocessedPlayers.removeAllObjects() }
}
#endif
