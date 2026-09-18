//
//  ViewController.swift
//  Examples
//
//  Created by Sondra on 2026/3/23.
//

import UIKit
import SVGAView

class ViewController: UIViewController {

    private enum StageState {
        case hidden
        case loading
        case empty
        case stopped
        case error
    }

    private let titleLabel = UILabel()
    private let currentGiftLabel = UILabel()
    private let summaryLabel = PaddedLabel()
    private let stageView = UIView()
    private let playerView = SVGAView()
    private let stateLabel = UILabel()
    private let downloadProgressStack = UIStackView()
    private let downloadProgressView = UIProgressView(progressViewStyle: .default)
    private let downloadProgressLabel = UILabel()
    private let sourceBadgeLabel = PaddedLabel()
    private let replayButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let loopButton = UIButton(type: .system)
    private let searchField = UISearchTextField()
    private let collectionEmptyLabel = UILabel()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(GiftEffectCell.self, forCellWithReuseIdentifier: GiftEffectCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        return collectionView
    }()

    private let giftEffectsLoader: () throws -> [GiftEffect]

    /// 创建礼物演示页，并指定礼物目录的加载方式。
    ///
    /// - Parameter giftEffectsLoader: 默认读取应用中的礼物目录；测试可提供独立资源地址。
    init(giftEffectsLoader: @escaping () throws -> [GiftEffect] = { try GiftEffectsDataSource.load() }) {
        self.giftEffectsLoader = giftEffectsLoader
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        giftEffectsLoader = { try GiftEffectsDataSource.load() }
        super.init(coder: coder)
    }

    private var effects: [GiftEffect] = []
    private var filteredEffects: [GiftEffect] = []
    private var selectedEffect: GiftEffect?
    private var stageState: StageState = .hidden
    private var isLooping = true
    /// 当前选中礼物是否已成功加载到播放器。
    ///
    /// 播放器停止或替换加载失败后可能保留上一份实体，因此不能仅凭播放状态允许继续。
    private var hasPlayableSelection = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        configurePlaybackCallbacks()
        loadGiftEffects()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 先撤销播放资格，再停止播放器，避免同步状态事件重新启用旧资源的控制按钮。
        hasPlayableSelection = false
        playerView.stop()
        if selectedEffect != nil {
            showState("播放已停止\n点击重播继续", state: .stopped)
        } else {
            hideDownloadProgress()
        }
        updatePauseButton()
    }
}

// MARK: - Setup

private extension ViewController {
    func configureLayout() {
        view.backgroundColor = .systemGroupedBackground

        let rootStack = UIStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.spacing = 12
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            rootStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        let headerStack = makeHeaderStack()
        let controlsStack = makeControlsStack()

        configureStage()
        configureSearchField()
        configureCollectionEmptyLabel()

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(stageView)
        rootStack.addArrangedSubview(controlsStack)
        rootStack.addArrangedSubview(searchField)
        rootStack.addArrangedSubview(collectionView)

        let stageHeight = stageView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.34)
        stageHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stageHeight,
            stageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            stageView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            controlsStack.heightAnchor.constraint(equalToConstant: 44),
            searchField.heightAnchor.constraint(equalToConstant: 44),
            collectionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        setControlsEnabled(false)
    }

    func makeHeaderStack() -> UIStackView {
        titleLabel.text = "礼物特效演示"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true

        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLabel.textColor = .white
        summaryLabel.backgroundColor = .systemPink
        summaryLabel.layer.cornerRadius = 10
        summaryLabel.clipsToBounds = true
        summaryLabel.text = "0 个礼物"
        summaryLabel.setContentHuggingPriority(.required, for: .horizontal)

        currentGiftLabel.text = "读取 gift_effects_svga.json"
        currentGiftLabel.font = .systemFont(ofSize: 15, weight: .medium)
        currentGiftLabel.textColor = .secondaryLabel
        currentGiftLabel.numberOfLines = 2

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), summaryLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 10

        let headerStack = UIStackView(arrangedSubviews: [titleRow, currentGiftLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 4
        return headerStack
    }

    func configureStage() {
        stageView.translatesAutoresizingMaskIntoConstraints = false
        stageView.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        stageView.layer.cornerRadius = 8
        stageView.layer.borderWidth = 1
        stageView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        stageView.clipsToBounds = true

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.contentMode = .scaleAspectFit
        playerView.loops = 0
        playerView.clearsAfterStop = true

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stateLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isHidden = true

        downloadProgressStack.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressStack.axis = .vertical
        downloadProgressStack.spacing = 8
        downloadProgressStack.isHidden = true

        downloadProgressView.progressTintColor = .systemPink
        downloadProgressView.trackTintColor = UIColor.white.withAlphaComponent(0.18)

        downloadProgressLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        downloadProgressLabel.textColor = UIColor.white.withAlphaComponent(0.86)
        downloadProgressLabel.textAlignment = .center
        downloadProgressLabel.text = DownloadProgressFormatter.percentText(for: 0)

        downloadProgressStack.addArrangedSubview(downloadProgressView)
        downloadProgressStack.addArrangedSubview(downloadProgressLabel)

        sourceBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceBadgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        sourceBadgeLabel.textColor = .white
        sourceBadgeLabel.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        sourceBadgeLabel.layer.cornerRadius = 9
        sourceBadgeLabel.clipsToBounds = true
        sourceBadgeLabel.text = "SOURCE"

        stageView.addSubview(playerView)
        stageView.addSubview(stateLabel)
        stageView.addSubview(downloadProgressStack)
        stageView.addSubview(sourceBadgeLabel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 8),
            playerView.leadingAnchor.constraint(equalTo: stageView.leadingAnchor, constant: 8),
            playerView.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -8),
            playerView.bottomAnchor.constraint(equalTo: stageView.bottomAnchor, constant: -8),

            stateLabel.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: stageView.leadingAnchor, constant: 24),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: stageView.trailingAnchor, constant: -24),

            stateLabel.bottomAnchor.constraint(lessThanOrEqualTo: downloadProgressStack.topAnchor, constant: -16),
            downloadProgressStack.leadingAnchor.constraint(equalTo: stageView.leadingAnchor, constant: 42),
            downloadProgressStack.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -42),
            downloadProgressStack.bottomAnchor.constraint(equalTo: stageView.bottomAnchor, constant: -22),

            sourceBadgeLabel.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 12),
            sourceBadgeLabel.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -12)
        ])
    }

    func makeControlsStack() -> UIStackView {
        configureButton(replayButton, title: "重播", symbolName: "arrow.clockwise", backgroundColor: .systemPink)
        configureButton(pauseButton, title: "暂停", symbolName: "pause.fill", backgroundColor: .systemIndigo)
        configureButton(loopButton, title: "循环", symbolName: "repeat", backgroundColor: .systemTeal)

        replayButton.addTarget(self, action: #selector(replaySelectedGift), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        loopButton.addTarget(self, action: #selector(toggleLoop), for: .touchUpInside)

        let controlsStack = UIStackView(arrangedSubviews: [replayButton, pauseButton, loopButton])
        controlsStack.axis = .horizontal
        controlsStack.spacing = 10
        controlsStack.distribution = .fillEqually
        return controlsStack
    }

    func configureButton(_ button: UIButton, title: String, symbolName: String, backgroundColor: UIColor) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = backgroundColor
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.accessibilityLabel = title
    }

    func configureSearchField() {
        searchField.placeholder = "搜索礼物名称或来源"
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .done
        searchField.autocorrectionType = .no
        searchField.backgroundColor = .secondarySystemGroupedBackground
        searchField.layer.cornerRadius = 8
        searchField.clipsToBounds = true
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextDidChange), for: .editingChanged)
    }

    func configureCollectionEmptyLabel() {
        collectionEmptyLabel.text = "没有匹配的礼物"
        collectionEmptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        collectionEmptyLabel.textColor = .secondaryLabel
        collectionEmptyLabel.textAlignment = .center
        collectionEmptyLabel.numberOfLines = 0
    }

    func configurePlaybackCallbacks() {
        playerView.onEvent = { [weak self] event in
            switch event {
            case .frameChanged:
                // 加载期间的迟到帧不能代表新资源已开始播放。
                guard let self, self.stageState == .loading,
                      self.playerView.state == .playing else { return }
                self.hideState()
            case .downloadProgress(let progress):
                self?.showDownloadProgress(progress)
            case .loadFailed:
                self?.showState("加载失败\n点击重播重试", state: .error)
            case .stateChanged(let state):
                guard let self else { return }
                if case .failed = state { self.hasPlayableSelection = false }
                self.updatePauseButton()
            case .ready:
                guard let self else { return }
                self.hasPlayableSelection = true
                self.updatePauseButton()
            default:
                break
            }
        }
    }
}

// MARK: - Data And Playback

private extension ViewController {
    func loadGiftEffects() {
        do {
            effects = try giftEffectsLoader()
            filteredEffects = effects
            collectionView.reloadData()
            updateCollectionBackground()
            updateSummary()
            setControlsEnabled(!effects.isEmpty)

            guard let firstEffect = effects.first else {
                currentGiftLabel.text = "暂无礼物资源"
                sourceBadgeLabel.text = "EMPTY"
                showState("JSON 中没有礼物资源", state: .empty)
                return
            }

            play(firstEffect)
        } catch {
            effects = []
            filteredEffects = []
            currentGiftLabel.text = "资源加载失败"
            sourceBadgeLabel.text = "ERROR"
            collectionView.reloadData()
            updateCollectionBackground()
            updateSummary()
            setControlsEnabled(false)
            showState("无法读取 gift_effects_svga.json\n\(error.localizedDescription)", state: .error)
        }
    }

    func play(_ effect: GiftEffect) {
        selectedEffect = effect
        currentGiftLabel.text = effect.name
        sourceBadgeLabel.text = effect.sourceLabel.uppercased()
        hasPlayableSelection = false
        playerView.loops = isLooping ? 0 : 1
        updatePauseButton()
        updateLoopButton()
        collectionView.reloadData()

        // clear() 只清空图层；先停止旧播放的帧驱动及加载，避免旧帧隐藏新下载状态。
        // clearsAfterStop 为 true，stop() 同时清除旧画面。
        playerView.stop()
        showState("准备下载...", state: .loading)
        showDownloadProgress(0)
        playerView.play(remoteURL: effect.url)
    }

    @objc func replaySelectedGift() {
        guard let selectedEffect else { return }
        play(selectedEffect)
    }

    @objc func togglePause() {
        // 即使收到已排队的按钮事件，也不能暂停尚未加载的资源或恢复上一份礼物。
        guard canControlPlayback else { return }
        switch playerView.state {
        case .playing:
            playerView.pause()
        case .ready, .paused, .stopped:
            playerView.start()
        case .idle, .loading, .failed:
            break
        }
    }

    @objc func toggleLoop() {
        isLooping.toggle()
        playerView.loops = isLooping ? 0 : 1
        updateLoopButton()
    }

    @objc func searchTextDidChange() {
        filteredEffects = GiftEffectsDataSource.filter(effects, query: searchField.text ?? "")
        collectionView.reloadData()
        updateCollectionBackground()
        updateSummary()
    }
}

// MARK: - State

private extension ViewController {
    private func showState(_ text: String, state: StageState) {
        stageState = state
        stateLabel.text = text
        stateLabel.isHidden = false

        switch state {
        case .hidden:
            stateLabel.isHidden = true
            hideDownloadProgress()
        case .loading:
            stateLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        case .empty, .stopped:
            stateLabel.textColor = UIColor.white.withAlphaComponent(0.72)
            hideDownloadProgress()
        case .error:
            stateLabel.textColor = .systemRed
            hideDownloadProgress()
        }
    }

    func hideState() {
        stageState = .hidden
        stateLabel.isHidden = true
        hideDownloadProgress()
    }

    func showDownloadProgress(_ progress: Double) {
        guard stageState == .loading else { return }
        let boundedProgress = min(1, max(0, progress))
        stateLabel.text = boundedProgress >= 1 ? "下载完成，准备播放..." : "下载中..."
        downloadProgressView.setProgress(Float(boundedProgress), animated: boundedProgress > 0)
        downloadProgressLabel.text = DownloadProgressFormatter.percentText(for: boundedProgress)
        downloadProgressStack.isHidden = false
    }

    func hideDownloadProgress() {
        downloadProgressStack.isHidden = true
        downloadProgressView.setProgress(0, animated: false)
    }

    func setControlsEnabled(_ enabled: Bool) {
        replayButton.isEnabled = enabled
        loopButton.isEnabled = enabled
        searchField.isEnabled = enabled
        collectionView.isUserInteractionEnabled = enabled
        [replayButton, loopButton].forEach { $0.alpha = enabled ? 1 : 0.45 }
        updatePauseButton()
    }

    /// 当前选中礼物是否支持暂停或继续播放。
    var canControlPlayback: Bool {
        guard selectedEffect != nil, hasPlayableSelection else { return false }
        switch playerView.state {
        case .ready, .playing, .paused, .stopped:
            return true
        case .idle, .loading, .failed:
            return false
        }
    }

    func updatePauseButton() {
        // 文案跟随实际播放状态，包括自动播放与自然结束，不单独维护暂停标志。
        let enabled = canControlPlayback
        let showsContinue = enabled && playerView.state != .playing
        let title = showsContinue ? "继续" : "暂停"
        let symbolName = showsContinue ? "play.fill" : "pause.fill"
        configureButton(pauseButton, title: title, symbolName: symbolName, backgroundColor: .systemIndigo)
        pauseButton.isEnabled = enabled
        pauseButton.alpha = enabled ? 1 : 0.45
    }

    func updateLoopButton() {
        let title = isLooping ? "循环" : "一次"
        let symbolName = isLooping ? "repeat" : "repeat.1"
        configureButton(loopButton, title: title, symbolName: symbolName, backgroundColor: isLooping ? .systemTeal : .systemGray)
    }

    func updateSummary() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            summaryLabel.text = "\(effects.count) 个礼物"
        } else {
            summaryLabel.text = "\(filteredEffects.count)/\(effects.count)"
        }
    }

    func updateCollectionBackground() {
        if filteredEffects.isEmpty {
            collectionEmptyLabel.text = effects.isEmpty ? "暂无礼物资源" : "没有匹配的礼物"
            collectionView.backgroundView = collectionEmptyLabel
        } else {
            collectionView.backgroundView = nil
        }
    }
}

// MARK: - Collection View

extension ViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredEffects.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GiftEffectCell.reuseIdentifier, for: indexPath)
        guard let giftCell = cell as? GiftEffectCell else { return cell }

        let effect = filteredEffects[indexPath.item]
        giftCell.configure(with: effect, selected: effect == selectedEffect)
        return giftCell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        play(filteredEffects[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let layout = collectionViewLayout as? UICollectionViewFlowLayout
        let insets = layout?.sectionInset ?? .zero
        let spacing = layout?.minimumInteritemSpacing ?? 10
        let columns: CGFloat = collectionView.bounds.width >= 430 ? 4 : 3
        let availableWidth = collectionView.bounds.width - insets.left - insets.right - spacing * (columns - 1)
        let width = floor(availableWidth / columns)
        return CGSize(width: width, height: 78)
    }
}

// MARK: - Text Field

extension ViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Cells

private final class GiftEffectCell: UICollectionViewCell {
    static let reuseIdentifier = "GiftEffectCell"

    private let titleLabel = UILabel()
    private let badgeLabel = PaddedLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.alpha = isHighlighted ? 0.72 : 1
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        badgeLabel.text = nil
        applySelectedStyle(false)
    }

    func configure(with effect: GiftEffect, selected: Bool) {
        titleLabel.text = effect.name
        badgeLabel.text = effect.sourceLabel.uppercased()
        applySelectedStyle(selected)
    }

    private func configureLayout() {
        contentView.layer.cornerRadius = 8
        contentView.layer.borderWidth = 1
        contentView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabel
        badgeLabel.backgroundColor = .tertiarySystemGroupedBackground
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        badgeLabel.setContentHuggingPriority(.required, for: .vertical)

        let stack = UIStackView(arrangedSubviews: [titleLabel, badgeLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10)
        ])

        applySelectedStyle(false)
    }

    private func applySelectedStyle(_ selected: Bool) {
        contentView.backgroundColor = selected ? UIColor.systemPink.withAlphaComponent(0.14) : .secondarySystemGroupedBackground
        contentView.layer.borderColor = selected ? UIColor.systemPink.cgColor : UIColor.separator.cgColor
        titleLabel.textColor = selected ? .systemPink : .label
        badgeLabel.textColor = selected ? .white : .secondaryLabel
        badgeLabel.backgroundColor = selected ? .systemPink : .tertiarySystemGroupedBackground
    }
}

private final class PaddedLabel: UILabel {
    var contentInsets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8) {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + contentInsets.left + contentInsets.right,
                      height: size.height + contentInsets.top + contentInsets.bottom)
    }
}
