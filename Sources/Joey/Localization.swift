import Foundation
import LeafiyUICore

/// App strings resolved against this target's zh-Hans table.
private let appBundle = LeafiyLocalization.moduleBundle(package: "joey", target: "Joey")

@inline(__always)
func L(_ key: String) -> String { LeafiyLocalization.string(key, bundle: appBundle) }
