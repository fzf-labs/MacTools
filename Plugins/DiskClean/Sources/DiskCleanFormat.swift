import SwiftUI
import MacToolsPluginKit

/// Formatting shared by cleanup workspaces and history.
///
/// Bytes always carry "about" (estimated logical size ≠ actual free space, design §7.7); fixed-width numeric columns avoid layout jitter on refresh.
enum DiskCleanFormat {
    /// Byte-column width. Fixed width keeps "about 1.2 GB" and "about 812 KB" aligned so refreshes do not jump sideways.
    static let byteColumnWidth: CGFloat = 92

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale))
    }

    static func approximateBytes(_ value: Int64, localization: PluginLocalization) -> String {
        localization.format("detail.candidate.size", defaultValue: "约 %@", bytes(value))
    }

    static func itemCount(_ count: Int, localization: PluginLocalization) -> String {
        localization.format("item.count", defaultValue: "%d 项", count)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func confirmationTitle(
        _ snapshot: DiskCleanControllerSnapshot,
        localization: PluginLocalization
    ) -> String {
        guard let pending = snapshot.pendingPlan else {
            return localization.string("detail.confirm.fallbackTitle", defaultValue: "确认永久清理")
        }
        return localization.format(
            "detail.confirm.title",
            defaultValue: "确认永久清理 %d 项 · 约 %@",
            pending.itemCount,
            bytes(pending.totalEstimatedBytes)
        )
    }

    static func partialReasons(
        _ reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        localization: PluginLocalization
    ) -> String {
        let ordered: [DiskCleanScanCompleteness.PartialReason] = [
            .timedOut, .permissionDenied, .unsupportedVolume, .crossedMountPoint, .walkError
        ]
        return ordered
            .filter(reasons.contains)
            .map { reason in
                switch reason {
                case .timedOut:
                    return localization.string("partial.timedOut", defaultValue: "超时")
                case .permissionDenied:
                    return localization.string("partial.permissionDenied", defaultValue: "权限不足")
                case .unsupportedVolume:
                    return localization.string("partial.unsupportedVolume", defaultValue: "不支持的卷")
                case .crossedMountPoint:
                    return localization.string("partial.crossedMountPoint", defaultValue: "含挂载点")
                case .walkError:
                    return localization.string("partial.walkError", defaultValue: "读取异常")
                }
            }
            .joined(separator: localization.string("list.separator", defaultValue: "、"))
    }

    /// Per-line copy for the limited-scan banner (design §4.5).
    static func limitation(
        _ limitation: DiskCleanScanLimitation,
        localization: PluginLocalization
    ) -> String {
        switch limitation {
        case let .fdaRestricted(skippedTargetIDs):
            return localization.format(
                "limitation.fdaRestricted",
                defaultValue: "未开启完全磁盘访问，已跳过 %d 项系统缓存",
                skippedTargetIDs.count
            )
        case let .dynamicRuleFailed(targetID, reason):
            return localization.format(
                "limitation.dynamicRuleFailed",
                defaultValue: "动态规则 %@ 未能运行：%@",
                targetID,
                reason
            )
        case let .targetExpansionFailed(targetID, reason):
            return localization.format(
                "limitation.targetExpansionFailed",
                defaultValue: "规则 %@ 展开失败：%@",
                targetID,
                reason
            )
        case let .volumeSkipped(path):
            return localization.format(
                "limitation.volumeSkipped",
                defaultValue: "已跳过非本地卷：%@",
                path
            )
        case let .scanRootUnreadable(path, reason):
            guard reason == .permissionDenied else {
                return localization.format(
                    "limitation.scanRootUnreadable",
                    defaultValue: "无法读取 %@（%@）",
                    path,
                    partialReasons([reason], localization: localization)
                )
            }
            return localization.format(
                "limitation.scanRootDenied",
                defaultValue: "没有访问 %@ 的权限，其中的内容未被扫描",
                path
            )
        case .installerSearchLimited:
            return localization.string("limitation.installerSearchLimited", defaultValue: "搜索已达范围上限，部分文件夹未检查")
        case .developerSearchLimited:
            return localization.string("limitation.developerSearchLimited", defaultValue: "工程检查未完成，部分项目已跳过")
        case .walkerCircuitBroken:
            return localization.string(
                "limitation.walkerCircuitBroken",
                defaultValue: "扫描引擎已降级，本次不再计算大小，重启应用后恢复"
            )
        case let .threadsAbandoned(count):
            return localization.format(
                "limitation.threadsAbandoned",
                defaultValue: "有 %d 个扫描线程未能按时返回",
                count
            )
        }
    }

    static func stagedName(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .trashed(_, stagedName),
             let .partiallyDeleted(stagedName, _),
             let .rollbackBlocked(stagedName, _):
            return stagedName
        case .removed, .skipped, .changedSinceScan, .failed:
            return nil
        }
    }

    static func attentionTitle(
        _ outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> String {
        switch outcome {
        case .partiallyDeleted:
            return localization.string("detail.result.partiallyDeleted", defaultValue: "只删除了一部分")
        case .rollbackBlocked:
            return localization.string("detail.result.rollbackBlocked", defaultValue: "无法放回原处")
        case .removed, .trashed, .skipped, .changedSinceScan, .failed:
            return localization.string("detail.result.attention", defaultValue: "需要处理")
        }
    }

    /// Guidance must say "what the disk looks like now" and "what the user can do", not only a status name.
    static func attentionGuidance(
        _ outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> String {
        switch outcome {
        case .partiallyDeleted:
            return localization.string(
                "detail.result.partiallyDeleted.guidance",
                defaultValue: "删除中途失败，暂存对象里只剩一部分内容，不会被放回原路径。可在访达中按暂存名找到并自行删除。"
            )
        case .rollbackBlocked:
            return localization.string(
                "detail.result.rollbackBlocked.guidance",
                defaultValue: "原路径已被重新创建，暂存对象未覆盖它。可在访达中按暂存名找到并自行处理。"
            )
        case let .failed(message):
            return message
        case .removed, .trashed, .skipped, .changedSinceScan:
            return ""
        }
    }

    static func logSymbolName(_ tone: DiskCleanScanLogTone) -> String {
        switch tone {
        case .info:
            return "circle"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    static func logTint(_ tone: DiskCleanScanLogTone) -> Color {
        switch tone {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
