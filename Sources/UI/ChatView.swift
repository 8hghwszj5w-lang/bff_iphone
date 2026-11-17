import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 聊天界面
//
// 发一条消息的完整旅程（改输入/发送逻辑前先看）：
//   输入框/📷/📎 → send() 取走 input + 附件 → 气泡先上屏（含轻量摘要）
//   → Task 后台：图片转 JPEG、文件交给 Pipeline（内部上传 Files API）
//   → pipeline.handle 流式回调 → ChatDeltaBuffer 攒 50ms 批量刷 UI（约 20Hz）
//   → 收到完整回复 → 落定气泡
// 注意：messages 是本地 @State，历史恢复靠 onAppear 从 MemoryStore 读。

struct ChatMessageView: Identifiable, Equatable {
    var id: UUID
    var role: String       // user / assistant
    var text: String       // 气泡显示的文本（带附件时是摘要，不是喂给模型的全文）
    var isStreaming = false

    init(role: String, text: String, isStreaming: Bool = false, id: UUID = UUID()) {
        self.id = id; self.role = role; self.text = text; self.isStreaming = isStreaming
    }
}

struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @State private var messages: [ChatMessageView] = []
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false
    @State private var showCalls = false
    @State private var photoItem: PhotosPickerItem?
    @State private var albumPickerPresented = false   // ＋ 面板「相册」磁贴触发
    @State private var showFileImporter = false
    @State private var pendingImage: UIImage?
    @State private var pendingFile: (name: String, url: URL)?
    @State private var showAttachmentPanel = false   // 微信式「＋」面板展开态
    @State private var showCamera = false            // 拍摄（真机）
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty { emptyState }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { m in
                                Bubble(message: m)
                                    .equatable()
                                    .id(m.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: messages.count) { _ in scrollToBottom(proxy) }
                    .onChange(of: messages.last?.text) { _ in scrollToBottom(proxy) }
                }
                inputBar
            }
            .background { chatBackgroundLayer.ignoresSafeArea() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showCalls = true } label: { Image(systemName: "phone") }
                }
            }
            .sheet(isPresented: $showCalls){ PhoneView() }
            .navigationTitle("大肥鱼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                if messages.isEmpty {
                    messages = app.memory.record.entries.map {
                        ChatMessageView(role: $0.role, text: $0.content)
                    }
                }
            }
            .alert("出错了", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("你好，今天过得怎么样？")
                .font(.subheadline).foregroundStyle(.secondary)
            if app.settings.apiKey.isEmpty {
                Text("先到右上角 ⚙️ 填 DeepSeek API Key")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            attachmentChips
            // 微信式输入行：[输入框][＋][发送]。＋ 只负责开合下方面板。
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(18)
                    .focused($inputFocused)
                    .onSubmit(send)
                // ＋：再点一次收起；展开时顺带收起键盘（微信行为）
                Button {
                    showAttachmentPanel.toggle()
                    if showAttachmentPanel { inputFocused = false }
                } label: {
                    Image(systemName: showAttachmentPanel ? "plus.circle.fill" : "plus.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(showAttachmentPanel ? Color.accentColor : .secondary)
                }
                .disabled(busy)
                Button {
                    busy ? nil : send()
                } label: {
                    Image(systemName: busy ? "hourglass" : "paperplane.fill")
                        .padding(10)
                        .background(busy ? Color.gray : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .disabled((input.trimmingCharacters(in: .whitespaces).isEmpty
                           && pendingImage == nil && pendingFile == nil) || busy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            // ＋ 展开的宫格面板（微信风格：图标在上、文字在下，一排四个）
            if showAttachmentPanel {
                attachmentPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 选择器必须挂在常驻视图上；磁贴点击会立即移除整个附件面板。
        .photosPicker(isPresented: $albumPickerPresented,
                      selection: $photoItem,
                      matching: .images)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            showAttachmentPanel = false
            handlePickedFile(result)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image {
                    pendingImage = image       // 与相册共用同一条待发附件通道
                    pendingFile = nil
                    showAttachmentPanel = false
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            showAttachmentPanel = false
            loadPhoto(item)
            photoItem = nil
        }
        // 键盘弹起时自动收起面板（互斥，同微信）
        .onChange(of: inputFocused) { focused in
            if focused { showAttachmentPanel = false }
        }
    }

    /// ＋ 展开的附件宫格。想加新入口：加一个 panelTile 并接好动作即可。
    private var attachmentPanel: some View {
        HStack(spacing: 0) {
            panelTile(icon: "photo.on.rectangle.angled", label: "相册") {
                showAttachmentPanel = false
                albumPickerPresented = true   // 打开系统相册选择器
            }
            panelTile(icon: "camera.fill", label: "拍摄") {
                showAttachmentPanel = false
                showCamera = true
            }
            panelTile(icon: "folder.fill", label: "文件") {
                showAttachmentPanel = false
                showFileImporter = true
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(Color(.systemGroupedBackground))
    }

    /// 面板里的单个磁贴：圆角方块内放大图标，下方一行小字
    private func panelTile(icon: String, label: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 62, height: 62)
                    .overlay(Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// 待发送附件预览条
    @ViewBuilder
    private var attachmentChips: some View {
        if pendingImage != nil || pendingFile != nil {
            HStack(spacing: 8) {
                if let img = pendingImage {
                    attachmentChip {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        removeButton { pendingImage = nil }
                    }
                }
                if let file = pendingFile {
                    attachmentChip {
                        Image(systemName: "doc.text")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.caption).lineLimit(1)
                            Text(sendHint(for: file.url))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        removeButton { pendingFile = nil }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private func attachmentChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// 附件处理
    // 想支持一次带多个图片/文件：把 pendingImage/pendingFile 换成数组，
    // chips 用 ForEach 渲染，send() 里 captured 原样传数组即可（Pipeline 已支持数组入参）。

    private func loadPhoto(_ item: PhotosPickerItem) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentError.invalidImage
                }
                let image = await Task.detached(priority: .userInitiated) {
                    AttachmentExtractor.image(from: data)
                }.value
                guard let image else { throw AttachmentError.invalidImage }
                pendingImage = image
                pendingFile = nil   // 一次只带一个附件，新的替换旧的
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard !busy else { return }
        let url: URL
        do {
            guard let first = try result.get().first else { return }
            url = first
        } catch {
            self.error = error.localizedDescription
            return
        }
        let imageExts = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                if imageExts.contains(url.pathExtension.lowercased()) {
                    // URL 直接交给 ImageIO；安全作用域和磁盘读取都在后台完成。
                    let image = await Task.detached(priority: .userInitiated) {
                        AttachmentExtractor.image(from: url)
                    }.value
                    guard let image else { throw AttachmentError.invalidImage }
                    pendingImage = image
                    pendingFile = nil
                } else {
                    // 不做本地预抽取：发送时按类型直传 Files API 或兜底抽取
                    pendingFile = (url.lastPathComponent, url)
                    pendingImage = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 聊天背景层（设置 → 聊天背景 里选）
    @ViewBuilder
    private var chatBackgroundLayer: some View {
        switch app.chatBackground.style {
        case .system:
            Color(.systemGroupedBackground)
        case .warm:
            Color(red: 0.96, green: 0.94, blue: 0.90)
        case .mint:
            Color(red: 0.90, green: 0.96, blue: 0.93)
        case .sakura:
            Color(red: 0.97, green: 0.92, blue: 0.94)
        case .aurora:
            LinearGradient(colors: [Color(red: 0.85, green: 0.89, blue: 1.00),
                                    Color(red: 0.93, green: 0.87, blue: 0.98),
                                    Color(red: 0.85, green: 0.97, blue: 0.96)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .night:
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22),
                                    Color(red: 0.05, green: 0.07, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
        case .custom:
            CustomChatBackground(fileName: app.chatBackground.customFile,
                                 revision: app.chatBackground.imageRevision)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        if last.isStreaming {
            // 流式刷新不反复启动相互重叠的滚动动画。
            proxy.scrollTo(last.id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func send() {
        guard !busy else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedImage = pendingImage
        let capturedFile = pendingFile
        guard !text.isEmpty || capturedImage != nil || capturedFile != nil else { return }

        // 气泡里显示轻量摘要；图片/文件全文按官方文档直传给模型
        var visibleParts: [String] = []
        if capturedImage != nil { visibleParts.append("📷 图片") }
        if let f = capturedFile { visibleParts.append("📄 \(f.name)") }
        if !text.isEmpty { visibleParts.append(text) }
        let userVisible = visibleParts.joined(separator: "\n")

        input = ""
        pendingImage = nil
        pendingFile = nil
        inputFocused = false
        busy = true
        error = nil

        let userBubble = ChatMessageView(role: "user", text: userVisible)
        let replyID = UUID()
        messages.append(userBubble)
        messages.append(ChatMessageView(role: "assistant", text: "", isStreaming: true, id: replyID))

        func appendDelta(_ delta: String) {
            guard !delta.isEmpty else { return }
            if let idx = messages.lastIndex(where: { $0.id == replyID }) {
                messages[idx].text += delta
            }
        }
        func finishReply(_ finalText: String?) {
            if let idx = messages.lastIndex(where: { $0.id == replyID }) {
                var m = messages[idx]
                m.isStreaming = false
                if let finalText { m.text = finalText }
                if m.text.isEmpty { m.text = "（她没说话…可能是网络或 API 出了问题）" }
                messages[idx] = m
            }
        }

        Task { @MainActor in
            // 图片按官方文档转 JPEG base64 内联；文件由流水线按类型直传 Files API。
            // 压缩参数：0.85 质量 + ImageIO 已限制 4096px，单图约 1–3MB，
            // 远小于官方 32MiB 单图 / 48MiB 请求体上限，一般不用动。
            let imageData: [Data]
            if let img = capturedImage {
                imageData = await Task.detached(priority: .userInitiated) {
                    [img.jpegData(compressionQuality: 0.85)].compactMap { $0 }
                }.value
            } else {
                imageData = []
            }
            let fileAttachments: [UserFileAttachment]
            if let f = capturedFile {
                fileAttachments = [UserFileAttachment(name: f.name, localURL: f.url)]
            } else {
                fileAttachments = []
            }

            // 回调只缓冲文本；约 20Hz 更新 UI，避免每个 token 新建主线程任务。
            let stream = ChatDeltaBuffer()
            let updates = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 50_000_000) }
                    catch { break }
                    appendDelta(stream.drain())
                }
            }
            do {
                let reply = try await app.pipeline.handle(userText: text,
                                                          images: imageData,
                                                          files: fileAttachments) { delta in
                    stream.append(delta)
                }
                updates.cancel()
                _ = stream.finish()
                finishReply(reply)
            } catch {
                updates.cancel()
                appendDelta(stream.finish())
                finishReply(nil)
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// 附件条上的提示文案：能不能直传一眼可见
    private func sendHint(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if AttachmentExtractor.uploadPurpose(ext: ext) != nil {
            return "发送时经 Files API 直传"
        }
        if AttachmentExtractor.isImageExt(ext) {
            return "图片 · 发送时直传模型"
        }
        return "发送时按纯文本附上内容"
    }
}

/// 网络回调可来自任意 executor；所有可变状态均由锁保护。
final class ChatDeltaBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var finished = false

    func append(_ delta: String) {
        lock.lock()
        defer { lock.unlock() }
        if !finished { pending += delta }
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let delta = pending
        pending = ""
        return delta
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        let delta = pending
        pending = ""
        return delta
    }
}

// MARK: - 气泡

private struct Bubble: View, Equatable {
    let message: ChatMessageView
    var isMine: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            Text(message.text + (message.isStreaming && message.text.isEmpty ? "…" : ""))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(isMine ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isMine ? .white : .primary)
                .textSelection(.enabled)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isMine { Spacer(minLength: 48) }
        }
    }
}

/// 自定义照片背景：从 App 沙盒读取，加一层浅色薄纱保证气泡可读
struct CustomChatBackground: View {
    let fileName: String
    var revision: Int = 0
    @State private var image: UIImage?

    private struct ImageKey: Hashable {
        let fileName: String
        let revision: Int
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.white.opacity(0.22))
                    .accessibilityHidden(true)
            }
        }
        .task(id: ImageKey(fileName: fileName, revision: revision)) {
            guard !fileName.isEmpty else { image = nil; return }
            let name = fileName
            let version = revision
            image = nil
            let loaded = await Task.detached(priority: .utility) {
                ChatBackgroundImageCache.shared.load(fileName: name, revision: version)
            }.value
            // 同一路径被重裁或视图消失时，不让旧解码结果覆盖新背景。
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// 聊天页与设置预览共享解码缓存；NSCache 线程安全且可在内存紧张时回收。
private final class ChatBackgroundImageCache: @unchecked Sendable {
    static let shared = ChatBackgroundImageCache()
    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.countLimit = 2
        images.totalCostLimit = 32 * 1024 * 1024
    }

    func load(fileName: String, revision: Int) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        let key = "\(revision):\(url.path)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = AttachmentExtractor.image(from: url, maxPixelSize: 2048) else { return nil }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: key, cost: cost)
        return image
    }
}

// MARK: - 拍摄（＋ 面板「拍摄」磁贴；真机可用，模拟器无摄像头只出黑屏）
//
/// UIImagePickerController 相机包装。拍完经 onImage 回 UIImage（已带 EXIF 方向修正，
/// 由下游 AttachmentExtractor.image 统一处理）。
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // 没摄像头（模拟器）：直接收起，不崩
            DispatchQueue.main.async { dismiss() }
            return picker
        }
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onImage(image)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImage(nil)
            parent.dismiss()
        }
    }
}
