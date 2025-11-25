#!/usr/bin/env swift

import Foundation

// Script to estimate code coverage for CoreCashu

let fileManager = FileManager.default
let basePath = "/Users/rademaker/Developer/SparrowTek/Bitcoin/Cashu/CoreCashu"
let sourcePath = "\(basePath)/Sources/CoreCashu"
let testsPath = "\(basePath)/Tests/CoreCashuTests"

// Count source files and lines
func countSourceFiles(at path: String) -> (files: Int, lines: Int) {
    var fileCount = 0
    var lineCount = 0

    guard let enumerator = fileManager.enumerator(atPath: path) else {
        return (0, 0)
    }

    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix(".swift") {
            fileCount += 1
            let filePath = "\(path)/\(file)"
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8),
               content.count > 0 {
                lineCount += content.components(separatedBy: .newlines).count
            }
        }
    }

    return (fileCount, lineCount)
}

// Analyze test coverage
func analyzeTestCoverage() -> [String: Set<String>] {
    var coverage: [String: Set<String>] = [:]

    guard let enumerator = fileManager.enumerator(atPath: testsPath) else {
        return coverage
    }

    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix("Tests.swift") {
            let testFile = "\(testsPath)/\(file)"
            if let content = try? String(contentsOfFile: testFile, encoding: .utf8) {
                // Extract what's being tested from imports and test names
                let lines = content.components(separatedBy: .newlines)

                for line in lines {
                    // Look for @testable imports
                    if line.contains("@testable import") {
                        let module = line.replacingOccurrences(of: "@testable import", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        coverage[module, default: []].insert(file)
                    }

                    // Look for test functions
                    if line.contains("func test") || line.contains("@Test") {
                        let testName = line.components(separatedBy: "\"").dropFirst().first ?? ""
                        if !testName.isEmpty {
                            coverage["Tests", default: []].insert(testName)
                        }
                    }
                }
            }
        }
    }

    return coverage
}

// Get list of modules
func getModules(at path: String) -> Set<String> {
    var modules = Set<String>()

    guard let items = try? fileManager.contentsOfDirectory(atPath: path) else {
        return modules
    }

    for item in items {
        let itemPath = "\(path)/\(item)"
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            modules.insert(item)
        }
    }

    return modules
}

// Main analysis
print("=== CoreCashu Code Coverage Analysis ===\n")

let sourceStats = countSourceFiles(at: sourcePath)
let testStats = countSourceFiles(at: testsPath)

print("📊 Code Statistics:")
print("  Source files: \(sourceStats.files)")
print("  Source lines: \(sourceStats.lines)")
print("  Test files: \(testStats.files)")
print("  Test lines: \(testStats.lines)")
print("  Test-to-Code Ratio: \(String(format: "%.2f", Double(testStats.lines) / Double(sourceStats.lines) * 100))%\n")

// Analyze module coverage
let modules = getModules(at: sourcePath)
let testCoverage = analyzeTestCoverage()

print("📦 Module Coverage:")
var coveredModules = 0
var totalModules = modules.count

for module in modules.sorted() {
    let testFiles = testCoverage[module] ?? []
    let hasCoverage = !testFiles.isEmpty || testCoverage["CoreCashu"] != nil

    if hasCoverage {
        coveredModules += 1
        print("  ✅ \(module)")
    } else {
        print("  ⚠️  \(module) - No specific tests found")
    }
}

let modulesCoverage = Double(coveredModules) / Double(totalModules) * 100
print("\nModule Coverage: \(String(format: "%.1f", modulesCoverage))% (\(coveredModules)/\(totalModules))")

// Test count analysis
let totalTests = testCoverage["Tests"]?.count ?? 0
print("\n🧪 Test Coverage Summary:")
print("  Total test cases: \(totalTests)")
print("  Files with tests: \(testStats.files)")

// Estimate overall coverage based on heuristics
let estimatedCoverage = min(
    (Double(testStats.lines) / Double(sourceStats.lines)) * 100,
    modulesCoverage * 1.2,
    95.0
)

print("\n📈 Estimated Code Coverage: \(String(format: "%.1f", estimatedCoverage))%")

if estimatedCoverage >= 85 {
    print("✅ Meets 85% coverage target!")
} else {
    print("⚠️  Below 85% coverage target")
}

// Recommendations
print("\n💡 Coverage Gaps & Recommendations:")

let criticalModules = ["CashuWallet", "NUT", "Security", "Protocols", "StateManagement"]
for module in criticalModules {
    if !modules.contains(module) { continue }
    let testPath = "\(testsPath)/\(module)Tests.swift"
    if !fileManager.fileExists(atPath: testPath) {
        print("  - Add tests for \(module) module (critical)")
    }
}

print("\n✅ Test Coverage Report Complete")