import AppKit
import SharedUI

@MainActor
final class InspectorSettingsViewController: NSViewController {
    private let model: AppModel
    private var embedded: InspectorFieldSettingsViewController?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = InspectorFieldSettingsViewController(
            sectionsProvider: { [weak self] in
                guard let self else { return [] }
                return self.model.inspectorFieldSections.map { grouped in
                    InspectorFieldSettingsSection(
                        title: grouped.section,
                        fields: grouped.fields.map { field in
                            InspectorFieldSettingsField(id: field.id, label: field.label, isEnabled: field.isEnabled)
                        }
                    )
                }
            },
            onToggleSection: { [weak self] section, isEnabled in
                self?.model.setInspectorSectionEnabled(section: section, isEnabled: isEnabled)
            },
            onToggleField: { [weak self] fieldID, isEnabled in
                self?.model.setInspectorFieldEnabled(fieldID: fieldID, isEnabled: isEnabled)
            }
        )
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        embedded = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inspectorFieldsChanged),
            name: .librarianInspectorFieldsChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func inspectorFieldsChanged() {
        embedded?.reload()
    }
}
