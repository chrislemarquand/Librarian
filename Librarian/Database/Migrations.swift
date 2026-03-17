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

        migrator.registerMigration("v2_add_screenshot_review_state") { db in
            try db.create(table: "screenshot_review") { t in
                t.column("assetLocalIdentifier", .text).notNull().primaryKey()
                t.column("decision", .text).notNull()
                t.column("decidedAt", .datetime).notNull()
                t.foreignKey(["assetLocalIdentifier"], references: "asset", onDelete: .cascade)
            }
            try db.create(index: "screenshot_review_decision", on: "screenshot_review", columns: ["decision"])
        }

        migrator.registerMigration("v3_add_archive_candidate_queue") { db in
            try db.create(table: "archive_candidate") { t in
                t.column("assetLocalIdentifier", .text).notNull().primaryKey()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("queuedAt", .datetime).notNull()
                t.column("exportedAt", .datetime)
                t.column("deletedAt", .datetime)
                t.column("archivePath", .text)
                t.column("lastError", .text)
                t.foreignKey(["assetLocalIdentifier"], references: "asset", onDelete: .cascade)
            }
            try db.create(index: "archive_candidate_status", on: "archive_candidate", columns: ["status"])
            try db.create(index: "archive_candidate_queuedAt", on: "archive_candidate", columns: ["queuedAt"])
        }

        migrator.registerMigration("v4_add_active_asset_view") { db in
            try db.execute(
                sql: """
                    CREATE VIEW IF NOT EXISTS asset_active AS
                    SELECT a.*
                    FROM asset a
                    WHERE a.isDeletedFromPhotos = 0
                      AND NOT EXISTS (
                        SELECT 1
                        FROM archive_candidate ac
                        WHERE ac.assetLocalIdentifier = a.localIdentifier
                    )
                """
            )
        }

        migrator.registerMigration("v5_refine_active_asset_view_filters") { db in
            try db.execute(sql: "DROP VIEW IF EXISTS asset_active")
            try db.execute(
                sql: """
                    CREATE VIEW asset_active AS
                    SELECT a.*
                    FROM asset a
                    WHERE a.isDeletedFromPhotos = 0
                      AND NOT EXISTS (
                        SELECT 1
                        FROM archive_candidate ac
                        WHERE ac.assetLocalIdentifier = a.localIdentifier
                          AND ac.status IN ('pending', 'exporting', 'failed', 'exported')
                      )
                """
            )
        }
    }
}
