//
//  SuccessView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import SwiftUI

struct SuccessView: View {

    let title: String
    let subtitle: String?
    let logFileURL: URL?

    @State private var isLogsPresented = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text(title)
                .font(.title)
                .bold()

            if let subtitle {
                Text(subtitle)
                    .font(.title3)
            }

            if logFileURL != nil {
                Button {
                    isLogsPresented = true
                } label: {
                    Label(isInjectionReport ? NSLocalizedString("View Report", comment: "") : NSLocalizedString("View Logs", comment: ""),
                          systemImage: "note.text")
                }
            }
        }
        .padding()
        .multilineTextAlignment(.center)
        .sheet(isPresented: $isLogsPresented) {
            if let logFileURL {
                if isInjectionReport {
                    DiagnosticFileView(url: logFileURL)
                } else {
                    LogsView(url: logFileURL)
                }
            }
        }
    }

    private var isInjectionReport: Bool {
        logFileURL?.lastPathComponent.hasPrefix("injection-report-") == true
    }
}

struct DiagnosticFileView: View {
    let url: URL
    @Environment(\.presentationMode) private var presentationMode

    private var content: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? NSLocalizedString("Unable to read report.", comment: "")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(NSLocalizedString("Injection Report", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SuccessView(
        title: "Hello, World!",
        subtitle: nil,
        logFileURL: nil
    )
}
