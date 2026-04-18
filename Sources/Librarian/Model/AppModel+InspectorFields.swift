import Foundation

enum InspectorFieldAvailability: String, Codable, Hashable {
    case photo
    case archive
    case both
}

struct InspectorFieldCatalogEntry: Hashable, Identifiable {
    let id: String
    let section: String
    let label: String
    let availability: InspectorFieldAvailability
    let isEnabled: Bool

    func withEnabled(_ isEnabled: Bool) -> InspectorFieldCatalogEntry {
        InspectorFieldCatalogEntry(
            id: id,
            section: section,
            label: label,
            availability: availability,
            isEnabled: isEnabled
        )
    }
}

@MainActor
extension AppModel {
    static func defaultInspectorFieldCatalog() -> [InspectorFieldCatalogEntry] {
        [
            .init(id: "datetime-original", section: "Date and Time", label: "Original", availability: .both, isEnabled: true),
            .init(id: "datetime-digitized", section: "Date and Time", label: "Digitised", availability: .both, isEnabled: true),
            .init(id: "datetime-modified", section: "Date and Time", label: "Modified", availability: .both, isEnabled: true),

            .init(id: "camera-make", section: "Camera", label: "Make", availability: .both, isEnabled: true),
            .init(id: "camera-model", section: "Camera", label: "Model", availability: .both, isEnabled: true),
            .init(id: "camera-serial", section: "Camera", label: "Serial Number", availability: .both, isEnabled: true),
            .init(id: "camera-lens-model", section: "Camera", label: "Lens Model", availability: .both, isEnabled: true),

            .init(id: "capture-aperture", section: "Capture", label: "Aperture", availability: .both, isEnabled: true),
            .init(id: "capture-shutter", section: "Capture", label: "Shutter Speed", availability: .both, isEnabled: true),
            .init(id: "capture-iso", section: "Capture", label: "ISO", availability: .both, isEnabled: true),
            .init(id: "capture-focal-length", section: "Capture", label: "Focal Length", availability: .both, isEnabled: true),
            .init(id: "capture-exposure-program", section: "Capture", label: "Exposure Program", availability: .both, isEnabled: true),
            .init(id: "capture-flash", section: "Capture", label: "Flash", availability: .both, isEnabled: true),
            .init(id: "capture-metering-mode", section: "Capture", label: "Metering Mode", availability: .both, isEnabled: true),
            .init(id: "capture-exposure-compensation", section: "Capture", label: "Exposure Compensation", availability: .both, isEnabled: true),

            .init(id: "location-latitude", section: "Location", label: "Latitude", availability: .both, isEnabled: true),
            .init(id: "location-longitude", section: "Location", label: "Longitude", availability: .both, isEnabled: true),
            .init(id: "location-direction", section: "Location", label: "Direction", availability: .both, isEnabled: true),

            .init(id: "descriptive-title", section: "Descriptive", label: "Title", availability: .both, isEnabled: true),
            .init(id: "descriptive-description", section: "Descriptive", label: "Description", availability: .both, isEnabled: true),
            .init(id: "descriptive-keywords", section: "Descriptive", label: "Keywords", availability: .both, isEnabled: true),

            .init(id: "rights-artist", section: "Rights", label: "Artist", availability: .both, isEnabled: true),
            .init(id: "rights-copyright", section: "Rights", label: "Copyright", availability: .both, isEnabled: true),
            .init(id: "rights-creator", section: "Rights", label: "Creator", availability: .both, isEnabled: true),

            .init(id: "library-favorite", section: "Library", label: "Favourite", availability: .photo, isEnabled: true),
            .init(id: "library-hidden", section: "Library", label: "Hidden", availability: .photo, isEnabled: true),
            .init(id: "library-edited", section: "Library", label: "Edited", availability: .photo, isEnabled: true),
            .init(id: "library-burst", section: "Library", label: "Burst Photo", availability: .photo, isEnabled: true),
            .init(id: "library-live-photo", section: "Library", label: "Live Photo", availability: .photo, isEnabled: true),
            .init(id: "library-icloud", section: "Library", label: "iCloud", availability: .photo, isEnabled: true),
            .init(id: "library-albums", section: "Library", label: "Albums", availability: .photo, isEnabled: true),
            .init(id: "library-shared", section: "Library", label: "Shared Library", availability: .photo, isEnabled: true),

            .init(id: "analysis-quality", section: "Analysis", label: "Quality", availability: .photo, isEnabled: true),
            .init(id: "analysis-caption", section: "Analysis", label: "Caption", availability: .photo, isEnabled: true),
            .init(id: "analysis-people-detected", section: "Analysis", label: "People Detected", availability: .photo, isEnabled: true),
            .init(id: "analysis-people-named", section: "Analysis", label: "Named People", availability: .photo, isEnabled: true),
            .init(id: "analysis-extracted-text", section: "Analysis", label: "Extracted Text", availability: .photo, isEnabled: true),

            .init(id: "archive-status", section: "Archive Status", label: "Status", availability: .photo, isEnabled: true),
            .init(id: "archive-queued", section: "Archive Status", label: "Queued", availability: .photo, isEnabled: true),
            .init(id: "archive-exported", section: "Archive Status", label: "Exported", availability: .photo, isEnabled: true),
            .init(id: "archive-deleted", section: "Archive Status", label: "Deleted", availability: .photo, isEnabled: true),
            .init(id: "archive-path", section: "Archive Status", label: "Archive Path", availability: .photo, isEnabled: true),
            .init(id: "archive-last-error", section: "Archive Status", label: "Last Error", availability: .photo, isEnabled: true),
        ]
    }

    static func applyingInspectorVisibilityPreferences(to catalog: [InspectorFieldCatalogEntry]) -> [InspectorFieldCatalogEntry] {
        guard let visibility = UserDefaults.standard.dictionary(forKey: Self.inspectorFieldVisibilityKey) as? [String: Bool] else {
            return catalog
        }
        return catalog.map { entry in
            guard let isEnabled = visibility[entry.id] else { return entry }
            return entry.withEnabled(isEnabled)
        }
    }

    var inspectorFieldSections: [(section: String, fields: [InspectorFieldCatalogEntry])] {
        var ordered: [(section: String, fields: [InspectorFieldCatalogEntry])] = []
        for entry in activeInspectorFieldCatalog {
            if let index = ordered.firstIndex(where: { $0.section == entry.section }) {
                ordered[index].fields.append(entry)
            } else {
                ordered.append((section: entry.section, fields: [entry]))
            }
        }
        return ordered
    }

    func isInspectorFieldEnabled(_ fieldID: String) -> Bool {
        activeInspectorFieldCatalog.first(where: { $0.id == fieldID })?.isEnabled ?? false
    }

    func setInspectorFieldEnabled(fieldID: String, isEnabled: Bool) {
        let updated = activeInspectorFieldCatalog.map { entry in
            guard entry.id == fieldID else { return entry }
            return entry.withEnabled(isEnabled)
        }
        applyInspectorFieldCatalogUpdate(updated)
    }

    func setInspectorSectionEnabled(section: String, isEnabled: Bool) {
        let updated = activeInspectorFieldCatalog.map { entry in
            guard entry.section == section else { return entry }
            return entry.withEnabled(isEnabled)
        }
        applyInspectorFieldCatalogUpdate(updated)
    }

    func applyInspectorFieldCatalogUpdate(_ updated: [InspectorFieldCatalogEntry]) {
        guard updated != activeInspectorFieldCatalog else { return }
        activeInspectorFieldCatalog = updated
        persistInspectorFieldVisibility()
        NotificationCenter.default.post(name: .librarianInspectorFieldsChanged, object: nil)
    }

    func persistInspectorFieldVisibility() {
        let visibility = Dictionary(uniqueKeysWithValues: activeInspectorFieldCatalog.map { ($0.id, $0.isEnabled) })
        UserDefaults.standard.set(visibility, forKey: Self.inspectorFieldVisibilityKey)
    }
}
