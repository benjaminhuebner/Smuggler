//
//  AboutView.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 07.11.26.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private let info = Bundle.main

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(verbatim: string("CFBundleName"))
                .font(.title3.weight(.semibold))
                .padding(.top, 8)

            Text(
                "Version \(string("CFBundleShortVersionString")) (\(string("CFBundleVersion")))",
                comment: "About window: the app's version, then its build number in parentheses"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 4)

            HStack(spacing: 8) {
                linkButton(
                    Text("Website", comment: "About window button: opens the app's website"), ProductLinks.website)
                linkButton(
                    Text(
                        "Support",
                        comment: "Help menu item and About window button: opens the support form on the app's website"),
                    ProductLinks.support)
                linkButton(
                    Text("GitHub", comment: "About window button: opens the source code on GitHub"),
                    ProductLinks.sourceCode)
            }
            .padding(.top, 20)

            VStack(spacing: 4) {
                footerLink(ProductLinks.emailURL) {
                    Text(verbatim: ProductLinks.email)
                }
                footerLink(ProductLinks.developer) {
                    HStack(spacing: 3) {
                        Text(verbatim: string("NSHumanReadableCopyright"))
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                }
                .help(Text(verbatim: ProductLinks.developer.host() ?? ProductLinks.developer.absoluteString))
            }
            .font(.subheadline)
            .padding(.top, 20)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(width: 320)
    }

    private func string(_ key: String) -> String {
        info.object(forInfoDictionaryKey: key) as? String ?? ""
    }

    private func linkButton(_ label: Text, _ url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            label.frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func footerLink(_ url: URL, @ViewBuilder label: () -> some View) -> some View {
        Button {
            openURL(url)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointerStyle(.link)
    }
}

#Preview {
    AboutView()
}
