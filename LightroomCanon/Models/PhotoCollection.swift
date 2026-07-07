import Foundation
import SwiftData

/// A user-named grouping of photos — Lightroom's "Collections" concept.
/// Many-to-many with `Photo` (a photo can belong to any number of
/// collections); deleting a collection only ungroups its photos rather than
/// deleting them. Named `PhotoCollection` rather than `Collection` to avoid
/// colliding with Swift's own `Collection` protocol.
@Model
final class PhotoCollection {
    var id: UUID = UUID()
    var name: String = ""
    var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Photo.collections)
    var photos: [Photo] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
    }
}
