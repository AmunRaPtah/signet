//
//  CertificateMonitor.swift
//  Signet
//

import Foundation
import UserNotifications
import Zsign

/// Local reminders before a signing certificate expires, and a once-a-day revocation check.
final class CertificateMonitor {
	static let shared = CertificateMonitor()
	private init() {}
	
	static let expiryAlertsKey = "Signet.expiryAlerts"
	static let revokeCheckKey = "Signet.dailyRevokeCheck"
	private static let _lastRevokeCheckKey = "Signet.lastRevokeCheck"
	private static let _idPrefix = "signet.cert."
	
	/// Days before expiry at which a reminder fires
	private let _reminderDays = [7, 1]
	
	private var _defaults: UserDefaults { .standard }
	
	private var _expiryAlertsEnabled: Bool {
		_defaults.object(forKey: Self.expiryAlertsKey) as? Bool ?? true
	}
	
	private var _revokeCheckEnabled: Bool {
		_defaults.object(forKey: Self.revokeCheckKey) as? Bool ?? true
	}
	
	// MARK: Launch
	
	/// Called on launch: refresh reminders and run the revocation check if a day has passed.
	func refresh() {
		DispatchQueue.main.async {
			self.rescheduleReminders()
			self.checkRevocationIfDue()
		}
	}
	
	// MARK: Expiry reminders
	
	func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
			DispatchQueue.main.async { completion?(granted) }
		}
	}
	
	func rescheduleReminders() {
		let center = UNUserNotificationCenter.current()
		center.getPendingNotificationRequests { pending in
			let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self._idPrefix) }
			center.removePendingNotificationRequests(withIdentifiers: ours)
			
			DispatchQueue.main.async {
				guard self._expiryAlertsEnabled else { return }
				let certs = Storage.shared.getAllCertificates()
				guard !certs.isEmpty else { return }
				
				self.requestAuthorization { granted in
					guard granted else { return }
					for cert in certs where !cert.revoked {
						self._schedule(for: cert)
					}
				}
			}
		}
	}
	
	private func _schedule(for cert: CertificatePair) {
		guard let expiration = cert.expiration, expiration > .now else { return }
		let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("Your certificate")
		
		for days in _reminderDays {
			guard let fireDate = Calendar.current.date(byAdding: .day, value: -days, to: expiration),
				  fireDate > .now
			else { continue }
			
			let content = UNMutableNotificationContent()
			content.title = days == 1
				? .localized("Certificate expires tomorrow")
				: .localized("Certificate expires in %lld days", arguments: days)
			content.body = .localized("“%@” stops working on %@. Apps signed with it will no longer open, so re-sign them with a new certificate.", arguments: name, expiration.formatted(date: .abbreviated, time: .shortened))
			content.sound = .default
			
			let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
			let request = UNNotificationRequest(
				identifier: "\(Self._idPrefix)\(cert.uuid ?? UUID().uuidString).\(days)",
				content: content,
				trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
			)
			UNUserNotificationCenter.current().add(request)
		}
	}
	
	// MARK: Revocation
	
	var lastRevokeCheck: Date? {
		_defaults.object(forKey: Self._lastRevokeCheckKey) as? Date
	}
	
	func checkRevocationIfDue() {
		guard _revokeCheckEnabled else { return }
		if let last = lastRevokeCheck, Date.now.timeIntervalSince(last) < 86_400 { return }
		checkRevocation()
	}
	
	/// Checks every unrevoked certificate; notifies for any newly revoked one.
	func checkRevocation(completion: ((_ newlyRevoked: [String]) -> Void)? = nil) {
		let certs = Storage.shared.getAllCertificates().filter { !$0.revoked }
		_defaults.set(Date.now, forKey: Self._lastRevokeCheckKey)
		
		guard !certs.isEmpty else {
			completion?([])
			return
		}
		
		let group = DispatchGroup()
		var revoked: [String] = []
		
		for cert in certs {
			guard
				let provision = Storage.shared.getFile(.provision, from: cert)?.path,
				let p12 = Storage.shared.getFile(.certificate, from: cert)?.path
			else { continue }
			
			group.enter()
			Zsign.checkRevokage(
				provisionPath: provision,
				p12Path: p12,
				p12Password: cert.password ?? ""
			) { status, _, _ in
				DispatchQueue.main.async {
					if status == 1 {
						cert.revoked = true
						revoked.append(cert.nickname ?? .localized("Certificate"))
					}
					group.leave()
				}
			}
		}
		
		group.notify(queue: .main) {
			if !revoked.isEmpty {
				Storage.shared.saveContext()
				self._notifyRevoked(revoked)
				self.rescheduleReminders()
			}
			completion?(revoked)
		}
	}
	
	private func _notifyRevoked(_ names: [String]) {
		let content = UNMutableNotificationContent()
		content.title = .localized("Certificate revoked")
		content.body = .localized("Apple revoked %@. Apps signed with it will not open, so import a new certificate and re-sign them.", arguments: names.joined(separator: ", "))
		content.sound = .default
		
		let request = UNNotificationRequest(
			identifier: "signet.revoked.\(UUID().uuidString)",
			content: content,
			trigger: nil
		)
		UNUserNotificationCenter.current().add(request)
	}
}
