//
//  ScreenView.swift
//  J2MEEmulator
//
//  Native views for the MIDP high-level screens: Form (with every Item type),
//  List and TextBox. Java describes a screen as a JSON document
//  (ScreenWriter.java); changes the user makes go back as input events.
//  Alerts are shown by the game screen as system alerts.
//

import UIKit

private func post(_ type: Int32, _ code: Int32) {
    j2me_input_post_key(type, code)
}

private func postValue(item: Int, _ value: String) {
    j2me_ui_set_text_result(Int32(item), value)
    j2me_input_post_event(Int32(J2ME_UI_ITEM_VALUE), Int32(item), 0)
}

// MARK: - Screen

final class ScreenView: UIView, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {

    private let titleLabel = UILabel()
    private let tickerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let table = UITableView()
    private let textView = UITextView()
    private let commandBar = UIStackView()
    private let content = UIView()

    private var structure = ""
    private var rows: [FormRow] = []

    private var listMode = 3
    private var listOptions: [[String: Any]] = []
    private var textMaxSize = 0
    private var fieldDelegates: [J2METextFieldDelegate] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        tickerLabel.font = .systemFont(ofSize: 14)
        tickerLabel.textColor = .secondaryLabel
        tickerLabel.textAlignment = .center

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(stack)

        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag

        textView.font = .systemFont(ofSize: 17)
        textView.delegate = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no

        commandBar.axis = .horizontal
        commandBar.spacing = 10
        commandBar.distribution = .fillEqually

        for v in [titleLabel, tickerLabel, content, commandBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [scrollView, table, textView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 60),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -60),
            tickerLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            tickerLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            tickerLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: tickerLabel.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -8),
            commandBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            commandBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            // Follows the on-screen keyboard, so fields are never covered
            commandBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -8),
            commandBar.heightAnchor.constraint(equalToConstant: 46),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show or update a screen description.
    func show(_ doc: [String: Any]) {
        let kind = doc["kind"] as? String ?? "form"
        titleLabel.text = doc["title"] as? String
        let ticker = doc["ticker"] as? String
        tickerLabel.text = ticker
        tickerLabel.isHidden = ticker == nil

        scrollView.isHidden = kind != "form"
        table.isHidden = kind != "list"
        textView.isHidden = kind != "textbox"

        switch kind {
        case "form": showForm(doc)
        case "list": showList(doc)
        default: showTextBox(doc)
        }

        setCommands(doc["commands"] as? [[String: Any]] ?? [])
    }

    // MARK: Commands

    private var commandSignature = ""

    private func setCommands(_ commands: [[String: Any]]) {
        let signature = commands.map { ($0["label"] as? String ?? "") + "|\($0["id"] ?? 0)" }.joined(separator: ";")
        guard signature != commandSignature else { return }
        commandSignature = signature
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for command in commands.sorted(by: { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }).prefix(5) {
            var config = UIButton.Configuration.filled()
            config.title = command["label"] as? String
            config.titleLineBreakMode = .byTruncatingTail
            let id = Int32(command["id"] as? Int ?? 0)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.endEditing(true)
                post(Int32(J2ME_UI_COMMAND_ACTION), id)
            })
            commandBar.addArrangedSubview(button)
        }
        commandBar.isHidden = commands.isEmpty
    }

    // MARK: Form

    private func showForm(_ doc: [String: Any]) {
        let items = doc["items"] as? [[String: Any]] ?? []
        let signature = items.map { FormRow.structure(of: $0) }.joined(separator: ";")
        if signature != structure || rows.count != items.count {
            structure = signature
            rebuildForm(items)
        } else {
            for (row, item) in zip(rows, items) { row.update(item) }
        }
    }

    private func rebuildForm(_ items: [[String: Any]]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in FormRow(index: index, item: item) }
        rows.forEach { stack.addArrangedSubview($0) }
    }

    // MARK: List

    private func showList(_ doc: [String: Any]) {
        listMode = doc["mode"] as? Int ?? 3
        listOptions = doc["options"] as? [[String: Any]] ?? []
        table.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { listOptions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        var config = cell.defaultContentConfiguration()
        let option = listOptions[indexPath.row]
        config.text = option["text"] as? String
        config.image = decodeImage(option["image"] as? String)
        cell.contentConfiguration = config
        cell.accessoryType = listMode != 3 && (option["selected"] as? Bool ?? false) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = indexPath.row
        post(Int32(J2ME_UI_LIST_SELECT), Int32(row))
        if listMode == 3 { return }                 // IMPLICIT: the game reacts
        var changed = listOptions
        if listMode == 1 {                          // EXCLUSIVE
            for i in changed.indices { changed[i]["selected"] = i == row }
        } else {                                    // MULTIPLE
            changed[row]["selected"] = !(changed[row]["selected"] as? Bool ?? false)
        }
        listOptions = changed
        tableView.reloadData()
    }

    // MARK: TextBox

    private func showTextBox(_ doc: [String: Any]) {
        let text = doc["text"] as? String ?? ""
        textMaxSize = doc["maxSize"] as? Int ?? 0
        let constraints = doc["constraints"] as? Int ?? 0
        if textView.text != text { textView.text = text }
        textView.isSecureTextEntry = (constraints & J2MEConstraints.password) != 0
        textView.keyboardType = UIKeyboardType.j2me(constraints)
        textView.isEditable = (constraints & J2MEConstraints.uneditable) == 0
        if textView.isEditable && !textView.isFirstResponder {
            DispatchQueue.main.async { [weak self] in self?.textView.becomeFirstResponder() }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        postValue(item: 0, textView.text)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textMaxSize > 0 else { return true }
        let current = textView.text as NSString
        return current.replacingCharacters(in: range, with: text).utf16.count <= textMaxSize
    }

    /// Called when another screen replaces this one.
    func reset() {
        endEditing(true)
        structure = ""
        rows = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandSignature = ""
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

func decodeImage(_ base64: String?) -> UIImage? {
    guard let base64, let data = Data(base64Encoded: base64) else { return nil }
    return UIImage(data: data)
}

// MARK: - One Form item

final class FormRow: UIStackView, UITextFieldDelegate {
    private let index: Int
    private let kind: String
    private let labelView = UILabel()

    private var textField: UITextField?
    private var stringLabel: UILabel?
    private var imageView: UIImageView?
    private var slider: UISlider?
    private var progress: UIProgressView?
    private var spinner: UIActivityIndicatorView?
    private var datePicker: UIDatePicker?
    private var fieldDelegate: J2METextFieldDelegate?

    // Choice
    private var options: [[String: Any]] = []
    private var choiceMode = 1
    private var optionButtons: [UIButton] = []
    private var popupButton: UIButton?

    static func structure(of item: [String: Any]) -> String {
        let kind = item["kind"] as? String ?? ""
        let commands = (item["commands"] as? [[String: Any]])?.count ?? 0
        var s = "\(kind):\(commands)"
        if kind == "choice" { s += ":\((item["options"] as? [Any])?.count ?? 0):\(item["mode"] ?? 0)" }
        if kind == "gauge" { s += ":\(item["interactive"] ?? false)" }
        return s
    }

    init(index: Int, item: [String: Any]) {
        self.index = index
        kind = item["kind"] as? String ?? ""
        super.init(frame: .zero)
        axis = .vertical
        spacing = 6
        labelView.font = .boldSystemFont(ofSize: 15)
        labelView.textColor = .secondaryLabel
        labelView.numberOfLines = 0
        addArrangedSubview(labelView)
        build(item)
        addCommands(item)
        update(item)
    }

    required init(coder: NSCoder) { fatalError() }

    private func build(_ item: [String: Any]) {
        switch kind {
        case "string":
            let appearance = item["appearance"] as? Int ?? 0
            if appearance == 2 || appearance == 1, let commands = item["commands"] as? [[String: Any]], !commands.isEmpty {
                return      // shown by its command buttons
            }
            let label = UILabel()
            label.font = .systemFont(ofSize: 16)
            label.numberOfLines = 0
            stringLabel = label
            addArrangedSubview(label)
        case "image", "custom":
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.layer.magnificationFilter = .nearest
            iv.setContentHuggingPriority(.required, for: .vertical)
            imageView = iv
            addArrangedSubview(iv)
        case "text":
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.font = .systemFont(ofSize: 17)
            let constraints = item["constraints"] as? Int ?? 0
            field.applyJ2MEConstraints(constraints)
            field.isEnabled = (constraints & J2MEConstraints.uneditable) == 0
            let delegate = J2METextFieldDelegate(maxLength: item["maxSize"] as? Int ?? 0)
            delegate.onReturn = { [weak field] in field?.resignFirstResponder() }
            fieldDelegate = delegate
            field.delegate = delegate
            field.addAction(UIAction { [weak self, weak field] _ in
                guard let self, let field else { return }
                postValue(item: self.index, field.text ?? "")
            }, for: .editingChanged)
            textField = field
            addArrangedSubview(field)
        case "choice":
            buildChoice(item)
        case "gauge":
            let max = item["max"] as? Int ?? -1
            if item["interactive"] as? Bool ?? false, max > 0 {
                let s = UISlider()
                s.minimumValue = 0
                s.maximumValue = Float(max)
                s.addAction(UIAction { [weak self, weak s] _ in
                    guard let self, let s else { return }
                    let v = Int(s.value.rounded())
                    s.value = Float(v)
                    postValue(item: self.index, String(v))
                }, for: .valueChanged)
                slider = s
                addArrangedSubview(s)
            } else if max < 0 {
                let sp = UIActivityIndicatorView(style: .medium)
                sp.startAnimating()
                sp.hidesWhenStopped = false
                spinner = sp
                addArrangedSubview(sp)
            } else {
                let p = UIProgressView(progressViewStyle: .default)
                progress = p
                addArrangedSubview(p)
            }
        case "date":
            let picker = UIDatePicker()
            let mode = item["mode"] as? Int ?? 3
            picker.datePickerMode = mode == 1 ? .date : (mode == 2 ? .time : .dateAndTime)
            picker.preferredDatePickerStyle = .compact
            picker.contentHorizontalAlignment = .leading
            picker.addAction(UIAction { [weak self, weak picker] _ in
                guard let self, let picker else { return }
                postValue(item: self.index, String(Int64(picker.date.timeIntervalSince1970 * 1000)))
            }, for: .valueChanged)
            datePicker = picker
            addArrangedSubview(picker)
        case "spacer":
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalToConstant: CGFloat(item["height"] as? Int ?? 0)).isActive = true
            addArrangedSubview(v)
        default:
            break
        }
    }

    private func buildChoice(_ item: [String: Any]) {
        choiceMode = item["mode"] as? Int ?? 1
        options = item["options"] as? [[String: Any]] ?? []
        if choiceMode == 4 {        // POPUP
            var config = UIButton.Configuration.bordered()
            config.indicator = .popup
            let button = UIButton(configuration: config)
            button.showsMenuAsPrimaryAction = true
            popupButton = button
            addArrangedSubview(button)
            return
        }
        for (i, _) in options.enumerated() {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            config.imagePadding = 10
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.toggleOption(i)
            })
            button.contentHorizontalAlignment = .leading
            optionButtons.append(button)
            addArrangedSubview(button)
        }
    }

    private func toggleOption(_ i: Int) {
        if choiceMode == 2 {
            options[i]["selected"] = !(options[i]["selected"] as? Bool ?? false)
        } else {
            for k in options.indices { options[k]["selected"] = k == i }
        }
        refreshChoice()
        let flags = options.map { ($0["selected"] as? Bool ?? false) ? "1" : "0" }.joined()
        postValue(item: index, flags)
    }

    private func refreshChoice() {
        if let popupButton {
            let selected = options.firstIndex { $0["selected"] as? Bool ?? false } ?? 0
            popupButton.configuration?.title = options.isEmpty ? nil : options[selected]["text"] as? String
            popupButton.menu = UIMenu(children: options.enumerated().map { i, option in
                UIAction(title: option["text"] as? String ?? "", state: i == selected ? .on : .off) { [weak self] _ in
                    self?.toggleOption(i)
                }
            })
            return
        }
        for (i, button) in optionButtons.enumerated() where i < options.count {
            let selected = options[i]["selected"] as? Bool ?? false
            let symbol = choiceMode == 2 ? (selected ? "checkmark.square.fill" : "square")
                                         : (selected ? "largecircle.fill.circle" : "circle")
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.title = options[i]["text"] as? String
        }
    }

    private func addCommands(_ item: [String: Any]) {
        guard let commands = item["commands"] as? [[String: Any]], !commands.isEmpty else { return }
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        for command in commands {
            var config = UIButton.Configuration.tinted()
            if (item["appearance"] as? Int ?? 0) != 0 && kind == "string" {
                config.title = item["text"] as? String ?? command["label"] as? String
            } else {
                config.title = command["label"] as? String
            }
            let id = Int32(command["id"] as? Int ?? 0)
            let itemIndex = Int32(index)
            row.addArrangedSubview(UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.endEditing(true)
                j2me_input_post_event(Int32(J2ME_UI_ITEM_COMMAND), itemIndex, id)
            }))
        }
        addArrangedSubview(row)
    }

    func update(_ item: [String: Any]) {
        let label = item["label"] as? String
        labelView.text = label
        labelView.isHidden = label == nil || label?.isEmpty == true

        switch kind {
        case "string":
            stringLabel?.text = item["text"] as? String
        case "image", "custom":
            imageView?.image = decodeImage(item["image"] as? String)
            if imageView?.image == nil, let alt = item["alt"] as? String { labelView.text = alt; labelView.isHidden = false }
        case "text":
            let text = item["text"] as? String ?? ""
            if let field = textField, !field.isEditing, field.text != text { field.text = text }
        case "choice":
            options = item["options"] as? [[String: Any]] ?? []
            refreshChoice()
        case "gauge":
            let value = item["value"] as? Int ?? 0, max = item["max"] as? Int ?? 0
            if let s = slider, !s.isTracking { s.value = Float(value) }
            if max > 0 { progress?.progress = Float(value) / Float(max) }
        case "date":
            if let ms = item["value"] as? Int64 { datePicker?.date = Date(timeIntervalSince1970: Double(ms) / 1000) }
            else if let ms = item["value"] as? Int { datePicker?.date = Date(timeIntervalSince1970: Double(ms) / 1000) }
        default:
            break
        }
    }
}
