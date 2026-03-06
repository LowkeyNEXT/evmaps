//
//  PorscheVehicleMapper.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

enum PorscheVehicleMapper {
    static func map(summary: PorscheVehicleSummary) -> PorscheVehicleSnapshot {
        PorscheVehicleSnapshot(
            vin: summary.vin,
            batterySoc: summary.batterySoc ?? 0,
            rangeKm: summary.rangeKm ?? 0,
            charging: summary.charging ?? false,
            locked: summary.locked ?? false,
            latitude: summary.latitude,
            longitude: summary.longitude,
            capabilities: .init(
                canLock: summary.capabilities?.canLock ?? false,
                canClimatise: summary.capabilities?.canClimatise ?? false,
                canCharge: summary.capabilities?.canCharge ?? false
            )
        )
    }

}
