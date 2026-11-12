//
//  Concurrency.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 13.12.23.
//

import Foundation

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension Sequence {
    
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values = [T]()
        
        for element in self {
            try await values.append(transform(element))
        }
        
        return values
    }
    
    func concurrentMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T) async -> [T] where Element: Sendable {
        
        // 구조화된 자식 작업은 마지막 소비자가 취소할 때 함께 취소된다.
        // 도착 순서와 무관하게 원래 client 우선순위를 보존한다.
        let elements = Array(self)
        return await withTaskGroup(of: (Int, T).self) { group in
            for (index, element) in elements.enumerated() {
                group.addTask { (index, await transform(element)) }
            }
            var values: [Int: T] = [:]
            for await (index, value) in group { values[index] = value }
            return elements.indices.compactMap { values[$0] }
        }
    }
    
}
