import GRDB

enum LibrarianMigrations {

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "asset") { t in
                t.column("localIdentifier", .text).primaryKey()
                t.column("creationDate", .datetime)
                t.column("modificationDate", .datetime)
                t.column("mediaType", .integer).notNull().defaults(to: 1)
                t.column("mediaSubtypes", .integer).notNull().defaults(to: 0)
                t.column("pixelWidth", .integer).notNull().defaults(to: 0)
                t.column("pixelHeight", .integer).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
                t.column("isScreenshot", .boolean).notNull().defaults(to: false)
                t.column("isCloudOnly", .boolean).notNull().defaults(to: false)
                t.column("hasLocalThumbnail", .boolean).notNull().defaults(to: false)
                t.column("hasLocalOriginal", .boolean).notNull().defaults(to: false)
                t.column("iCloudDownloadState", .text).notNull().defaults(to: "notRequired")
                t.column("analysisVersion", .integer).notNull().defaults(to: 0)
                t.column("lastSeenInLibraryAt", .datetime)
                t.column("isDeletedFromPhotos", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "asset_creationDate", on: "asset", columns: ["creationDate"])
            try db.create(index: "asset_isScreenshot", on: "asset", columns: ["isScreenshot"])
            try db.create(index: "asset_mediaType", on: "asset", columns: ["mediaType"])

            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("type", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
                t.column("payloadJSON", .text)
                t.column("errorText", .text)
            }

            try db.create(index: "job_type_state", on: "job", columns: ["type", "state"])
        }
    }
}
