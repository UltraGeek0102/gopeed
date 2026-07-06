import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Formatters

private func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useAll]; f.countStyle = .file
    f.includesUnit = true; f.isAdaptive = true
    return f.string(fromByteCount: bytes)
}
private func formatSpeed(_ bps: Int64) -> String {
    guard bps > 0 else { return "–" }
    return "\(formatBytes(bps))/s"
}

// MARK: - Timeline widget
// This widget's sole job is to give WidgetKit a reason to wake the extension
// process so we can call activity.update() from here — where the cooperative
// thread pool is never suspended. No home screen UI is needed.

struct GopeedProgressEntry: TimelineEntry {
    let date: Date
    let items: [SharedProgress]
}

struct GopeedTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> GopeedProgressEntry {
        GopeedProgressEntry(date: Date(), items: [])
    }
    func getSnapshot(in context: Context,
                     completion: @escaping (GopeedProgressEntry) -> Void) {
        completion(GopeedProgressEntry(date: Date(),
                                       items: SharedProgressStore.shared.read()))
    }
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<GopeedProgressEntry>) -> Void) {
        let items = SharedProgressStore.shared.read()

        // Update all active Live Activities from THIS process.
        // The widget extension is never suspended by iOS, so this always executes.
        if #available(iOS 16.2, *) {
            updateActivities(from: items)
        }

        let entry    = GopeedProgressEntry(date: Date(), items: items)
        let nextDate = Date().addingTimeInterval(items.isEmpty ? 60 : 1)
        completion(Timeline(entries: [entry], policy: .after(nextDate)))
    }

    @available(iOS 16.2, *)
    private func updateActivities(from items: [SharedProgress]) {
        let live = Activity<DownloadActivityAttributes>.activities
        for item in items {
            guard let activity = live.first(where: {
                $0.attributes.downloadId == item.id
            }) else { continue }

            let state = DownloadActivityAttributes.ContentState(
                progress: item.progress,
                downloadedBytes: item.downloadedBytes,
                totalBytes: item.totalBytes,
                speedBytesPerSec: item.speedBytesPerSec,
                statusLabel: "Downloading"
            )
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
                print("[Widget] updated \(item.id) \(String(format:"%.1f",item.progress*100))%")
            }
        }
    }
}

struct GopeedTimelineWidgetView: View {
    let entry: GopeedProgressEntry
    var body: some View {
        if entry.items.isEmpty {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
        } else {
            VStack(spacing: 2) {
                ForEach(entry.items.prefix(2), id: \.id) { item in
                    ProgressView(value: item.progress).tint(.blue)
                }
            }.padding(4)
        }
    }
}

@available(iOS 16.2, *)
struct GopeedDownloadTimelineWidget: Widget {
    static let kind = "GopeedDownloadWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GopeedTimelineProvider()) { entry in
            GopeedTimelineWidgetView(entry: entry)
        }
        .configurationDisplayName("Gopeed")
        .description("Download progress")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

// MARK: - Live Activity widget (Dynamic Island + Lock Screen UI)

// MARK: Lock Screen / StandBy view

@available(iOS 16.2, *)
struct DownloadLockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    private var pct: String {
        String(format: "%.0f%%", context.state.progress * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue).font(.title3)
                Text(context.attributes.filename)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(pct)
                    .font(.headline).monospacedDigit()
                    .foregroundColor(context.state.progress >= 1 ? .green : .primary)
            }
            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(context.state.statusLabel == "Failed" ? .red : .blue)
                .scaleEffect(x: 1, y: 1.6)
            HStack {
                if context.state.totalBytes > 0 {
                    Text("\(formatBytes(context.state.downloadedBytes)) / \(formatBytes(context.state.totalBytes))")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(formatBytes(context.state.downloadedBytes))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(formatSpeed(context.state.speedBytesPerSec))
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }
        }
        .padding()
        .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
    }
}

// MARK: Dynamic Island views

@available(iOS 16.2, *)
struct DI_CompactLeading: View {
    let context: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        Image(systemName: context.state.statusLabel == "Failed"
              ? "exclamationmark.circle.fill"
              : (context.state.progress >= 1 ? "checkmark.circle.fill" : "arrow.down.circle.fill"))
            .foregroundColor(context.state.statusLabel == "Failed" ? .red
                             : (context.state.progress >= 1 ? .green : .blue))
            .font(.body)
    }
}

@available(iOS 16.2, *)
struct DI_CompactTrailing: View {
    let context: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        Text(String(format: "%.0f%%", context.state.progress * 100))
            .monospacedDigit().font(.caption2).bold()
    }
}

@available(iOS 16.2, *)
struct DI_Expanded: View {
    let context: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
                Text(context.attributes.filename)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f%%", context.state.progress * 100))
                    .font(.caption).bold().monospacedDigit()
            }
            ProgressView(value: context.state.progress).progressViewStyle(.linear).tint(.blue)
            HStack {
                Text(formatBytes(context.state.downloadedBytes))
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(formatSpeed(context.state.speedBytesPerSec))
                    .font(.caption2).foregroundColor(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

@available(iOS 16.2, *)
struct GopeedDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue).font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format: "%.0f%%", context.state.progress * 100))
                        .bold().monospacedDigit().padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DI_Expanded(context: context)
                }
            } compactLeading: {
                DI_CompactLeading(context: context)
            } compactTrailing: {
                DI_CompactTrailing(context: context)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
            }
            .widgetURL(URL(string: "gopeed://open"))
            .keylineTint(.blue)
        }
    }
}
