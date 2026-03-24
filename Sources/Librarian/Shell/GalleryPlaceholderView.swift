import Combine
import SharedUI
import SwiftUI

// MARK: - Content

enum GalleryPlaceholderContent: Equatable {
    case unavailable(title: String, symbolName: String, description: String)
    case loading(title: String, symbolName: String)
    case action(title: String, symbolName: String, description: String, actionTitle: String)
}

// MARK: - ViewModel

@MainActor
final class GalleryPlaceholderViewModel: ObservableObject {
    @Published var content: GalleryPlaceholderContent?
    var actionHandler: (() -> Void)?
}

// MARK: - View

struct GalleryPlaceholderView: View {
    @ObservedObject var viewModel: GalleryPlaceholderViewModel

    var body: some View {
        if let content = viewModel.content {
            switch content {
            case let .unavailable(title, symbolName, description):
                PlaceholderView(symbolName: symbolName, title: title, description: description)
            case let .loading(title, symbolName):
                PlaceholderView(
                    symbolName: symbolName,
                    title: title,
                    isLoading: true
                )
            case let .action(title, symbolName, description, actionTitle):
                PlaceholderView(
                    symbolName: symbolName,
                    title: title,
                    description: description,
                    actionTitle: actionTitle,
                    action: viewModel.actionHandler
                )
            }
        }
    }
}
