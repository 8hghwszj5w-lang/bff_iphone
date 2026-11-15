import SwiftUI

// MARK: - 聊天背景裁剪页（拖动平移 + 双指缩放 + 比例选择，所见即所得裁剪）

enum CropAspect: String, CaseIterable, Identifiable {
    case fullScreen = "全屏"
    case portrait = "3:4"
    case square = "1:1"
    case landscape = "16:9"

    var id: String { rawValue }
    var ratio: CGFloat {
        switch self {
        case .fullScreen: return 9 / 19.5
        case .portrait: return 3 / 4
        case .square: return 1
        case .landscape: return 16 / 9
        }
    }
}

struct ImageCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var aspect: CropAspect = .fullScreen
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var frameSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let frame = cropSize(container: geo.size)
                let fit = fitScale(frame: frame)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: image.size.width * fit * scale,
                               height: image.size.height * fit * scale)
                        .offset(offset)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = clamped(translate(lastOffset, by: v.translation), frame: frame, fit: fit)
                        }
                        .onEnded { _ in lastOffset = offset }
                        .simultaneously(with:
                            MagnificationGesture()
                                .onChanged { v in
                                    scale = min(6, max(1, lastScale * v))
                                    offset = clamped(offset, frame: frame, fit: fit)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    offset = clamped(offset, frame: frame, fit: fit)
                                    lastOffset = offset
                                }
                        )
                )
                .onAppear { updateFrame(frame) }
                // 比例切换也会改变裁剪框，不能只监听外部容器尺寸。
                .onChange(of: frame) { updateFrame($0) }
            }
            .padding(.horizontal, 16)

            Picker("比例", selection: $aspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .onChange(of: aspect) { _ in reset() }

            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("重置", action: reset)
                Spacer()
                Button("完成") { cropAndSave() }
                    .font(.body.bold())
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: 几何计算

    private func cropSize(container: CGSize) -> CGSize {
        let availH = max(container.height - 8, 1)
        var w = max(container.width, 1)
        var h = w / aspect.ratio
        if h > availH {
            h = availH
            w = h * aspect.ratio
        }
        return CGSize(width: w, height: h)
    }

    /// scaledToFill 的基准缩放：让图片刚好铺满裁剪框
    private func fitScale(frame: CGSize) -> CGFloat {
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0, frame.width > 0, frame.height > 0 else { return 1 }
        return max(frame.width / iw, frame.height / ih)
    }

    /// 平移限位：保证图片始终铺满裁剪框，不露底
    private func clamped(_ o: CGSize, frame: CGSize, fit: CGFloat) -> CGSize {
        let w = image.size.width * fit * scale
        let h = image.size.height * fit * scale
        let mx = max(0, (w - frame.width) / 2)
        let my = max(0, (h - frame.height) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)),
                      height: min(my, max(-my, o.height)))
    }

    private func updateFrame(_ frame: CGSize) {
        frameSize = frame
        offset = clamped(offset, frame: frame, fit: fitScale(frame: frame))
        lastOffset = offset
    }

    private func translate(_ a: CGSize, by b: CGSize) -> CGSize {
        CGSize(width: a.width + b.width, height: a.height + b.height)
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    // MARK: 导出：用 ImageRenderer 精确渲染用户看到的裁剪框内容

    private func cropAndSave() {
        guard frameSize.width > 0, frameSize.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        let canvas = CropCanvas(image: image,
                                frame: frameSize,
                                fit: fitScale(frame: frameSize),
                                scale: scale,
                                offset: offset)
        let renderer = ImageRenderer(content: canvas)
        // 保留手机上的三倍输出，避免大屏窗口导出不必要的超大位图。
        renderer.scale = min(3, 4096 / max(frameSize.width, frameSize.height))
        if let out = renderer.uiImage {
            onDone(out)
        }
    }
}

/// 与交互视图完全同构的静态画布，供 ImageRenderer 离屏渲染
struct CropCanvas: View {
    let image: UIImage
    let frame: CGSize
    let fit: CGFloat
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: image.size.width * fit * scale,
                       height: image.size.height * fit * scale)
                .offset(offset)
        }
        .frame(width: frame.width, height: frame.height)
        .clipped()
    }
}
