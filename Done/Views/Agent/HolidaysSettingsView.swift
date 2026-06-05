//
//  HolidaysSettingsView.swift
//  Done
//
//  Toggles for the lightweight calendar date annotations (Chinese 24 solar
//  terms + common Gregorian holidays). See `CalendarAnnotation.swift`.
//

import SwiftUI

struct HolidaysSettingsView: View {
    @AppStorage(AppSettingsKeys.holidaysShowSolarTerms) private var showSolarTerms = true
    @AppStorage(AppSettingsKeys.holidaysShowGregorianHolidays) private var showGregorianHolidays = true

    var body: some View {
        settingsPage(L(.holidaysAndTerms)) {
            settingsCard {
                Toggle(L(.solarTerms24), isOn: $showSolarTerms)
                Toggle(L(.gregorianHolidays), isOn: $showGregorianHolidays)
            }

            settingsHintCard(L(.hintHolidays))
        }
    }
}
