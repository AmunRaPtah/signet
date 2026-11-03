//
//  HomeView.swift
//  Signet
//

import SwiftUI
import NimbleViews

// MARK: - View
/// Signet's landing tab: certificate health at a glance, quick imports, and what's ready to install or sign.
struct HomeView: View {
	@StateObject private var _downloadManager = DownloadManager.shared
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _isImportingPresenting = false
	@State private var _isURLPresenting = false
	@State private var _isAddingCertPresenting = false
	@State private var _urlString = ""
	@State private var _isCheckingStatus = false
	@State private var _selectedInstallApp: AnyApp?
	@State private var _selectedSigningApp: AnyApp?
	
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	private var _selectedCertificate: CertificatePair? {
		guard _storedSelectedCert >= 0, _storedSelectedCert < _certificates.count else {
			return _certificates.first
		}
		return _certificates[_storedSelectedCert]
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Signet")) {
			ScrollView {
				VStack(alignment: .leading, spacing: 22) {
					_certificateCard()
					_quickActions()
					_stats()
					
					if !_signedApps.isEmpty {
						_appRow(
							title: .localized("Ready to Install"),
							systemImage: "arrow.down.app",
							apps: Array(_signedApps.prefix(5)),
							actionTitle: .localized("Install")
						) { app in
							_selectedInstallApp = AnyApp(base: app)
						}
					}
					
					if !_importedApps.isEmpty {
						_appRow(
							title: .localized("Waiting to Sign"),
							systemImage: "signature",
							apps: Array(_importedApps.prefix(5)),
							actionTitle: .localized("Sign")
						) { app in
							_selectedSigningApp = AnyApp(base: app)
						}
					}
					
					if _signedApps.isEmpty && _importedApps.isEmpty {
						_emptyState()
					}
				}
				.padding(.horizontal)
				.padding(.vertical, 8)
			}
			.background(Color(uiColor: .systemGroupedBackground))
		}
		.sheet(item: $_selectedInstallApp) { app in
			InstallPreviewView(app: app.base, isSharing: app.archive)
				.presentationDetents([.height(200)])
				.presentationDragIndicator(.visible)
		}
		.fullScreenCover(item: $_selectedSigningApp) { app in
			SigningView(app: app.base)
		}
		.sheet(isPresented: $_isAddingCertPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
		.onChange(of: _certificates.count) { _ in
			CertificateMonitor.shared.rescheduleReminders()
		}
		.sheet(isPresented: $_isImportingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.ipa, .tipa],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					for url in urls {
						let id = "FeatherManualDownload_\(UUID().uuidString)"
						let dl = _downloadManager.startArchive(from: url, id: id)
						try? _downloadManager.handlePachageFile(url: url, dl: dl)
					}
				}
			)
			.ignoresSafeArea()
		}
		.alert(.localized("Import from URL"), isPresented: $_isURLPresenting) {
			TextField(.localized("https://example.com/app.ipa"), text: $_urlString)
				.textInputAutocapitalization(.never)
				.keyboardType(.URL)
			Button(.localized("Cancel"), role: .cancel) { _urlString = "" }
			Button(.localized("Download")) {
				_download(_urlString)
				_urlString = ""
			}
		}
	}
}

// MARK: - Certificate card
extension HomeView {
	@ViewBuilder
	private func _certificateCard() -> some View {
		if let cert = _selectedCertificate {
			let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
			let expiration = cert.expiration ?? decoded?.ExpirationDate
			let daysLeft = expiration.map { Calendar.current.dateComponents([.day], from: .now, to: $0).day ?? 0 } ?? 0
			let isExpired = (expiration ?? .distantPast) < .now
			let statusColor = SignetTheme.color(daysLeft: isExpired ? -1 : daysLeft, revoked: cert.revoked)
			let statusText: String = cert.revoked
				? .localized("Revoked")
				: (isExpired ? .localized("Expired") : .localized("Valid"))
			
			VStack(alignment: .leading, spacing: 16) {
				HStack(alignment: .center, spacing: 16) {
					_daysRing(daysLeft: max(daysLeft, 0), total: 365, color: statusColor, expired: isExpired || cert.revoked)
					
					VStack(alignment: .leading, spacing: 4) {
						Text(verbatim: cert.nickname ?? decoded?.Name ?? .localized("Certificate"))
							.font(.title3.bold())
							.lineLimit(2)
						if let team = decoded?.TeamName {
							Text(verbatim: team)
								.font(.subheadline)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						HStack(spacing: 6) {
							Circle().fill(statusColor).frame(width: 8, height: 8)
							Text(verbatim: statusText)
								.font(.caption.weight(.semibold))
								.foregroundStyle(statusColor)
							if let expiration {
								Text(verbatim: "· " + expiration.formatted(date: .abbreviated, time: .omitted))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
					Spacer(minLength: 0)
				}
				
				HStack(spacing: 10) {
					Button {
						_checkStatus()
					} label: {
						HStack(spacing: 6) {
							if _isCheckingStatus {
								ProgressView().controlSize(.small)
							} else {
								Image(systemName: "checkmark.shield")
							}
							Text(.localized("Check Status"))
						}
						.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
					.disabled(_isCheckingStatus)
					
					NavigationLink {
						CertificatesView()
					} label: {
						HStack(spacing: 6) {
							Image(systemName: "person.text.rectangle")
							Text(.localized("Manage"))
						}
						.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
				}
				
				if let last = CertificateMonitor.shared.lastRevokeCheck {
					Text(verbatim: .localized("Last checked %@", arguments: last.formatted(.relative(presentation: .named))))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
			.padding(18)
			.background(_cardBackground(accent: statusColor))
		} else {
			VStack(alignment: .leading, spacing: 12) {
				Label(.localized("No certificate yet"), systemImage: "seal")
					.font(.title3.bold())
				Text(.localized("Add a .p12 and its .mobileprovision to start signing apps. Signet will remind you before it expires."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
				Button {
					_isAddingCertPresenting = true
				} label: {
					Label(.localized("Add Certificate"), systemImage: "plus")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
			}
			.padding(18)
			.background(_cardBackground(accent: SignetTheme.wax))
		}
	}
	
	@ViewBuilder
	private func _daysRing(daysLeft: Int, total: Int, color: Color, expired: Bool) -> some View {
		let progress = expired ? 1.0 : min(Double(daysLeft) / Double(total), 1.0)
		ZStack {
			Circle()
				.stroke(color.opacity(0.18), lineWidth: 7)
			Circle()
				.trim(from: 0, to: progress)
				.stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
				.rotationEffect(.degrees(-90))
			VStack(spacing: -2) {
				if expired {
					Image(systemName: "xmark")
						.font(.title3.bold())
						.foregroundStyle(color)
				} else {
					Text(verbatim: "\(daysLeft)")
						.font(.title2.bold().monospacedDigit())
					Text(.localized("days"))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
		}
		.frame(width: 72, height: 72)
	}
	
	private func _cardBackground(accent: Color) -> some View {
		RoundedRectangle(cornerRadius: 22, style: .continuous)
			.fill(SignetTheme.cardFill)
			.overlay(
				RoundedRectangle(cornerRadius: 22, style: .continuous)
					.fill(
						LinearGradient(
							colors: [accent.opacity(0.16), .clear],
							startPoint: .topLeading,
							endPoint: .bottomTrailing
						)
					)
			)
	}
	
	private func _checkStatus() {
		_isCheckingStatus = true
		CertificateMonitor.shared.checkRevocation { revoked in
			_isCheckingStatus = false
			UIAlertController.showAlertWithOk(
				title: .localized("Certificate Status"),
				message: revoked.isEmpty
					? .localized("No revoked certificates found.")
					: .localized("Revoked: %@", arguments: revoked.joined(separator: ", "))
			)
		}
	}
}

// MARK: - Quick actions
extension HomeView {
	@ViewBuilder
	private func _quickActions() -> some View {
		VStack(alignment: .leading, spacing: 10) {
			_sectionHeader(.localized("Quick Actions"), systemImage: "bolt")
			LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
				_actionTile(.localized("Import IPA"), systemImage: "doc.badge.plus") {
					_isImportingPresenting = true
				}
				_actionTile(.localized("From URL"), systemImage: "link") {
					_isURLPresenting = true
				}
				_actionTile(.localized("Paste Link"), systemImage: "doc.on.clipboard") {
					_pasteLink()
				}
				_actionTile(.localized("Add Certificate"), systemImage: "checkmark.seal") {
					_isAddingCertPresenting = true
				}
			}
		}
	}
	
	private func _actionTile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: systemImage)
					.font(.body.weight(.semibold))
					.foregroundStyle(Color.accentColor)
					.frame(width: 34, height: 34)
					.background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				Text(verbatim: title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
					.minimumScaleFactor(0.8)
				Spacer(minLength: 0)
			}
			.padding(12)
			.background(SignetTheme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
		.buttonStyle(.plain)
	}
	
	private func _pasteLink() {
		let text = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
		guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
			  url.scheme?.hasPrefix("http") == true
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("Paste Link"),
				message: .localized("The clipboard doesn't contain a download link.")
			)
			return
		}
		_download(url.absoluteString)
	}
	
	private func _download(_ string: String) {
		guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else { return }
		_ = _downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
	}
}

// MARK: - Stats & lists
extension HomeView {
	@ViewBuilder
	private func _stats() -> some View {
		HStack(spacing: 10) {
			_statTile(value: _signedApps.count, label: .localized("Signed"), systemImage: "signature")
			_statTile(value: _importedApps.count, label: .localized("Imported"), systemImage: "square.and.arrow.down")
			_statTile(value: _certificates.count, label: .localized("Certificates"), systemImage: "seal")
			_statTile(value: _sources.count, label: .localized("Sources"), systemImage: "globe.desk")
		}
	}
	
	private func _statTile(value: Int, label: String, systemImage: String) -> some View {
		VStack(spacing: 4) {
			Image(systemName: systemImage)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(verbatim: "\(value)")
				.font(.title3.bold().monospacedDigit())
			Text(verbatim: label)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.minimumScaleFactor(0.7)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 12)
		.background(SignetTheme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
	}
	
	@ViewBuilder
	private func _appRow(
		title: String,
		systemImage: String,
		apps: [AppInfoPresentable],
		actionTitle: String,
		action: @escaping (AppInfoPresentable) -> Void
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			_sectionHeader(title, systemImage: systemImage)
			VStack(spacing: 0) {
				ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
					HStack(spacing: 12) {
						FRAppIconView(app: app, size: 44)
						VStack(alignment: .leading, spacing: 2) {
							Text(verbatim: app.name ?? .localized("Unknown"))
								.font(.subheadline.weight(.semibold))
								.lineLimit(1)
							Text(verbatim: [app.version, app.identifier].compactMap { $0 }.joined(separator: " · "))
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						Spacer(minLength: 0)
						Button {
							action(app)
						} label: {
							Text(verbatim: actionTitle)
								.font(.subheadline.bold())
						}
						.buttonStyle(.bordered)
						.buttonBorderShape(.capsule)
					}
					.padding(.horizontal, 14)
					.padding(.vertical, 10)
					
					if index < apps.count - 1 {
						Divider().padding(.leading, 70)
					}
				}
			}
			.background(SignetTheme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
		}
	}
	
	@ViewBuilder
	private func _emptyState() -> some View {
		VStack(spacing: 10) {
			Image(systemName: "shippingbox")
				.font(.system(size: 34))
				.foregroundStyle(.secondary)
			Text(.localized("No apps yet"))
				.font(.headline)
			Text(.localized("Import an IPA, paste a link, or browse your sources to get started."))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(28)
		.background(SignetTheme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
	}
	
	private func _sectionHeader(_ title: String, systemImage: String) -> some View {
		Label {
			Text(verbatim: title)
		} icon: {
			Image(systemName: systemImage)
		}
		.font(.headline)
		.foregroundStyle(.primary)
	}
}
