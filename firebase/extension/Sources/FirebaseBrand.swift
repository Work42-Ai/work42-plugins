// FirebaseBrand.swift — Firebase's official product icons and logomark, embedded so widgets and the
// Projects button can show them with no network and no bundle resources (the same approach as
// linear42's Linear42Brand.swift). Foundation only.
//
// Sources, all from Firebase itself:
//   authIconPNG        https://firebase.google.com/static/images/products/icons/build_auth.svg
//   analyticsIconPNG   https://firebase.google.com/static/images/products/icons/run_analytics.svg
//   firestoreIconPNG   https://firebase.google.com/static/images/products/icons/build_firestore.svg
//   crashlyticsIconPNG https://firebase.google.com/static/images/products/icons/run_crashlytics.svg
//   firebaseMarkPNG    https://firebase.google.com/static/downloads/brand-guidelines/SVG/logo-logomark.svg
// (the product icons are the ones on the Build and Run pages of https://firebase.google.com/products-build;
// the logomark is from https://firebase.google.com/brand-guidelines).
//
// Rendered unmodified to 64x64 PNGs with a real alpha channel (transparent corners; the icons are circles)
// by headless Chrome: each SVG in a 64x64 <img> on a transparent page,
//   chrome --headless=new --default-background-color=00000000 --window-size=64,64 --screenshot=<out>.png <page>.html
// The artwork is never redrawn or recoloured. Use is subject to Firebase's brand guidelines.

import Foundation

enum FirebaseBrand {
    /// Authentication, 64x64 PNG with alpha.
    static let authIconPNG: Data = decode(
        """
        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
        """)

    /// Analytics, 64x64 PNG with alpha.
    static let analyticsIconPNG: Data = decode(
        """
        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
        """)

    /// Firestore, 64x64 PNG with alpha.
    static let firestoreIconPNG: Data = decode(
        """
        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
        """)

    /// Crashlytics, 64x64 PNG with alpha.
    static let crashlyticsIconPNG: Data = decode(
        """
        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
        SUVORK5CYII=
        """)

    /// the Firebase logomark (flame), 64x64 PNG with alpha.
    static let firebaseMarkPNG: Data = decode(
        """
        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
        """)

    private static func decode(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
    }
}
