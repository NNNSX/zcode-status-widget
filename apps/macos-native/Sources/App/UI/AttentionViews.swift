import AppKit
import Core

// 提醒视图（对照 renderer/styles.css attention 部分与 main.ts renderAttention）。

/// 卡片形态：46px 图标圆 + eyebrow/标题/工作区（styles.css:121-175）。
final class AttentionCardView: NSView, AttentionContentView {
    private(set) var currentContent = AttentionContent.demo

    private let markLayer = CALayer()
    private let iconContainer = NSView()
    private let eyebrowField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let workspaceField = NSTextField(labelWithString: "")
    private let separatorField = NSTextField(labelWithString: "·")
    private let summaryField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 25/255, green: 29/255, blue: 35/255, alpha: 0.98).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = false

        markLayer.cornerRadius = 23
        layer?.addSublayer(markLayer)

        iconContainer.wantsLayer = true
        addSubview(iconContainer)

        eyebrowField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.cell?.wraps = false
        workspaceField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        separatorField.font = .systemFont(ofSize: 12)
        summaryField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for field in [eyebrowField, titleField, workspaceField, separatorField, summaryField] {
            field.cell?.wraps = false
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func update(content: AttentionContent) {
        currentContent = content
        let waiting = content.kind == .waiting
        layer?.borderWidth = 1
        layer?.borderColor = (waiting
            ? NSColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 0.5)
            : NSColor(red: 70/255, green: 184/255, blue: 129/255, alpha: 0.52)).cgColor
        markLayer.backgroundColor = (waiting
            ? NSColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 0.14)
            : NSColor(red: 70/255, green: 184/255, blue: 129/255, alpha: 0.14)).cgColor

        configureIcon(tint: waiting ? Palette.markWaiting : Palette.markDone,
                      symbol: waiting ? "bell.badge" : "checkmark.circle.fill")
        eyebrowField.stringValue = waiting ? "等待用户操作" : "任务已完成"
        eyebrowField.textColor = waiting ? Palette.eyebrowWaiting : Palette.eyebrowDone
        titleField.stringValue = content.title
        titleField.textColor = Palette.title
        workspaceField.stringValue = content.workspace
        let hasSummary = !content.summary.trimmingCharacters(in: .whitespaces).isEmpty
        workspaceField.textColor = waiting ? Palette.detailWaiting : Palette.detailDone
        summaryField.textColor = workspaceField.textColor
        separatorField.textColor = waiting ? Palette.separatorWaiting : Palette.separatorDone
        separatorField.isHidden = !hasSummary
        summaryField.isHidden = !hasSummary
        summaryField.stringValue = content.summary
        needsLayout = true
    }

    private func configureIcon(tint: NSColor, symbol: String) {
        iconContainer.subviews.forEach { $0.removeFromSuperview() }
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        let imageView = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        imageView.symbolConfiguration = configuration
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 0, y: 0, width: 46, height: 46)
        iconContainer.addSubview(imageView)
    }

    private enum Palette {
        static let markWaiting = NSColor(red: 255/255, green: 133/255, blue: 138/255, alpha: 1)   // #ff858a
        static let markDone = NSColor(red: 120/255, green: 210/255, blue: 160/255, alpha: 1)     // #78d2a0
        static let eyebrowWaiting = NSColor(red: 221/255, green: 154/255, blue: 158/255, alpha: 1) // #dd9a9e
        static let eyebrowDone = NSColor(red: 145/255, green: 213/255, blue: 170/255, alpha: 1)  // #91d5aa
        static let title = NSColor(red: 245/255, green: 247/255, blue: 251/255, alpha: 1)       // #f5f7fb
        static let detailWaiting = NSColor(red: 185/255, green: 195/255, blue: 209/255, alpha: 1) // #b9c3d1
        static let detailDone = NSColor(red: 190/255, green: 213/255, blue: 199/255, alpha: 1)  // #bed5c7
        static let separatorWaiting = NSColor(red: 142/255, green: 153/255, blue: 170/255, alpha: 1) // #8e99aa
        static let separatorDone = NSColor(red: 145/255, green: 173/255, blue: 156/255, alpha: 1) // #91ad9c
    }

    override func layout() {
        super.layout()
        let markSize: CGFloat = 46
        let originX: CGFloat = 18
        markLayer.frame = NSRect(x: originX, y: bounds.midY - markSize / 2, width: markSize, height: markSize)
        iconContainer.frame = markLayer.frame

        let textX = originX + markSize + 14
        let textWidth = bounds.width - textX - 18
        eyebrowField.frame = NSRect(x: textX, y: bounds.height - 30, width: textWidth, height: 14)
        titleField.frame = NSRect(x: textX, y: bounds.height - 58, width: textWidth, height: 22)
        let detailY: CGFloat = 18
        workspaceField.sizeToFit()
        summaryField.sizeToFit()
        let separatorWidth: CGFloat = 8
        let summaryWidth = summaryField.isHidden ? 0 : summaryField.frame.width
        let workspaceWidth = summaryField.isHidden
            ? textWidth
            : min(workspaceField.frame.width, textWidth - separatorWidth - summaryWidth - 4)
        workspaceField.frame = NSRect(x: textX, y: detailY, width: workspaceWidth, height: 15)
        separatorField.frame = NSRect(x: workspaceField.frame.maxX + 2, y: detailY, width: separatorWidth, height: 15)
        summaryField.frame = NSRect(x: separatorField.frame.maxX + 2, y: detailY, width: summaryWidth, height: 15)
    }

    /// 入场动画 180ms（attention-enter：opacity 0→1、y +5→0、scale 0.98→1）。
    func playEnterAnimation() {
        guard let layer else { return }
        layer.removeAllAnimations()
        let group = CAAnimationGroup()
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -5
        rise.toValue = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.98
        scale.toValue = 1
        group.animations = [fade, rise, scale]
        layer.add(group, forKey: "attention-enter")
    }
}

/// 边缘扫光形态：四边色条 + 流动光谱条（styles.css:177-259）。
/// waiting 红系 3px/2.6s，done 绿系 2px/3.4s；上下边水平移动、左右边垂直移动，
/// bottom/left 反向。
final class AttentionEdgeView: NSView, AttentionContentView {
    private(set) var currentContent = AttentionContent.demo
    private let top = EdgeStripLayer()
    private let bottom = EdgeStripLayer()
    private let left = EdgeStripLayer()
    private let right = EdgeStripLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for strip in [top, bottom, left, right] {
            layer?.addSublayer(strip)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func update(content: AttentionContent) {
        currentContent = content
        let palette = EdgePalette(kind: content.kind)
        for strip in [top, bottom, left, right] {
            strip.apply(palette: palette)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let thickness = top.edgeThickness
        top.frame = NSRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
        bottom.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
        left.frame = NSRect(x: 0, y: 0, width: thickness, height: bounds.height)
        right.frame = NSRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height)
        top.configure(edge: .top, bounds: bounds)
        bottom.configure(edge: .bottom, bounds: bounds)
        left.configure(edge: .left, bounds: bounds)
        right.configure(edge: .right, bounds: bounds)
    }

    func playEnterAnimation() {
        // edge 无入场动画（对照 styles.css：无 enter keyframes）。
    }
}

/// 单条边：底色条 + 向内光晕 + 流动扫光。
private final class EdgeStripLayer: CALayer {
    enum Edge {
        case top, bottom, left, right
    }

    var edgeThickness: CGFloat = 3
    private var palette: EdgePalette?
    private var edge: Edge = .top
    private var ownerBounds: CGRect = .zero

    private let baseLayer = CALayer()
    private let haloLayer = CAGradientLayer()
    private let streakLayer = CAGradientLayer()

    override init() {
        super.init()
        addSublayer(haloLayer)
        addSublayer(baseLayer)
        addSublayer(streakLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func apply(palette: EdgePalette) {
        self.palette = palette
        edgeThickness = palette.width
        baseLayer.backgroundColor = palette.base.cgColor
        haloLayer.colors = [palette.haloCore.cgColor, NSColor.clear.cgColor]
        streakLayer.colors = palette.spectrum
        streakLayer.shadowColor = palette.streakShadow.cgColor
        streakLayer.shadowRadius = 11
        streakLayer.shadowOpacity = 1
        streakLayer.shadowOffset = .zero
        relayout()
    }

    func configure(edge: Edge, bounds ownerBounds: CGRect) {
        self.edge = edge
        self.ownerBounds = ownerBounds
        relayout()
    }

    private func relayout() {
        guard bounds.width > 0, bounds.height > 0, let palette else { return }

        let haloDepth: CGFloat = 58
        switch edge {
        case .top:
            haloLayer.frame = CGRect(x: 0, y: -haloDepth, width: bounds.width, height: haloDepth)
            haloLayer.startPoint = CGPoint(x: 0.5, y: 0)
            haloLayer.endPoint = CGPoint(x: 0.5, y: 1)
        case .bottom:
            haloLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: haloDepth)
            haloLayer.startPoint = CGPoint(x: 0.5, y: 1)
            haloLayer.endPoint = CGPoint(x: 0.5, y: 0)
        case .left:
            haloLayer.frame = CGRect(x: 0, y: 0, width: haloDepth, height: bounds.height)
            haloLayer.startPoint = CGPoint(x: 0, y: 0.5)
            haloLayer.endPoint = CGPoint(x: 1, y: 0.5)
        case .right:
            haloLayer.frame = CGRect(x: bounds.width - haloDepth, y: 0, width: haloDepth, height: bounds.height)
            haloLayer.startPoint = CGPoint(x: 1, y: 0.5)
            haloLayer.endPoint = CGPoint(x: 0, y: 0.5)
        }
        baseLayer.frame = bounds

        // 扫光条：长 = 40% 边长（--edge-streak-length），沿边流动。
        let isHorizontal = edge == .top || edge == .bottom
        let length = isHorizontal ? bounds.width : bounds.height
        let streakLength = length * 0.4
        streakLayer.frame = isHorizontal
            ? CGRect(x: 0, y: 0, width: streakLength, height: bounds.height)
            : CGRect(x: 0, y: 0, width: bounds.width, height: streakLength)
        if isHorizontal {
            streakLayer.startPoint = CGPoint(x: 0, y: 0.5)
            streakLayer.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            streakLayer.startPoint = CGPoint(x: 0.5, y: 0)
            streakLayer.endPoint = CGPoint(x: 0.5, y: 1)
        }

        streakLayer.removeAllAnimations()
        let key = isHorizontal ? "position.x" : "position.y"
        let move = CABasicAnimation(keyPath: key)
        let lead = streakLength / 2
        let tail = length + streakLength / 2
        // top/right 正向（-115% → 300% 近似从外侧滑入到外侧滑出）；bottom/left 反向。
        let reversed = edge == .bottom || edge == .left
        move.fromValue = reversed ? tail : lead
        move.toValue = reversed ? lead : tail
        move.duration = palette.duration
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        move.repeatCount = .infinity
        streakLayer.add(move, forKey: "sweep")
    }
}

/// 边缘配色（styles.css:177-206 的两组 CSS 变量）。
private struct EdgePalette {
    let width: CGFloat
    let base: NSColor
    let haloCore: NSColor
    let streakShadow: NSColor
    let spectrum: [Any]
    let duration: Double

    init(kind: AttentionContent.Kind) {
        if kind == .waiting {
            width = 3
            base = NSColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 0.88)
            haloCore = NSColor(red: 255/255, green: 127/255, blue: 137/255, alpha: 0.46)
            streakShadow = NSColor(red: 255/255, green: 184/255, blue: 118/255, alpha: 0.54)
            spectrum = Self.colors([
                (190, 134, 255, 0.0), (190, 134, 255, 0.88), (94, 191, 255, 0.98),
                (91, 224, 171, 0.98), (255, 209, 105, 0.98), (255, 104, 136, 0.92),
                (255, 104, 136, 0.0),
            ])
            duration = 2.6
        } else {
            width = 2
            base = NSColor(red: 70/255, green: 184/255, blue: 129/255, alpha: 0.72)
            haloCore = NSColor(red: 126/255, green: 225/255, blue: 170/255, alpha: 0.38)
            streakShadow = NSColor(red: 111/255, green: 224/255, blue: 181/255, alpha: 0.42)
            spectrum = Self.colors([
                (91, 186, 255, 0.0), (91, 186, 255, 0.86), (94, 229, 173, 0.98),
                (166, 232, 113, 0.96), (255, 222, 119, 0.94), (192, 149, 255, 0.86),
                (192, 149, 255, 0.0),
            ])
            duration = 3.4
        }
    }

    private static func colors(_ rgba: [(Int, Int, Int, Double)]) -> [Any] {
        rgba.map { CGColor(red: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: CGFloat($0.3)) }
    }
}
