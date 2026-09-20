import SwiftUI

/// Compact week control — previous week visible above current, futures below.
struct WeekPickerControl: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text("WEEK \(appState.selectedWeek)")
                    .font(BrandTheme.display(12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(BrandTheme.ink)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            weekList
                .presentationCompactAdaptation(.popover)
        }
    }

    private var weekList: some View {
        let current = appState.currentSeasonWeek
        let weeks = appState.availableWeeks
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(weeks, id: \.self) { week in
                        Button {
                            appState.selectWeek(week)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Text("Week \(week)")
                                    .font(BrandTheme.body(13, weight: week == appState.selectedWeek ? .semibold : .regular))
                                    .foregroundStyle(BrandTheme.ink)
                                Spacer(minLength: 4)
                                if week == appState.selectedWeek {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(BrandTheme.muted)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(week)

                        if week != weeks.last {
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .frame(width: 168, height: 196)
            .onAppear {
                // Show the week before current at the top (when possible), with current just below.
                let focus = weeks.contains(current) ? current : appState.selectedWeek
                let topVisible = focus > 1 ? focus - 1 : focus
                DispatchQueue.main.async {
                    proxy.scrollTo(topVisible, anchor: .top)
                }
            }
        }
    }
}
