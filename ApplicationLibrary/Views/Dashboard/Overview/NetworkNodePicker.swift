import Libbox
import Library
import SwiftUI

#if !os(tvOS)
    struct NetworkNodePicker: View {
        @Environment(\.dismiss) private var dismiss

        let groups: [OutboundGroup]
        let pendingSelections: [String: String]
        let onSelect: (_ groupTag: String, _ outboundTag: String) -> Void

        private var selectableGroups: [OutboundGroup] {
            groups.filter(\.selectable)
        }

        var body: some View {
            NavigationView {
                List {
                    ForEach(selectableGroups, id: \.tag) { group in
                        Section(group.tag) {
                            ForEach(group.items, id: \.tag) { item in
                                nodeRow(item, in: group)
                            }
                        }
                    }
                }
                .navigationTitle(String(localized: "Select Node"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done")) {
                            dismiss()
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 440, minHeight: 360, idealHeight: 560)
        }

        private func nodeRow(_ item: OutboundGroupItem, in group: OutboundGroup) -> some View {
            let selected = pendingSelections[group.tag] ?? group.selected

            return Button {
                guard selected != item.tag else { return }
                onSelect(group.tag, item.tag)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.tag)
                            .font(.body.weight(.medium))
                            .foregroundStyle(NetworkDashboardStyle.ink)
                        Text(item.displayType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Text(item.delayString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(NetworkDashboardStyle.connectedInk)
                        .opacity(selected == item.tag ? 1 : 0)
                        .accessibilityHidden(selected != item.tag)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.tag), \(item.displayType), \(item.delayString)")
            .accessibilityValue(selected == item.tag ? String(localized: "Selected") : "")
        }

        static func presentationGroups(from groups: [LibboxOutboundGroup]?) -> [OutboundGroup] {
            guard let groups else { return [] }

            return groups.map { group in
                var items: [OutboundGroupItem] = []
                let iterator = group.getItems()!
                while iterator.hasNext() {
                    let item = iterator.next()!
                    items.append(OutboundGroupItem(
                        tag: item.tag,
                        type: item.type,
                        urlTestTime: Date(timeIntervalSince1970: Double(item.urlTestTime)),
                        urlTestDelay: UInt16(item.urlTestDelay)
                    ))
                }
                return OutboundGroup(
                    tag: group.tag,
                    type: group.type,
                    selected: group.selected,
                    selectable: group.selectable,
                    isExpand: group.isExpand,
                    items: items
                )
            }
        }
    }
#endif
