//
//  SettingsView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/28.
//

import SwiftUI

struct SettingsView: View {
    let app: App

    init(_ app: App) {
        self.app = app
        _useWeakReference = AppStorage(wrappedValue: true, "UseWeakReference-\(app.bid)")
        _preferMainExecutable = AppStorage(wrappedValue: false, "PreferMainExecutable-\(app.bid)")
        _useFrameworkEnumerationFallback = AppStorage(wrappedValue: true, "UseFrameworkEnumerationFallback-\(app.bid)")
        _deferPlugInLoading = AppStorage(wrappedValue: false, "DeferPlugInLoading-\(app.bid)")
        _injectStrategy = AppStorage(wrappedValue: .lexicographic, "InjectStrategy-\(app.bid)")
        _dryRun = AppStorage(wrappedValue: false, "DryRun-\(app.bid)")
    }

    @AppStorage var useWeakReference: Bool
    @AppStorage var preferMainExecutable: Bool
    @AppStorage var useFrameworkEnumerationFallback: Bool
    @AppStorage var deferPlugInLoading: Bool
    @AppStorage var injectStrategy: InjectorV3.Strategy
    @AppStorage var dryRun: Bool

    @StateObject var viewControllerHost = ViewControllerHost()
    @State private var isDryRunWarningPresented = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(InjectorV3.Strategy.allCases, id: \.self) { strategy in
                        Button {
                            injectStrategy = strategy
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(strategy.localizedDescription)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(strategy.localizedDetail)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if injectStrategy == strategy {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Injection Strategy", comment: ""))
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Choose how TrollFools tries possible targets. If the plug-in does not work as expected, try another option.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Pre-main Compatibility Loading", comment: ""), isOn: $deferPlugInLoading)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Loads plug-ins after app frameworks initialize but before app launch. Enable this when injection succeeds but the target app crashes immediately.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Enable Compatibility Fallback", comment: ""), isOn: $useFrameworkEnumerationFallback)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("If needed, TrollFools will use a compatibility mode to improve success rate. Keeping this on is recommended.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Prefer Main Executable", comment: ""), isOn: $preferMainExecutable)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Try the app’s main file first. Turn this on when the plug-in does not seem active.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Use Weak Reference", comment: ""), isOn: $useWeakReference)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Controls whether the app crashes when the plug-in cannot be found. Keeping this on can reduce unexpected crashes in some scenarios, but the plug-in will not work in those cases.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Dry Run", comment: ""), isOn: dryRunBinding)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Analyze compatibility and create an injection report without modifying the app.", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Advanced Settings", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $isDryRunWarningPresented) {
                Alert(
                    title: Text(NSLocalizedString("Enable Injection Debug?", comment: "")),
                    message: Text(NSLocalizedString("Injection Debug performs a complete simulation on temporary copies. It does not inject the plug-in, so the plug-in list remains empty. This option takes longer and will turn off automatically the next time TrollFools starts.", comment: "")),
                    primaryButton: .default(Text(NSLocalizedString("Enable", comment: ""))) {
                        dryRun = true
                    },
                    secondaryButton: .cancel {
                        dryRun = false
                    }
                )
            }
            .onViewWillAppear {
                viewControllerHost.viewController = $0
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewControllerHost.viewController?.dismiss(animated: true)
                    } label: {
                        Text(NSLocalizedString("Done", comment: ""))
                    }
                }
            }
        }
    }

    private var dryRunBinding: Binding<Bool> {
        Binding(
            get: { dryRun },
            set: { enabled in
                if enabled {
                    isDryRunWarningPresented = true
                } else {
                    dryRun = false
                }
            }
        )
    }

    @ViewBuilder
    private func paddedHeaderFooterText(_ content: String) -> some View {
        if #available(iOS 15, *) {
            Text(content)
                .font(.footnote)
        } else {
            Text(content)
                .font(.footnote)
                .padding(.horizontal, 16)
        }
    }
}
