// GopeedWidgets/GopeedDownloadWidget.swift
// Add this file to the GopeedWidgets extension target only.

import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Helper: byte formatter

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func formatSpeed(_ bps: Int64) -> String {
    guard bps > 0 else { return "–" }
    return "\(formatBytes(bps))/s"
}

// MARK: - Lock Screen / StandBy view

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
                    .foregroundColor(.blue)
                    .font(.title3)
                Text(context.attributes.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(pct)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundColor(context.state.progress >= 1 ? .green : .primary)
            }

            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(context.state.statusLabel == "Failed" ? .red : .blue)
                .scaleEffect(x: 1, y: 1.6)

            HStack {
                if context.state.totalBytes > 0 {
                    Text("\(formatBytes(context.state.downloadedBytes)) / \(formatBytes(context.state.totalBytes))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(formatBytes(context.state.downloadedBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatSpeed(context.state.speedBytesPerSec))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
        .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
    }
}

// MARK: - Dynamic Island views

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
            .monospacedDigit()
            .font(.caption2)
            .bold()
    }
}

@available(iOS 16.2, *)
struct DI_Expanded: View {
    let context: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                Text(context.attributes.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f%%", context.state.progress * 100))
                    .font(.caption)
                    .bold()
                    .monospacedDigit()
            }
            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(.blue)
            HStack {
                Text(formatBytes(context.state.downloadedBytes))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatSpeed(context.state.speedBytesPerSec))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Widget configuration

@available(iOS 16.2, *)
struct GopeedDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format: "%.0f%%", context.state.progress * 100))
                        .bold()
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DI_Expanded(context: context)
                }
            } compactLeading: {
                DI_CompactLeading(context: context)
            } compactTrailing: {
                DI_CompactTrailing(context: context)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
            }
            .widgetURL(URL(string: "gopeed://open"))
            .keylineTint(.blue)
        }
    }
}
