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

        migrator.registerMigration("v6_add_analysis_fields") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "overallScore", .double)
                t.add(column: "fileSizeBytes", .integer)
                t.add(column: "hasNamedPerson", .boolean)
                t.add(column: "namedPersonCount", .integer)
                t.add(column: "detectedPersonCount", .integer)
                t.add(column: "labelsJSON", .text)
                t.add(column: "fingerprint", .text)
                t.add(column: "aiCaption", .text)
                t.add(column: "analysedAt", .datetime)
            }
            try db.create(index: "asset_fingerprint", on: "asset", columns: ["fingerprint"])
            try db.create(index: "asset_overallScore", on: "asset", columns: ["overallScore"])
        }

        migrator.registerMigration("v7_add_queue_keep_decisions") { db in
            try db.create(table: "queue_keep_decision") { t in
                t.column("assetLocalIdentifier", .text).notNull()
                t.column("queueKind", .text).notNull()
                t.column("decidedAt", .datetime).notNull()
                t.primaryKey(["assetLocalIdentifier", "queueKind"])
                t.foreignKey(["assetLocalIdentifier"], references: "asset", onDelete: .cascade)
            }
            try db.create(index: "queue_keep_decision_kind", on: "queue_keep_decision", columns: ["queueKind"])

            // Migrate existing screenshot keep decisions from screenshot_review.
            try db.execute(sql: """
                INSERT OR IGNORE INTO queue_keep_decision (assetLocalIdentifier, queueKind, decidedAt)
                SELECT assetLocalIdentifier, 'screenshots', decidedAt
                FROM screenshot_review
                WHERE decision = 'keep'
            """)
        }

        migrator.registerMigration("v8_photos_only_active_view") { db in
            // Librarian focuses on photos only — videos are excluded from all views.
            // mediaType 1 = PHAssetMediaType.image
            try db.execute(sql: "DROP VIEW IF EXISTS asset_active")
            try db.execute(sql: """
                CREATE VIEW asset_active AS
                SELECT a.*
                FROM asset a
                WHERE a.isDeletedFromPhotos = 0
                  AND a.mediaType = 1
                  AND NOT EXISTS (
                    SELECT 1
                    FROM archive_candidate ac
                    WHERE ac.assetLocalIdentifier = a.localIdentifier
                      AND ac.status IN ('pending', 'exporting', 'failed', 'exported')
                  )
            """)
        }

        migrator.registerMigration("v9_add_vision_analysis_fields") { db in
            // Vision-computed fields for the four new queues:
            // saliency (accidental captures), OCR text (documents), barcode detection,
            // and near-duplicate cluster membership.
            try db.alter(table: "asset") { t in
                t.add(column: "visionSaliencyScore",    .double)   // VNGenerateAttentionBasedSaliencyImageRequest
                t.add(column: "visionOcrText",          .text)     // VNRecognizeTextRequest — concatenated detected text
                t.add(column: "visionBarcodeDetected",  .boolean)  // VNDetectBarcodesRequest
                t.add(column: "nearDuplicateClusterID", .text)     // UUID grouping visually similar photos
                t.add(column: "visionAnalysedAt",       .datetime) // when Vision analysis was last run on this asset
            }
            try db.create(index: "asset_visionSaliencyScore",    on: "asset", columns: ["visionSaliencyScore"])
            try db.create(index: "asset_visionBarcodeDetected",  on: "asset", columns: ["visionBarcodeDetected"])
            try db.create(index: "asset_nearDuplicateClusterID", on: "asset", columns: ["nearDuplicateClusterID"])
        }

        migrator.registerMigration("v10_add_archived_item_index") { db in
            try db.create(table: "archived_item") { t in
                t.column("relativePath", .text).primaryKey()
                t.column("absolutePath", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("fileExtension", .text).notNull()
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("fileModificationDate", .datetime).notNull()
                t.column("captureDate", .datetime)
                t.column("sortDate", .datetime).notNull()
                t.column("pixelWidth", .integer).notNull().defaults(to: 0)
                t.column("pixelHeight", .integer).notNull().defaults(to: 0)
                t.column("thumbnailRelativePath", .text).notNull()
                t.column("lastIndexedAt", .datetime).notNull()
            }
            try db.create(index: "archived_item_sortDate", on: "archived_item", columns: ["sortDate"])
            try db.create(index: "archived_item_fileModificationDate", on: "archived_item", columns: ["fileModificationDate"])
        }

        migrator.registerMigration("v11_add_archive_import_run") { db in
            try db.create(table: "archive_import_run") { t in
                t.primaryKey("id", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("archiveRootPath", .text).notNull()
                t.column("sourcePathsJSON", .text).notNull()
                t.column("discovered", .integer).notNull().defaults(to: 0)
                t.column("imported", .integer).notNull().defaults(to: 0)
                t.column("skippedDuplicateInSource", .integer).notNull().defaults(to: 0)
                t.column("skippedExistsInPhotoKit", .integer).notNull().defaults(to: 0)
                t.column("failed", .integer).notNull().defaults(to: 0)
                t.column("failureDetailsJSON", .text)
            }
        }

        migrator.registerMigration("v12_add_cloud_shared_flag") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "isCloudShared", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "asset_isCloudShared", on: "asset", columns: ["isCloudShared"])
        }

        migrator.registerMigration("v13_add_isWhatsApp") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "isWhatsApp", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "asset_isWhatsApp", on: "asset", columns: ["isWhatsApp"])
        }

        migrator.registerMigration("v14_add_asset_content_hash") { db in
            try db.alter(table: "asset") { t in
                // Lazy cache for exact dedupe against PhotoKit originals.
                // Stored as lowercase SHA-256 hex (64 chars) when available.
                t.add(column: "contentHashSHA256", .text)
            }
            try db.create(index: "asset_contentHashSHA256", on: "asset", columns: ["contentHashSHA256"])
            try db.create(index: "asset_fileSizeBytes_creationDate", on: "asset", columns: ["fileSizeBytes", "creationDate"])
        }

        migrator.registerMigration("v16_drop_queue_keep_decision") { db in
            // Keep decisions removed from product — boxes show all matching assets by default.
            try db.execute(sql: "DROP TABLE IF EXISTS queue_keep_decision")
        }

        migrator.registerMigration("v15_add_vision_feature_print") { db in
            // Persisted VNFeaturePrintObservation blob — enables global near-duplicate
            // re-clustering across analysis runs rather than per-batch only.
            // Nullable: NULL until Vision analysis has run on the asset.
            // No index: fetched in bulk, never used in a WHERE clause.
            try db.alter(table: "asset") { t in
                t.add(column: "visionFeaturePrint", .blob)
            }
        }

        migrator.registerMigration("v17_add_archive_exact_dedupe_tables") { db in
            // Canonical fingerprint index for exact (byte-for-byte) archive dedupe.
            try db.create(table: "archive_file_fingerprint") { t in
                t.column("relativePath", .text).notNull().primaryKey()
                t.column("sha256", .text)
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("fileModificationDate", .datetime).notNull()
                t.column("captureDate", .datetime)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastVerifiedAt", .datetime).notNull()
                t.column("isCanonical", .boolean).notNull().defaults(to: false)
                t.column("canonicalRelativePath", .text)
                t.column("ingestSource", .text).notNull().defaults(to: "unknown")
                t.column("state", .text).notNull().defaults(to: "indeterminate")
            }
            try db.create(index: "archive_file_fingerprint_sha256", on: "archive_file_fingerprint", columns: ["sha256"])
            try db.create(index: "archive_file_fingerprint_state", on: "archive_file_fingerprint", columns: ["state"])
            try db.create(index: "archive_file_fingerprint_canonicalRelativePath", on: "archive_file_fingerprint", columns: ["canonicalRelativePath"])
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX archive_file_fingerprint_unique_canonical_sha256
                    ON archive_file_fingerprint(sha256)
                    WHERE isCanonical = 1 AND sha256 IS NOT NULL
                """
            )

            // Audit trail for duplicate suppressions and uncertain cases.
            try db.create(table: "archive_duplicate_event") { t in
                t.primaryKey("id", .text)
                t.column("incomingRelativePath", .text).notNull()
                t.column("canonicalRelativePath", .text)
                t.column("incomingSHA256", .text)
                t.column("reason", .text).notNull()
                t.column("flow", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "archive_duplicate_event_createdAt", on: "archive_duplicate_event", columns: ["createdAt"])
            try db.create(index: "archive_duplicate_event_flow", on: "archive_duplicate_event", columns: ["flow"])
        }

        migrator.registerMigration("v18_add_archive_import_run_archive_skip_count") { db in
            try db.alter(table: "archive_import_run") { t in
                t.add(column: "skippedExistsInArchive", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v19_add_performance_indexes") { db in
            try db.create(index: "asset_isFavorite", on: "asset", columns: ["isFavorite"])
            try db.create(index: "asset_isDeletedFromPhotos_mediaType", on: "asset", columns: ["isDeletedFromPhotos", "mediaType"])
        }
    }
}
