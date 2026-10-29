import PSTCore
import SwiftUI

/// The row above the message list: folder name, search box, sort menu.
struct MessageListHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 12) {
            Text(model.scopeTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(model.scopeTitle)

            SearchField()
                .frame(minWidth: 150, idealWidth: 260, maxWidth: 320)

            Spacer(minLength: 0)

            // A menu labelled with the full sort name, kept at its natural width so it never truncates.
            Menu {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(MessageSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(model.sortOrder.title)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .layoutPriority(2)
            .help("Sort order")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A rounded search box with a clear button and, on its right, the advanced-search button.
struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.runSearch(debounce: false) }
                .onExitCommand { model.searchText = "" }

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }

            Button {
                model.openAdvancedSearch()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Show search options (⌥⌘F)")
            .accessibilityLabel("Show search options")
            .popover(isPresented: $model.showAdvancedSearch, arrowEdge: .bottom) {
                AdvancedSearchView()
                    .environment(model)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// Gmail-style search options. Search writes the fields back into the search box as text
/// (from:, subject:, larger:, after: …), so the box always shows exactly what's being searched.
struct AdvancedSearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow { label("From"); textField("From", $model.searchForm.from) }
                GridRow { label("To"); textField("To", $model.searchForm.to) }
                GridRow { label("Subject"); textField("Subject", $model.searchForm.subject) }
                GridRow { label("Has the words"); textField("Has the words", $model.searchForm.hasWords) }
                GridRow { label("Doesn’t have"); textField("Doesn’t have", $model.searchForm.doesntHave) }

                GridRow {
                    label("Size")
                    HStack(spacing: 8) {
                        Picker("Size comparison", selection: $model.searchForm.sizeComparison) {
                            ForEach(SearchForm.SizeComparison.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("", text: $model.searchForm.sizeValue)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Size")
                        Picker("Size unit", selection: $model.searchForm.sizeUnit) {
                            ForEach(SearchForm.SizeUnit.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                GridRow {
                    label("Date within")
                    HStack(spacing: 8) {
                        Picker("Date range", selection: $model.searchForm.dateRange) {
                            ForEach(SearchForm.DateRange.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("of")
                            .foregroundStyle(.secondary)
                        TextField("Any date", text: $model.searchForm.dateText)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Date")
                        Button {
                            model.showDatePicker = true
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .buttonStyle(.borderless)
                        .help("Choose a date")
                        .accessibilityLabel("Choose a date")
                        .popover(isPresented: $model.showDatePicker, arrowEdge: .bottom) {
                            DatePicker("Date", selection: Binding(
                                get: { model.searchForm.date ?? Date() },
                                set: { model.searchForm.setDate($0); model.showDatePicker = false }
                            ), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(12)
                        }
                    }
                }

                GridRow {
                    label("Search")
                    Picker("Search in", selection: $model.searchFormScope) {
                        ForEach(model.searchScopes) { scope in
                            Text(scope.title).tag(scope.item)
                        }
                    }
                    .labelsHidden()
                }
            }

            Toggle("Has attachment", isOn: $model.searchForm.hasAttachment)

            if model.searchForm.dateIsInvalid {
                Text("That date isn’t recognized. Try a date like 3/15/2019 or 2019-03-15.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Clear") { model.clearSearchForm() }
                Button("Search") { model.applySearchForm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.searchForm.dateIsInvalid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 540)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private func textField(_ title: String, _ text: Binding<String>) -> some View {
        TextField("", text: text)
            .accessibilityLabel(title)
            .onSubmit { model.applySearchForm() }
    }
}
