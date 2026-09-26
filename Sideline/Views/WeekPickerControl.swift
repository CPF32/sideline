import SwiftUI

/// Compact week control — opens scrolled to the currently selected week.
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
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select week")
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
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(weeks, id: \.self) { week in
                        let active = week == appState.selectedWeek
                        Button {
                            appState.selectWeek(week)
                            isPresented = false
                        } label: {
                            Text("Week \(week)")
                                .font(BrandTheme.body(13, weight: active ? .semibold : .regular))
                                .foregroundStyle(BrandTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                        .fill(active ? BrandTheme.accentWash : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                        .stroke(active ? BrandTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(week)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }
            .frame(width: 168, height: 220)
            .onAppear {
                let selected = appState.selectedWeek
                let focus = weeks.contains(selected) ? selected : (weeks.contains(current) ? current : weeks.first)
                guard let focus else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(focus, anchor: .center)
                }
            }
        }
    }
}
