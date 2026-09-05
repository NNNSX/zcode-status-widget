import AppKit
import Core

/// 布局常量（styles.css:46-76 的结构，数值取挂件密度二档：2026-09-05 两轮
/// 收紧，与 Windows 的 27/11/8 有意分叉）。
private enum PanelMetrics {
    static let dotSize: CGFloat = 6
    static let dotGap: CGFloat = 3.5
    static let rowHeight: CGFloat = WindowContract.sessionRowHeight
    static let rowGap: CGFloat = WindowContract.sessionRowGap
    static let listPadding: CGFloat = 6
    static let rowPaddingX: CGFloat = 4
    static let columnGap: CGFloat = 4
    static let lightsColumn: CGFloat = 32
    static let workspaceColumn: CGFloat = 56
    static let todoColumn: CGFloat = 26
    static let durationColumn: CGFloat = 36
    static let fontSize: CGFloat = 9.5
}

/// 配色（对照 styles.css:64-76）。
private enum PanelPalette {
    static let rowText = NSColor(red: 0.725, green: 0.753, blue: 0.800, alpha: 1)          // #b9c0cc
    static let workspace = NSColor(red: 0.933, green: 0.949, blue: 0.973, alpha: 1)        // #eef2f8
    static let task = NSColor(red: 0.616, green: 0.651, blue: 0.710, alpha: 1)             // #9da6b5
    static let todo = NSColor(red: 0.667, green: 0.718, blue: 0.792, alpha: 1)             // #aab7ca
    static let duration = NSColor(red: 0.573, green: 0.627, blue: 0.698, alpha: 1)         // #92a0b2
    static let background = NSColor(red: 25/255, green: 29/255, blue: 35/255, alpha: 0.94)
    static let border = NSColor(white: 1, alpha: 0.14)
    static let hover = NSColor(white: 1, alpha: 0.075)

    static let redOn = NSColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 1)        // #e5484d
    static let redOff = NSColor(red: 61/255, green: 42/255, blue: 44/255, alpha: 1)        // #3d2a2c
    static let yellowOn = NSColor(red: 242/255, green: 193/255, blue: 78/255, alpha: 1)    // #f2c14e
    static let yellowOff = NSColor(red: 65/255, green: 58/255, blue: 38/255, alpha: 1)     // #413a26
    static let greenOn = NSColor(red: 70/255, green: 184/255, blue: 129/255, alpha: 1)     // #46b881
    static let greenOff = NSColor(red: 40/255, green: 64/255, blue: 47/255, alpha: 1)      // #28402f
}

private typealias Metrics = PanelMetrics
private typealias Palette = PanelPalette

/// 状态面板视图：会话行 + 三色灯（对照 src/renderer/panel.ts 与 styles.css:23-76）。
/// 快照 → 全量重建行，无局部 diff（与 Electron 版渲染模型一致）。
/// 会话行超过窗口高度上限（= workArea）时列表内滚动（对照 .session-list
/// 的 overflow-y:auto + 6px 细滚动条）；此前超界行被 masksToBounds 直接裁掉。
final class PanelView: NSView {

    private let scrollView = PanelScrollView()
    private let listView = SessionListView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.background.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
        layer?.masksToBounds = true

        scrollView.documentView = listView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// 快照更新（全量重建行，滚动位置回到顶部——对照 innerHTML 全量重建）。
    func update(sessions: [DisplaySession]) {
        listView.update(sessions: sessions)
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(.zero)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let viewportHeight = scrollView.contentView.bounds.height
        let contentHeight = listView.intrinsicContentHeight
        // 文档高度取内容与视口较大者：行少时铺满（无空洞），行多时滚动。
        listView.frame = NSRect(
            origin: .zero,
            size: CGSize(width: bounds.width, height: max(contentHeight, viewportHeight))
        )
    }
}

/// 滚动容器：无边框透明、overlay 细滚动条自动隐藏（对照 6px thin scrollbar）；
/// 整链允许背景拖动（面板窗口靠 isMovableByWindowBackground 拖动）。
private final class PanelScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        contentView.backgroundColor = .clear
        contentView.drawsBackground = false
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }
}

/// 会话列表文档视图（flipped：行从顶部向下排，滚动语义直观）。
private final class SessionListView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private var rows: [SessionRowView] = []

    func update(sessions: [DisplaySession]) {
        for row in rows {
            row.removeFromSuperview()
        }
        rows.removeAll()
        for session in sessions {
            let row = SessionRowView(frame: .zero)
            row.update(session)
            addSubview(row)
            rows.append(row)
        }
        needsLayout = true
    }

    /// 行内容总高（padding*2 + 行高 + 行距），供滚动文档高度计算。
    var intrinsicContentHeight: CGFloat {
        let count = max(rows.count, 1)
        return Metrics.listPadding * 2
            + CGFloat(count) * Metrics.rowHeight
            + CGFloat(count - 1) * Metrics.rowGap
    }

    override func layout() {
        super.layout()
        let contentWidth = bounds.width - Metrics.listPadding * 2
        for (index, row) in rows.enumerated() {
            let originY = Metrics.listPadding + CGFloat(index) * (Metrics.rowHeight + Metrics.rowGap)
            row.frame = NSRect(
                x: Metrics.listPadding,
                y: originY,
                width: contentWidth,
                height: Metrics.rowHeight
            )
        }
    }
}

/// 单个会话行：灯组 | 工作区 | 任务 | Todo | 时长。
private final class SessionRowView: NSView {
    private let lights = SignalGroupView(frame: .zero)
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let todoLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5

        for label in [workspaceLabel, taskLabel, todoLabel, durationLabel] {
            label.font = .systemFont(ofSize: Metrics.fontSize)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.cell?.wraps = false
            addSubview(label)
        }
        workspaceLabel.textColor = Palette.workspace
        workspaceLabel.font = .systemFont(ofSize: Metrics.fontSize, weight: .bold)
        taskLabel.textColor = Palette.task
        todoLabel.textColor = Palette.todo
        durationLabel.textColor = Palette.duration
        durationLabel.alignment = .right
        durationLabel.font = .monospacedDigitSystemFont(ofSize: Metrics.fontSize, weight: .regular)
        addSubview(lights)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func update(_ session: DisplaySession) {
        lights.setState(session.state)
        workspaceLabel.stringValue = session.workspace
        taskLabel.stringValue = session.task
        taskLabel.toolTip = session.task
        todoLabel.stringValue = session.todoProgress
        durationLabel.stringValue = session.duration
        layoutColumns(width: bounds.width)
    }

    private func layoutColumns(width: CGFloat) {
        let height = bounds.height
        lights.frame = NSRect(
            x: Metrics.rowPaddingX,
            y: (height - Metrics.dotSize) / 2,
            width: Metrics.lightsColumn - Metrics.rowPaddingX * 2,
            height: Metrics.dotSize
        )
        // 单行 label 在高 frame 里贴顶绘制，须按字体行高垂直居中
        // （对照 styles.css:49 的 align-items:center）。
        let textHeight = ceil(workspaceLabel.fittingSize.height)
        let textY = (height - textHeight) / 2
        let workspaceX = Metrics.lightsColumn + Metrics.columnGap
        workspaceLabel.frame = NSRect(x: workspaceX, y: textY, width: Metrics.workspaceColumn, height: textHeight)
        let durationWidth = sessionDurationWidth()
        let todoX = width - Metrics.rowPaddingX - Metrics.durationColumn - Metrics.columnGap - Metrics.todoColumn
        todoLabel.frame = NSRect(x: todoX, y: textY, width: Metrics.todoColumn, height: textHeight)
        durationLabel.frame = NSRect(x: width - Metrics.rowPaddingX - durationWidth, y: textY, width: durationWidth, height: textHeight)
        let taskX = workspaceX + Metrics.workspaceColumn + Metrics.columnGap
        taskLabel.frame = NSRect(x: taskX, y: textY, width: todoX - Metrics.columnGap - taskX, height: textHeight)
    }

    private func sessionDurationWidth() -> CGFloat {
        Metrics.durationColumn
    }

    override func layout() {
        super.layout()
        layoutColumns(width: bounds.width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        layer?.backgroundColor = isHovered ? Palette.hover.cgColor : nil
    }

    private var isHovered: Bool {
        // window 坐标必须显式转到本行坐标系：列表滚动后文档原点与窗口不再重合。
        guard let window = window else { return false }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(location)
    }
}

/// 三颗灯：红（等待）黄（执行中）绿（完成）。
/// 动画节奏对照 styles.css:64-70, 251-253：红 0.48s 阶跃闪烁、黄 1s ease-in-out、绿 2.4s 呼吸。
private final class SignalGroupView: NSView {
    private let red = SignalDotView()
    private let yellow = SignalDotView()
    private let green = SignalDotView()
    private var state: SessionState = .unknown

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for dot in [red, yellow, green] {
            addSubview(dot)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func setState(_ newState: SessionState) {
        state = newState
        red.setActive(newState == .waiting, on: Palette.redOn, off: Palette.redOff, glowAlpha: 0.65, animation: .blink)
        yellow.setActive(newState == .working, on: Palette.yellowOn, off: Palette.yellowOff, glowAlpha: 0.6, animation: .pulse)
        green.setActive(newState == .done, on: Palette.greenOn, off: Palette.greenOff, glowAlpha: 0.55, animation: .breathe)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let spacing = Metrics.dotGap
        let dotSide = Metrics.dotSize
        let total = 3 * dotSide + 2 * spacing
        var x = (bounds.width - total) / 2
        for dot in [red, yellow, green] {
            dot.frame = NSRect(x: x, y: 0, width: dotSide, height: dotSide)
            x += dotSide + spacing
        }
    }
}

/// 单颗灯：CALayer + 发光阴影 + 状态动画。
private final class SignalDotView: NSView {
    enum Animation {
        case blink      // 红：0.48s 阶跃
        case pulse      // 黄：1s ease-in-out
        case breathe    // 绿：2.4s 呼吸（透明度 + 缩放）
    }

    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func setActive(
        _ active: Bool,
        on: NSColor,
        off: NSColor,
        glowAlpha: CGFloat,
        animation: Animation
    ) {
        self.active = active
        guard let layer else { return }
        layer.removeAllAnimations()
        layer.sublayers?.forEach { $0.removeAllAnimations() }
        layer.cornerRadius = Metrics.dotSize / 2
        layer.masksToBounds = false
        if active {
            layer.backgroundColor = on.cgColor
            layer.shadowColor = on.cgColor
            layer.shadowOpacity = Float(glowAlpha)
            layer.shadowRadius = 4.5
            layer.shadowOffset = .zero
            switch animation {
            case .blink:
                // steps(2, end)：0.48s 内 1 → 0.25 → 1 阶跃。
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1.0, 0.25, 1.0]
                fade.keyTimes = [0, 0.5, 1]
                fade.duration = 0.48
                fade.calculationMode = .discrete
                fade.repeatCount = .infinity
                layer.add(fade, forKey: "blink")
            case .pulse:
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1.0, 0.35, 1.0]
                fade.keyTimes = [0, 0.5, 1]
                fade.duration = 1.0
                fade.timingFunctions = [
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .easeInEaseOut),
                ]
                fade.repeatCount = .infinity
                layer.add(fade, forKey: "pulse")
            case .breathe:
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.42, 1.0, 0.42]
                fade.keyTimes = [0, 0.5, 1]
                fade.duration = 2.4
                fade.timingFunctions = [
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .easeInEaseOut),
                ]
                fade.repeatCount = .infinity
                layer.add(fade, forKey: "breathe")
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.9, 1.0, 0.9]
                scale.keyTimes = [0, 0.5, 1]
                scale.duration = 2.4
                scale.timingFunctions = [
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .easeInEaseOut),
                ]
                scale.repeatCount = .infinity
                layer.add(scale, forKey: "breathe-scale")
            }
        } else {
            layer.backgroundColor = off.cgColor
            layer.shadowOpacity = 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
