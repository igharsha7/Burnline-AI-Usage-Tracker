//
//  SegmentedChoice.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import SwiftUI

/// A small segmented choice for content, in the dashboard's neutrals rather
/// than the system accent, so provider colours stay the only colour on the
/// page. The selection slides between segments, and the segment under the
/// pointer lifts a little so it reads as clickable.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    @Namespace private var namespace
    @State private var hovered: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.callout.weight(selected ? .medium : .regular))
                        .foregroundStyle(selected || hovered == option.value ? Palette.textPrimary : Palette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.control)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            } else if hovered == option.value {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.control.opacity(0.5))
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        if inside { hovered = option.value } else if hovered == option.value { hovered = nil }
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}
