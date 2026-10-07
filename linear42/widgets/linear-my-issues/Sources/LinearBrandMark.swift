// LinearBrandMark.swift — the Linear logo as a SwiftUI view, for widget empty / unbound states
// (modelled on the Jira widget's JiraBrandMark). Byte-identical in all four linear42 widgets
// (Tests/LogicTests/run.sh fails on drift). The image is `linearIconPNG` from Linear42Brand.swift;
// if it ever fails to decode, the widget's old SF Symbol stands in so the state never renders blank.

import AppKit
import SwiftUI

struct LinearBrandMark: View {
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let data = linearIconPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
