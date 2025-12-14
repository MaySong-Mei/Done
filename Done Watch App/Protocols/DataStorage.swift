//
//  DataStorage.swift
//  Done
//
//  Created by Claude on 12/14/25.
//

import Foundation

/// Protocol for generic data storage using UserDefaults
protocol DataStorage {
    func load<T: Codable>(_ key: String) -> T?
    func save<T: Codable>(_ value: T, key: String)
}

extension DataStorage {
    /// Load a Codable value from UserDefaults
    func load<T: Codable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Save a Codable value to UserDefaults
    func save<T: Codable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
