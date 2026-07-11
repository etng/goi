import AppKit
import SwiftUI

/// About / help: license, third-party acknowledgements (GPLv3 compliance),
/// and the donation corner. QR images are loaded from the app bundle's
/// Resources/donate/ (populated from assets/donate/ by scripts/make-app.sh).
struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    @State private var checking = false
    @State private var updateStatus = ""
    @State private var pendingRelease: Updater.Release?

    private struct Acknowledgement: Identifiable {
        var id: String { name }
        let name: String
        let detail: String
        let license: String
    }

    private let bundled: [Acknowledgement] = [
        .init(
            name: "minilzo（Markus F.X.J. Oberhumer）",
            detail: "LZO1X 块解压算法的 Swift 移植，用于读取 LZO 压缩的 MDX/MDD",
            license: "GPL-2.0-or-later"
        ),
        .init(
            name: "readmdict / js-mdict",
            detail: "MDict (MDX/MDD) 文件格式的逆向工程文档与参考实现",
            license: "格式参考，未包含其代码"
        ),
        .init(
            name: "RIPEMD-128",
            detail: "按公开规范（KU Leuven COSIC）实现，用于解密 MDX 加密索引",
            license: "公开算法"
        ),
    ]

    private let runtime: [Acknowledgement] = [
        .init(
            name: "mecab + IPADIC",
            detail: "日语形态分析（变形还原），运行时检测调用，未捆绑",
            license: "GPL / LGPL / BSD 三重许可"
        ),
        .init(
            name: "Anki + AnkiConnect",
            detail: "生词本同步的间隔重复后端，经本地 HTTP 通信，未捆绑",
            license: "AGPL-3.0"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("語").font(.system(size: 44, weight: .medium))
                    Text("Goi \(version)").font(.headline)
                    Text("本地词典 · 生词本 · Anki 同步").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .padding(.top, 20)

                HStack(spacing: 14) {
                    Link("GitHub 仓库", destination: URL(string: "https://github.com/etng/goi")!)
                    Link("GPLv3 许可证", destination: URL(string: "https://github.com/etng/goi/blob/main/LICENSE")!)
                }
                .font(.system(size: 12))

                HStack(spacing: 8) {
                    Button(checking ? "检查中…" : "检查更新") { checkUpdate() }
                        .disabled(checking)
                    if !updateStatus.isEmpty {
                        Text(updateStatus).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if let release = pendingRelease {
                        Button("下载 \(release.version)") {
                            NSWorkspace.shared.open(URL(string: release.downloadURL ?? release.htmlURL)!)
                        }
                    }
                }

                groupBox("捆绑的第三方组件", items: bundled)
                groupBox("可选的运行时依赖（未捆绑）", items: runtime)

                VStack(spacing: 8) {
                    Text("请作者喝杯咖啡 ☕️").font(.system(size: 13, weight: .semibold))
                    donationArea
                    Text("捐款墙筹备中——所有捐助者都会列在项目主页。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkUpdate() {
        checking = true
        updateStatus = ""
        pendingRelease = nil
        Updater.check { result in
            checking = false
            switch result {
            case .upToDate:
                updateStatus = "已是最新版本（\(version)）"
            case .available(let release):
                updateStatus = "有新版本 \(release.version)"
                pendingRelease = release
            case .failed(let reason):
                updateStatus = reason
            }
        }
    }

    private var donationQRs: [(name: String, image: NSImage)] {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("donate"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: resourceURL, includingPropertiesForKeys: nil
              ) else { return [] }
        return files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                NSImage(contentsOf: url).map { (url.deletingPathExtension().lastPathComponent, $0) }
            }
    }

    @ViewBuilder
    private var donationArea: some View {
        let qrs = donationQRs
        if qrs.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 40) {
                ForEach(qrs, id: \.name) { qr in
                    VStack(spacing: 8) {
                        Image(nsImage: qr.image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        Text(qr.name).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func groupBox(_ title: String, items: [Acknowledgement]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(item.name).font(.system(size: 12))
                        Spacer()
                        Text(item.license).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Text(item.detail).font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }
}
