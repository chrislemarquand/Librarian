import Testing
import Foundation
@testable import Librarian

@Test func whatsAppFilenameDetectionMatchesLegacyPrefixes() {
    #expect(AssetIndexer.isWhatsAppFilename("WhatsApp Image 2026-03-22 at 20.00.00.jpg"))
    #expect(AssetIndexer.isWhatsAppFilename("WhatsApp Video 2026-03-22 at 20.00.00.mp4"))
    #expect(AssetIndexer.isWhatsAppFilename("IMG_0001_from_whatsapp_export.jpg"))
}

@Test func whatsAppFilenameDetectionMatchesUUIDStyleBasenames() {
    let afterHDRollout = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: afterHDRollout,
            pixelWidth: 3024,
            pixelHeight: 4032
        )
    )
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "3b159952-8a6a-4fcc-a420-712584139f72 (1).jpg",
            creationDate: afterHDRollout,
            pixelWidth: 4032,
            pixelHeight: 3024
        )
    )
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "A656B73D-558C-420E-81BB-890C041BBF66.HEIC",
            creationDate: afterHDRollout,
            pixelWidth: 4096,
            pixelHeight: 2692
        )
    )
}

@Test func whatsAppFilenameDetectionRejectsUUIDAboveEraResolutionCaps() {
    let beforeHDRollout = Date(timeIntervalSince1970: 1_650_000_000) // Apr 2022
    #expect(
        !AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: beforeHDRollout,
            pixelWidth: 3024,
            pixelHeight: 4032
        )
    )
    let afterHDRollout = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
    #expect(
        !AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: afterHDRollout,
            pixelWidth: 6000,
            pixelHeight: 4000
        )
    )
}

@Test func whatsAppFilenameDetectionRejectsNonWhatsAppLikeNames() {
    #expect(!AssetIndexer.isWhatsAppFilename("IMG_1234.JPG"))
    #expect(!AssetIndexer.isWhatsAppFilename("photo-from-camera-roll.jpg"))
    #expect(!AssetIndexer.isWhatsAppFilename("3b159952-8a6a-4fcc-a420-712584139f72.txt"))
}
