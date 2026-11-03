//
//  SignetTheme.swift
//  Signet
//

import SwiftUI

/// Signet's palette: sealing-wax red on ink, with brass for warnings.
enum SignetTheme {
	static let defaultTintHex = "#C8432F"
	
	static let wax = Color(hex: "#C8432F")
	static let waxDeep = Color(hex: "#7A1A14")
	static let ink = Color(hex: "#1B1F2A")
	static let brass = Color(hex: "#C99A3B")
	static let moss = Color(hex: "#3F8F5A")
	
	/// Card background used across the Home screen
	static var cardFill: Color { Color(uiColor: .secondarySystemGroupedBackground) }
	
	static let waxGradient = LinearGradient(
		colors: [Color(hex: "#D9533C"), Color(hex: "#9E2A20")],
		startPoint: .topLeading,
		endPoint: .bottomTrailing
	)
	
	/// Status color for a number of days left on a certificate
	static func color(daysLeft: Int, revoked: Bool) -> Color {
		if revoked || daysLeft < 0 { return wax }
		if daysLeft <= 7 { return brass }
		return moss
	}
}
