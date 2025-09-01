//
//  KiaTextFieldStyle.swift
//  KiaMaps
//
//  Created by Lukáš Foldýna on 29/8/25.
//  Copyright © 2025 Apple. All rights reserved.
//

import SwiftUI

struct KiaTextFieldStyle: TextFieldStyle {
    let hasError: Bool
    
    init(hasError: Bool = false) {
        self.hasError = hasError
    }
    
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .padding(KiaDesign.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(KiaDesign.Colors.cardBackground)
                    .stroke(
                        hasError ? KiaDesign.Colors.error : KiaDesign.Colors.textTertiary.opacity(0.2), 
                        lineWidth: hasError ? 2 : 1
                    )
            )
            .font(KiaDesign.Typography.body)
    }
}
