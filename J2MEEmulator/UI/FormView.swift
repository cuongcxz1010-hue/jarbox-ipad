//
//  FormView.swift
//  J2MEEmulator
//
//  Displays J2ME Forms/Lists/Alerts using native UIKit views.
//  Mirrors J2ME-Loader's approach of using Android native widgets.
//

import UIKit

class FormView: UIView {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    private var commandButtons: [UIButton] = []
    private let commandBar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Scroll + Stack for items
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .fill
        stackView.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        // Command bar at bottom
        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -8),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            commandBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            commandBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            commandBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            commandBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Build the form from native bridge data.
    func buildFromNativeData() {
        // Clear previous content
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandButtons.removeAll()
        fieldDelegates.removeAll()

        // Title
        titleLabel.text = String(cString: j2me_ui_get_form_title())

        // Items
        let count = j2me_ui_get_form_item_count()
        for i in 0..<count {
            let itemType = j2me_ui_get_form_item_type(Int32(i))
            let label = String(cString: j2me_ui_get_form_item_label(Int32(i)))
            let text = String(cString: j2me_ui_get_form_item_text(Int32(i)))

            switch itemType {
            case 0: // StringItem
                addStringItem(label: label, text: text)
            case 1: // TextField
                addTextField(index: Int(i), label: label, text: text,
                             maxSize: Int(j2me_ui_get_form_item_param1(Int32(i))),
                             constraints: Int(j2me_ui_get_form_item_param2(Int32(i))))
            default:
                addStringItem(label: label, text: text) // fallback
            }
        }

        // Commands
        let cmdCount = j2me_ui_get_command_count()
        for i in 0..<cmdCount {
            let cmdLabel = String(cString: j2me_ui_get_command_label(Int32(i)))
            let cmdId = j2me_ui_get_command_id(Int32(i))

            let btn = UIButton(type: .system)
            btn.setTitle(cmdLabel, for: .normal)
            btn.titleLabel?.font = .boldSystemFont(ofSize: 16)
            btn.tag = Int(cmdId)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 8
            btn.addTarget(self, action: #selector(commandTapped(_:)), for: .touchUpInside)
            commandBar.addArrangedSubview(btn)
            commandButtons.append(btn)
        }
    }

    private func addStringItem(label: String, text: String) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 2

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel
            container.addArrangedSubview(labelView)
        }

        if !text.isEmpty {
            let textView = UILabel()
            textView.text = text
            textView.font = .systemFont(ofSize: 16)
            textView.numberOfLines = 0
            container.addArrangedSubview(textView)
        }

        stackView.addArrangedSubview(container)
    }

    private var fieldDelegates: [J2METextFieldDelegate] = []

    private func addTextField(index: Int, label: String, text: String, maxSize: Int, constraints: Int) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel
            container.addArrangedSubview(labelView)
        }

        let tf = UITextField()
        tf.text = text
        tf.tag = index   // native item index == Java Form item index
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 16)
        tf.applyJ2MEConstraints(constraints)
        let delegate = J2METextFieldDelegate(maxLength: maxSize)
        delegate.onReturn = { [weak tf] in tf?.resignFirstResponder() }
        fieldDelegates.append(delegate)   // UITextField.delegate is weak
        tf.delegate = delegate
        tf.addTarget(self, action: #selector(textFieldChanged(_:)), for: .editingChanged)
        container.addArrangedSubview(tf)

        stackView.addArrangedSubview(container)
    }

    @objc private func commandTapped(_ sender: UIButton) {
        endEditing(true)
        let cmdId = Int32(sender.tag)
        j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), cmdId)
    }

    /// Hand the typed text to Java; it is applied to the TextField when a command fires.
    @objc private func textFieldChanged(_ sender: UITextField) {
        j2me_ui_set_text_result(Int32(sender.tag), sender.text ?? "")
    }
}

// ============================================================
// List view
// ============================================================

class J2MEListView: UIView, UITableViewDataSource, UITableViewDelegate {

    private let titleLabel = UILabel()
    private let tableView = UITableView()
    private var items: [String] = []
    private var commandButtons: [UIButton] = []
    private let commandBar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -8),

            commandBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            commandBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            commandBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            commandBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func buildFromNativeData() {
        titleLabel.text = String(cString: j2me_ui_get_form_title())

        items.removeAll()
        let count = j2me_ui_get_list_item_count()
        for i in 0..<count {
            items.append(String(cString: j2me_ui_get_list_item(Int32(i))))
        }
        tableView.reloadData()

        // Commands
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandButtons.removeAll()
        let cmdCount = j2me_ui_get_command_count()
        for i in 0..<cmdCount {
            let cmdLabel = String(cString: j2me_ui_get_command_label(Int32(i)))
            let cmdId = j2me_ui_get_command_id(Int32(i))
            let btn = UIButton(type: .system)
            btn.setTitle(cmdLabel, for: .normal)
            btn.tag = Int(cmdId)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 8
            btn.addTarget(self, action: #selector(commandTapped(_:)), for: .touchUpInside)
            commandBar.addArrangedSubview(btn)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        var content = cell.defaultContentConfiguration()
        content.text = items[indexPath.row]
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        j2me_input_post_key(Int32(J2ME_UI_LIST_SELECT), Int32(indexPath.row))
    }

    @objc private func commandTapped(_ sender: UIButton) {
        j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), Int32(sender.tag))
    }
}
