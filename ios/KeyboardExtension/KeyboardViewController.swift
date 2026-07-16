import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
  private enum State {
    case idle
    case processing
    case message(String, isError: Bool)
  }

  private let settingsStore: KeyboardSettingsStore
  private let transformer: KeyboardTransforming
  private let operationCoordinator = KeyboardOperationCoordinator()
  private var operation: Task<Void, Never>?
  private var actionButtons: [UIButton] = []
  private var characterButtons: [UIButton] = []
  private var documentGeneration: UInt64 = 0
  private var shiftEnabled = false
  private var keyboardPlane = KeyboardPlane.letters
  private var heightConstraint: NSLayoutConstraint?
  private var typingPlane: UIStackView?
  private var actionsStack: UIStackView?
  private var rootStack: UIStackView?
  private var footerStack: UIStackView?
  private var actionHeightConstraints: [NSLayoutConstraint] = []
  private var typingRowHeightConstraints: [NSLayoutConstraint] = []
  private var typingRows: [UIStackView] = []
  private var footerHeightConstraint: NSLayoutConstraint?
  private var rootLeadingConstraint: NSLayoutConstraint?
  private var rootTrailingConstraint: NSLayoutConstraint?
  private var rootTopConstraint: NSLayoutConstraint?
  private var rootBottomConstraint: NSLayoutConstraint?
  private var currentLayoutMetrics: KeyboardLayoutMetrics?
  private var heightBudget = KeyboardHeightBudget()
  private var activeLayoutKey: String?
  private weak var shiftButton: UIButton?
  private let backgroundEffectView = UIVisualEffectView()

  private lazy var statusLabel: UILabel = {
    let label = UILabel()
    label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
      for: .systemFont(ofSize: 13),
      maximumPointSize: 18
    )
    label.textAlignment = .center
    label.numberOfLines = 2
    label.adjustsFontForContentSizeCategory = true
    return label
  }()

  private lazy var nextKeyboardButton: UIButton = {
    var configuration = UIButton.Configuration.tinted()
    configuration.image = UIImage(systemName: "globe")
    configuration.cornerStyle = .medium
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = localized("next_keyboard")
    button.addTarget(
      self,
      action: #selector(handleInputModeList(from:with:)),
      for: .allTouchEvents
    )
    return button
  }()

  init(
    settingsStore: KeyboardSettingsStore = .shared,
    transformer: KeyboardTransforming = KeyboardTransformationService()
  ) {
    self.settingsStore = settingsStore
    self.transformer = transformer
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    settingsStore = .shared
    transformer = KeyboardTransformationService()
    super.init(coder: coder)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureView()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateBackgroundMaterial),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contentSizeCategoryDidChange),
      name: UIContentSizeCategory.didChangeNotification,
      object: nil
    )
    render(.idle)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshTypingPlaneIfNeeded()
    applySettingsAppearance()
    applyLayoutPolicy()
  }

  override func viewWillDisappear(_ animated: Bool) {
    cancelCurrentOperation()
    super.viewWillDisappear(animated)
  }

  override func didReceiveMemoryWarning() {
    cancelCurrentOperation()
    render(.message(localized("cancelled"), isError: true))
    super.didReceiveMemoryWarning()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    nextKeyboardButton.isHidden = !needsInputModeSwitchKey
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyLayoutPolicy()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyLayoutPolicy()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    let contentSizeChanged = previousTraitCollection?.preferredContentSizeCategory
      != traitCollection.preferredContentSizeCategory
    guard previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass
      || previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass
      || contentSizeChanged else { return }
    if contentSizeChanged {
      activeLayoutKey = nil
      refreshTypingPlaneIfNeeded()
      if shiftEnabled { setShiftEnabled(true) }
    }
    applyLayoutPolicy()
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    guard !UIAccessibility.isReduceMotionEnabled else {
      applyLayoutPolicy(availableSize: size)
      return
    }
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.applyLayoutPolicy(availableSize: size)
      self?.view.layoutIfNeeded()
    })
  }

  private func configureView() {
    backgroundEffectView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backgroundEffectView)
    NSLayoutConstraint.activate([
      backgroundEffectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backgroundEffectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backgroundEffectView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundEffectView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    updateBackgroundMaterial()
    heightConstraint = view.heightAnchor.constraint(equalToConstant: 0)
    heightConstraint?.priority = .defaultHigh
    heightConstraint?.isActive = true

    let actions = UIStackView(arrangedSubviews: KeyboardAction.allCases.map(makeActionButton))
    actions.axis = .horizontal
    actions.spacing = 8
    actions.distribution = .fillEqually
    actionsStack = actions

    let typingPlane = makeTypingPlane()
    self.typingPlane = typingPlane

    let footer = UIStackView(arrangedSubviews: [nextKeyboardButton, statusLabel])
    footer.axis = .horizontal
    footer.spacing = 10
    footer.alignment = .center
    footerStack = footer
    footerHeightConstraint = footer.heightAnchor.constraint(equalToConstant: 44)
    footerHeightConstraint?.isActive = true

    let root = UIStackView(arrangedSubviews: [actions, typingPlane, footer])
    root.axis = .vertical
    root.spacing = 12
    root.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(root)
    rootStack = root

    rootLeadingConstraint = root.leadingAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.leadingAnchor,
      constant: 10
    )
    rootTrailingConstraint = root.trailingAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.trailingAnchor,
      constant: -10
    )
    rootTopConstraint = root.topAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.topAnchor,
      constant: 10
    )
    rootBottomConstraint = root.bottomAnchor.constraint(
      lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
      constant: -8
    )

    let rootConstraints = [
      rootLeadingConstraint,
      rootTrailingConstraint,
      rootTopConstraint,
      rootBottomConstraint,
    ].compactMap { $0 }
    NSLayoutConstraint.activate(rootConstraints + [
      nextKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
      nextKeyboardButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    applyLayoutPolicy()
  }

  @objc private func contentSizeCategoryDidChange() {
    activeLayoutKey = nil
    refreshTypingPlaneIfNeeded()
    if shiftEnabled { setShiftEnabled(true) }
    applyLayoutPolicy()
  }

  private func applyLayoutPolicy(availableSize: CGSize? = nil) {
    guard let rootStack, let actionsStack, let footerStack else { return }
    let size = availableSize ?? view.bounds.size
    let environmentTemplate = KeyboardLayoutEnvironment(
      availableWidth: Double(size.width),
      availableHeight: 0,
      horizontalSizeClass: layoutSizeClass(traitCollection.horizontalSizeClass),
      verticalSizeClass: layoutSizeClass(traitCollection.verticalSizeClass),
      textSize: traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        ? .accessibility
        : .standard,
      typingRowCount: max(1, typingRows.count),
      safeAreaTop: Double(view.safeAreaInsets.top),
      safeAreaBottom: Double(view.safeAreaInsets.bottom)
    )
    let availableHeight = heightBudget.availableHeight(
      observedHeight: Double(size.height),
      requestedHeight: currentLayoutMetrics?.preferredHeight,
      environment: environmentTemplate,
      isExplicitHostSize: availableSize != nil
    )
    let metrics = KeyboardLayoutPolicy.metrics(
      for: KeyboardLayoutEnvironment(
        availableWidth: environmentTemplate.availableWidth,
        availableHeight: availableHeight,
        horizontalSizeClass: environmentTemplate.horizontalSizeClass,
        verticalSizeClass: environmentTemplate.verticalSizeClass,
        textSize: environmentTemplate.textSize,
        typingRowCount: environmentTemplate.typingRowCount,
        safeAreaTop: environmentTemplate.safeAreaTop,
        safeAreaBottom: environmentTemplate.safeAreaBottom
      )
    )
    guard metrics != currentLayoutMetrics else { return }
    currentLayoutMetrics = metrics

    heightConstraint?.constant = CGFloat(metrics.preferredHeight)
    rootLeadingConstraint?.constant = CGFloat(metrics.horizontalInset)
    rootTrailingConstraint?.constant = -CGFloat(metrics.horizontalInset)
    rootTopConstraint?.constant = CGFloat(metrics.topInset)
    rootBottomConstraint?.constant = -CGFloat(metrics.bottomInset)
    rootStack.spacing = CGFloat(metrics.rootSpacing)
    actionsStack.spacing = CGFloat(metrics.actionSpacing)
    footerStack.spacing = CGFloat(metrics.actionSpacing)
    footerHeightConstraint?.constant = CGFloat(metrics.footerHeight)
    statusLabel.numberOfLines = metrics.statusLineCount

    for constraint in actionHeightConstraints {
      constraint.constant = CGFloat(metrics.actionHeight)
    }
    for constraint in typingRowHeightConstraints {
      constraint.constant = CGFloat(metrics.keyHeight)
    }
    typingPlane?.spacing = CGFloat(metrics.keyRowSpacing)
    for row in typingRows {
      row.spacing = CGFloat(metrics.keySpacing)
    }
    refreshActionConfigurations(compact: metrics.usesCompactActionContent)
  }

  private func layoutSizeClass(_ sizeClass: UIUserInterfaceSizeClass) -> KeyboardLayoutSizeClass {
    switch sizeClass {
    case .compact:
      return .compact
    case .regular:
      return .regular
    default:
      return .unspecified
    }
  }

  @objc private func updateBackgroundMaterial() {
    if UIAccessibility.isReduceTransparencyEnabled {
      backgroundEffectView.effect = nil
      view.backgroundColor = .secondarySystemBackground
    } else {
      view.backgroundColor = .clear
      backgroundEffectView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  override func textWillChange(_ textInput: UITextInput?) {
    invalidateDocumentGeneration()
    super.textWillChange(textInput)
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    refreshTypingPlaneIfNeeded(announceLayoutChange: true)
  }

  override func selectionWillChange(_ textInput: UITextInput?) {
    invalidateDocumentGeneration()
    super.selectionWillChange(textInput)
  }

  private func invalidateDocumentGeneration() {
    documentGeneration &+= 1
    cancelCurrentOperation()
  }

  private func makeActionButton(_ action: KeyboardAction) -> UIButton {
    let configuration = actionConfiguration(for: action, emphasized: true, compact: false)
    let button = UIButton(configuration: configuration)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 2
    button.tag = KeyboardAction.allCases.firstIndex(of: action) ?? 0
    button.accessibilityHint = localized("action_hint")
    button.addTarget(self, action: #selector(actionPressed(_:)), for: .touchUpInside)
    let height = button.heightAnchor.constraint(equalToConstant: 64)
    height.isActive = true
    actionHeightConstraints.append(height)
    actionButtons.append(button)
    return button
  }

  private func makeTypingPlane() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    KeyboardLayout.forceTypingOrderLeftToRight(stack)
    stack.spacing = 5
    populateTypingPlane(stack)
    return stack
  }

  private func refreshTypingPlaneIfNeeded(announceLayoutChange: Bool = false) {
    guard let typingPlane else { return }
    let layoutKey = KeyboardLayout.presentationKey(
      language: layoutLanguage(),
      plane: effectiveKeyboardPlane(),
      contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue
    )
    guard KeyboardLayout.requiresPresentationRebuild(
      activeKey: activeLayoutKey,
      nextKey: layoutKey
    ) else { return }
    for view in typingPlane.arrangedSubviews {
      typingPlane.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    NSLayoutConstraint.deactivate(typingRowHeightConstraints)
    typingRowHeightConstraints.removeAll(keepingCapacity: true)
    typingRows.removeAll(keepingCapacity: true)
    characterButtons.removeAll(keepingCapacity: true)
    populateTypingPlane(typingPlane)
    currentLayoutMetrics = nil
    applyLayoutPolicy()
    if announceLayoutChange, UIAccessibility.isVoiceOverRunning {
      UIAccessibility.post(
        notification: .layoutChanged,
        argument: characterButtons.first
      )
    }
  }

  private func populateTypingPlane(_ stack: UIStackView) {
    let language = layoutLanguage()
    let effectivePlane = effectiveKeyboardPlane()
    activeLayoutKey = KeyboardLayout.presentationKey(
      language: language,
      plane: effectivePlane,
      contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue
    )
    for characters in KeyboardLayout.rows(language: language, plane: effectivePlane) {
      let row = UIStackView(arrangedSubviews: characters.map(makeCharacterButton))
      row.axis = .horizontal
      KeyboardLayout.forceTypingOrderLeftToRight(row)
      row.spacing = 4
      row.distribution = .fillEqually
      addTypingRow(row, to: stack)
    }

    if effectivePlane == .asciiNumberPad {
      shiftButton = nil
      let delete = makeSystemKey(
        symbol: "delete.left",
        accessibilityLabel: localized("delete"),
        action: #selector(deleteBackward)
      )
      let enter = makeSystemKey(
        symbol: "return",
        accessibilityLabel: localized("return"),
        action: #selector(insertReturn)
      )
      let controls = UIStackView(arrangedSubviews: [delete, enter])
      controls.axis = .horizontal
      controls.spacing = 5
      controls.distribution = .fillEqually
      addTypingRow(controls, to: stack)
      return
    }

    let leadingKey: UIButton
    let alternatePlaneKey: UIButton
    switch effectivePlane {
    case .letters:
      leadingKey = makeSystemKey(
        symbol: "shift",
        accessibilityLabel: localized("shift"),
        action: #selector(toggleShift)
      )
      shiftButton = leadingKey
      alternatePlaneKey = makeSystemKey(
        title: "123",
        accessibilityLabel: localized("numbers"),
        action: #selector(showNumbers)
      )
    case .numbers:
      shiftButton = nil
      leadingKey = makeSystemKey(
        title: "ABC",
        accessibilityLabel: localized("letters"),
        action: #selector(showLetters)
      )
      alternatePlaneKey = makeSystemKey(
        title: "#+=",
        accessibilityLabel: localized("symbols"),
        action: #selector(showSymbols)
      )
    case .symbols:
      shiftButton = nil
      leadingKey = makeSystemKey(
        title: "ABC",
        accessibilityLabel: localized("letters"),
        action: #selector(showLetters)
      )
      alternatePlaneKey = makeSystemKey(
        title: "123",
        accessibilityLabel: localized("numbers"),
        action: #selector(showNumbers)
      )
    case .asciiNumberPad:
      return
    }
    let space = makeSystemKey(
      title: localized("space"),
      accessibilityLabel: localized("space"),
      action: #selector(insertSpace)
    )
    let delete = makeSystemKey(
      symbol: "delete.left",
      accessibilityLabel: localized("delete"),
      action: #selector(deleteBackward)
    )
    let enter = makeSystemKey(
      symbol: "return",
      accessibilityLabel: localized("return"),
      action: #selector(insertReturn)
    )
    let controls = UIStackView(
      arrangedSubviews: [leadingKey, alternatePlaneKey, space, delete, enter]
    )
    controls.axis = .horizontal
    controls.spacing = 5
    controls.distribution = .fillProportionally
    space.widthAnchor.constraint(
      greaterThanOrEqualTo: leadingKey.widthAnchor,
      multiplier: 2
    ).isActive = true
    addTypingRow(controls, to: stack)
    if effectivePlane == .letters { setShiftEnabled(shiftEnabled) }
  }

  private func addTypingRow(_ row: UIStackView, to stack: UIStackView) {
    KeyboardLayout.forceTypingOrderLeftToRight(row)
    let height = row.heightAnchor.constraint(equalToConstant: 44)
    height.isActive = true
    typingRows.append(row)
    typingRowHeightConstraints.append(height)
    stack.addArrangedSubview(row)
  }

  private func effectiveKeyboardPlane() -> KeyboardPlane {
    KeyboardLayout.resolvedPlane(
      requested: keyboardPlane,
      requiresAsciiNumberPad: textDocumentProxy.keyboardType == .asciiCapableNumberPad
    )
  }

  private func layoutLanguage() -> String {
    let configured = settingsStore.load().locale
    let requiresAscii: Bool
    switch textDocumentProxy.keyboardType {
    case .asciiCapable, .asciiCapableNumberPad:
      requiresAscii = true
    default:
      requiresAscii = false
    }
    return KeyboardLayout.resolvedLanguage(
      configured: configured,
      systemLanguage: Locale.current.languageCode,
      requiresAscii: requiresAscii
    )
  }

  private func makeCharacterButton(_ character: String) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.title = character
    configuration.cornerStyle = .medium
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 6,
      leading: 2,
      bottom: 6,
      trailing: 2
    )
    configuration.titleTextAttributesTransformer = scaledTitleTransformer(
      textStyle: .body,
      baseSize: 18,
      weight: .regular,
      maximumPointSize: 24
    )
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = character
    button.addTarget(self, action: #selector(insertCharacter(_:)), for: .touchUpInside)
    characterButtons.append(button)
    return button
  }

  private func makeSystemKey(
    title: String? = nil,
    symbol: String? = nil,
    accessibilityLabel: String,
    action: Selector
  ) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.title = title
    configuration.image = symbol.flatMap(UIImage.init(systemName:))
    configuration.cornerStyle = .medium
    configuration.titleTextAttributesTransformer = scaledTitleTransformer(
      textStyle: .callout,
      baseSize: 15,
      weight: .medium,
      maximumPointSize: 21
    )
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = accessibilityLabel
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func insertCharacter(_ sender: UIButton) {
    guard let character = sender.configuration?.title else { return }
    textDocumentProxy.insertText(shiftEnabled ? character.uppercased() : character)
    if shiftEnabled { setShiftEnabled(false) }
  }

  @objc private func toggleShift() {
    setShiftEnabled(!shiftEnabled)
  }

  @objc private func showLetters() {
    setKeyboardPlane(.letters)
  }

  @objc private func showNumbers() {
    setKeyboardPlane(.numbers)
  }

  @objc private func showSymbols() {
    setKeyboardPlane(.symbols)
  }

  private func setKeyboardPlane(_ plane: KeyboardPlane) {
    guard keyboardPlane != plane else { return }
    keyboardPlane = plane
    shiftEnabled = false
    activeLayoutKey = nil
    refreshTypingPlaneIfNeeded(announceLayoutChange: true)
  }

  private func setShiftEnabled(_ enabled: Bool) {
    shiftEnabled = enabled
    for button in characterButtons {
      guard var configuration = button.configuration,
            let title = configuration.title else { continue }
      configuration.title = enabled ? title.uppercased() : title.lowercased()
      button.configuration = configuration
      button.accessibilityLabel = configuration.title
    }
    if enabled {
      shiftButton?.accessibilityTraits.insert(.selected)
    } else {
      shiftButton?.accessibilityTraits.remove(.selected)
    }
  }

  @objc private func insertSpace() {
    textDocumentProxy.insertText(" ")
  }

  @objc private func deleteBackward() {
    textDocumentProxy.deleteBackward()
  }

  @objc private func insertReturn() {
    textDocumentProxy.insertText("\n")
  }

  private func applySettingsAppearance() {
    nextKeyboardButton.accessibilityLabel = localized("next_keyboard")
    refreshActionConfigurations(
      compact: currentLayoutMetrics?.usesCompactActionContent ?? false
    )
    render(.idle)
  }

  private func refreshActionConfigurations(compact: Bool) {
    let defaultAction = settingsStore.load().defaultAction
    for (index, action) in KeyboardAction.allCases.enumerated() {
      guard actionButtons.indices.contains(index) else { continue }
      let emphasized = action == defaultAction
      actionButtons[index].configuration = actionConfiguration(
        for: action,
        emphasized: emphasized,
        compact: compact
      )
      actionButtons[index].accessibilityValue = emphasized
        ? localized("default_action")
        : nil
      actionButtons[index].accessibilityHint = localized("action_hint")
    }
  }

  private func actionConfiguration(
    for action: KeyboardAction,
    emphasized: Bool,
    compact: Bool
  ) -> UIButton.Configuration {
    var configuration = emphasized
      ? UIButton.Configuration.filled()
      : UIButton.Configuration.tinted()
    configuration.title = localized(action.localizationKey)
    configuration.image = UIImage(systemName: action.symbolName)
    configuration.imagePlacement = compact ? .leading : .top
    configuration.imagePadding = compact ? 4 : 5
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: compact ? 5 : 7,
      leading: 6,
      bottom: compact ? 5 : 7,
      trailing: 6
    )
    configuration.cornerStyle = .large
    configuration.titleTextAttributesTransformer = scaledTitleTransformer(
      textStyle: .footnote,
      baseSize: 13,
      weight: .semibold,
      maximumPointSize: compact ? 17 : 20
    )
    return configuration
  }

  private func scaledTitleTransformer(
    textStyle: UIFont.TextStyle,
    baseSize: CGFloat,
    weight: UIFont.Weight,
    maximumPointSize: CGFloat
  ) -> UIConfigurationTextAttributesTransformer {
    UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      let baseFont = UIFont.systemFont(ofSize: baseSize, weight: weight)
      outgoing.font = UIFontMetrics(forTextStyle: textStyle).scaledFont(
        for: baseFont,
        maximumPointSize: maximumPointSize
      )
      return outgoing
    }
  }

  @objc private func actionPressed(_ sender: UIButton) {
    guard KeyboardAction.allCases.indices.contains(sender.tag) else { return }
    start(KeyboardAction.allCases[sender.tag])
  }

  private func start(_ action: KeyboardAction) {
    cancelCurrentOperation()

    guard transformer.isAvailable else {
      render(.message(localized("service_unavailable"), isError: true))
      return
    }

    guard hasFullAccess else {
      render(.message(localized("full_access_required"), isError: true))
      return
    }

    let proxy = textDocumentProxy
    let snapshot: KeyboardSelectionSnapshot
    do {
      snapshot = try KeyboardTransactionGate.capture(
        selectedText: proxy.selectedText,
        documentIdentifier: proxy.documentIdentifier,
        contextBeforeInput: proxy.documentContextBeforeInput,
        contextAfterInput: proxy.documentContextAfterInput,
        documentGeneration: documentGeneration
      )
    } catch KeyboardTransactionError.noSelection {
      render(.message(localized("select_text"), isError: true))
      return
    } catch {
      render(.message(localized("selection_too_large"), isError: true))
      return
    }

    let settings = settingsStore.load()
    let operationToken = operationCoordinator.begin()
    render(.processing)
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        let transformed = try await transformer.transform(
          text: snapshot.selectedText,
          action: action,
          timeout: TimeInterval(settings.requestTimeoutMilliseconds) / 1_000
        )
        try Task.checkCancellation()
        guard operationCoordinator.isCurrent(operationToken) else { return }
        let currentProxy = textDocumentProxy
        guard KeyboardTransactionGate.canCommit(
          snapshot,
          currentSelectedText: currentProxy.selectedText,
          currentDocumentIdentifier: currentProxy.documentIdentifier,
          currentContextBeforeInput: currentProxy.documentContextBeforeInput,
          currentContextAfterInput: currentProxy.documentContextAfterInput,
          currentDocumentGeneration: documentGeneration
        ) else {
          guard operationCoordinator.finish(operationToken) else { return }
          render(.message(localized("selection_changed"), isError: true))
          operation = nil
          return
        }
        guard operationCoordinator.finish(operationToken) else { return }
        operation = nil
        currentProxy.insertText(transformed)
        render(.message(localized("completed"), isError: false))
      } catch is CancellationError {
        guard operationCoordinator.finish(operationToken) else { return }
        operation = nil
        render(.idle)
      } catch KeyboardTransformationError.cancelled {
        guard operationCoordinator.finish(operationToken) else { return }
        operation = nil
        render(.idle)
      } catch KeyboardTransformationError.serviceUnavailable {
        guard operationCoordinator.finish(operationToken) else { return }
        operation = nil
        render(.message(localized("service_unavailable"), isError: true))
      } catch {
        guard operationCoordinator.finish(operationToken) else { return }
        operation = nil
        if Task.isCancelled {
          render(.idle)
        } else {
          render(.message(localized("request_failed"), isError: true))
        }
      }
    }
  }

  private func cancelCurrentOperation() {
    operationCoordinator.cancel()
    operation?.cancel()
    operation = nil
  }

  private func render(_ state: State) {
    switch state {
    case .idle:
      statusLabel.text = localized("select_text")
      statusLabel.textColor = .secondaryLabel
      actionButtons.forEach { $0.isEnabled = true }
    case .processing:
      statusLabel.text = localized("processing")
      statusLabel.textColor = .secondaryLabel
      actionButtons.forEach { $0.isEnabled = false }
    case let .message(message, isError):
      statusLabel.text = message
      statusLabel.textColor = isError ? .systemRed : .systemGreen
      actionButtons.forEach { $0.isEnabled = true }
    }
    switch state {
    case .idle:
      break
    case .processing, .message:
      UIAccessibility.post(
        notification: .announcement,
        argument: statusLabel.text
      )
    }
  }

  private func localized(_ key: String) -> String {
    let locale = settingsStore.load().locale
    let bundle: Bundle
    if locale != "system",
       let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
       let configuredBundle = Bundle(path: path) {
      bundle = configuredBundle
    } else {
      bundle = .main
    }
    return NSLocalizedString(
      key,
      tableName: "Localizable",
      bundle: bundle,
      comment: ""
    )
  }
}

private extension KeyboardAction {
  var localizationKey: String {
    switch self {
    case .emojify: return "emojify"
    case .rewrite: return "rewrite"
    case .fix: return "fix"
    }
  }

  var symbolName: String {
    switch self {
    case .emojify: return "face.smiling"
    case .rewrite: return "wand.and.stars"
    case .fix: return "checkmark.circle"
    }
  }
}
