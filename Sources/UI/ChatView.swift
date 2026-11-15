import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 聊天界面

struct ChatMessageView: Identifiable, Equatable {
    var id: UUID
    var role: String       // user / assistant
    var text: String
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
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var pendingImage: UIImage?
    @State private var pendingFile: (name: String, text: String)?
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
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .disabled(busy)
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .disabled(busy)
                TextField("说点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(18)
                    .focused($inputFocused)
                    .onSubmit(send)
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
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            handlePickedFile(result)
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            loadPhoto(item)
            photoItem = nil
        }
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
                        Text("图片 · 发送时识别文字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                            Text("\(file.text.count) 字 · 发送时附上提取内容")
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

    // MARK: 附件处理

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
                    let text = try await Task.detached(priority: .userInitiated) {
                        try AttachmentExtractor.fileText(from: url)
                    }.value
                    pendingFile = (url.lastPathComponent, text)
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

        // 气泡里显示轻量摘要；OCR/文件全文只喂给模型
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
            // 组装喂给模型的内容：附件提取出的文字 + 用户附言
            var modelText = text
            if let f = capturedFile {
                let block = "【用户发来文件「\(f.name)」，内容如下】\n\(f.text)"
                modelText = modelText.isEmpty ? block : block + "\n\n" + modelText
            }
            if let img = capturedImage {
                let ocr = await AttachmentExtractor.ocr(from: img)
                let block = ocr.isEmpty
                    ? "【用户发来一张图片，本机 OCR 未识别到文字】"
                    : "【用户发来一张图片，OCR 识别内容如下】\n\(String(ocr.prefix(AttachmentExtractor.maxOCRChars)))"
                modelText = modelText.isEmpty ? block : block + "\n\n" + modelText
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
                let reply = try await app.pipeline.handle(userText: modelText) { delta in
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
