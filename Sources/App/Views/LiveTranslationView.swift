import SwiftUI
import KCDeepLCore

struct LiveTranslationWorkspace: View {
    @Binding var showTools: Bool
    @StateObject private var viewModel = LiveTranslationViewModel()
    @State private var showsVolumePopover = false
    @State private var editableTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            LiveTranslationTopBar(
                title: $editableTitle,
                isOnAir: viewModel.isOnAir,
                volume: $viewModel.listenerVolume,
                showsVolumePopover: $showsVolumePopover,
                showTools: $showTools,
                onNewConversation: viewModel.newConversation,
                onTitleSubmit: {
                    viewModel.updateSelectedTitle(editableTitle)
                },
                onToggleOnAir: {
                    viewModel.setOnAir(!viewModel.isOnAir)
                }
            )

            HStack(spacing: 0) {
                LiveConversationSidebar(
                    conversations: viewModel.conversations,
                    selection: Binding(
                        get: { viewModel.selectedConversationID },
                        set: { viewModel.selectConversation($0) }
                    )
                )
                .frame(width: 236)

                Divider().opacity(0.35)

                LiveConversationDetail(
                    conversation: viewModel.selectedConversation,
                    incomingDraft: viewModel.incomingDraft,
                    outgoingDraft: viewModel.outgoingDraft,
                    isMicrophoneTranslationEnabled: viewModel.isMicrophoneTranslationEnabled,
                    onToggleMicrophone: {
                        viewModel.setMicrophoneTranslationEnabled(!viewModel.isMicrophoneTranslationEnabled)
                    }
                )
            }

            LiveStatusBar(message: viewModel.statusMessage)
        }
        .background(AppTheme.panelBackground)
        .onAppear {
            viewModel.appear()
            editableTitle = viewModel.selectedConversationTitle
        }
        .onChange(of: viewModel.selectedConversationID) { _, _ in
            editableTitle = viewModel.selectedConversationTitle
        }
        .onChange(of: viewModel.selectedConversationTitle) { _, newValue in
            editableTitle = newValue
        }
    }
}

private struct LiveTranslationTopBar: View {
    @Binding var title: String
    let isOnAir: Bool
    @Binding var volume: Double
    @Binding var showsVolumePopover: Bool
    @Binding var showTools: Bool
    let onNewConversation: () -> Void
    let onTitleSubmit: () -> Void
    let onToggleOnAir: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onNewConversation) {
                Label("새대화", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 6))
            .help("새 대화")

            TextField("대화방 이름", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .onSubmit(onTitleSubmit)
                .onChange(of: title) { _, _ in
                    onTitleSubmit()
                }

            Spacer()

            Button(action: onToggleOnAir) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOnAir ? Color.red : Color.secondary.opacity(0.7))
                        .frame(width: 8, height: 8)
                    Text(isOnAir ? "On Air" : "By Pass")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(isOnAir ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    isOnAir ? Color.red.opacity(0.92) : AppTheme.controlBackground,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .help(isOnAir ? "By Pass로 전환" : "On Air로 전환")

            Button {
                showsVolumePopover.toggle()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 6))
            .popover(isPresented: $showsVolumePopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("볼륨 \(Int(volume * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 180)
                }
                .padding(14)
            }
            .help("볼륨")

            if !showTools {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        showTools = true
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("툴바")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(AppTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.panelBorder)
                .frame(height: 1)
        }
    }
}

private struct LiveConversationSidebar: View {
    let conversations: [LiveConversation]
    @Binding var selection: LiveConversation.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("대화목록")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            List(selection: $selection) {
                ForEach(conversations) { conversation in
                    LiveConversationRow(conversation: conversation)
                        .tag(conversation.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(AppTheme.panelBackground)
    }
}

private struct LiveConversationRow: View {
    let conversation: LiveConversation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if conversation.messages.isEmpty {
            return conversation.createdAt.formatted(date: .numeric, time: .shortened)
        }
        return "\(conversation.messages.count)개 메시지"
    }
}

private struct LiveConversationDetail: View {
    let conversation: LiveConversation?
    let incomingDraft: LiveTranscriptDraft
    let outgoingDraft: LiveTranscriptDraft
    let isMicrophoneTranslationEnabled: Bool
    let onToggleMicrophone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if let conversation {
                            ForEach(conversation.messages) { message in
                                LiveMessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if !incomingDraft.isEmpty {
                            LiveDraftBubble(draft: incomingDraft)
                                .id("incoming-draft")
                        }

                        if !outgoingDraft.isEmpty {
                            LiveDraftBubble(draft: outgoingDraft)
                                .id("outgoing-draft")
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation?.messages.count ?? 0) { _, _ in
                    scrollToBottom(proxy: proxy, conversation: conversation)
                }
                .onChange(of: incomingDraft) { _, _ in
                    scrollToBottom(proxy: proxy, conversation: conversation)
                }
                .onChange(of: outgoingDraft) { _, _ in
                    scrollToBottom(proxy: proxy, conversation: conversation)
                }
            }

            LiveComposerBar(
                transcript: outgoingDraft.originalText,
                isMicrophoneTranslationEnabled: isMicrophoneTranslationEnabled,
                onToggleMicrophone: onToggleMicrophone
            )
        }
        .background(Color.black.opacity(0.08))
    }

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: LiveConversation?) {
        withAnimation(.easeOut(duration: 0.18)) {
            if !outgoingDraft.isEmpty {
                proxy.scrollTo("outgoing-draft", anchor: .bottom)
            } else if !incomingDraft.isEmpty {
                proxy.scrollTo("incoming-draft", anchor: .bottom)
            } else if let lastID = conversation?.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private struct LiveMessageBubble: View {
    let message: LiveConversationMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.speaker == .me {
                Spacer(minLength: 80)
                timestamp
                bubble
            } else {
                bubble
                timestamp
                Spacer(minLength: 80)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(primaryText)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(message.speaker == .me ? Color.white : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(message.speaker == .me ? Color.white.opacity(0.78) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(
            message.speaker == .me ? AppTheme.accent : AppTheme.controlBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var timestamp: some View {
        Text(message.timestamp.formatted(date: .omitted, time: .standard))
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.bottom, 8)
    }

    private var primaryText: String {
        switch message.speaker {
        case .me:
            return message.originalText.isEmpty ? message.translatedText : message.originalText
        case .other:
            return message.translatedText.isEmpty ? message.originalText : message.translatedText
        }
    }

    private var secondaryText: String {
        switch message.speaker {
        case .me:
            return message.translatedText
        case .other:
            return message.originalText
        }
    }
}

private struct LiveDraftBubble: View {
    let draft: LiveTranscriptDraft

    var body: some View {
        LiveMessageBubble(
            message: LiveConversationMessage(
                speaker: draft.speaker,
                originalText: draft.originalText,
                translatedText: draft.translatedText
            )
        )
        .opacity(0.72)
    }
}

private struct LiveComposerBar: View {
    let transcript: String
    let isMicrophoneTranslationEnabled: Bool
    let onToggleMicrophone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.panelBorder, lineWidth: 1)
                    .background(AppTheme.controlBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))

                ScrollView {
                    Text(transcript.isEmpty ? "한국어 원문이 실시간으로 표시됩니다" : transcript)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(transcript.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
            }
            .frame(height: 54)

            Button(action: onToggleMicrophone) {
                Image(systemName: isMicrophoneTranslationEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 21, weight: .bold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(isMicrophoneTranslationEnabled ? Color.white : AppTheme.accent)
                    .background(
                        isMicrophoneTranslationEnabled ? Color.red.opacity(0.92) : AppTheme.controlBackground,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help(isMicrophoneTranslationEnabled ? "마이크 통역 끄기" : "마이크 통역 켜기")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(AppTheme.panelBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.panelBorder)
                .frame(height: 1)
        }
    }
}

private struct LiveStatusBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(AppTheme.elevatedBackground)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }

    private var statusIcon: String {
        message.contains("실패") || message.contains("오류") || message.contains("설정")
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        statusIcon == "exclamationmark.triangle.fill" ? .orange : AppTheme.success
    }
}
